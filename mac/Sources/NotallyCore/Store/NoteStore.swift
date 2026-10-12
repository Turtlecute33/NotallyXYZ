import Foundation
import Observation

/// Decrypted notes and labels in memory, backed by the sealed local cache.
@MainActor @Observable
public final class NoteStore {
    public internal(set) var notes: [String: Note] = [:]
    public internal(set) var labels: [String: Label] = [:]
    /// Called after every local change (sync scheduling, reminders).
    @ObservationIgnored public var onLocalChange: (() -> Void)?
    /// Called after notes changed for any reason (reminders).
    @ObservationIgnored public var onNotesChanged: (() -> Void)?

    public let keys: SyncKeys
    @ObservationIgnored let local: LocalStore
    @ObservationIgnored var openEditors = Set<String>()

    public init(directory: URL, keys: SyncKeys) throws {
        self.keys = keys
        local = try LocalStore(directory: directory)
        for r in try local.allRecords() where !r.deleted {
            guard let sealed = r.sealed else { continue }
            loadIntoMemory(kind: r.kind, id: r.id, sealed: sealed)
        }
        // Remote versions held back for an editor when the app quit.
        for id in try local.pendingIDs() { try applyPending(id) }
    }

    @discardableResult
    func loadIntoMemory(kind: String, id: String, sealed: Data) -> Bool {
        guard let plain = try? Seal.open(sealed, key: keys.encKey, ad: Seal.ad(kind, id)) else { return false }
        switch kind {
        case "note":
            guard let note = Payload.decodeNote(id: id, plain) else { return false }
            notes[id] = note
        case "label":
            guard let label = Payload.decodeLabel(id: id, plain) else { return false }
            labels[id] = label
        default:
            return false
        }
        return true
    }

    func sealNote(_ note: Note) throws -> Data {
        try Seal.seal(Payload.encode(note), key: keys.encKey, ad: Seal.ad("note", note.id))
    }

    func sealLabel(_ label: Label) throws -> Data {
        try Seal.seal(Payload.encode(label), key: keys.encKey, ad: Seal.ad("label", label.id))
    }

    // MARK: Queries

    /// Labels in the NotallyX drawer order: `order` descending, then name.
    public var sortedLabels: [Label] {
        labels.values.sorted { $0.order != $1.order ? $0.order > $1.order : $0.value < $1.value }
    }

    public func note(_ id: String) -> Note? { notes[id] }

    // MARK: Note changes

    public func save(_ note: Note) {
        guard notes[note.id] != note else { return }
        do {
            try local.putLocal(kind: "note", id: note.id, sealed: try sealNote(note))
            notes[note.id] = note
            for name in note.labels where labels[keys.labelID(name)] == nil { createLabel(name) }
            changed()
        } catch {
            NSLog("NotallyXYZ: save failed: \(error)")
        }
    }

    public func create(_ type: NoteType, color: String = NoteColor.defaultValue, labels: [String] = []) -> Note {
        var note = Note(type: type)
        note.color = color
        note.labels = labels
        return note
    }

    public func deleteForever(_ id: String) {
        guard notes[id] != nil else { return }
        try? local.putLocal(kind: "note", id: id, sealed: nil)
        notes[id] = nil
        changed()
    }

    public func emptyBin() {
        for note in notes.values where note.folder == .deleted { deleteForever(note.id) }
    }

    public func duplicate(_ id: String) -> Note? {
        guard let original = notes[id] else { return nil }
        var copy = original
        copy.id = Data.randomID()
        copy.title = original.title.isEmpty ? "Copy" : "\(original.title) (Copy)"
        copy.timestamp = Note.now()
        copy.modifiedTimestamp = copy.timestamp
        copy.reminders = []
        save(copy)
        return copy
    }

    private func changed() {
        onLocalChange?()
        onNotesChanged?()
    }

    // MARK: Labels

    public func createLabel(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let id = keys.labelID(value)
        guard labels[id] == nil else { return }
        let label = Label(id: id, value: value, order: (labels.values.map(\.order).max() ?? -1) + 1)
        try? local.putLocal(kind: "label", id: id, sealed: try sealLabel(label))
        labels[id] = label
        onLocalChange?()
    }

    /// Like NotallyX `CommonDao.updateLabel`: renames the label in every note.
    public func renameLabel(_ old: String, to new: String) {
        let new = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, old != new, let oldLabel = labels[keys.labelID(old)] else { return }
        let id = keys.labelID(new)
        if labels[id] == nil {
            let label = Label(id: id, value: new, order: oldLabel.order)
            try? local.putLocal(kind: "label", id: id, sealed: try sealLabel(label))
            labels[id] = label
        }
        removeLabelRecord(oldLabel.id)
        for var note in notes.values where note.labels.contains(old) {
            note.labels = note.labels.map { $0 == old ? new : $0 }
            note.labels = note.labels.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
            save(note)
        }
        onLocalChange?()
    }

    /// Like NotallyX `CommonDao.deleteLabel`: removes the label from every note.
    public func deleteLabel(_ value: String) {
        removeLabelRecord(keys.labelID(value))
        for var note in notes.values where note.labels.contains(value) {
            note.labels.removeAll { $0 == value }
            save(note)
        }
        onLocalChange?()
    }

    private func removeLabelRecord(_ id: String) {
        guard labels[id] != nil else { return }
        try? local.putLocal(kind: "label", id: id, sealed: nil)
        labels[id] = nil
    }

    // MARK: Attachments

    /// Copies a file into the sealed blob cache. Returns the new attachment (UUID name like Android).
    public func importAttachment(from url: URL, mimeType: String) throws -> FileAttachment {
        let ext = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension.lowercased())"
        let localName = UUID().uuidString.lowercased() + ext
        let blobID = keys.blobID(localName)
        try Seal.sealFile(from: url, to: local.blobURL(blobID), key: keys.encKey, ad: Seal.ad("blob", blobID))
        try local.addBlob(blobID, uploaded: false)
        return FileAttachment(localName: localName, originalName: url.lastPathComponent, mimeType: mimeType)
    }

    public func hasAttachment(_ localName: String) -> Bool { local.hasBlob(keys.blobID(localName)) }

    /// Decrypted attachment bytes, or nil if not downloaded yet.
    public func attachmentData(_ localName: String) -> Data? {
        let id = keys.blobID(localName)
        guard let sealed = try? Data(contentsOf: local.blobURL(id)) else { return nil }
        return try? Seal.open(sealed, key: keys.encKey, ad: Seal.ad("blob", id))
    }

    /// Writes the plaintext attachment to `target` (for opening in another app).
    public func exportAttachment(_ localName: String, to target: URL) throws {
        let id = keys.blobID(localName)
        try Seal.openFile(from: local.blobURL(id), to: target, key: keys.encKey, ad: Seal.ad("blob", id))
    }

    var referencedBlobIDs: Set<String> {
        Set(notes.values.flatMap { $0.allAttachmentNames.map(keys.blobID) })
    }
}
