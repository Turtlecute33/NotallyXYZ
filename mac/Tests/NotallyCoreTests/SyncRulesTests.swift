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
                OutgoingChange(kind: "note", id: note.id, base: seqs[note.id]!, data: garbage),
                OutgoingChange(kind: "label", id: labelID, base: seqs[labelID]!, data: garbage),
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

    @Test func changeWithoutSealedDataIsNotADeletion() async throws {
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

            // A malicious server sends changes without sealed data (the `deleted` flag is not read).
            try a.store.applyRemote([RemoteChange(kind: "note", id: note.id, seq: 1000, data: nil)], cursor: cursor)
            try a.store.applyRemote([RemoteChange(kind: "note", id: note.id, seq: 1001, data: nil)], cursor: cursor)
            #expect(a.store.notes[note.id]?.title == "Keep me")
            let row = try a.store.local.record(kind: "note", id: note.id)
            #expect(row?.seq == 1001 && (row?.dirty ?? 0) > 0)  // pushed again on top of the forged change

            // An authentic tombstone deletes.
            let tombstone = try a.store.sealTombstone(kind: "note", id: gone.id)
            try a.store.applyRemote([RemoteChange(kind: "note", id: gone.id, seq: 1002, data: tombstone)], cursor: cursor)
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
            b.store.editorOpened(note.id)  // the same note in a second window
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

            b.store.editorClosed(note.id)  // the other window is still open
            #expect(b.store.notes[note.id]?.color == NoteColor.defaultValue)  // still held back
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

    @Test func firstPullDoesNotLinkDifferentAttachments() async throws {
        try await withAccount { keys in
            let a = try client(keys), d = try client(keys)
            defer { [a.dir, d.dir].forEach { try? FileManager.default.removeItem(at: $0) } }
            var memo = a.store.create(.note, labels: ["Voice"])  // an Android voice memo: no title, no text
            memo.audios = [Audio(name: "memo.m4a", duration: 3000, timestamp: 1)]
            memo.reminders = [Reminder(id: 0, dateTime: Note.now() + 3_600_000, repetition: nil)]
            a.store.save(memo)
            try await sync(a)

            var photo = d.store.create(.note)
            photo.images = [FileAttachment(localName: "p.jpg", originalName: "p.jpg", mimeType: "image/jpeg")]
            d.store.save(photo)
            try await sync(d)
            try await sync(a)
            for c in [a, d] {
                #expect(c.store.notes.count == 2)
                #expect(c.store.notes[memo.id]?.audios == memo.audios)
                #expect(c.store.notes[memo.id]?.labels == ["Voice"] && c.store.notes[memo.id]?.reminders == memo.reminders)
                #expect(c.store.notes[memo.id]?.images == [])
                #expect(c.store.notes[photo.id]?.images == photo.images)
            }
        }
    }

    @Test func deletionOfUnsyncedRecordIsNotSent() async throws {
        try await withAccount { keys in
            let a = try client(keys)
            defer { try? FileManager.default.removeItem(at: a.dir) }
            var note = a.store.create(.note)
            note.title = "Never synced"
            a.store.save(note)
            a.store.createLabel("Gone")
            a.store.deleteForever(note.id)
            a.store.deleteLabel("Gone")
            #expect(try a.store.local.record(kind: "note", id: note.id) == nil)
            #expect(try !a.store.local.hasDirty())
            try await sync(a)
            #expect(try await a.engine.api.changes(since: 0).changes.isEmpty)

            // Deleted while its first push was on the way: the deletion is pushed after it.
            try a.store.local.markPushed(kind: "note", id: note.id, seq: 7, dirty: 1, pushed: Data([1]))
            let row = try #require(try a.store.local.record(kind: "note", id: note.id))
            #expect(row.deleted && row.seq == 7 && row.dirty > 0)
        }
    }

    @Test func cleanEditorMergesWaitingVersion() async throws {
        try await withAccount { keys in
            let a = try client(keys), b = try client(keys)
            defer { [a.dir, b.dir].forEach { try? FileManager.default.removeItem(at: $0) } }
            var note = a.store.create(.note)
            note.title = "Shared"
            a.store.save(note)
            try await sync(a)
            try await sync(b)

            b.store.editorOpened(note.id)
            var fromA = a.store.notes[note.id]!
            fromA.color = "#FFCC80"
            a.store.save(fromA)
            try await sync(a)
            try await sync(b)
            #expect(b.store.waiting == [note.id])
            var fromB = b.store.notes[note.id]!
            fromB.body = "typed on B"
            b.store.save(fromB)  // the editor's autosave, then it has no unsaved changes
            b.store.mergeWaiting(note.id)
            #expect(b.store.waiting.isEmpty)
            #expect(b.store.notes[note.id]?.color == "#FFCC80" && b.store.notes[note.id]?.body == "typed on B")
            try await sync(b)  // pushed while the editor is still open
            try await sync(a)
            #expect(a.store.notes[note.id]?.body == "typed on B")
            b.store.editorClosed(note.id)
        }
    }

    @Test func cursorAheadStopsSyncAndCleanUp() async throws {
        try await withAccount { keys in
            let a = try client(keys)
            defer { try? FileManager.default.removeItem(at: a.dir) }
            try a.store.local.setCursor(1000)  // as after a restore of an older server backup
            await a.engine.sync()
            #expect(a.engine.lastError?.hasPrefix("The server has older data than this Mac.") == true)
            await #expect(throws: APIError.http(409, "cursor_ahead")) { _ = try await a.engine.removeUnusedServerBlobs() }
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
