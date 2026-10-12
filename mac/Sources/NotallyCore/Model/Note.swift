import Foundation

public enum NoteType: String, Sendable { case note = "NOTE", list = "LIST" }
public enum Folder: String, Sendable, CaseIterable { case notes = "NOTES", archived = "ARCHIVED", deleted = "DELETED" }

public struct Span: Equatable, Sendable {
    public var start: Int
    public var end: Int
    public var bold = false
    public var italic = false
    public var monospace = false
    public var strikethrough = false
    public var link = false
    public var linkData: String?

    public init(start: Int, end: Int, bold: Bool = false, italic: Bool = false, monospace: Bool = false,
                strikethrough: Bool = false, link: Bool = false, linkData: String? = nil) {
        self.start = start; self.end = end; self.bold = bold; self.italic = italic
        self.monospace = monospace; self.strikethrough = strikethrough; self.link = link; self.linkData = linkData
    }

    public var isUseful: Bool { bold || italic || monospace || strikethrough || link }
}

public struct ListItem: Equatable, Identifiable, Sendable {
    /// Local identity for the UI only. Not synced.
    public var id = UUID()
    public var body: String
    public var checked = false
    public var isChild = false
    public var order: Int?
    public var checkedTimestamp: Int64?

    public init(body: String, checked: Bool = false, isChild: Bool = false, order: Int? = nil, checkedTimestamp: Int64? = nil) {
        self.body = body; self.checked = checked; self.isChild = isChild
        self.order = order; self.checkedTimestamp = checkedTimestamp
    }

    public static func == (a: ListItem, b: ListItem) -> Bool {
        a.body == b.body && a.checked == b.checked && a.isChild == b.isChild
            && a.order == b.order && a.checkedTimestamp == b.checkedTimestamp
    }
}

public struct FileAttachment: Equatable, Hashable, Sendable {
    public var localName: String
    public var originalName: String
    public var mimeType: String

    public init(localName: String, originalName: String, mimeType: String) {
        self.localName = localName; self.originalName = originalName; self.mimeType = mimeType
    }
}

public struct Audio: Equatable, Hashable, Sendable {
    public var name: String
    public var duration: Int64?
    public var timestamp: Int64

    public init(name: String, duration: Int64?, timestamp: Int64) {
        self.name = name; self.duration = duration; self.timestamp = timestamp
    }
}

public enum RepetitionUnit: String, CaseIterable, Sendable {
    case minutes = "MINUTES", hours = "HOURS", days = "DAYS", weeks = "WEEKS", months = "MONTHS", years = "YEARS"
}

public struct Repetition: Equatable, Sendable {
    public var value: Int
    public var unit: RepetitionUnit
    /// MONTHS only: 1...4 or -1 (last) occurrence of `dayOfWeek` (1 = Sunday ... 7 = Saturday).
    public var occurrence: Int?
    public var dayOfWeek: Int?

    public init(value: Int, unit: RepetitionUnit, occurrence: Int? = nil, dayOfWeek: Int? = nil) {
        self.value = max(1, value); self.unit = unit; self.occurrence = occurrence; self.dayOfWeek = dayOfWeek
    }
}

public struct Reminder: Equatable, Identifiable, Sendable {
    public var id: Int64
    public var dateTime: Int64
    public var repetition: Repetition?

    public init(id: Int64, dateTime: Int64, repetition: Repetition?) {
        self.id = id; self.dateTime = dateTime; self.repetition = repetition
    }

    public var date: Date { Date(timeIntervalSince1970: Double(dateTime) / 1000) }
}

public struct Note: Equatable, Identifiable, Sendable {
    public var id: String
    public var type: NoteType = .note
    public var folder: Folder = .notes
    public var color: String = NoteColor.defaultValue
    public var title = ""
    public var pinned = false
    public var timestamp: Int64
    public var modifiedTimestamp: Int64
    public var labels: [String] = []
    public var body = ""
    public var spans: [Span] = []
    public var items: [ListItem] = []
    public var images: [FileAttachment] = []
    public var files: [FileAttachment] = []
    public var audios: [Audio] = []
    public var reminders: [Reminder] = []
    public var viewMode = "EDIT"
    /// Top-level JSON fields this client does not know. Written back unchanged.
    public var extra = Data("{}".utf8)

    public init(id: String = Data.randomID(), type: NoteType, now: Int64 = Note.now()) {
        self.id = id; self.type = type; timestamp = now; modifiedTimestamp = now
    }

    public static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    public var isReadOnly: Bool { viewMode == "READ_ONLY" }

    /// Same title and content (PROTOCOL.md §7 conflict rule, like `BaseNote.equalContents`).
    public func equalContents(_ other: Note) -> Bool {
        type == other.type && title == other.title && body == other.body
            && spans == other.spans && items == other.items
    }

    public var allAttachmentNames: [String] {
        images.map(\.localName) + files.map(\.localName) + audios.map(\.name)
    }

    public var isEmpty: Bool {
        title.isEmpty && body.isEmpty && items.allSatisfy { $0.body.isEmpty }
            && images.isEmpty && files.isEmpty && audios.isEmpty
    }
}

public struct Label: Equatable, Identifiable, Sendable {
    public var id: String
    public var value: String
    public var order: Int

    public init(id: String, value: String, order: Int) {
        self.id = id; self.value = value; self.order = order
    }
}
