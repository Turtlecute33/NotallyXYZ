import Foundation
import Testing

@testable import NotallyCore

@Suite struct MergeTests {
    func note(_ change: (inout Note) -> Void = { _ in }) -> Note {
        var n = Note(id: "0123456789abcdef0123456789abcdef", type: .note, now: 1000)
        n.title = "T"
        n.body = "base"
        n.labels = ["a"]
        change(&n)
        return n
    }

    @Test func oneSideChanges() {
        let base = note()
        let local = note { $0.color = "#FFCC80" }
        let remote = note { $0.body = "remote"; $0.pinned = true; $0.modifiedTimestamp = 2000 }
        let r = NoteMerge.merge(base: base, local: local, remote: remote)
        #expect(r.conflictCopy == nil)
        #expect(r.note.body == "remote" && r.note.pinned && r.note.color == "#FFCC80")
        #expect(r.note.modifiedTimestamp == 2000)
    }

    @Test func bothChangeContent() {
        let base = note()
        let r = NoteMerge.merge(base: base, local: note { $0.body = "mine" }, remote: note { $0.body = "theirs" })
        #expect(r.note.body == "mine")
        #expect(r.conflictCopy?.body == "theirs")
        #expect(r.conflictCopy?.title == "T (conflict)")
        #expect(r.conflictCopy?.id != base.id)
        let untitled = NoteMerge.merge(base: note { $0.title = "" }, local: note { $0.title = ""; $0.body = "x" },
                                       remote: note { $0.title = ""; $0.body = "y" })
        #expect(untitled.conflictCopy?.title == "(conflict)")
    }

    @Test func bothChangeMetadata() {
        let base = note()
        let img = { (n: String) in FileAttachment(localName: n, originalName: n, mimeType: "image/png") }
        let local = note { $0.labels = ["a", "l"]; $0.color = "#FFCC80"; $0.images = [img("1.png")] }
        let remote = note { $0.labels = ["r"]; $0.color = "#AFCCDC"; $0.images = [img("1.png"), img("2.png")] }
        let r = NoteMerge.merge(base: base, local: local, remote: remote)
        #expect(r.note.color == "#FFCC80")  // local wins
        #expect(r.note.labels == ["a", "l", "r"])  // union
        #expect(r.note.images.map(\.localName) == ["1.png", "2.png"])
        #expect(r.conflictCopy == nil)
    }

    @Test func nullsAreOmitted() throws {
        var n = note()
        n.spans = [Span(start: 0, end: 1, bold: true)]
        n.items = [ListItem(body: "x")]
        n.audios = [Audio(name: "a.m4a", duration: nil, timestamp: 1)]
        n.reminders = [Reminder(id: 0, dateTime: 5, repetition: nil)]
        let json = String(decoding: Payload.encode(n), as: UTF8.self)
        #expect(!json.contains("null"))
        // Android writes "\/" and leaves out null keys; both must parse.
        let android = #"{"type":"NOTE","title":"a\/b","spans":[{"start":0,"end":1,"link":true}],"items":[{"body":"x"}]}"#
        let parsed = try #require(Payload.decodeNote(id: "x", Data(android.utf8)))
        #expect(parsed.title == "a/b" && parsed.spans.first?.linkData == nil && parsed.items.first?.order == nil)
    }

    @Test func unsafeAttachmentNamesAreDropped() throws {
        let json = #"{"images":[{"localName":"../x","originalName":"a","mimeType":"image/png"},{"localName":".hidden","mimeType":"image/png"},{"localName":"ok.png","mimeType":"image/png"}],"audios":[{"name":"a\\b","timestamp":1},{"name":"","timestamp":1}]}"#
        let n = try #require(Payload.decodeNote(id: "x", Data(json.utf8)))
        #expect(n.images.map(\.localName) == ["ok.png"])
        #expect(n.audios.isEmpty)
        #expect(!Payload.isSafeFileName(String(repeating: "a", count: 256)))
        #expect(!Payload.isSafeFileName("a\u{7}b"))
    }
}
