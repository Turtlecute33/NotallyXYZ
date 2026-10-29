package core

import (
	"crypto/rand"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf16"
)

// NoteStore holds the decrypted notes and labels in memory, backed by the sealed local cache.
// All methods are safe for concurrent use. Callbacks run without the lock held.
type NoteStore struct {
	Keys  Keys
	local *LocalStore

	mu          sync.Mutex
	notes       map[string]Note
	labels      map[string]Label
	openEditors map[string]bool
	cache       blobCache

	// OnChange runs after notes or labels changed for any reason.
	OnChange func()
	// OnLocalChange runs after a local change that waits for a push.
	OnLocalChange func()
}

type memOp struct {
	note   *Note
	label  *Label
	remove string // "note:<id>" or "label:<id>"
}

func OpenNoteStore(dir string, keys Keys) (*NoteStore, error) {
	local, err := OpenLocalStore(dir)
	if err != nil {
		return nil, err
	}
	s := &NoteStore{Keys: keys, local: local, notes: map[string]Note{}, labels: map[string]Label{},
		openEditors: map[string]bool{}, cache: blobCache{max: 64 << 20}}
	var pending map[string]bool
	_ = local.View(func(tx *Tx) error {
		for _, r := range tx.Records() {
			if !r.Deleted && r.Sealed != nil {
				s.loadIntoMemory(r.Kind, r.ID, r.Sealed)
			}
		}
		pending = tx.PendingIDs()
		return nil
	})
	// Remote versions held back for an editor when the app quit.
	for id := range pending {
		s.applyPending(id)
	}
	return s, nil
}

func (s *NoteStore) Close() error { return s.local.Close() }

func (s *NoteStore) loadIntoMemory(kind, id string, sealed []byte) {
	plain, err := s.Keys.Open(kind, id, sealed)
	if err != nil {
		return
	}
	switch kind {
	case "note":
		if n, ok := DecodeNote(id, plain); ok {
			s.notes[id] = n
		}
	case "label":
		if l, ok := DecodeLabel(id, plain); ok {
			s.labels[id] = l
		}
	}
}

func (s *NoteStore) emit(local bool) {
	if s.OnChange != nil {
		s.OnChange()
	}
	if local && s.OnLocalChange != nil {
		s.OnLocalChange()
	}
}

// Queries

// Notes returns all notes; NextReminder is set for the UI.
func (s *NoteStore) Notes() []Note {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	out := make([]Note, 0, len(s.notes))
	for _, n := range s.notes {
		if next, ok := NextReminder(n, now); ok {
			n.NextReminder = next.UnixMilli()
		}
		out = append(out, n)
	}
	return out
}

func (s *NoteStore) Note(id string) (Note, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	n, ok := s.notes[id]
	return n, ok
}

// Labels in the NotallyX drawer order: order descending, then name.
func (s *NoteStore) Labels() []Label {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]Label, 0, len(s.labels))
	for _, l := range s.labels {
		out = append(out, l)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Order != out[j].Order {
			return out[i].Order > out[j].Order
		}
		return out[i].Value < out[j].Value
	})
	return out
}

// Local changes

func (s *NoteStore) sealNote(n Note) []byte   { return s.Keys.Seal("note", n.ID, EncodeNote(n)) }
func (s *NoteStore) sealLabel(l Label) []byte { return s.Keys.Seal("label", l.ID, EncodeLabel(l)) }

// maxBodyLength is the longest body that Android can store, in UTF-16 units (PROTOCOL.md §5).
const maxBodyLength = 393_216

func utf16Len(s string) int {
	n := 0
	for _, r := range s {
		n += utf16.RuneLen(r)
	}
	return n
}

func (s *NoteStore) Save(n Note) error {
	if !isValidID(n.ID) {
		return fmt.Errorf("invalid note id")
	}
	n.normalize()
	s.mu.Lock()
	old, ok := s.notes[n.ID]
	if ok && old.Equal(n) {
		s.mu.Unlock()
		return nil
	}
	// Only a body that grows past the limit is refused. Other changes of a longer note are saved.
	if size := utf16Len(n.Body); size > maxBodyLength && (!ok || size > utf16Len(old.Body)) {
		s.mu.Unlock()
		return fmt.Errorf("The text is longer than %d characters.", maxBodyLength)
	}
	err := s.local.Update(func(tx *Tx) error {
		if err := tx.PutLocal("note", n.ID, s.sealNote(n)); err != nil {
			return err
		}
		for _, name := range n.Labels {
			if err := s.createLabel(tx, name); err != nil {
				return err
			}
		}
		return nil
	})
	if err == nil {
		s.notes[n.ID] = n
	}
	s.mu.Unlock()
	if err == nil {
		s.emit(true)
	}
	return err
}

func (s *NoteStore) DeleteForever(ids ...string) error {
	s.mu.Lock()
	var removed []string
	err := s.local.Update(func(tx *Tx) error {
		for _, id := range ids {
			if _, ok := s.notes[id]; !ok {
				continue
			}
			if err := tx.PutLocal("note", id, nil); err != nil {
				return err
			}
			removed = append(removed, id)
		}
		return nil
	})
	if err == nil {
		for _, id := range removed {
			delete(s.notes, id)
		}
	}
	s.mu.Unlock()
	if err == nil && len(removed) > 0 {
		s.emit(true)
	}
	return err
}

func (s *NoteStore) EmptyBin() error {
	s.mu.Lock()
	var ids []string
	for id, n := range s.notes {
		if n.Folder == FolderDeleted {
			ids = append(ids, id)
		}
	}
	s.mu.Unlock()
	return s.DeleteForever(ids...)
}

func (s *NoteStore) Duplicate(id string) (Note, error) {
	original, ok := s.Note(id)
	if !ok {
		return Note{}, fmt.Errorf("note not found")
	}
	c := original
	c.ID = RandomID()
	c.Title = "Copy"
	if original.Title != "" {
		c.Title = original.Title + " (Copy)"
	}
	c.Timestamp = Now()
	c.ModifiedTimestamp = c.Timestamp
	c.Reminders = nil
	c.Labels = append([]string{}, original.Labels...)
	return c, s.Save(c)
}

// Labels

func (s *NoteStore) createLabel(tx *Tx, value string) error {
	value = strings.TrimSpace(value)
	if value == "" {
		return nil
	}
	id := s.Keys.LabelID(value)
	if _, ok := s.labels[id]; ok {
		return nil
	}
	order := -1
	for _, l := range s.labels {
		order = max(order, l.Order)
	}
	l := Label{ID: id, Value: value, Order: order + 1}
	if err := tx.PutLocal("label", id, s.sealLabel(l)); err != nil {
		return err
	}
	s.labels[id] = l
	return nil
}

func (s *NoteStore) CreateLabel(value string) error {
	s.mu.Lock()
	err := s.local.Update(func(tx *Tx) error { return s.createLabel(tx, value) })
	s.mu.Unlock()
	if err == nil {
		s.emit(true)
	}
	return err
}

// RenameLabel renames the label in every note, like NotallyX CommonDao.updateLabel.
func (s *NoteStore) RenameLabel(old, value string) error {
	value = strings.TrimSpace(value)
	s.mu.Lock()
	oldLabel, ok := s.labels[s.Keys.LabelID(old)]
	if value == "" || value == old || !ok {
		s.mu.Unlock()
		return nil
	}
	err := s.local.Update(func(tx *Tx) error {
		id := s.Keys.LabelID(value)
		if _, exists := s.labels[id]; !exists {
			l := Label{ID: id, Value: value, Order: oldLabel.Order}
			if err := tx.PutLocal("label", id, s.sealLabel(l)); err != nil {
				return err
			}
			s.labels[id] = l
		}
		if err := tx.PutLocal("label", oldLabel.ID, nil); err != nil {
			return err
		}
		delete(s.labels, oldLabel.ID)
		return s.relabel(tx, old, value)
	})
	s.mu.Unlock()
	s.emit(true)
	return err
}

// DeleteLabel removes the label from every note, like NotallyX CommonDao.deleteLabel.
func (s *NoteStore) DeleteLabel(value string) error {
	s.mu.Lock()
	err := s.local.Update(func(tx *Tx) error {
		id := s.Keys.LabelID(value)
		if _, ok := s.labels[id]; ok {
			if err := tx.PutLocal("label", id, nil); err != nil {
				return err
			}
			delete(s.labels, id)
		}
		return s.relabel(tx, value, "")
	})
	s.mu.Unlock()
	s.emit(true)
	return err
}

// relabel replaces (or with "" removes) a label in all notes.
func (s *NoteStore) relabel(tx *Tx, old, value string) error {
	for id, n := range s.notes {
		found := false
		var labels []string
		for _, l := range n.Labels {
			if l == old {
				found = true
				l = value
			}
			if l != "" && !contains(labels, l) {
				labels = append(labels, l)
			}
		}
		if !found {
			continue
		}
		n.Labels = labels
		n.normalize()
		if err := tx.PutLocal("note", id, s.sealNote(n)); err != nil {
			return err
		}
		s.notes[id] = n
	}
	return nil
}

func contains(list []string, v string) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

// Attachments

func newUUID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}

// ImportAttachment seals a file into the blob cache. The local name is a UUID, like Android.
func (s *NoteStore) ImportAttachment(path, mimeType string) (FileAttachment, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return FileAttachment{}, err
	}
	localName := newUUID() + strings.ToLower(filepath.Ext(path))
	if !IsSafeFileName(localName) {
		localName = newUUID()
	}
	id := s.Keys.BlobID(localName)
	if err := writeFileAtomic(s.local.BlobPath(id), s.Keys.Seal("blob", id, data)); err != nil {
		return FileAttachment{}, err
	}
	s.mu.Lock()
	err = s.local.Update(func(tx *Tx) error { return tx.AddBlob(id, false) })
	s.mu.Unlock()
	return FileAttachment{LocalName: localName, OriginalName: filepath.Base(path), MimeType: mimeType}, err
}

func writeFileAtomic(path string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".tmp-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

func (s *NoteStore) HasAttachment(localName string) bool {
	return s.local.HasBlob(s.Keys.BlobID(localName))
}

// AttachmentData returns the decrypted attachment, or an error if it is not downloaded yet.
func (s *NoteStore) AttachmentData(localName string) ([]byte, error) {
	id := s.Keys.BlobID(localName)
	if data, ok := s.cache.get(id); ok {
		return data, nil
	}
	sealed, err := os.ReadFile(s.local.BlobPath(id))
	if err != nil {
		return nil, err
	}
	data, err := s.Keys.Open("blob", id, sealed)
	if err != nil {
		return nil, err
	}
	s.cache.put(id, data)
	return data, nil
}

func (s *NoteStore) referencedBlobIDs() map[string]bool {
	out := map[string]bool{}
	for _, n := range s.notes {
		for _, name := range n.AttachmentNames() {
			out[s.Keys.BlobID(name)] = true
		}
	}
	return out
}

func (s *NoteStore) ReferencedBlobIDs() map[string]bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.referencedBlobIDs()
}

// Editors

// EditorOpened: remote versions of this note wait until the editor closes (PROTOCOL.md §7).
func (s *NoteStore) EditorOpened(id string) {
	s.mu.Lock()
	s.openEditors[id] = true
	s.mu.Unlock()
}

// EditorClosed removes the note if it is empty (like NotallyX) and merges a waiting remote version.
func (s *NoteStore) EditorClosed(id string) {
	s.mu.Lock()
	delete(s.openEditors, id)
	n, ok := s.notes[id]
	s.mu.Unlock()
	if ok && n.IsEmpty() {
		_ = s.DeleteForever(id)
	}
	s.applyPending(id)
}

// blobCache keeps recently used decrypted attachments in memory only.
type blobCache struct {
	mu    sync.Mutex
	max   int
	size  int
	order []string
	data  map[string][]byte
}

func (c *blobCache) get(id string) ([]byte, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	d, ok := c.data[id]
	return d, ok
}

func (c *blobCache) put(id string, d []byte) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(d) > c.max/4 {
		return
	}
	if c.data == nil {
		c.data = map[string][]byte{}
	}
	if _, ok := c.data[id]; ok {
		return
	}
	c.data[id] = d
	c.order = append(c.order, id)
	c.size += len(d)
	for c.size > c.max && len(c.order) > 0 {
		old := c.order[0]
		c.order = c.order[1:]
		c.size -= len(c.data[old])
		delete(c.data, old)
	}
}

func (c *blobCache) clear() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.data, c.order, c.size = nil, nil, 0
}
