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

    @MainActor @Test func newLabelAfterLargestOrderDoesNotCrash() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try NoteStore(directory: dir, keys: .generate())
        let id = store.keys.labelID("Synced")
        store.labels[id] = Label(id: id, value: "Synced", order: .max)  // as decoded from a crafted record
        store.createLabel("New")
        #expect(store.labels[store.keys.labelID("New")] != nil)
    }

    @MainActor @Test func importedFileGetsANameThatReadersKeep() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try NoteStore(directory: dir, keys: .generate())
        let file = dir.appendingPathComponent("photo.j\\pg")  // "\" is allowed in a macOS file name
        try Data([1, 2, 3]).write(to: file)
        let attachment = try await store.importAttachment(from: file, mimeType: "image/jpeg")
        #expect(Payload.isSafeFileName(attachment.localName) && store.hasAttachment(attachment.localName))
        var note = store.create(.note)
        note.files = [attachment]
        #expect(Payload.decodeNote(id: note.id, Payload.encode(note))?.files == [attachment])
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

    @Test func listIsNotRewrittenWithoutEdits() throws {
        // As Android may store it: checked item first, no order, an empty item.
        let json = #"{"type":"LIST","title":"L","items":[{"body":"Done","checked":true},{"body":""},{"body":"Open"}]}"#
        let stored = try #require(Payload.decodeNote(id: "x", Data(json.utf8)))
        #expect(ListOps.toSave(stored, since: stored, autoSort: true) == nil)  // opened and closed
        var edited = stored
        edited.title = "L2"
        let saved = try #require(ListOps.toSave(edited, since: stored, autoSort: true))
        #expect(saved.items.map(\.body) == ["Open", "Done"] && saved.items.map(\.order) == [0, 1])
        // The editor still shows its own version (with the empty item): nothing more to save.
        #expect(ListOps.toSave(edited, since: saved, autoSort: true) == nil)
    }

    @Test func repetitionJumpMatchesStepping() {
        let cal = Calendar(identifier: .gregorian)
        let start = cal.date(from: DateComponents(year: 2019, month: 3, day: 5, hour: 7, minute: 30))!
        let from = cal.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 12))!
        for (unit, component) in [(RepetitionUnit.days, Calendar.Component.day), (.weeks, .weekOfYear)] {
            for value in [1, 3] {
                let r = Reminder(id: 0, dateTime: Int64(start.timeIntervalSince1970 * 1000),
                                 repetition: Repetition(value: value, unit: unit))
                var stepped = start
                while stepped <= from { stepped = cal.date(byAdding: component, value: value, to: stepped)! }
                #expect(r.nextNotification(after: from, calendar: cal) == stepped)
            }
        }
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

    // Each occurrence counts from the start date: a day that a short month cut comes back.
    // The Android ReminderRepetitionTest and desktop core_test.go have the same table.
    @Test func monthsAndYearsCountFromStart() {
        let cases: [(start: String, value: Int, unit: RepetitionUnit, from: String, next: String)] = [
            ("2025-01-31 09:00", 1, .months, "2025-02-01 00:00", "2025-02-28 09:00"),
            ("2025-01-31 09:00", 1, .months, "2025-03-01 00:00", "2025-03-31 09:00"),
            ("2025-01-31 09:00", 1, .months, "2025-04-01 00:00", "2025-04-30 09:00"),
            ("2025-01-31 09:00", 1, .months, "2025-05-01 00:00", "2025-05-31 09:00"),
            ("2024-01-31 09:00", 1, .months, "2024-02-01 00:00", "2024-02-29 09:00"),
            ("2025-01-31 09:00", 2, .months, "2025-02-01 00:00", "2025-03-31 09:00"),
            ("2025-01-31 09:00", 2, .months, "2025-04-01 00:00", "2025-05-31 09:00"),
            ("2025-01-31 09:00", 2, .months, "2025-10-01 00:00", "2025-11-30 09:00"),
            ("2025-08-31 09:00", 1, .months, "2025-09-01 00:00", "2025-09-30 09:00"),
            ("2025-08-31 09:00", 1, .months, "2025-10-01 00:00", "2025-10-31 09:00"),
            ("2025-08-31 09:00", 1, .months, "2026-03-01 00:00", "2026-03-31 09:00"),
            ("2024-02-29 09:00", 1, .years, "2024-03-01 00:00", "2025-02-28 09:00"),
            ("2024-02-29 09:00", 1, .years, "2026-03-01 00:00", "2027-02-28 09:00"),
            ("2024-02-29 09:00", 1, .years, "2027-03-01 00:00", "2028-02-29 09:00"),
            ("2025-03-15 09:00", 1, .months, "2025-03-16 00:00", "2025-04-15 09:00"),
            ("2025-03-15 09:00", 1, .months, "2026-01-01 00:00", "2026-01-15 09:00"),
            ("2025-01-31 09:00", 1, .months, "2025-03-31 08:00", "2025-03-31 09:00"),
            ("2025-01-31 09:00", 1, .months, "2025-03-31 09:00", "2025-04-30 09:00"),
            ("2025-01-31 09:00", 1, .months, "2025-03-31 10:00", "2025-04-30 09:00"),
        ]
        let cal = Calendar(identifier: .gregorian)
        let format = DateFormatter()
        format.calendar = cal
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm"
        for c in cases {
            let start = format.date(from: c.start)!
            let r = Reminder(id: 0, dateTime: Int64(start.timeIntervalSince1970 * 1000),
                             repetition: Repetition(value: c.value, unit: c.unit))
            #expect(r.nextNotification(after: format.date(from: c.from)!, calendar: cal) == format.date(from: c.next),
                    "\(c.start) every \(c.value) \(c.unit) from \(c.from)")
        }
        // In Asunción, October 2017 starts at 01:00 (a time change at midnight).
        var asuncion = Calendar(identifier: .gregorian)
        asuncion.timeZone = TimeZone(identifier: "America/Asuncion")!
        let start = asuncion.date(from: DateComponents(year: 2017, month: 10, day: 15, hour: 9))!
        let r = Reminder(id: 0, dateTime: Int64(start.timeIntervalSince1970 * 1000), repetition: Repetition(value: 1, unit: .months))
        let from = asuncion.date(from: DateComponents(year: 2017, month: 12, day: 20, hour: 9))!
        #expect(r.nextNotification(after: from, calendar: asuncion) == asuncion.date(from: DateComponents(year: 2018, month: 1, day: 15, hour: 9)))
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
