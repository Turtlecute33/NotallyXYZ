// Package core is the sync client of NotallyXYZ for Linux and Windows: note model, payloads
// (PROTOCOL.md §5), sealed local cache, three-way merge and the sync engine (§6–7).
// It follows the macOS app (mac/Sources/NotallyCore) rule for rule.
package core

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"strings"
	"time"
	"unicode"
)

type Span struct {
	Start         int     `json:"start"`
	End           int     `json:"end"`
	Bold          bool    `json:"bold"`
	Italic        bool    `json:"italic"`
	Monospace     bool    `json:"monospace"`
	Strikethrough bool    `json:"strikethrough"`
	Link          bool    `json:"link"`
	LinkData      *string `json:"linkData,omitempty"`
}

type ListItem struct {
	Body             string `json:"body"`
	Checked          bool   `json:"checked"`
	IsChild          bool   `json:"isChild"`
	Order            *int   `json:"order,omitempty"`
	CheckedTimestamp *int64 `json:"checkedTimestamp,omitempty"`
}

type FileAttachment struct {
	LocalName    string `json:"localName"`
	OriginalName string `json:"originalName"`
	MimeType     string `json:"mimeType"`
}

type Audio struct {
	Name      string `json:"name"`
	Duration  *int64 `json:"duration,omitempty"`
	Timestamp int64  `json:"timestamp"`
}

type Repetition struct {
	Value int    `json:"value"`
	Unit  string `json:"unit"` // MINUTES | HOURS | DAYS | WEEKS | MONTHS | YEARS
	// MONTHS only: 1…4 or -1 (last) occurrence of DayOfWeek (1 = Sunday … 7 = Saturday).
	Occurrence *int `json:"occurrence,omitempty"`
	DayOfWeek  *int `json:"dayOfWeek,omitempty"`
}

type Reminder struct {
	ID         int64       `json:"id"`
	DateTime   int64       `json:"dateTime"`
	Repetition *Repetition `json:"repetition,omitempty"`
}

// Note is the payload of a note record plus its record id. Extra holds the top-level JSON
// fields that this client does not know; they are written back unchanged.
type Note struct {
	ID                string           `json:"id"`
	Type              string           `json:"type"`   // NOTE | LIST
	Folder            string           `json:"folder"` // NOTES | ARCHIVED | DELETED
	Color             string           `json:"color"`
	Title             string           `json:"title"`
	Pinned            bool             `json:"pinned"`
	Timestamp         int64            `json:"timestamp"`
	ModifiedTimestamp int64            `json:"modifiedTimestamp"`
	Labels            []string         `json:"labels"`
	Body              string           `json:"body"`
	Spans             []Span           `json:"spans"`
	Items             []ListItem       `json:"items"`
	Images            []FileAttachment `json:"images"`
	Files             []FileAttachment `json:"files"`
	Audios            []Audio          `json:"audios"`
	Reminders         []Reminder       `json:"reminders"`
	ViewMode          string           `json:"viewMode"` // EDIT | READ_ONLY
	Extra             json.RawMessage  `json:"extra"`
	// Next reminder notification (ms), for the UI only. Not synced.
	NextReminder int64 `json:"nextReminder,omitempty"`
}

type Label struct {
	ID    string `json:"id"`
	Value string `json:"value"`
	Order int    `json:"order"`
}

const (
	TypeNote       = "NOTE"
	TypeList       = "LIST"
	FolderNotes    = "NOTES"
	FolderArchived = "ARCHIVED"
	FolderDeleted  = "DELETED"
	ColorDefault   = "DEFAULT"
)

func Now() int64 { return time.Now().UnixMilli() }

// RandomID is a new note record id: 16 random bytes as hex.
func RandomID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

func NewNote(typ string) Note {
	now := Now()
	n := Note{ID: RandomID(), Type: typ, Timestamp: now, ModifiedTimestamp: now}
	n.normalize()
	return n
}

// normalize sets defaults and empty slices, so that equal notes compare equal.
func (n *Note) normalize() {
	if n.Type != TypeList {
		n.Type = TypeNote
	}
	if n.Folder != FolderArchived && n.Folder != FolderDeleted {
		n.Folder = FolderNotes
	}
	if n.Color == "" {
		n.Color = ColorDefault
	}
	if n.ViewMode != "READ_ONLY" {
		n.ViewMode = "EDIT"
	}
	if n.Labels == nil {
		n.Labels = []string{}
	}
	if n.Spans == nil {
		n.Spans = []Span{}
	}
	if n.Items == nil {
		n.Items = []ListItem{}
	}
	if n.Images == nil {
		n.Images = []FileAttachment{}
	}
	if n.Files == nil {
		n.Files = []FileAttachment{}
	}
	if n.Audios == nil {
		n.Audios = []Audio{}
	}
	if n.Reminders == nil {
		n.Reminders = []Reminder{}
	}
	n.Extra = canonicalObject(n.Extra)
	n.NextReminder = 0
}

// canonicalObject re-encodes a JSON object with sorted keys ("{}" if empty or invalid).
func canonicalObject(raw json.RawMessage) json.RawMessage {
	var m map[string]json.RawMessage
	if len(raw) == 0 || json.Unmarshal(raw, &m) != nil || len(m) == 0 {
		return json.RawMessage("{}")
	}
	out, err := json.Marshal(m)
	if err != nil {
		return json.RawMessage("{}")
	}
	return out
}

func (n Note) IsEmpty() bool {
	for _, it := range n.Items {
		if it.Body != "" {
			return false
		}
	}
	return n.Title == "" && n.Body == "" && len(n.Images) == 0 && len(n.Files) == 0 && len(n.Audios) == 0
}

// AttachmentNames are the local names of all attachments (blob ids derive from them).
func (n Note) AttachmentNames() []string {
	var out []string
	for _, f := range n.Images {
		out = append(out, f.LocalName)
	}
	for _, f := range n.Files {
		out = append(out, f.LocalName)
	}
	for _, a := range n.Audios {
		out = append(out, a.Name)
	}
	return out
}

// Equal compares the synced content of two notes.
func (n Note) Equal(o Note) bool { return bytes.Equal(EncodeNote(n), EncodeNote(o)) }

// IsSafeFileName: attachment names become file names on Android. No paths, no hidden
// files, no control characters (PROTOCOL.md §7).
func IsSafeFileName(name string) bool {
	if name == "" || len(name) > 255 || strings.HasPrefix(name, ".") || strings.ContainsAny(name, `/\`) {
		return false
	}
	for _, r := range name {
		if unicode.IsControl(r) {
			return false
		}
	}
	return true
}
