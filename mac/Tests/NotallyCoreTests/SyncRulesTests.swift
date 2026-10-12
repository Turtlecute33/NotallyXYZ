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
