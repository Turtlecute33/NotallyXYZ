package core

import (
	"encoding/json"
	"path"
)

var noteKeys = map[string]bool{
	"v": true, "type": true, "folder": true, "color": true, "title": true, "pinned": true,
	"timestamp": true, "modifiedTimestamp": true, "labels": true, "body": true, "spans": true,
	"items": true, "images": true, "files": true, "audios": true, "reminders": true, "viewMode": true,
}

// tombstone is the sealed payload of a deletion (PROTOCOL.md §5). The server cannot make it.
var tombstone = []byte(`{"v":1,"deleted":true}`)

// IsTombstone reports whether an opened payload is a deletion.
func IsTombstone(plain []byte) bool {
	var p struct {
		Deleted *bool `json:"deleted"`
	}
	return json.Unmarshal(plain, &p) == nil && p.Deleted != nil && *p.Deleted
}

// EncodeNote returns the note payload. Null values are omitted, like org.json on Android.
func EncodeNote(n Note) []byte {
	n.normalize()
	m := map[string]any{}
	var extra map[string]json.RawMessage
	_ = json.Unmarshal(n.Extra, &extra)
	for k, v := range extra {
		m[k] = v
	}
	m["v"] = 1
	m["type"] = n.Type
	m["folder"] = n.Folder
	m["color"] = n.Color
	m["title"] = n.Title
	m["pinned"] = n.Pinned
	m["timestamp"] = n.Timestamp
	m["modifiedTimestamp"] = n.ModifiedTimestamp
	m["labels"] = n.Labels
	m["body"] = n.Body
	m["spans"] = n.Spans
	m["items"] = n.Items
	m["images"] = n.Images
	m["files"] = n.Files
	m["audios"] = n.Audios
	reminders := make([]Reminder, len(n.Reminders))
	for i, r := range n.Reminders {
		if r.Repetition != nil && (r.Repetition.Occurrence == nil || r.Repetition.DayOfWeek == nil) {
			rep := *r.Repetition
			rep.Occurrence, rep.DayOfWeek = nil, nil
			r.Repetition = &rep
		}
		reminders[i] = r
	}
	m["reminders"] = reminders
	m["viewMode"] = n.ViewMode
	out, err := json.Marshal(m)
	if err != nil {
		return []byte("{}")
	}
	return out
}

// DecodeNote reads a note payload. Fields of the wrong type get their default value.
func DecodeNote(id string, data []byte) (Note, bool) {
	var raw map[string]json.RawMessage
	if json.Unmarshal(data, &raw) != nil || raw == nil {
		return Note{}, false
	}
	get := func(k string, v any) {
		if r, ok := raw[k]; ok {
			_ = json.Unmarshal(r, v)
		}
	}
	n := Note{ID: id}
	get("type", &n.Type)
	get("folder", &n.Folder)
	get("color", &n.Color)
	get("title", &n.Title)
	get("pinned", &n.Pinned)
	get("timestamp", &n.Timestamp)
	n.ModifiedTimestamp = n.Timestamp
	get("modifiedTimestamp", &n.ModifiedTimestamp)
	var labels []any
	get("labels", &labels)
	for _, l := range labels {
		if s, ok := l.(string); ok {
			n.Labels = append(n.Labels, s)
		}
	}
	get("body", &n.Body)

	var spans []struct {
		Start, End                                   *int
		Bold, Italic, Monospace, Strikethrough, Link bool
		LinkData                                     *string `json:"linkData"`
	}
	get("spans", &spans)
	for _, s := range spans {
		if s.Start != nil && s.End != nil {
			n.Spans = append(n.Spans, Span{Start: *s.Start, End: *s.End, Bold: s.Bold, Italic: s.Italic,
				Monospace: s.Monospace, Strikethrough: s.Strikethrough, Link: s.Link, LinkData: s.LinkData})
		}
	}
	get("items", &n.Items)

	var files []struct{ LocalName, Name, OriginalName, MimeType *string }
	file := func(key string) []FileAttachment {
		files = nil
		get(key, &files)
		var out []FileAttachment
		for _, f := range files {
			local := f.LocalName
			if local == nil {
				local = f.Name
			}
			if local == nil || !IsSafeFileName(*local) {
				continue
			}
			a := FileAttachment{LocalName: *local, OriginalName: path.Base(*local), MimeType: "application/octet-stream"}
			if f.OriginalName != nil {
				a.OriginalName = *f.OriginalName
			}
			if f.MimeType != nil {
				a.MimeType = *f.MimeType
			}
			out = append(out, a)
		}
		return out
	}
	n.Images = file("images")
	n.Files = file("files")

	var audios []Audio
	get("audios", &audios)
	for _, a := range audios {
		if IsSafeFileName(a.Name) {
			n.Audios = append(n.Audios, a)
		}
	}

	var reminders []struct {
		ID, DateTime *int64
		Repetition   *Repetition
	}
	get("reminders", &reminders)
	for _, r := range reminders {
		if r.ID == nil || r.DateTime == nil {
			continue
		}
		rem := Reminder{ID: *r.ID, DateTime: *r.DateTime}
		if rep := r.Repetition; rep != nil && validUnit(rep.Unit) {
			rep.Value = max(1, rep.Value)
			if rep.Occurrence == nil || rep.DayOfWeek == nil || !validOccurrence(*rep.Occurrence) ||
				*rep.DayOfWeek < 1 || *rep.DayOfWeek > 7 {
				rep.Occurrence, rep.DayOfWeek = nil, nil
			}
			rem.Repetition = rep
		}
		n.Reminders = append(n.Reminders, rem)
	}
	get("viewMode", &n.ViewMode)

	extra := map[string]json.RawMessage{}
	for k, v := range raw {
		if !noteKeys[k] {
			extra[k] = v
		}
	}
	n.Extra, _ = json.Marshal(extra)
	n.normalize()
	return n, true
}

func validUnit(u string) bool {
	switch u {
	case "MINUTES", "HOURS", "DAYS", "WEEKS", "MONTHS", "YEARS":
		return true
	}
	return false
}

func validOccurrence(o int) bool { return o == -1 || (o >= 1 && o <= 4) }

func EncodeLabel(l Label) []byte {
	out, _ := json.Marshal(map[string]any{"v": 1, "value": l.Value, "order": l.Order})
	return out
}

func DecodeLabel(id string, data []byte) (Label, bool) {
	var p struct {
		Value *string
		Order int
	}
	if json.Unmarshal(data, &p) != nil || p.Value == nil {
		return Label{}, false
	}
	return Label{ID: id, Value: *p.Value, Order: p.Order}, true
}
