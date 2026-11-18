package core

import (
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"math"
	"os"
	"strings"
	"testing"
	"time"

	"notallyxyz-server/seal"
)

// TestVectors checks the key handling against testvectors.json of the server.
func TestVectors(t *testing.T) {
	raw, err := os.ReadFile("../../server/testvectors.json")
	if err != nil {
		t.Fatal(err)
	}
	var v seal.Vectors
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	keys, err := ParseKeys(strings.ToLower(v.Display))
	if err != nil {
		t.Fatal(err)
	}
	if hex.EncodeToString(keys.Raw) != v.SyncKey || keys.Display() != v.Display {
		t.Fatal("sync key")
	}
	if keys.Bearer() != v.AuthToken || hex.EncodeToString(keys.EncKey) != v.EncKey {
		t.Fatal("derived keys")
	}
	for value, id := range v.LabelIDs {
		if keys.LabelID(value) != id {
			t.Fatalf("label id %q", value)
		}
	}
	for name, id := range v.BlobIDs {
		if keys.BlobID(name) != id {
			t.Fatalf("blob id %q", name)
		}
	}
	for _, s := range v.Seal {
		sealed, _ := hex.DecodeString(s.Sealed)
		plain, err := keys.Open(s.Kind, s.ID, sealed)
		if err != nil || hex.EncodeToString(plain) != s.Plain {
			t.Fatalf("vector %s", s.Name)
		}
	}
	if _, err := ParseKeys(v.Display[:len(v.Display)-1] + "0"); err == nil {
		t.Fatal("bad checksum accepted")
	}
	_ = base64.RawURLEncoding
}

const androidNote = `{"v":1,"type":"LIST","folder":"ARCHIVED","color":"#FAAFA9","title":"Shop","pinned":true,
"timestamp":1700000000000,"modifiedTimestamp":1700000001000,"labels":["Home",3],"body":"",
"spans":[{"start":0,"end":4,"bold":true,"italic":false,"monospace":false,"strikethrough":false,"link":true,"linkData":"note://-1/NOTE"},{"start":1}],
"items":[{"body":"Milk","checked":true,"isChild":false,"order":0,"checkedTimestamp":1700000000500},{"body":"Oat","checked":false,"isChild":true}],
"images":[{"localName":"a.jpg","originalName":"cat.jpg","mimeType":"image/jpeg"},{"localName":"../x"}],
"files":[{"name":"b.pdf"}],"audios":[{"name":"c.m4a","duration":1234,"timestamp":1}],
"reminders":[{"id":1,"dateTime":1700000000000,"repetition":{"value":1,"unit":"MONTHS","occurrence":2,"dayOfWeek":3}},{"id":2,"dateTime":5,"repetition":{"value":0,"unit":"DAYS","occurrence":9,"dayOfWeek":3}}],
"viewMode":"READ_ONLY","futureField":{"a":[1,2]},"isPinnedToStatus":false}`

func TestPayloadRoundTrip(t *testing.T) {
	n, ok := DecodeNote("00112233445566778899aabbccddeeff", []byte(androidNote))
	if !ok {
		t.Fatal("decode")
	}
	if n.Type != TypeList || n.Folder != FolderArchived || !n.Pinned || n.ViewMode != "READ_ONLY" {
		t.Fatalf("fields: %+v", n)
	}
	if len(n.Labels) != 1 || len(n.Spans) != 1 || *n.Spans[0].LinkData != "note://-1/NOTE" {
		t.Fatalf("labels/spans: %+v %+v", n.Labels, n.Spans)
	}
	if len(n.Items) != 2 || n.Items[1].Order != nil || *n.Items[0].CheckedTimestamp != 1700000000500 {
		t.Fatalf("items: %+v", n.Items)
	}
	if len(n.Images) != 1 || len(n.Files) != 1 || n.Files[0].OriginalName != "b.pdf" || n.Files[0].MimeType != "application/octet-stream" {
		t.Fatalf("attachments: %+v %+v", n.Images, n.Files)
	}
	r := n.Reminders
	if len(r) != 2 || *r[0].Repetition.Occurrence != 2 || r[1].Repetition.Occurrence != nil || r[1].Repetition.Value != 1 {
		t.Fatalf("reminders: %+v", r)
	}
	if string(n.Extra) != `{"futureField":{"a":[1,2]},"isPinnedToStatus":false}` {
		t.Fatalf("extra: %s", n.Extra)
	}
	enc := string(EncodeNote(n))
	for _, want := range []string{`"futureField":{"a":[1,2]}`, `"v":1`, `"linkData":"note://-1/NOTE"`} {
		if !strings.Contains(enc, want) {
			t.Fatalf("encoded lacks %s: %s", want, enc)
		}
	}
	for _, bad := range []string{"null", `"occurrence":9`, `"nextReminder"`, `"extra"`, `"id":"0011`} {
		if strings.Contains(enc, bad) {
			t.Fatalf("encoded has %s: %s", bad, enc)
		}
	}
	again, _ := DecodeNote(n.ID, []byte(enc))
	if !again.Equal(n) {
		t.Fatal("round trip changed the note")
	}
	if !IsTombstone(tombstone) || IsTombstone([]byte(androidNote)) || IsTombstone([]byte(`{"deleted":false}`)) {
		t.Fatal("tombstone detection")
	}
}

// Like NSNumber (macOS) and org.json (Android): a number with a fraction or an exponent is
// read as its integer part, not as 0.
func TestPayloadNumbersWithFraction(t *testing.T) {
	n, ok := DecodeNote("00112233445566778899aabbccddeeff", []byte(`{"title":"1.5","timestamp":1.7e12,
"modifiedTimestamp":1700000000001.0,"spans":[{"start":0.0,"end":4.9}],"items":[{"body":"a","order":2.0,"checkedTimestamp":5e0}],
"audios":[{"name":"c.m4a","duration":1.5,"timestamp":1e3}],"reminders":[{"id":1.5,"dateTime":1.7e12,"repetition":{"value":3.0,"unit":"DAYS"}}],
"big":12345678901234567890.5}`))
	if !ok || n.Title != "1.5" || n.Timestamp != 1_700_000_000_000 || n.ModifiedTimestamp != 1_700_000_000_001 {
		t.Fatalf("note: %+v", n)
	}
	if len(n.Spans) != 1 || n.Spans[0].Start != 0 || n.Spans[0].End != 4 {
		t.Fatalf("spans: %+v", n.Spans)
	}
	if len(n.Items) != 1 || *n.Items[0].Order != 2 || *n.Items[0].CheckedTimestamp != 5 {
		t.Fatalf("items: %+v", n.Items)
	}
	if len(n.Audios) != 1 || *n.Audios[0].Duration != 1 || n.Audios[0].Timestamp != 1000 {
		t.Fatalf("audios: %+v", n.Audios)
	}
	if r := n.Reminders; len(r) != 1 || r[0].ID != 1 || r[0].DateTime != 1_700_000_000_000 || r[0].Repetition.Value != 3 {
		t.Fatalf("reminders: %+v", r)
	}
	if string(n.Extra) != `{"big":12345678901234567890.5}` {
		t.Fatalf("unknown field changed: %s", n.Extra)
	}
	if l, ok := DecodeLabel("x", []byte(`{"v":1,"value":"Work","order":2.0}`)); !ok || l.Order != 2 {
		t.Fatalf("label: %+v %v", l, ok)
	}
}

func TestMerge(t *testing.T) {
	base := NewNote(TypeNote)
	base.Title, base.Body, base.Labels = "T", "base", []string{"A"}
	local, remote := base, base
	local.Body, local.Labels, local.Color = "local", []string{"A", "L"}, "#FAAFA9"
	remote.Pinned, remote.Labels, remote.ModifiedTimestamp = true, []string{"A", "R"}, base.ModifiedTimestamp+5
	r := Merge(&base, local, remote)
	if r.ConflictCopy != nil || r.Note.Body != "local" || !r.Note.Pinned || r.Note.Color != "#FAAFA9" ||
		strings.Join(r.Note.Labels, ",") != "A,L,R" || r.Note.ModifiedTimestamp != remote.ModifiedTimestamp {
		t.Fatalf("one-sided merge: %+v", r.Note)
	}
	remote.Body, remote.Reminders = "remote", []Reminder{{ID: 1, DateTime: 1}}
	r = Merge(&base, local, remote)
	if r.ConflictCopy == nil || r.ConflictCopy.Title != "T (conflict)" || r.ConflictCopy.Body != "remote" || r.Note.Body != "local" {
		t.Fatalf("content conflict: %+v", r)
	}
	// The pin and the reminders stay on the note only, else each reminder fires twice.
	if c := r.ConflictCopy; c.Pinned || len(c.Reminders) != 0 || c.Reminders == nil || !r.Note.Pinned || len(r.Note.Reminders) != 1 {
		t.Fatalf("conflict copy: %+v", c)
	}
	local.Body = "remote"
	if r = Merge(&base, local, remote); r.ConflictCopy != nil {
		t.Fatal("same content on both sides is no conflict")
	}
}

// A label change whose transaction fails leaves the notes and labels in memory as on disk.
func TestFailedLabelChangeKeepsMemory(t *testing.T) {
	store, err := OpenNoteStore(t.TempDir(), GenerateKeys())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	note := NewNote(TypeNote)
	note.Title, note.Labels = "Plan", []string{"Work"}
	if err := store.Save(note); err != nil {
		t.Fatal(err)
	}
	// A note whose row cannot be written: the key is longer than bbolt allows.
	bad := NewNote(TypeNote)
	bad.ID, bad.Labels = strings.Repeat("a", 40_000), []string{"Work"}
	store.notes[bad.ID] = bad
	check := func(op string, err error) {
		t.Helper()
		if err == nil {
			t.Fatalf("%s did not fail", op)
		}
		if l := store.Labels(); len(l) != 1 || l[0].Value != "Work" {
			t.Fatalf("%s: labels in memory: %+v", op, l)
		}
		if n, _ := store.Note(note.ID); len(n.Labels) != 1 || n.Labels[0] != "Work" {
			t.Fatalf("%s: note in memory: %+v", op, n.Labels)
		}
	}
	check("rename", store.RenameLabel("Work", "Job"))
	check("delete", store.DeleteLabel("Work"))
}

func TestSameText(t *testing.T) {
	a := NewNote(TypeList)
	a.Items = []ListItem{{Body: "Milk"}}
	b := a
	b.Items = []ListItem{{Body: "Milk", Checked: true}}
	if !SameText(a, a) || SameText(a, b) {
		t.Fatal("checked state")
	}
	b = a
	b.Audios = []Audio{{Name: "rec.m4a"}}
	if SameText(a, b) {
		t.Fatal("attachments")
	}
	a.Audios = []Audio{{Name: "rec.m4a", Timestamp: 5}}
	if !SameText(a, b) {
		t.Fatal("same attachment names")
	}
}

func TestReminders(t *testing.T) {
	at := func(y int, m time.Month, d, h int) time.Time { return time.Date(y, m, d, h, 0, 0, 0, time.Local) }
	r := Reminder{DateTime: at(2026, 1, 31, 9).UnixMilli(), Repetition: &Repetition{Value: 1, Unit: "MONTHS"}}
	got, _ := NextNotification(r, at(2026, 2, 1, 0))
	if !got.Equal(at(2026, 2, 28, 9)) {
		t.Fatalf("month clamp: %v", got)
	}
	got, _ = NextNotification(r, at(2026, 3, 1, 0))
	if !got.Equal(at(2026, 3, 28, 9)) {
		t.Fatalf("month after clamp (Calendar keeps the 28th): %v", got)
	}
	two, tue := 2, 3 // 2nd Tuesday
	r.Repetition = &Repetition{Value: 1, Unit: "MONTHS", Occurrence: &two, DayOfWeek: &tue}
	got, _ = NextNotification(r, at(2026, 2, 1, 0))
	if !got.Equal(at(2026, 2, 10, 9)) {
		t.Fatalf("2nd Tuesday: %v", got)
	}
	r.Repetition = &Repetition{Value: 90, Unit: "MINUTES"}
	got, _ = NextNotification(r, at(2026, 1, 31, 12))
	if !got.Equal(at(2026, 1, 31, 13).Add(30 * time.Minute)) { // 9:00 + n × 90 min, strictly after 12:00
		t.Fatalf("minutes: %v", got)
	}
	r.Repetition = nil
	if _, ok := NextNotification(r, at(2026, 2, 1, 0)); ok {
		t.Fatal("past one-time reminder")
	}
}

// A value that does not fit in a Duration (value × unit wraps to 0) must not panic.
func TestRemindersHugeInterval(t *testing.T) {
	at := func(y int, m time.Month, d, h int) time.Time { return time.Date(y, m, d, h, 0, 0, 0, time.Local) }
	r := Reminder{DateTime: at(2026, 1, 1, 9).UnixMilli()}
	for _, unit := range []string{"MINUTES", "HOURS"} {
		r.Repetition = &Repetition{Value: 1 << 53, Unit: unit}
		if _, ok := NextNotification(r, at(2026, 2, 1, 0)); ok {
			t.Fatalf("%s: interval too long to repeat", unit)
		}
	}
	r.Repetition = &Repetition{Value: int(math.MaxInt64 / int64(time.Minute)), Unit: "MINUTES"}
	if got, ok := NextNotification(r, at(2026, 2, 1, 0)); !ok || !got.After(at(2300, 1, 1, 0)) {
		t.Fatalf("longest interval that fits: %v %v", got, ok)
	}
}
