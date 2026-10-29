import Foundation

extension NoteStore {
    enum MemoryOp {
        case setNote(Note)
        case removeNote(String)
        case setLabel(Label)
        case removeLabel(String)
    }

    static func isValidID(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// Applies one page of remote changes and the new cursor in one transaction
    /// (PROTOCOL.md §7, step 1). Returns the number of conflict copies created.
    @discardableResult
    func applyRemote(_ changes: [RemoteChange], cursor: Int64) throws -> Int {
        var ops: [MemoryOp] = []
        var conflicts = 0
        try local.transaction {
            var unsynced = try local.unsyncedNoteIDs()
            for change in changes where ["note", "label"].contains(change.kind) && Self.isValidID(change.id) {
                let row = try local.record(kind: change.kind, id: change.id)
                // Already known: our own push coming back, or an older version.
                if let row, row.seq >= change.seq { continue }
                // Only data that opens counts. The `deleted` flag of the server is not authenticated.
                // The id of a label must match its value.
                guard let data = change.data,
                      let plain = try? Seal.open(data, key: keys.encKey, ad: Seal.ad(change.kind, change.id)),
                      change.kind != "label" || Payload.isTombstone(plain)
                          || Payload.decodeLabel(id: change.id, plain).map({ keys.labelID($0.value) }) == change.id else {
                    try repair(kind: change.kind, id: change.id, seq: change.seq, row: row)
                    continue
                }
                let sealed = Payload.isTombstone(plain) ? nil : data
                // The editor would overwrite it: keep it aside until the editor closes.
                if change.kind == "note" && openEditors.contains(change.id) {
                    try local.putPending(.init(id: change.id, seq: change.seq, sealed: sealed))
                    continue
                }
                conflicts += try apply(kind: change.kind, id: change.id, seq: change.seq, sealed: sealed, row: row,
                                       unsynced: &unsynced, ops: &ops)
            }
            try local.setCursor(cursor)
        }
        finish(ops, conflicts: conflicts)
        return conflicts
    }

    func finish(_ ops: [MemoryOp], conflicts: Int) {
        for op in ops {
            switch op {
            case .setNote(let n): notes[n.id] = n
            case .removeNote(let id): notes[id] = nil
            case .setLabel(let l): labels[l.id] = l
            case .removeLabel(let id): labels[id] = nil
            }
        }
        if !ops.isEmpty { onNotesChanged?() }
        if conflicts > 0 { onLocalChange?() }
    }

    /// A change that does not open (forged deletion, tampered or damaged record) is never applied.
    /// The local copy stays and is pushed again on top of that change, which repairs the server copy.
    private func repair(kind: String, id: String, seq: Int64, row: LocalStore.Record?) throws {
        guard let row, row.dirty > 0 || !row.deleted else { return }
        try local.setServerVersion(kind: kind, id: id, seq: seq, base: row.base)
        if row.dirty == 0 { try local.markDirty(kind: kind, id: id) }
    }

    /// One authentic remote version (sealed == nil means deleted). Returns 1 if a conflict copy was made.
    private func apply(kind: String, id: String, seq: Int64, sealed: Data?, row: LocalStore.Record?,
                       unsynced: inout Set<String>, ops: inout [MemoryOp]) throws -> Int {
        let dirty = (row?.dirty ?? 0) > 0

        guard let sealed else {
            if !dirty || row?.deleted == true {
                try local.put(.init(kind: kind, id: id, seq: seq, sealed: nil, deleted: true, dirty: 0, base: nil))
                ops.append(kind == "note" ? .removeNote(id) : .removeLabel(id))
            } else {
                try local.setServerVersion(kind: kind, id: id, seq: seq, base: nil)  // local edit wins
            }
            return 0
        }
        guard let plain = try? Seal.open(sealed, key: keys.encKey, ad: Seal.ad(kind, id)) else { return 0 }

        func takeRemote() throws {
            try local.put(.init(kind: kind, id: id, seq: seq, sealed: sealed, deleted: false, dirty: 0, base: sealed))
            if kind == "note", let note = Payload.decodeNote(id: id, plain) {
                ops.append(.setNote(note))
            } else if kind == "label", let label = Payload.decodeLabel(id: id, plain) {
                ops.append(.setLabel(label))
            }
        }

        if kind == "label" {
            if dirty && row?.deleted == false {
                try local.setServerVersion(kind: kind, id: id, seq: seq, base: sealed)
            } else {
                try takeRemote()
            }
            return 0
        }
        guard let remote = Payload.decodeNote(id: id, plain) else {
            try repair(kind: kind, id: id, seq: seq, row: row)
            return 0
        }

        // First pull: link an unsynced local note with the same text instead of duplicating it.
        var mine: Note? = dirty && row?.deleted == false ? notes[id] : nil
        var base: Note? = row?.base.flatMap { try? Seal.open($0, key: keys.encKey, ad: Seal.ad("note", id)) }
            .flatMap { Payload.decodeNote(id: id, $0) }
        if row == nil, let twin = unsynced.first(where: { notes[$0].map { NoteMerge.sameText($0, remote) } ?? false }) {
            unsynced.remove(twin)
            try local.deleteRow(kind: "note", id: twin)
            ops.append(.removeNote(twin))
            mine = notes[twin].map { var n = $0; n.id = id; return n }
            base = remote
        }

        // A remote edit beats a pending local deletion: nothing gets lost.
        guard let mine else {
            try takeRemote()
            return 0
        }
        let result = NoteMerge.merge(base: base, local: mine, remote: remote)
        if result.note == remote {
            try takeRemote()
        } else {
            try local.put(.init(kind: kind, id: id, seq: seq, sealed: try sealNote(result.note), deleted: false,
                                dirty: local.nextDirty(), base: sealed))
            ops.append(.setNote(result.note))
        }
        guard let copy = result.conflictCopy else { return 0 }
        try local.putLocal(kind: "note", id: copy.id, sealed: try sealNote(copy))
        ops.append(.setNote(copy))
        return 1
    }

    // MARK: Editors

    /// Remote changes of an open note wait until the editor closes.
    public func editorOpened(_ id: String) { openEditors.insert(id) }

    public func editorClosed(_ id: String) {
        openEditors.remove(id)
        try? applyPending(id)
    }

    func applyPending(_ id: String) throws {
        var ops: [MemoryOp] = []
        var conflicts = 0
        try local.transaction {
            guard let pending = try local.takePending(id) else { return }
            let row = try local.record(kind: "note", id: id)
            if let row, row.seq >= pending.seq { return }
            var unsynced = Set<String>()
            conflicts = try apply(kind: "note", id: id, seq: pending.seq, sealed: pending.sealed, row: row,
                                  unsynced: &unsynced, ops: &ops)
        }
        finish(ops, conflicts: conflicts)
        if !ops.isEmpty { onLocalChange?() }
    }

    /// Notes with a held-back remote version are not pushed (the merge comes first).
    func isHeldBack(_ record: LocalStore.Record) -> Bool {
        record.kind == "note" && ((try? local.pendingIDs())?.contains(record.id) ?? false)
    }
}
