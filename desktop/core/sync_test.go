package core

import (
	"bytes"
	"context"
	"errors"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

const invite = "desktop-test-invite-0123456789"

// testServer builds and runs the real server of ../../server on a free loopback port.
func testServer(t *testing.T) *url.URL {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "server")
	if runtime.GOOS == "windows" {
		bin += ".exe"
	}
	build := exec.Command("go", "build", "-o", bin, ".")
	build.Dir = "../../server"
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build server: %v\n%s", err, out)
	}
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := l.Addr().String()
	l.Close()
	cmd := exec.Command(bin)
	cmd.Env = append(os.Environ(), "DATA_DIR="+t.TempDir(), "LISTEN_ADDR="+addr, "SIGNUP_TOKEN="+invite)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cmd.Process.Kill(); _ = cmd.Wait() })
	u, _ := url.Parse("http://" + addr)
	for range 100 {
		if resp, err := http.Get(u.String() + "/v1/health"); err == nil {
			resp.Body.Close()
			return u
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("server did not start")
	return nil
}

type device struct {
	store  *NoteStore
	engine *Engine
}

func newDevice(t *testing.T, server *url.URL, keys Keys) *device {
	t.Helper()
	store, err := OpenNoteStore(t.TempDir(), keys)
	if err != nil {
		t.Fatal(err)
	}
	engine := NewEngine(store, NewAPI(server, keys))
	t.Cleanup(func() { engine.Stop(); store.Close() })
	return &device{store, engine}
}

func (d *device) sync(t *testing.T) {
	t.Helper()
	d.engine.Sync()
	if st := d.engine.Status(); st.Error != "" {
		t.Fatalf("sync: %s", st.Error)
	}
}

func account(t *testing.T) (*url.URL, Keys) {
	server := testServer(t)
	keys := GenerateKeys()
	if created, err := NewAPI(server, keys).CreateAccount(context.Background(), invite); err != nil || !created {
		t.Fatalf("create account: %v", err)
	}
	return server, keys
}

func TestSyncNotesLabelsBlobsAndConflicts(t *testing.T) {
	server, keys := account(t)
	a, b := newDevice(t, server, keys), newDevice(t, server, keys)

	file := filepath.Join(t.TempDir(), "photo.jpg")
	if err := os.WriteFile(file, bytes.Repeat([]byte{7}, 100_000), 0o600); err != nil {
		t.Fatal(err)
	}
	att, err := a.store.ImportAttachment(file, "image/jpeg")
	if err != nil {
		t.Fatal(err)
	}
	note := NewNote(TypeNote)
	note.Title, note.Body, note.Labels, note.Images = "Plan", "base", []string{"Work"}, []FileAttachment{att}
	if err := a.store.Save(note); err != nil {
		t.Fatal(err)
	}
	a.sync(t)
	b.sync(t)
	got, ok := b.store.Note(note.ID)
	if !ok || got.Body != "base" || len(b.store.Labels()) != 1 {
		t.Fatalf("B did not get the note and label: %+v", got)
	}
	if data, err := b.store.AttachmentData(att.LocalName); err != nil || len(data) != 100_000 {
		t.Fatalf("attachment: %v", err)
	}

	// Both edit the content: B keeps its version and gets a conflict copy.
	na, nb := got, got
	na.Body, na.Pinned = "from A", true
	nb.Body = "from B"
	_ = a.store.Save(na)
	_ = b.store.Save(nb)
	a.sync(t)
	b.sync(t)
	a.sync(t)
	for _, d := range []*device{a, b} {
		n, _ := d.store.Note(note.ID)
		if n.Body != "from B" || !n.Pinned || len(d.store.Notes()) != 2 {
			t.Fatalf("after conflict: %+v (%d notes)", n, len(d.store.Notes()))
		}
	}

	// Label rename on B reaches A, in the notes too.
	_ = b.store.RenameLabel("Work", "Job")
	b.sync(t)
	a.sync(t)
	n, _ := a.store.Note(note.ID)
	if labels := a.store.Labels(); len(labels) != 1 || labels[0].Value != "Job" || n.Labels[0] != "Job" {
		t.Fatalf("rename: %+v %+v", labels, n.Labels)
	}

	// Deletion reaches the other device.
	_ = a.store.DeleteForever(note.ID)
	a.sync(t)
	b.sync(t)
	if _, ok := b.store.Note(note.ID); ok {
		t.Fatal("deletion did not reach B")
	}
	a.sync(t)
	if _, ok := a.store.Note(note.ID); ok {
		t.Fatal("deleted note came back on A")
	}
}

func TestForgedDeletionsAreRepaired(t *testing.T) {
	server, keys := account(t)
	a := newDevice(t, server, keys)
	note := NewNote(TypeNote)
	note.Title, note.Labels = "Keep me", []string{"Work"}
	_ = a.store.Save(note)
	a.sync(t)

	// Someone with the bearer token writes deletions that do not open.
	ctx := context.Background()
	api := NewAPI(server, keys)
	page, err := api.Changes(ctx, 0, 100, 0)
	if err != nil {
		t.Fatal(err)
	}
	var forged []OutgoingChange
	for _, ch := range page.Changes {
		forged = append(forged, OutgoingChange{Kind: ch.Kind, ID: ch.ID, Base: ch.Seq, Data: bytes.Repeat([]byte{1}, 400)})
	}
	if res, err := api.Push(ctx, forged); err != nil || len(res) != 2 || res[0].Conflict {
		t.Fatalf("forge: %v %+v", err, res)
	}
	a.sync(t)
	if n, ok := a.store.Note(note.ID); !ok || n.Title != "Keep me" || len(a.store.Labels()) != 1 {
		t.Fatal("forged deletion was applied")
	}
	// A pushed both records again: a new device gets them.
	c := newDevice(t, server, keys)
	c.sync(t)
	if n, ok := c.store.Note(note.ID); !ok || n.Title != "Keep me" || len(c.store.Labels()) != 1 {
		t.Fatal("server copy was not repaired")
	}

	// A change without data, or with a sealed note, is no deletion either.
	before := len(a.store.Notes())
	err = a.store.ApplyRemote([]RemoteChange{
		{Kind: "note", ID: note.ID, Seq: 1000},
		{Kind: "note", ID: note.ID, Seq: 1001, Data: keys.Seal("note", note.ID, EncodeNote(note))},
	}, 0)
	if err != nil || len(a.store.Notes()) != before {
		t.Fatalf("deletion without tombstone applied: %v", err)
	}
	// An authentic tombstone deletes.
	err = a.store.ApplyRemote([]RemoteChange{
		{Kind: "note", ID: note.ID, Seq: 1002, Data: keys.Seal("note", note.ID, tombstone)},
	}, 0)
	if _, ok := a.store.Note(note.ID); err != nil || ok {
		t.Fatal("authentic tombstone not applied")
	}
}

func TestOpenEditorDefersRemoteChange(t *testing.T) {
	server, keys := account(t)
	a, b := newDevice(t, server, keys), newDevice(t, server, keys)
	note := NewNote(TypeNote)
	note.Title = "Draft"
	_ = a.store.Save(note)
	a.sync(t)
	b.sync(t)

	b.store.EditorOpened(note.ID)
	edited := note
	edited.Body = "remote edit"
	_ = a.store.Save(edited)
	a.sync(t)
	b.sync(t)
	if n, _ := b.store.Note(note.ID); n.Body != "" {
		t.Fatal("remote change replaced the open note")
	}
	local, _ := b.store.Note(note.ID)
	local.Color = "#FAAFA9"
	_ = b.store.Save(local)
	b.sync(t) // held back: no push before the merge
	b.store.EditorClosed(note.ID)
	b.sync(t)
	a.sync(t)
	for _, d := range []*device{a, b} {
		if n, _ := d.store.Note(note.ID); n.Body != "remote edit" || n.Color != "#FAAFA9" {
			t.Fatalf("merge after close: %+v", n)
		}
	}
}

func TestFirstPullLinksSameNote(t *testing.T) {
	server, keys := account(t)
	a, b := newDevice(t, server, keys), newDevice(t, server, keys)
	for _, d := range []*device{a, b} {
		n := NewNote(TypeNote)
		n.Title, n.Body = "Same", "text"
		_ = d.store.Save(n)
	}
	a.sync(t)
	b.sync(t)
	a.sync(t)
	if len(a.store.Notes()) != 1 || len(b.store.Notes()) != 1 {
		t.Fatalf("duplicates: %d %d", len(a.store.Notes()), len(b.store.Notes()))
	}
}

// An Android voice memo and a photo note, both without title and text, are not linked: the
// link would keep only the local fields, and the audio, labels and reminders would be lost.
func TestFirstPullDoesNotLinkDifferentAttachments(t *testing.T) {
	server, keys := account(t)
	a, b := newDevice(t, server, keys), newDevice(t, server, keys)
	memo := NewNote(TypeNote)
	memo.Audios = []Audio{{Name: "rec.m4a", Timestamp: 1}}
	memo.Labels, memo.Reminders = []string{"Voice"}, []Reminder{{ID: 1, DateTime: 4102444800000}}
	_ = a.store.Save(memo)
	photo := NewNote(TypeNote)
	photo.Images = []FileAttachment{{LocalName: "photo.jpg", OriginalName: "photo.jpg", MimeType: "image/jpeg"}}
	_ = b.store.Save(photo)
	a.sync(t)
	b.sync(t)
	a.sync(t)
	for _, d := range []*device{a, b} {
		n, ok := d.store.Note(memo.ID)
		if len(d.store.Notes()) != 2 || !ok || len(n.Audios) != 1 || len(n.Labels) != 1 || len(n.Reminders) != 1 {
			t.Fatalf("memo: %+v (%d notes)", n, len(d.store.Notes()))
		}
	}
}

// A note or label deleted before its first push is never sent: the server never had it.
func TestDeletionBeforeFirstPushIsNotSent(t *testing.T) {
	server, keys := account(t)
	a := newDevice(t, server, keys)
	note := NewNote(TypeNote)
	note.Title = "Draft"
	_ = a.store.Save(note)
	_ = a.store.CreateLabel("Gone")
	_ = a.store.DeleteForever(note.ID)
	_ = a.store.DeleteLabel("Gone")
	a.sync(t)
	page, err := NewAPI(server, keys).Changes(context.Background(), 0, 100, 0)
	if err != nil || len(page.Changes) != 0 {
		t.Fatalf("sent: %v %+v", err, page.Changes)
	}
	_ = a.store.local.View(func(tx *Tx) error {
		if len(tx.Records()) != 0 {
			t.Fatalf("rows left: %+v", tx.Records())
		}
		return nil
	})
}

// The server refuses a whole push for one record over 8 MiB: Save refuses such a note, and push
// leaves one that is already stored and sends the others.
func TestTooLargeNote(t *testing.T) {
	server, keys := account(t)
	a, b := newDevice(t, server, keys), newDevice(t, server, keys)
	big := NewNote(TypeList)
	for range 9 {
		big.Items = append(big.Items, ListItem{Body: strings.Repeat("x", 1<<20)})
	}
	if err := a.store.Save(big); !errors.Is(err, errTooLarge) {
		t.Fatalf("save: %v", err)
	}
	if _, ok := a.store.Note(big.ID); ok {
		t.Fatal("refused note is in memory")
	}
	_ = a.store.local.Update(func(tx *Tx) error {
		return tx.PutLocal("note", big.ID, keys.Seal("note", big.ID, EncodeNote(big)))
	})
	small := NewNote(TypeNote)
	small.Title = "Small"
	_ = a.store.Save(small)
	a.engine.Sync()
	if st := a.engine.Status(); st.Error != errTooLarge.Error() {
		t.Fatalf("status: %+v", st)
	}
	b.sync(t)
	if _, ok := b.store.Note(small.ID); !ok || len(b.store.Notes()) != 1 {
		t.Fatal("the other note did not go")
	}
	_ = a.store.local.View(func(tx *Tx) error {
		if r := tx.Record("note", big.ID); r == nil || r.Dirty == 0 {
			t.Fatal("the large note is not pending")
		}
		return nil
	})
}

// A server restored from an older backup has fewer changes than the cursor: sync stops with a clear error.
func TestCursorAhead(t *testing.T) {
	server, keys := account(t)
	a := newDevice(t, server, keys)
	_ = a.store.local.Update(func(tx *Tx) error { return tx.SetCursor(1000) })
	a.engine.Sync()
	if st := a.engine.Status(); st.Error != ErrCursorAhead.Error() {
		t.Fatalf("status: %+v", st)
	}
}
