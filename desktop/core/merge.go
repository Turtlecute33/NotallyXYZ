package core

import "reflect"

// MergeResult is the outcome of a three-way merge.
type MergeResult struct {
	Note         Note
	ConflictCopy *Note
}

func ConflictTitle(title string) string {
	if title == "" {
		return "(conflict)"
	}
	return title + " (conflict)"
}

func equalContents(a, b Note) bool {
	return a.Type == b.Type && a.Title == b.Title && a.Body == b.Body &&
		reflect.DeepEqual(a.Spans, b.Spans) && reflect.DeepEqual(a.Items, b.Items)
}

// Merge merges a note field by field with the rules of the Android and macOS clients, so that
// all of them converge (PROTOCOL.md §7):
//   - content {type, title, body, spans, items} is one unit. Changed on both sides: keep local,
//     and the remote version becomes a new note titled "<title> (conflict)".
//   - other fields: changed on one side: take it; on both: local wins, except
//     modifiedTimestamp = max and labels, images, files, audios = union.
func Merge(base *Note, local, remote Note) MergeResult {
	local.normalize()
	remote.normalize()
	if base != nil {
		b := *base
		b.normalize()
		base = &b
	}
	out := local
	var copy *Note

	if !equalContents(local, remote) {
		localChanged := base == nil || !equalContents(*base, local)
		remoteChanged := base == nil || !equalContents(*base, remote)
		if remoteChanged && !localChanged {
			out.Type, out.Title, out.Body, out.Spans, out.Items = remote.Type, remote.Title, remote.Body, remote.Spans, remote.Items
		} else if remoteChanged {
			c := remote
			c.ID = RandomID()
			c.Title = ConflictTitle(remote.Title)
			copy = &c
		}
	}

	changed := func(get func(Note) any, side Note) bool {
		return base == nil || !reflect.DeepEqual(get(side), get(*base))
	}
	pick := func(get func(Note) any, set func(*Note, Note)) {
		if changed(get, remote) && !changed(get, local) {
			set(&out, remote)
		}
	}
	pick(func(n Note) any { return n.Folder }, func(o *Note, r Note) { o.Folder = r.Folder })
	pick(func(n Note) any { return n.Color }, func(o *Note, r Note) { o.Color = r.Color })
	pick(func(n Note) any { return n.Pinned }, func(o *Note, r Note) { o.Pinned = r.Pinned })
	pick(func(n Note) any { return n.Timestamp }, func(o *Note, r Note) { o.Timestamp = r.Timestamp })
	pick(func(n Note) any { return n.Reminders }, func(o *Note, r Note) { o.Reminders = r.Reminders })
	pick(func(n Note) any { return n.ViewMode }, func(o *Note, r Note) { o.ViewMode = r.ViewMode })
	pick(func(n Note) any { return string(n.Extra) }, func(o *Note, r Note) { o.Extra = r.Extra })

	out.Labels = union(base, local, remote, func(n Note) []string { return n.Labels }, func(s string) string { return s })
	out.Images = union(base, local, remote, func(n Note) []FileAttachment { return n.Images }, func(f FileAttachment) string { return f.LocalName })
	out.Files = union(base, local, remote, func(n Note) []FileAttachment { return n.Files }, func(f FileAttachment) string { return f.LocalName })
	out.Audios = union(base, local, remote, func(n Note) []Audio { return n.Audios }, func(a Audio) string { return a.Name })
	out.ModifiedTimestamp = max(local.ModifiedTimestamp, remote.ModifiedTimestamp)
	return MergeResult{Note: out, ConflictCopy: copy}
}

func union[T any](base *Note, local, remote Note, get func(Note) []T, key func(T) string) []T {
	changed := func(side Note) bool { return base == nil || !reflect.DeepEqual(get(side), get(*base)) }
	l, r := changed(local), changed(remote)
	switch {
	case r && !l:
		return get(remote)
	case r && l:
		seen := map[string]bool{}
		merged := append([]T{}, get(local)...)
		for _, e := range merged {
			seen[key(e)] = true
		}
		for _, e := range get(remote) {
			if !seen[key(e)] {
				seen[key(e)] = true
				merged = append(merged, e)
			}
		}
		return merged
	}
	return get(local)
}

// SameText: same title, type and content text, for linking an unsynced note on the first pull.
func SameText(a, b Note) bool {
	if a.Type != b.Type || a.Title != b.Title {
		return false
	}
	if a.Type == TypeNote {
		return a.Body == b.Body
	}
	if len(a.Items) != len(b.Items) {
		return false
	}
	for i := range a.Items {
		if a.Items[i].Body != b.Items[i].Body {
			return false
		}
	}
	return true
}
