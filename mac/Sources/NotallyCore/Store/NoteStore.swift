import Foundation
import Observation

/// Decrypted notes and labels in memory, backed by the sealed local cache.
@MainActor @Observable
public final class NoteStore {
    public internal(set) var notes: [String: Note] = [:]
    public internal(set) var labels: [String: Label] = [:]
    /// Why the last save failed; nil after a save that worked. Shown to the user.
    public internal(set) var saveError: String?
    /// Notes whose remote version waits for the editor to have no unsaved changes (`mergeWaiting`).
    public internal(set) var waiting: Set<String> = []
    /// Called after every local change (sync scheduling, reminders).
    @ObservationIgnored public var onLocalChange: (() -> Void)?
    /// Called after notes changed for any reason (reminders).
    @ObservationIgnored public var onNotesChanged: (() -> Void)?

    public let keys: SyncKeys
    @ObservationIgnored let local: LocalStore
    /// Open editors per note id. The same note can be open in more than one window.
    @ObservationIgnored var openEditors: [String: Int] = [:]

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

    func sealTombstone(kind: String, id: String) throws -> Data {
        try Seal.seal(Payload.tombstone, key: keys.encKey, ad: Seal.ad(kind, id))
    }

    // MARK: Queries

    /// Labels in the NotallyX drawer order: `order` descending, then name.
    public var sortedLabels: [Label] {
        labels.values.sorted { $0.order != $1.order ? $0.order > $1.order : $0.value < $1.value }
    }

    // MARK: Note changes

    /// The longest body that Android can store, in UTF-16 units (PROTOCOL.md §5).
    static let maxBodyLength = 393_216

    public func save(_ note: Note) {
        guard notes[note.id] != note else { return }
        // Only a body that grows past the limit is refused. Other changes of a longer note are saved.
        let size = note.body.utf16.count
        if size > Self.maxBodyLength && size > (notes[note.id]?.body.utf16.count ?? 0) {
            saveError = "Could not save: the text is longer than \(Self.maxBodyLength) characters."
            return
        }
        guard write(kind: "note", id: note.id, try sealNote(note)) else { return }
        notes[note.id] = note
        for name in note.labels where labels[keys.labelID(name)] == nil { createLabel(name) }
        changed()
    }

    /// Stores a local change. Memory changes only after this returns true; else the error is shown.
    private func write(kind: String, id: String, _ sealed: @autoclosure () throws -> Data?) -> Bool {
        do {
            try local.putLocal(kind: kind, id: id, sealed: sealed())
            saveError = nil
            return true
        } catch {
            fail(error)
            return false
        }
    }

    func fail(_ error: Error) {
        NSLog("NotallyXYZ: save failed: \(error)")
        saveError = "Could not save: \(error.localizedDescription)"
    }

    public func create(_ type: NoteType, color: String = NoteColor.defaultValue, labels: [String] = []) -> Note {
        var note = Note(type: type)
        note.color = color
        note.labels = labels
        return note
    }

    public func deleteForever(_ id: String) {
        guard notes[id] != nil, write(kind: "note", id: id, nil) else { return }
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
        return notes[copy.id]
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
        guard write(kind: "label", id: id, try sealLabel(label)) else { return }
        labels[id] = label
        onLocalChange?()
    }

    /// Like NotallyX `CommonDao.updateLabel`: renames the label in every note. Returns false if
    /// nothing was renamed.
    @discardableResult
    public func renameLabel(_ old: String, to new: String) -> Bool {
        let new = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, old != new, let oldLabel = labels[keys.labelID(old)] else { return false }
        let id = keys.labelID(new)
        if labels[id] == nil {
            let label = Label(id: id, value: new, order: oldLabel.order)
            guard write(kind: "label", id: id, try sealLabel(label)) else { return false }
            labels[id] = label
        }
        removeLabelRecord(oldLabel.id)
        for var note in notes.values where note.labels.contains(old) {
            note.labels = note.labels.map { $0 == old ? new : $0 }
            note.labels = note.labels.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
            save(note)
        }
        onLocalChange?()
        return true
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
        guard labels[id] != nil, write(kind: "label", id: id, nil) else { return }
        labels[id] = nil
    }

    // MARK: Attachments

    // Encryption and decryption of files run off the main actor.

    /// Copies a file into the sealed blob cache. Returns the new attachment (UUID name like Android).
    public func importAttachment(from url: URL, mimeType: String) async throws -> FileAttachment {
        let ext = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension.lowercased())"
        let localName = UUID().uuidString.lowercased() + ext
        let blobID = keys.blobID(localName), target = local.blobURL(blobID), key = keys.encKey
        try await Task.detached { try Seal.sealFile(from: url, to: target, key: key, ad: Seal.ad("blob", blobID)) }.value
        try local.addBlob(blobID, uploaded: false)
        return FileAttachment(localName: localName, originalName: url.lastPathComponent, mimeType: mimeType)
    }

    public func hasAttachment(_ localName: String) -> Bool { local.hasBlob(keys.blobID(localName)) }

    /// Decrypted attachment bytes, or nil if not downloaded yet.
    public func attachmentData(_ localName: String) async -> Data? {
        let id = keys.blobID(localName), source = local.blobURL(id), key = keys.encKey
        return await Task.detached {
            guard let sealed = try? Data(contentsOf: source) else { return nil }
            return try? Seal.open(sealed, key: key, ad: Seal.ad("blob", id))
        }.value
    }

    /// Writes the plaintext attachment to `target` (for opening in another app).
    public func exportAttachment(_ localName: String, to target: URL) async throws {
        let id = keys.blobID(localName), source = local.blobURL(id), key = keys.encKey
        try await Task.detached { try Seal.openFile(from: source, to: target, key: key, ad: Seal.ad("blob", id)) }.value
    }

    var referencedBlobIDs: Set<String> {
        Set(notes.values.flatMap { $0.allAttachmentNames.map(keys.blobID) })
    }
}
