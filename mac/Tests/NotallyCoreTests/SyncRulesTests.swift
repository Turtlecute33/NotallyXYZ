import Foundation
import Testing

@testable import NotallyCore

/// Rules agreed with the Android client (echo suppression, open editors, first-pull linking).
extension SyncTests {
    func withAccount(_ body: (SyncKeys) async throws -> Void) async throws {
        let server = try TestServer()
        defer { server.stop() }
        try await server.waitUntilReady()
        let keys = SyncKeys.generate()
        #expect(try await APIClient(baseURL: TestServer.url, keys: keys).createAccount(invite: TestServer.invite))
        try await body(keys)
    }

    @Test func deletedNoteDoesNotComeBack() async throws {
        try await withAccount { keys in
            let a = try client(keys), b = try client(keys)
            defer { [a.dir, b.dir].forEach { try? FileManager.default.removeItem(at: $0) } }
            var note = a.store.create(.note)
            note.title = "Short-lived"
            a.store.save(note)
            try await sync(a)  // pushed; A's cursor is still behind its own push
            a.store.deleteForever(note.id)
            try await sync(a)  // the pull returns the old version first: it must not resurrect the note
            try await sync(a)
            #expect(a.store.notes[note.id] == nil)
            try await sync(b)
            #expect(b.store.notes[note.id] == nil)
        }
    }

    @Test func deletionThatDoesNotOpenIsRepaired() async throws {
        try await withAccount { keys in
            let a = try client(keys)
            defer { try? FileManager.default.removeItem(at: a.dir) }
            a.store.createLabel("Work")
            var note = a.store.create(.note)
            note.title = "Keep me"
            a.store.save(note)
            try await sync(a)

            // Someone with the bearer token writes deletions whose data does not open.
            let api = APIClient(baseURL: TestServer.url, keys: keys)
            let seqs = Dictionary(uniqueKeysWithValues: try await api.changes(since: 0).changes.map { ($0.id, $0.seq) })
            let labelID = keys.labelID("Work")
            let garbage = Data(repeating: 1, count: 400)
            _ = try await api.push([
                OutgoingChange(kind: "note", id: note.id, base: seqs[note.id]!, deleted: true, data: garbage),
                OutgoingChange(kind: "label", id: labelID, base: seqs[labelID]!, deleted: true, data: garbage),
            ])
            try await sync(a)
            #expect(a.store.notes[note.id]?.title == "Keep me")
            #expect(a.store.sortedLabels.map(\.value) == ["Work"])

            // A pushed both records again: a new device gets them.
            let c = try client(keys)
            defer { try? FileManager.default.removeItem(at: c.dir) }
            try await sync(c)
            #expect(c.store.notes[note.id]?.title == "Keep me")
            #expect(c.store.sortedLabels.map(\.value) == ["Work"])
        }
    }

    @Test func deletedFlagWithoutSealedDataIsNotTrusted() async throws {
        try await withAccount { keys in
            let a = try client(keys)
            defer { try? FileManager.default.removeItem(at: a.dir) }
            var note = a.store.create(.note)
            note.title = "Keep me"
            a.store.save(note)
            var gone = a.store.create(.note)
            gone.title = "Gone"
            a.store.save(gone)
            try await sync(a)
            let cursor = a.store.local.cursor

            // A malicious server sends only flags, no sealed data.
            try a.store.applyRemote([RemoteChange(kind: "note", id: note.id, seq: 1000, deleted: true, data: nil)],
                                    cursor: cursor)
            try a.store.applyRemote([RemoteChange(kind: "note", id: note.id, seq: 1001, deleted: false, data: nil)],
                                    cursor: cursor)
            #expect(a.store.notes[note.id]?.title == "Keep me")
            let row = try a.store.local.record(kind: "note", id: note.id)
            #expect(row?.seq == 1001 && (row?.dirty ?? 0) > 0)  // pushed again on top of the forged change

            // An authentic tombstone deletes, whatever the flag says.
            let tombstone = try a.store.sealTombstone(kind: "note", id: gone.id)
            try a.store.applyRemote([RemoteChange(kind: "note", id: gone.id, seq: 1002, deleted: false, data: tombstone)],
                                    cursor: cursor)
            #expect(a.store.notes[gone.id] == nil)
            #expect(a.store.notes[note.id] != nil)
        }
    }

    @Test func openEditorDefersRemoteChanges() async throws {
        try await withAccount { keys in
            let a = try client(keys), b = try client(keys)
            defer { [a.dir, b.dir].forEach { try? FileManager.default.removeItem(at: $0) } }
            var note = a.store.create(.note)
            note.title = "Shared"
            note.body = "v1"
            a.store.save(note)
            try await sync(a)
            try await sync(b)

            b.store.editorOpened(note.id)
            var fromA = a.store.notes[note.id]!
            fromA.color = "#FFCC80"
            a.store.save(fromA)
            try await sync(a)
            try await sync(b)
            #expect(b.store.notes[note.id]?.color == NoteColor.defaultValue)  // held back

            var fromB = b.store.notes[note.id]!
            fromB.body = "v2 from B"
            b.store.save(fromB)
            try await sync(b)  // not pushed while a remote version waits
            try await sync(a)
            #expect(a.store.notes[note.id]?.body == "v1")

            b.store.editorClosed(note.id)  // three-way merge: A's color + B's body
            #expect(b.store.notes[note.id]?.color == "#FFCC80")
            #expect(b.store.notes[note.id]?.body == "v2 from B")
            try await sync(b)
            try await sync(a)
            for c in [a, b] {
                #expect(c.store.notes.count == 1)
                #expect(c.store.notes[note.id]?.color == "#FFCC80")
                #expect(c.store.notes[note.id]?.body == "v2 from B")
            }
        }
    }

    @Test func firstPullLinksIdenticalNote() async throws {
        try await withAccount { keys in
            let a = try client(keys), d = try client(keys)
            defer { [a.dir, d.dir].forEach { try? FileManager.default.removeItem(at: $0) } }
            var note = a.store.create(.list)
            note.title = "Groceries"
            note.items = ListOps.normalized([ListItem(body: "Milk")], autoSort: true)
            a.store.save(note)
            try await sync(a)

            var twin = d.store.create(.list, labels: ["Home"])
            twin.title = "Groceries"
            twin.items = ListOps.normalized([ListItem(body: "Milk")], autoSort: true)
            d.store.save(twin)
            try await sync(d)
            #expect(d.store.notes.count == 1)
            #expect(d.store.notes[note.id]?.labels == ["Home"])  // local metadata kept
            try await sync(a)
            #expect(a.store.notes.count == 1)
            #expect(a.store.notes[note.id]?.labels == ["Home"])
        }
    }
}
