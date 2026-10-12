import Foundation
import Testing

@testable import NotallyCore

@MainActor
@Suite(.serialized, .enabled(if: TestServer.available, "build the server: go build -o /tmp/nxyz-mac-test-server ."))
struct SyncTests {
    struct Client {
        let dir: URL
        let store: NoteStore
        let engine: SyncEngine
    }

    func client(_ keys: SyncKeys) throws -> Client {
        let dir = tempDir()
        let store = try NoteStore(directory: dir, keys: keys)
        return Client(dir: dir, store: store, engine: SyncEngine(store: store, api: APIClient(baseURL: TestServer.url, keys: keys)))
    }

    func sync(_ c: Client) async throws {
        await c.engine.sync()
        if let error = c.engine.lastError { Issue.record("sync error: \(error)") }
    }

    @Test func endToEnd() async throws {
        let server = try TestServer()
        defer { server.stop() }
        try await server.waitUntilReady()

        let keys = SyncKeys.generate()
        let a = try client(keys), b = try client(keys)
        defer { [a.dir, b.dir].forEach { try? FileManager.default.removeItem(at: $0) } }

        // Account: wrong invite is refused, right invite creates it.
        await #expect(throws: APIError.self) { try await a.engine.api.createAccount(invite: "wrong-invite-0000000000") }
        #expect(try await a.engine.api.createAccount(invite: TestServer.invite))

        // A: label, text note with spans, list, attachment.
        a.store.createLabel("Work")
        var text = a.store.create(.note, color: "#FAAFA9", labels: ["Work"])
        text.title = "Hello"
        text.body = "bold and plain"
        text.spans = [Span(start: 0, end: 4, bold: true)]
        let file = a.dir.appendingPathComponent("photo.jpg")
        let photo = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        try photo.write(to: file)
        text.images = [try a.store.importAttachment(from: file, mimeType: "image/jpeg")]
        a.store.save(text)
        var list = a.store.create(.list)
        list.title = "Groceries"
        list.items = ListOps.normalized([ListItem(body: "Milk"), ListItem(body: "Oat", isChild: true)], autoSort: true)
        a.store.save(list)
        try await sync(a)

        // B pulls everything, including the blob.
        try await sync(b)
        #expect(b.store.notes.count == 2)
        #expect(b.store.sortedLabels.map(\.value) == ["Work"])
        #expect(b.store.notes[text.id]?.spans == text.spans)
        #expect(b.store.notes[text.id]?.labels == ["Work"])
        #expect(b.store.notes[list.id]?.items.map(\.body) == ["Milk", "Oat"])
        #expect(b.store.attachmentData(text.images[0].localName) == photo)

        // Concurrent edits of the same note: B keeps its version, A's becomes a conflict copy.
        var fromA = a.store.notes[text.id]!
        fromA.body = "edited on A"
        a.store.save(fromA)
        var fromB = b.store.notes[text.id]!
        fromB.body = "edited on B"
        b.store.save(fromB)
        try await sync(a)
        try await sync(b)
        try await sync(a)
        for c in [a, b] {
            #expect(c.store.notes.count == 3)
            #expect(c.store.notes[text.id]?.body == "edited on B")
            let copy = c.store.notes.values.first { $0.title == "Hello (conflict)" }
            #expect(copy?.body == "edited on A")
            #expect(copy?.images == text.images)
        }

        // Metadata-only concurrent change: no conflict copy.
        var pinA = a.store.notes[list.id]!
        pinA.pinned = true
        a.store.save(pinA)
        var colorB = b.store.notes[list.id]!
        colorB.color = "#AFCCDC"
        b.store.save(colorB)
        try await sync(a)
        try await sync(b)
        try await sync(a)
        #expect(a.store.notes.count == 3 && b.store.notes.count == 3)
        for c in [a, b] {  // field merge: both changes survive on both devices
            #expect(c.store.notes[list.id]?.color == "#AFCCDC")
            #expect(c.store.notes[list.id]?.pinned == true)
        }

        // Delete and rename propagate.
        a.store.deleteForever(list.id)
        a.store.renameLabel("Work", to: "Job")
        try await sync(a)
        try await sync(b)
        #expect(b.store.notes[list.id] == nil)
        #expect(b.store.sortedLabels.map(\.value) == ["Job"])
        #expect(b.store.notes[text.id]?.labels == ["Job"])

        // A fresh device with only the key restores the same state from the server.
        let c = try client(SyncKeys(raw: keys.raw))
        defer { try? FileManager.default.removeItem(at: c.dir) }
        try await sync(c)
        #expect(Set(c.store.notes.keys) == Set(b.store.notes.keys))
        #expect(c.store.attachmentData(text.images[0].localName) == photo)

        // The local cache never contains plaintext.
        let cache = try Data(contentsOf: b.dir.appendingPathComponent("cache.sqlite"))
            + ((try? Data(contentsOf: b.dir.appendingPathComponent("cache.sqlite-wal"))) ?? Data())
        #expect(cache.range(of: Data("edited on B".utf8)) == nil)
        #expect(cache.range(of: Data("Job".utf8)) == nil)

        // Wrong key is rejected; account deletion works.
        let stranger = APIClient(baseURL: TestServer.url, keys: .generate())
        await #expect(throws: APIError.unauthorized) { _ = try await stranger.accountInfo() }
        try await a.engine.api.deleteAccount()
        await #expect(throws: APIError.unauthorized) { _ = try await a.engine.api.accountInfo() }
    }
}
