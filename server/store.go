package main

import (
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
	"time"

	bolt "go.etcd.io/bbolt"
)

var (
	errQuota       = errors.New("quota_exceeded")
	errAccountsMax = errors.New("accounts_limit")
	errNotFound    = errors.New("not_found")
)

var (
	bucketAccounts = []byte("accounts") // SHA-256(authToken) -> account id (16 bytes)
	bucketMeta     = []byte("meta")     // "seq", "bytes", "created"
	bucketRecords  = []byte("rec")      // kind ":" id -> seq(8) flags(1) data (tombstones too)
	bucketLog      = []byte("log")      // seq(8) -> kind ":" id
	bucketBlobs    = []byte("blob")     // id -> size(8) created(8)
	keySeq         = []byte("seq")
	keyBytes       = []byte("bytes")
	keyCreated     = []byte("created")
)

const flagDeleted = 1

// Store keeps all accounts in one bbolt file and blobs as files.
type Store struct {
	db      *bolt.DB
	blobDir string

	mu      sync.Mutex
	waiters map[string]chan struct{}
}

type Change struct {
	Kind    string `json:"kind"`
	ID      string `json:"id"`
	Seq     uint64 `json:"seq"`
	Deleted bool   `json:"deleted"`
	Data    []byte `json:"data,omitempty"`
}

type ChangeIn struct {
	Kind    string `json:"kind"`
	ID      string `json:"id"`
	Base    uint64 `json:"base"`
	Deleted bool   `json:"deleted"`
	Data    []byte `json:"data,omitempty"`
}

type Result struct {
	Kind     string `json:"kind"`
	ID       string `json:"id"`
	Seq      uint64 `json:"seq"`
	Conflict bool   `json:"conflict,omitempty"`
}

type BlobInfo struct {
	ID      string `json:"id"`
	Size    int64  `json:"size"`
	Created int64  `json:"created"`
}

type AccountInfo struct {
	Seq   uint64 `json:"seq"`
	Bytes int64  `json:"bytes"`
}

func openStore(dbPath, blobDir string) (*Store, error) {
	if err := os.MkdirAll(blobDir, 0o700); err != nil {
		return nil, err
	}
	db, err := bolt.Open(dbPath, 0o600, &bolt.Options{Timeout: 2 * time.Second})
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", dbPath, err)
	}
	err = db.Update(func(tx *bolt.Tx) error {
		_, err := tx.CreateBucketIfNotExists(bucketAccounts)
		return err
	})
	if err != nil {
		db.Close()
		return nil, err
	}
	// A stop during PutBlob can leave its temp file. Remove these files.
	tmp, _ := filepath.Glob(filepath.Join(blobDir, "*", ".upload-*"))
	for _, f := range tmp {
		_ = os.Remove(f)
	}
	return &Store{db: db, blobDir: blobDir, waiters: map[string]chan struct{}{}}, nil
}

func (s *Store) Close() error { return s.db.Close() }

func accountBucketName(acct string) []byte { return []byte("a:" + acct) }

func u64(b []byte) uint64 {
	if len(b) != 8 {
		return 0
	}
	return binary.BigEndian.Uint64(b)
}

func putU64(v uint64) []byte {
	b := make([]byte, 8)
	binary.BigEndian.PutUint64(b, v)
	return b
}

// Lookup returns the account id for a token hash.
func (s *Store) Lookup(tokenHash []byte) (string, bool) {
	var acct string
	_ = s.db.View(func(tx *bolt.Tx) error {
		if v := tx.Bucket(bucketAccounts).Get(tokenHash); v != nil {
			acct = hex.EncodeToString(v)
		}
		return nil
	})
	return acct, acct != ""
}

// CreateAccount creates an account for tokenHash. It reports false if it already exists.
func (s *Store) CreateAccount(tokenHash []byte, maxAccounts int) (bool, error) {
	created := false
	err := s.db.Update(func(tx *bolt.Tx) error {
		accounts := tx.Bucket(bucketAccounts)
		if accounts.Get(tokenHash) != nil {
			return nil
		}
		if maxAccounts > 0 && accounts.Stats().KeyN >= maxAccounts {
			return errAccountsMax
		}
		id := make([]byte, 16)
		if _, err := rand.Read(id); err != nil {
			return err
		}
		b, err := tx.CreateBucket(accountBucketName(hex.EncodeToString(id)))
		if err != nil {
			return err
		}
		for _, name := range [][]byte{bucketMeta, bucketRecords, bucketLog, bucketBlobs} {
			if _, err := b.CreateBucket(name); err != nil {
				return err
			}
		}
		if err := b.Bucket(bucketMeta).Put(keyCreated, putU64(uint64(time.Now().Unix()))); err != nil {
			return err
		}
		created = true
		return accounts.Put(tokenHash, id)
	})
	return created, err
}

// DeleteAccount removes the account, its records and its blobs.
func (s *Store) DeleteAccount(tokenHash []byte, acct string) error {
	err := s.db.Update(func(tx *bolt.Tx) error {
		if err := tx.Bucket(bucketAccounts).Delete(tokenHash); err != nil {
			return err
		}
		err := tx.DeleteBucket(accountBucketName(acct))
		if errors.Is(err, bolt.ErrBucketNotFound) {
			return nil
		}
		return err
	})
	if err != nil {
		return err
	}
	s.notify(acct)
	return os.RemoveAll(filepath.Join(s.blobDir, acct))
}

func (s *Store) Info(acct string) (AccountInfo, error) {
	var info AccountInfo
	err := s.db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket(accountBucketName(acct))
		if b == nil {
			return errNotFound
		}
		meta := b.Bucket(bucketMeta)
		info.Seq = u64(meta.Get(keySeq))
		info.Bytes = int64(u64(meta.Get(keyBytes)))
		return nil
	})
	return info, err
}

// Changes returns the newest version of each record with seq > since, in seq order.
func (s *Store) Changes(acct string, since uint64, limit int, maxBytes int) ([]Change, uint64, bool, error) {
	var (
		out   []Change
		last  = since
		more  bool
		total int
	)
	err := s.db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket(accountBucketName(acct))
		if b == nil {
			return errNotFound
		}
		recs := b.Bucket(bucketRecords)
		c := b.Bucket(bucketLog).Cursor()
		for k, v := c.Seek(putU64(since + 1)); k != nil; k, v = c.Next() {
			if len(out) >= limit || (len(out) > 0 && total >= maxBytes) {
				more = true
				break
			}
			rec := recs.Get(v)
			if len(rec) < 9 {
				continue
			}
			kind, id := splitKey(v)
			ch := Change{Kind: kind, ID: id, Seq: u64(k), Deleted: rec[8]&flagDeleted != 0}
			// Tombstones from 1.0.0 have no data; clients do not apply those.
			if len(rec) > 9 {
				ch.Data = append([]byte(nil), rec[9:]...)
			}
			total += len(ch.Data)
			out = append(out, ch)
			last = ch.Seq
		}
		return nil
	})
	return out, last, more, err
}

func splitKey(k []byte) (kind, id string) {
	for i, c := range k {
		if c == ':' {
			return string(k[:i]), string(k[i+1:])
		}
	}
	return "", string(k)
}

// Apply writes changes in one transaction. A change whose base differs from the
// stored seq is not written and is returned as a conflict.
func (s *Store) Apply(acct string, changes []ChangeIn, maxAccountBytes int64) ([]Result, error) {
	results := make([]Result, 0, len(changes))
	written := false
	err := s.db.Update(func(tx *bolt.Tx) error {
		b := tx.Bucket(accountBucketName(acct))
		if b == nil {
			return errNotFound
		}
		meta, recs, logb := b.Bucket(bucketMeta), b.Bucket(bucketRecords), b.Bucket(bucketLog)
		seq := u64(meta.Get(keySeq))
		used := int64(u64(meta.Get(keyBytes)))
		for _, ch := range changes {
			key := []byte(ch.Kind + ":" + ch.ID)
			var curSeq uint64
			var curSize int64
			if cur := recs.Get(key); len(cur) >= 9 {
				curSeq = u64(cur[:8])
				curSize = int64(len(cur) - 9)
				if ch.Base != curSeq {
					results = append(results, Result{Kind: ch.Kind, ID: ch.ID, Seq: curSeq, Conflict: true})
					continue
				}
				if err := logb.Delete(putU64(curSeq)); err != nil {
					return err
				}
			}
			seq++
			// A tombstone keeps its sealed data: clients delete only what opens as a deletion.
			var flags byte
			data := ch.Data
			if ch.Deleted {
				flags = flagDeleted
			}
			used += int64(len(data)) - curSize
			val := make([]byte, 9+len(data))
			copy(val, putU64(seq))
			val[8] = flags
			copy(val[9:], data)
			if err := recs.Put(key, val); err != nil {
				return err
			}
			if err := logb.Put(putU64(seq), key); err != nil {
				return err
			}
			results = append(results, Result{Kind: ch.Kind, ID: ch.ID, Seq: seq})
			written = true
		}
		if maxAccountBytes > 0 && used > maxAccountBytes {
			return errQuota
		}
		if used < 0 {
			used = 0
		}
		if err := meta.Put(keySeq, putU64(seq)); err != nil {
			return err
		}
		return meta.Put(keyBytes, putU64(uint64(used)))
	})
	if err != nil {
		return nil, err
	}
	if written {
		s.notify(acct)
	}
	return results, nil
}

func (s *Store) blobPath(acct, id string) string { return filepath.Join(s.blobDir, acct, id) }

func (s *Store) BlobExists(acct, id string) bool {
	exists := false
	_ = s.db.View(func(tx *bolt.Tx) error {
		if b := tx.Bucket(accountBucketName(acct)); b != nil {
			exists = b.Bucket(bucketBlobs).Get([]byte(id)) != nil
		}
		return nil
	})
	return exists
}

// Missing returns the ids that are not stored.
func (s *Store) Missing(acct string, ids []string) ([]string, error) {
	missing := []string{}
	err := s.db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket(accountBucketName(acct))
		if b == nil {
			return errNotFound
		}
		blobs := b.Bucket(bucketBlobs)
		for _, id := range ids {
			if blobs.Get([]byte(id)) == nil {
				missing = append(missing, id)
			}
		}
		return nil
	})
	return missing, err
}

func (s *Store) ListBlobs(acct string) ([]BlobInfo, error) {
	list := []BlobInfo{}
	err := s.db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket(accountBucketName(acct))
		if b == nil {
			return errNotFound
		}
		return b.Bucket(bucketBlobs).ForEach(func(k, v []byte) error {
			if len(v) == 16 {
				list = append(list, BlobInfo{ID: string(k), Size: int64(u64(v[:8])), Created: int64(u64(v[8:]))})
			}
			return nil
		})
	})
	return list, err
}

// PutBlob stores exactly size bytes from r. It keeps an existing blob.
func (s *Store) PutBlob(acct, id string, size int64, r io.Reader, maxAccountBytes int64) error {
	if s.BlobExists(acct, id) {
		return nil
	}
	if maxAccountBytes > 0 {
		info, err := s.Info(acct)
		if err != nil {
			return err
		}
		if info.Bytes+size > maxAccountBytes {
			return errQuota
		}
	}
	dir := filepath.Join(s.blobDir, acct)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".upload-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	n, err := io.Copy(tmp, io.LimitReader(r, size+1))
	if err == nil && n != size {
		err = io.ErrUnexpectedEOF
	}
	if err == nil {
		err = tmp.Sync()
	}
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return err
	}

	err = s.db.Update(func(tx *bolt.Tx) error {
		b := tx.Bucket(accountBucketName(acct))
		if b == nil {
			return errNotFound
		}
		blobs, meta := b.Bucket(bucketBlobs), b.Bucket(bucketMeta)
		if blobs.Get([]byte(id)) != nil {
			return nil
		}
		used := int64(u64(meta.Get(keyBytes))) + size
		if maxAccountBytes > 0 && used > maxAccountBytes {
			return errQuota
		}
		if err := os.Rename(tmp.Name(), s.blobPath(acct, id)); err != nil {
			return err
		}
		v := make([]byte, 16)
		binary.BigEndian.PutUint64(v, uint64(size))
		binary.BigEndian.PutUint64(v[8:], uint64(time.Now().Unix()))
		if err := blobs.Put([]byte(id), v); err != nil {
			return err
		}
		return meta.Put(keyBytes, putU64(uint64(used)))
	})
	return err
}

func (s *Store) OpenBlob(acct, id string) (*os.File, error) {
	if !s.BlobExists(acct, id) {
		return nil, errNotFound
	}
	return os.Open(s.blobPath(acct, id))
}

func (s *Store) DeleteBlob(acct, id string) error {
	err := s.db.Update(func(tx *bolt.Tx) error {
		b := tx.Bucket(accountBucketName(acct))
		if b == nil {
			return errNotFound
		}
		blobs, meta := b.Bucket(bucketBlobs), b.Bucket(bucketMeta)
		v := blobs.Get([]byte(id))
		if len(v) != 16 {
			return errNotFound
		}
		used := int64(u64(meta.Get(keyBytes))) - int64(u64(v[:8]))
		if used < 0 {
			used = 0
		}
		if err := blobs.Delete([]byte(id)); err != nil {
			return err
		}
		return meta.Put(keyBytes, putU64(uint64(used)))
	})
	if err != nil {
		return err
	}
	if err := os.Remove(s.blobPath(acct, id)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

// wait returns a channel that is closed on the next change of acct.
func (s *Store) wait(acct string) <-chan struct{} {
	s.mu.Lock()
	defer s.mu.Unlock()
	ch, ok := s.waiters[acct]
	if !ok {
		ch = make(chan struct{})
		s.waiters[acct] = ch
	}
	return ch
}

func (s *Store) notify(acct string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if ch, ok := s.waiters[acct]; ok {
		close(ch)
		delete(s.waiters, acct)
	}
}

func (s *Store) wakeAll() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for acct, ch := range s.waiters {
		close(ch)
		delete(s.waiters, acct)
	}
}
