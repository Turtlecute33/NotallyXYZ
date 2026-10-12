package core

func isValidID(id string) bool {
	if len(id) != 32 {
		return false
	}
	for _, c := range id {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// verify opens a remote change. A deletion counts only if its sealed payload says so; the
// server's deleted flag is never trusted (PROTOCOL.md §7). sealed == nil with ok means deletion.
func (s *NoteStore) verify(ch RemoteChange) (plain, sealed []byte, ok bool) {
	if len(ch.Data) == 0 {
		return nil, nil, false
	}
	plain, err := s.Keys.Open(ch.Kind, ch.ID, ch.Data)
	if err != nil {
		return nil, nil, false
	}
	if IsTombstone(plain) {
		return nil, nil, true
	}
	switch ch.Kind {
	case "note":
		if _, ok := DecodeNote(ch.ID, plain); !ok {
			return nil, nil, false
		}
	case "label":
		// The id must match the content.
		l, ok := DecodeLabel(ch.ID, plain)
		if !ok || s.Keys.LabelID(l.Value) != ch.ID {
			return nil, nil, false
		}
	}
	return plain, ch.Data, true
}

// repair: a change that does not open (forged deletion, tampered or damaged record) is not
// applied. A local copy is kept and pushed again on top of that change, which repairs the server.
func repair(tx *Tx, row *Record, seq int64) error {
	if row == nil || (row.Deleted && row.Dirty == 0) {
		return nil
	}
	row.Seq = seq
	if row.Dirty == 0 {
		row.Dirty = tx.NextDirty()
	}
	return tx.Put(*row)
}

// ApplyRemote applies one page of remote changes and the new cursor in one transaction
// (PROTOCOL.md §7, step 1).
func (s *NoteStore) ApplyRemote(changes []RemoteChange, cursor int64) error {
	s.mu.Lock()
	var ops []memOp
	local := false
	err := s.local.Update(func(tx *Tx) error {
		unsynced := tx.UnsyncedNoteIDs()
		for _, ch := range changes {
			if (ch.Kind != "note" && ch.Kind != "label") || !isValidID(ch.ID) {
				continue
			}
			row := tx.Record(ch.Kind, ch.ID)
			// Already known: our own push coming back, or an older version.
			if row != nil && row.Seq >= ch.Seq {
				continue
			}
			plain, sealed, ok := s.verify(ch)
			if !ok {
				if err := repair(tx, row, ch.Seq); err != nil {
					return err
				}
				local = local || row != nil
				continue
			}
			// The editor would overwrite it: keep it aside until the editor closes.
			if ch.Kind == "note" && s.openEditors[ch.ID] {
				if err := tx.PutPending(ch.ID, Pending{Seq: ch.Seq, Sealed: sealed}); err != nil {
					return err
				}
				continue
			}
			conflict, err := s.apply(tx, ch.Kind, ch.ID, ch.Seq, sealed, plain, row, unsynced, &ops)
			if err != nil {
				return err
			}
			local = local || conflict
		}
		return tx.SetCursor(cursor)
	})
	if err == nil {
		s.finish(ops)
	}
	s.mu.Unlock()
	if err == nil && len(ops) > 0 {
		s.emit(local)
	}
	return err
}

func (s *NoteStore) finish(ops []memOp) {
	for _, op := range ops {
		switch {
		case op.note != nil:
			s.notes[op.note.ID] = *op.note
		case op.label != nil:
			s.labels[op.label.ID] = *op.label
		case len(op.remove) > 5 && op.remove[:5] == "note:":
			delete(s.notes, op.remove[5:])
		case len(op.remove) > 6 && op.remove[:6] == "label:":
			delete(s.labels, op.remove[6:])
		}
	}
}

// apply applies one verified remote version (sealed == nil: deletion).
// It reports whether a conflict copy or a merge result waits for a push.
func (s *NoteStore) apply(tx *Tx, kind, id string, seq int64, sealed, plain []byte, row *Record,
	unsynced map[string]bool, ops *[]memOp) (bool, error) {
	dirty := row != nil && row.Dirty > 0

	if sealed == nil {
		if !dirty || row.Deleted {
			*ops = append(*ops, memOp{remove: kind + ":" + id})
			return false, tx.Put(Record{Kind: kind, ID: id, Seq: seq, Deleted: true})
		}
		return false, tx.SetServerVersion(kind, id, seq, nil) // a local edit wins
	}

	takeRemote := func() error {
		switch kind {
		case "note":
			if n, ok := DecodeNote(id, plain); ok {
				*ops = append(*ops, memOp{note: &n})
			}
		case "label":
			if l, ok := DecodeLabel(id, plain); ok {
				*ops = append(*ops, memOp{label: &l})
			}
		}
		return tx.Put(Record{Kind: kind, ID: id, Seq: seq, Sealed: sealed, Base: sealed})
	}

	if kind == "label" {
		if dirty && !row.Deleted {
			return false, tx.SetServerVersion(kind, id, seq, sealed)
		}
		return false, takeRemote()
	}
	remote, _ := DecodeNote(id, plain)

	var mine, base *Note
	if dirty && !row.Deleted {
		if n, ok := s.notes[id]; ok {
			mine = &n
		}
	}
	if row != nil && row.Base != nil {
		if p, err := s.Keys.Open("note", id, row.Base); err == nil {
			if b, ok := DecodeNote(id, p); ok {
				base = &b
			}
		}
	}
	// First pull: link an unsynced local note with the same text instead of duplicating it.
	if row == nil {
		for twin := range unsynced {
			n, ok := s.notes[twin]
			if !ok || !SameText(n, remote) {
				continue
			}
			delete(unsynced, twin)
			if err := tx.DeleteRow("note", twin); err != nil {
				return false, err
			}
			*ops = append(*ops, memOp{remove: "note:" + twin})
			n.ID = id
			r := remote
			mine, base = &n, &r
			break
		}
	}

	// A remote edit beats a pending local deletion: nothing gets lost.
	if mine == nil {
		return false, takeRemote()
	}
	result := Merge(base, *mine, remote)
	pending := false
	if result.Note.Equal(remote) {
		if err := takeRemote(); err != nil {
			return false, err
		}
	} else {
		merged := result.Note
		*ops = append(*ops, memOp{note: &merged})
		pending = true
		if err := tx.Put(Record{Kind: kind, ID: id, Seq: seq, Sealed: s.sealNote(merged),
			Dirty: tx.NextDirty(), Base: sealed}); err != nil {
			return false, err
		}
	}
	if c := result.ConflictCopy; c != nil {
		*ops = append(*ops, memOp{note: c})
		pending = true
		if err := tx.PutLocal("note", c.ID, s.sealNote(*c)); err != nil {
			return false, err
		}
	}
	return pending, nil
}

func (s *NoteStore) applyPending(id string) {
	s.mu.Lock()
	var ops []memOp
	local := false
	err := s.local.Update(func(tx *Tx) error {
		p := tx.TakePending(id)
		if p == nil {
			return nil
		}
		row := tx.Record("note", id)
		if row != nil && row.Seq >= p.Seq {
			return nil
		}
		var plain []byte
		if p.Sealed != nil {
			var err error
			if plain, err = s.Keys.Open("note", id, p.Sealed); err != nil {
				return nil
			}
		}
		var err error
		local, err = s.apply(tx, "note", id, p.Seq, p.Sealed, plain, row, map[string]bool{}, &ops)
		return err
	})
	if err == nil {
		s.finish(ops)
	}
	s.mu.Unlock()
	if err == nil && len(ops) > 0 {
		s.emit(local)
	}
}

// IsHeldBack: notes with a held-back remote version are not pushed (the merge comes first).
func (s *NoteStore) heldBack() map[string]bool {
	var out map[string]bool
	_ = s.local.View(func(tx *Tx) error {
		out = tx.PendingIDs()
		return nil
	})
	return out
}
