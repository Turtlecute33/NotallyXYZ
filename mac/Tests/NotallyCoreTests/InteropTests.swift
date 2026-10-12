import Foundation
import Testing

@testable import NotallyCore

/// Cross-client check with the Android app on a shared test account. Runs only when
/// NXYZ_INTEROP_URL and NXYZ_INTEROP_KEY_FILE are set; the Android side is driven by hand.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["NXYZ_INTEROP_URL"] != nil))
struct InteropTests {
    @Test func androidNotesArriveAndMacEditsGoBack() async throws {
        let env = ProcessInfo.processInfo.environment
        let url = URL(string: env["NXYZ_INTEROP_URL"]!)!
        let keyText = try String(contentsOfFile: env["NXYZ_INTEROP_KEY_FILE"]!, encoding: .utf8)
        let keys = try SyncKeys.parse(keyText)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nxyz-interop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try NoteStore(directory: dir, keys: keys)
        let engine = SyncEngine(store: store, api: APIClient(baseURL: url, keys: keys))

        await engine.sync()
        #expect(engine.lastError == nil)
        let fromAndroid = try #require(store.notes.values.first { $0.title == "From another device" })
        #expect(fromAndroid.labels == ["Shared"])
        #expect(fromAndroid.items.map(\.body) == ["Plan trip", "Book train"])
        #expect(fromAndroid.items.map(\.isChild) == [false, true])
        #expect(!store.notes.values.contains { $0.title == "Groceries from Android" })

        var edited = fromAndroid
        edited.items[0].checked = true
        store.save(edited)
        var note = store.create(.note, color: "#D3BFDB", labels: ["Shared"])
        note.title = "Written on the Mac"
        note.body = "bold and plain"
        note.spans = [Span(start: 0, end: 4, bold: true)]
        store.save(note)
        await engine.sync()
        #expect(engine.lastError == nil)
    }
}
