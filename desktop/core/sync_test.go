package core

import (
	"bytes"
	"context"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
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
		forged = append(forged, OutgoingChange{Kind: ch.Kind, ID: ch.ID, Base: ch.Seq, Deleted: true, Data: bytes.Repeat([]byte{1}, 400)})
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

	// A deleted flag without sealed data, or with a sealed note, is no deletion either.
	before := len(a.store.Notes())
	err = a.store.ApplyRemote([]RemoteChange{
		{Kind: "note", ID: note.ID, Seq: 1000, Deleted: true},
		{Kind: "note", ID: note.ID, Seq: 1001, Deleted: true, Data: keys.Seal("note", note.ID, EncodeNote(note))},
	}, 0)
	if err != nil || len(a.store.Notes()) != before {
		t.Fatalf("flag-only deletion applied: %v", err)
	}
	// An authentic tombstone deletes, whatever the flag says.
	err = a.store.ApplyRemote([]RemoteChange{
		{Kind: "note", ID: note.ID, Seq: 1002, Deleted: false, Data: keys.Seal("note", note.ID, tombstone)},
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
