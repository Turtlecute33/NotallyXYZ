package core

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	bolt "go.etcd.io/bbolt"
)

// Record is one record in the local cache, sealed exactly as on the server.
type Record struct {
	Kind    string `json:"-"`
	ID      string `json:"-"`
	Seq     int64  `json:"seq"`
	Sealed  []byte `json:"sealed,omitempty"`
	Deleted bool   `json:"deleted,omitempty"`
	// 0 = in sync, otherwise a counter value of the last local change.
	Dirty int64 `json:"dirty,omitempty"`
	// Sealed server version at Seq: the base of a three-way merge.
	Base []byte `json:"base,omitempty"`
}

// Pending is a remote version held back while its note is open in an editor.
// Sealed is nil for a verified deletion.
type Pending struct {
	Seq    int64  `json:"seq"`
	Sealed []byte `json:"sealed,omitempty"`
}

type blobRow struct {
	Uploaded bool  `json:"uploaded"`
	Created  int64 `json:"created"`
}

var (
	bRecords = []byte("records")
	bPending = []byte("pending")
	bBlobs   = []byte("blobs")
	bMeta    = []byte("meta")
)

// LocalStore is the encrypted local cache: records stay sealed, blobs are sealed files.
// Not safe for concurrent use; NoteStore serialises access.
type LocalStore struct {
	BlobDir string
	db      *bolt.DB
	dirty   int64
}

func OpenLocalStore(dir string) (*LocalStore, error) {
	blobDir := filepath.Join(dir, "blobs")
	if err := os.MkdirAll(blobDir, 0o700); err != nil {
		return nil, err
	}
	_ = os.Chmod(dir, 0o700)
	db, err := bolt.Open(filepath.Join(dir, "cache.db"), 0o600, &bolt.Options{Timeout: 2 * time.Second})
	if err != nil {
		return nil, err
	}
	s := &LocalStore{BlobDir: blobDir, db: db}
	err = db.Update(func(tx *bolt.Tx) error {
		for _, name := range [][]byte{bRecords, bPending, bBlobs, bMeta} {
			if _, err := tx.CreateBucketIfNotExists(name); err != nil {
				return err
			}
		}
		return tx.Bucket(bRecords).ForEach(func(_, v []byte) error {
			var r Record
			if json.Unmarshal(v, &r) == nil && r.Dirty > s.dirty {
				s.dirty = r.Dirty
			}
			return nil
		})
	})
	if err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

func (s *LocalStore) Close() error { return s.db.Close() }

// Tx is one read-write transaction.
type Tx struct {
	s  *LocalStore
	tx *bolt.Tx
}

func (s *LocalStore) Update(fn func(*Tx) error) error {
	return s.db.Update(func(tx *bolt.Tx) error { return fn(&Tx{s, tx}) })
}

func (s *LocalStore) View(fn func(*Tx) error) error {
	return s.db.View(func(tx *bolt.Tx) error { return fn(&Tx{s, tx}) })
}

func recordKey(kind, id string) []byte { return []byte(kind + ":" + id) }

func decodeRecord(k, v []byte) (Record, bool) {
	var r Record
	if json.Unmarshal(v, &r) != nil {
		return r, false
	}
	r.Kind, r.ID, _ = strings.Cut(string(k), ":")
	return r, true
}

// Record returns the record or nil.
func (t *Tx) Record(kind, id string) *Record {
	v := t.tx.Bucket(bRecords).Get(recordKey(kind, id))
	if v == nil {
		return nil
	}
	r, ok := decodeRecord(recordKey(kind, id), v)
	if !ok {
		return nil
	}
	return &r
}

func (t *Tx) Records() []Record {
	var out []Record
	_ = t.tx.Bucket(bRecords).ForEach(func(k, v []byte) error {
		if r, ok := decodeRecord(k, v); ok {
			out = append(out, r)
		}
		return nil
	})
	return out
}

func (t *Tx) Put(r Record) error {
	v, err := json.Marshal(r)
	if err != nil {
		return err
	}
	return t.tx.Bucket(bRecords).Put(recordKey(r.Kind, r.ID), v)
}

func (t *Tx) DeleteRow(kind, id string) error {
	return t.tx.Bucket(bRecords).Delete(recordKey(kind, id))
}

func (t *Tx) NextDirty() int64 {
	t.s.dirty++
	return t.s.dirty
}

// PutLocal stores a local change (sealed nil = deleted). The server seq stays as the base for the next push.
func (t *Tx) PutLocal(kind, id string, sealed []byte) error {
	r := Record{Kind: kind, ID: id, Sealed: sealed, Deleted: sealed == nil, Dirty: t.NextDirty()}
	if cur := t.Record(kind, id); cur != nil {
		r.Seq, r.Base = cur.Seq, cur.Base
	}
	return t.Put(r)
}

// MarkPushed: the pushed version becomes the base. Keeps the record dirty if it changed meanwhile.
func (t *Tx) MarkPushed(kind, id string, seq, dirty int64, pushed []byte) error {
	r := t.Record(kind, id)
	if r == nil {
		return nil
	}
	r.Seq, r.Base = seq, pushed
	if r.Dirty == dirty {
		r.Dirty = 0
	}
	return t.Put(*r)
}

// SetServerVersion records the server version while the local change stays pending.
func (t *Tx) SetServerVersion(kind, id string, seq int64, base []byte) error {
	r := t.Record(kind, id)
	if r == nil {
		return nil
	}
	r.Seq, r.Base = seq, base
	return t.Put(*r)
}

// UnsyncedNoteIDs are notes that were never pushed and have local changes.
func (t *Tx) UnsyncedNoteIDs() map[string]bool {
	out := map[string]bool{}
	for _, r := range t.Records() {
		if r.Kind == "note" && r.Seq == 0 && r.Dirty > 0 && !r.Deleted {
			out[r.ID] = true
		}
	}
	return out
}

func (t *Tx) PutPending(id string, p Pending) error {
	b := t.tx.Bucket(bPending)
	if cur := b.Get([]byte(id)); cur != nil {
		var old Pending
		if json.Unmarshal(cur, &old) == nil && old.Seq >= p.Seq {
			return nil
		}
	}
	v, _ := json.Marshal(p)
	return b.Put([]byte(id), v)
}

func (t *Tx) TakePending(id string) *Pending {
	b := t.tx.Bucket(bPending)
	v := b.Get([]byte(id))
	if v == nil {
		return nil
	}
	var p Pending
	ok := json.Unmarshal(v, &p) == nil
	_ = b.Delete([]byte(id))
	if !ok {
		return nil
	}
	return &p
}

func (t *Tx) PendingIDs() map[string]bool {
	out := map[string]bool{}
	_ = t.tx.Bucket(bPending).ForEach(func(k, _ []byte) error {
		out[string(k)] = true
		return nil
	})
	return out
}

func (t *Tx) Meta(key string) string { return string(t.tx.Bucket(bMeta).Get([]byte(key))) }

func (t *Tx) SetMeta(key, value string) error {
	return t.tx.Bucket(bMeta).Put([]byte(key), []byte(value))
}

func (t *Tx) Cursor() int64 {
	n, _ := strconv.ParseInt(t.Meta("cursor"), 10, 64)
	return n
}

func (t *Tx) SetCursor(seq int64) error { return t.SetMeta("cursor", strconv.FormatInt(seq, 10)) }

// Blobs

func (s *LocalStore) BlobPath(id string) string { return filepath.Join(s.BlobDir, id) }

func (s *LocalStore) HasBlob(id string) bool {
	_, err := os.Stat(s.BlobPath(id))
	return err == nil
}

func (t *Tx) AddBlob(id string, uploaded bool) error {
	v, _ := json.Marshal(blobRow{Uploaded: uploaded, Created: time.Now().Unix()})
	return t.tx.Bucket(bBlobs).Put([]byte(id), v)
}

func (t *Tx) blobs() map[string]blobRow {
	out := map[string]blobRow{}
	_ = t.tx.Bucket(bBlobs).ForEach(func(k, v []byte) error {
		var b blobRow
		if json.Unmarshal(v, &b) == nil {
			out[string(k)] = b
		}
		return nil
	})
	return out
}

func (t *Tx) PendingBlobs() []string {
	var out []string
	for id, b := range t.blobs() {
		if !b.Uploaded {
			out = append(out, id)
		}
	}
	return out
}

func (t *Tx) MarkUploaded(id string) error { return t.AddBlob(id, true) }

// PruneBlobs removes local blob files that no note references and that are on the server.
func (t *Tx) PruneBlobs(referenced map[string]bool) error {
	for id, b := range t.blobs() {
		if b.Uploaded && !referenced[id] {
			if err := os.Remove(t.s.BlobPath(id)); err != nil && !errors.Is(err, os.ErrNotExist) {
				continue
			}
			if err := t.tx.Bucket(bBlobs).Delete([]byte(id)); err != nil {
				return err
			}
		}
	}
	return nil
}
