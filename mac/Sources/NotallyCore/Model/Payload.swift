import Foundation

/// JSON payloads of PROTOCOL.md §5. Unknown top-level fields of notes are kept.
public enum Payload {
    static let noteKeys: Set<String> = [
        "v", "type", "folder", "color", "title", "pinned", "timestamp", "modifiedTimestamp", "labels",
        "body", "spans", "items", "images", "files", "audios", "reminders", "viewMode",
    ]

    public static func encode(_ note: Note) -> Data {
        var dict = (try? JSONSerialization.jsonObject(with: note.extra)) as? [String: Any] ?? [:]
        dict["v"] = 1
        dict["type"] = note.type.rawValue
        dict["folder"] = note.folder.rawValue
        dict["color"] = note.color
        dict["title"] = note.title
        dict["pinned"] = note.pinned
        dict["timestamp"] = note.timestamp
        dict["modifiedTimestamp"] = note.modifiedTimestamp
        dict["labels"] = note.labels
        dict["body"] = note.body
        // Null values are omitted, like org.json on Android. Android reads an explicit null
        // as the string "null" (linkData) or, for `repetition`, as a daily repetition.
        dict["spans"] = note.spans.map { s -> [String: Any] in
            var out: [String: Any] = ["start": s.start, "end": s.end, "bold": s.bold, "italic": s.italic,
                                      "monospace": s.monospace, "strikethrough": s.strikethrough, "link": s.link]
            out["linkData"] = s.linkData
            return out
        }
        dict["items"] = note.items.map { i -> [String: Any] in
            var out: [String: Any] = ["body": i.body, "checked": i.checked, "isChild": i.isChild]
            out["order"] = i.order
            out["checkedTimestamp"] = i.checkedTimestamp
            return out
        }
        let file = { (f: FileAttachment) -> [String: Any] in
            ["localName": f.localName, "originalName": f.originalName, "mimeType": f.mimeType]
        }
        dict["images"] = note.images.map(file)
        dict["files"] = note.files.map(file)
        dict["audios"] = note.audios.map { a -> [String: Any] in
            var out: [String: Any] = ["name": a.name, "timestamp": a.timestamp]
            out["duration"] = a.duration
            return out
        }
        dict["reminders"] = note.reminders.map { r -> [String: Any] in
            var out: [String: Any] = ["id": r.id, "dateTime": r.dateTime]
            if let rep = r.repetition {
                var repDict: [String: Any] = ["value": rep.value, "unit": rep.unit.rawValue]
                if let o = rep.occurrence, let d = rep.dayOfWeek { repDict["occurrence"] = o; repDict["dayOfWeek"] = d }
                out["repetition"] = repDict
            }
            return out
        }
        dict["viewMode"] = note.viewMode
        return (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    public static func decodeNote(id: String, _ data: Data) -> Note? {
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var note = Note(id: id, type: NoteType(rawValue: dict.string("type") ?? "") ?? .note, now: dict.int64("timestamp") ?? 0)
        note.folder = Folder(rawValue: dict.string("folder") ?? "") ?? .notes
        note.color = dict.string("color") ?? NoteColor.defaultValue
        note.title = dict.string("title") ?? ""
        note.pinned = dict.bool("pinned")
        note.modifiedTimestamp = dict.int64("modifiedTimestamp") ?? note.timestamp
        note.labels = (dict["labels"] as? [Any])?.compactMap { $0 as? String } ?? []
        note.body = dict.string("body") ?? ""
        note.spans = dict.objects("spans").compactMap { s in
            guard let start = s.int("start"), let end = s.int("end") else { return nil }
            return Span(start: start, end: end, bold: s.bool("bold"), italic: s.bool("italic"),
                        monospace: s.bool("monospace"), strikethrough: s.bool("strikethrough"),
                        link: s.bool("link"), linkData: s.string("linkData"))
        }
        note.items = dict.objects("items").map { i in
            ListItem(body: i.string("body") ?? "", checked: i.bool("checked"), isChild: i.bool("isChild"),
                     order: i.int("order"), checkedTimestamp: i.int64("checkedTimestamp"))
        }
        let file = { (f: [String: Any]) -> FileAttachment? in
            guard let local = f.string("localName") ?? f.string("name"), isSafeFileName(local) else { return nil }
            return FileAttachment(localName: local,
                                  originalName: f.string("originalName") ?? String(local.split(separator: "/").last ?? ""),
                                  mimeType: f.string("mimeType") ?? "application/octet-stream")
        }
        note.images = dict.objects("images").compactMap(file)
        note.files = dict.objects("files").compactMap(file)
        note.audios = dict.objects("audios").compactMap { a in
            guard let name = a.string("name"), isSafeFileName(name) else { return nil }
            return Audio(name: name, duration: a.int64("duration"), timestamp: a.int64("timestamp") ?? 0)
        }
        note.reminders = dict.objects("reminders").compactMap { r in
            guard let id = r.int64("id"), let dt = r.int64("dateTime") else { return nil }
            var rep: Repetition?
            if let rd = r["repetition"] as? [String: Any], let unit = RepetitionUnit(rawValue: rd.string("unit") ?? "") {
                rep = Repetition(value: rd.int("value") ?? 1, unit: unit)
                if let o = rd.int("occurrence"), let d = rd.int("dayOfWeek"), [-1, 1, 2, 3, 4].contains(o), (1...7).contains(d) {
                    rep?.occurrence = o; rep?.dayOfWeek = d
                }
            }
            return Reminder(id: id, dateTime: dt, repetition: rep)
        }
        note.viewMode = dict.string("viewMode") == "READ_ONLY" ? "READ_ONLY" : "EDIT"
        let unknown = dict.filter { !noteKeys.contains($0.key) }
        note.extra = (try? JSONSerialization.data(withJSONObject: unknown, options: [.sortedKeys])) ?? Data("{}".utf8)
        return note
    }

    /// Attachment names become file names on Android: no paths, no hidden files, no control chars.
    public static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 255 && !name.hasPrefix(".")
            && !name.contains("/") && !name.contains("\\")
            && !name.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    public static func encode(_ label: Label) -> Data {
        let dict: [String: Any] = ["v": 1, "value": label.value, "order": label.order]
        return (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data()
    }

    public static func decodeLabel(id: String, _ data: Data) -> Label? {
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let value = dict.string("value") else { return nil }
        return Label(id: id, value: value, order: dict.int("order") ?? 0)
    }
}

private extension Dictionary where Key == String, Value == Any {
    func string(_ k: String) -> String? { self[k] as? String }
    func bool(_ k: String) -> Bool { (self[k] as? NSNumber)?.boolValue ?? false }
    func int(_ k: String) -> Int? { (self[k] as? NSNumber)?.intValue }
    func int64(_ k: String) -> Int64? { (self[k] as? NSNumber)?.int64Value }
    func objects(_ k: String) -> [[String: Any]] { (self[k] as? [Any])?.compactMap { $0 as? [String: Any] } ?? [] }
}
