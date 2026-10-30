import Foundation
import Testing

@testable import NotallyCore

@Suite struct ModelTests {
    @Test func payloadRoundTripKeepsUnknownFields() throws {
        let json = """
            {"v":1,"type":"LIST","folder":"ARCHIVED","color":"#FFCC80","title":"T","pinned":true,
             "timestamp":1700000000000,"modifiedTimestamp":1700000000001,"labels":["a"],"body":"",
             "spans":[{"start":0,"end":1,"bold":true,"link":true,"linkData":"note://0123456789abcdef0123456789abcdef/NOTE"}],
             "items":[{"body":"x","checked":true,"isChild":false,"order":0,"checkedTimestamp":5}],
             "images":[{"localName":"a.jpg","originalName":"b.jpg","mimeType":"image/jpeg"}],
             "files":[],"audios":[{"name":"r.m4a","duration":12,"timestamp":3}],
             "reminders":[{"id":0,"dateTime":1700000000000,"repetition":{"value":2,"unit":"MONTHS","occurrence":-1,"dayOfWeek":2}}],
             "viewMode":"READ_ONLY","futureField":{"nested":[1,2]}}
            """
        let note = try #require(Payload.decodeNote(id: "id", Data(json.utf8)))
        #expect(note.type == .list && note.folder == .archived && note.pinned && note.isReadOnly)
        #expect(note.items.first?.checkedTimestamp == 5)
        #expect(note.reminders.first?.repetition == Repetition(value: 2, unit: .months, occurrence: -1, dayOfWeek: 2))
        let again = try #require(Payload.decodeNote(id: "id", Payload.encode(note)))
        #expect(again == note)
        let dict = try JSONSerialization.jsonObject(with: Payload.encode(note)) as! [String: Any]
        #expect((dict["futureField"] as? [String: Any])?["nested"] as? [Int] == [1, 2])
    }

    @Test func listRules() {
        var items = [ListItem(body: "A"), ListItem(body: "a1", isChild: true), ListItem(body: "B"), ListItem(body: "a2", isChild: true)]
        ListOps.setChecked(&items, at: 0, true, now: 10)
        #expect(items[0].checked && items[1].checked && items[1].checkedTimestamp == 10 && !items[2].checked)
        let sorted = ListOps.normalized(items, autoSort: true)
        #expect(sorted.map(\.body) == ["B", "a2", "A", "a1"])
        #expect(sorted.map(\.order) == [0, 1, 2, 3])

        var child = [ListItem(body: "P"), ListItem(body: "c1", isChild: true), ListItem(body: "c2", isChild: true)]
        ListOps.setChecked(&child, at: 1, true, now: 1)
        #expect(!ListOps.normalized(child, autoSort: false)[0].checked)
        ListOps.setChecked(&child, at: 2, true, now: 2)
        #expect(ListOps.normalized(child, autoSort: false)[0].checked)

        var indent = [ListItem(body: "x"), ListItem(body: "y")]
        ListOps.setChild(&indent, at: 0, true)
        #expect(!indent[0].isChild)
        ListOps.setChild(&indent, at: 1, true)
        #expect(indent[1].isChild)

        var moving = [ListItem(body: "A"), ListItem(body: "a1", isChild: true), ListItem(body: "B")]
        ListOps.move(&moving, from: IndexSet(integer: 0), to: 3)
        #expect(moving.map(\.body) == ["B", "A", "a1"])

        var del = [ListItem(body: "A", checked: true), ListItem(body: "B")]
        ListOps.deleteChecked(&del)
        #expect(del.map(\.body) == ["B"])
    }

    @Test func repetition() {
        let cal = Calendar(identifier: .gregorian)
        let start = cal.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 9))!
        let r = Reminder(id: 0, dateTime: Int64(start.timeIntervalSince1970 * 1000), repetition: Repetition(value: 1, unit: .days))
        let from = cal.date(from: DateComponents(year: 2026, month: 2, day: 3, hour: 10))!
        #expect(r.nextNotification(after: from) == cal.date(from: DateComponents(year: 2026, month: 2, day: 4, hour: 9)))
        // Last Monday of the month (dayOfWeek 2), monthly.
        let last = Reminder(id: 1, dateTime: Int64(start.timeIntervalSince1970 * 1000),
                            repetition: Repetition(value: 1, unit: .months, occurrence: -1, dayOfWeek: 2))
        #expect(last.nextNotification(after: from) == cal.date(from: DateComponents(year: 2026, month: 2, day: 23, hour: 9)))
        let once = Reminder(id: 2, dateTime: Int64(start.timeIntervalSince1970 * 1000), repetition: nil)
        #expect(once.nextNotification(after: from) == nil)
    }

    @Test func serverURLValidation() {
        #expect(APIClient.validate("https://notes.example.com/") != nil)
        #expect(APIClient.validate("http://127.0.0.1:8080") != nil)
        #expect(APIClient.validate("http://notes.example.com") == nil)
        #expect(APIClient.validate("ftp://x") == nil)
        #expect(APIClient.validate("notes.example.com") == nil)
        #expect(APIClient.validate("https://u:p@notes.example.com") == nil)
        #expect(APIClient.validate("https://:p@notes.example.com") == nil)
    }
}
