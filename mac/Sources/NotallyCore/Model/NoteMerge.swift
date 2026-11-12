import Foundation

/// Three-way merge of a note, field by field, with the same rules as the Android client so that
/// both converge:
/// - content {type, title, body, spans, items} is one unit. Changed on both sides → keep local,
///   and the remote version becomes a new note titled "<title> (conflict)", not pinned, no reminders.
/// - other fields: changed on one side → take it; on both → local wins, except
///   modifiedTimestamp = max and labels/images/files/audios = union.
public enum NoteMerge {
    public struct Result {
        public var note: Note
        public var conflictCopy: Note?
    }

    public static func conflictTitle(_ title: String) -> String {
        title.isEmpty ? "(conflict)" : "\(title) (conflict)"
    }

    public static func merge(base: Note?, local: Note, remote: Note) -> Result {
        var out = local
        var copy: Note?

        if !local.equalContents(remote) {
            let localChanged = base.map { !$0.equalContents(local) } ?? true
            let remoteChanged = base.map { !$0.equalContents(remote) } ?? true
            if remoteChanged && !localChanged {
                out.type = remote.type
                out.title = remote.title
                out.body = remote.body
                out.spans = remote.spans
                out.items = remote.items
            } else if remoteChanged {
                // Like Android: else each reminder fires twice.
                var c = remote
                c.id = Data.randomID()
                c.title = conflictTitle(remote.title)
                c.pinned = false
                c.reminders = []
                copy = c
            }
        }

        func changed<T: Equatable>(_ path: KeyPath<Note, T>, _ side: Note) -> Bool {
            guard let base else { return true }
            return side[keyPath: path] != base[keyPath: path]
        }
        func pick<T: Equatable>(_ path: WritableKeyPath<Note, T>) {
            if changed(path, remote) && !changed(path, local) { out[keyPath: path] = remote[keyPath: path] }
        }
        func union<T: Equatable, K: Hashable>(_ path: WritableKeyPath<Note, [T]>, by key: (T) -> K) {
            let l = changed(path, local), r = changed(path, remote)
            if r && !l {
                out[keyPath: path] = remote[keyPath: path]
            } else if r && l {
                var seen = Set(local[keyPath: path].map(key))
                var merged = local[keyPath: path]
                for element in remote[keyPath: path] where seen.insert(key(element)).inserted { merged.append(element) }
                out[keyPath: path] = merged
            }
        }

        pick(\.folder)
        pick(\.color)
        pick(\.pinned)
        pick(\.timestamp)
        pick(\.reminders)
        pick(\.viewMode)
        pick(\.extra)
        union(\.labels) { $0 }
        union(\.images) { $0.localName }
        union(\.files) { $0.localName }
        union(\.audios) { $0.name }
        out.modifiedTimestamp = max(local.modifiedTimestamp, remote.modifiedTimestamp)
        return Result(note: out, conflictCopy: copy)
    }

    /// Same type, title, content (list: item bodies and checked state, in order) and attachment
    /// names, for linking an unsynced note on the first pull (PROTOCOL.md §7).
    public static func isTwin(_ a: Note, _ b: Note) -> Bool {
        guard a.type == b.type, a.title == b.title,
              Set(a.images.map(\.localName)) == Set(b.images.map(\.localName)),
              Set(a.files.map(\.localName)) == Set(b.files.map(\.localName)),
              Set(a.audios.map(\.name)) == Set(b.audios.map(\.name)) else { return false }
        return a.type == .note
            ? a.body == b.body
            : a.items.elementsEqual(b.items) { $0.body == $1.body && $0.checked == $1.checked }
    }
}
