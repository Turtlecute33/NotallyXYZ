import AppKit
import NotallyCore
import SwiftUI

enum Destination: Hashable {
    case notes, reminders, unlabeled, archived, deleted
    case label(String)

    var title: String {
        switch self {
        case .notes: return "Notes"
        case .reminders: return "Reminders"
        case .unlabeled: return "Unlabeled"
        case .archived: return "Archived"
        case .deleted: return "Deleted"
        case .label(let name): return name
        }
    }
}

enum SortBy: String, CaseIterable, Identifiable {
    case modified = "Modified date", created = "Creation date", title = "Title", color = "Color"
    var id: String { rawValue }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// nil follows the system.
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum TextSize: String, CaseIterable, Identifiable {
    case small, normal = "default", large, extraLarge
    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: return "Small"
        case .normal: return "Default"
        case .large: return "Large"
        case .extraLarge: return "Extra large"
        }
    }

    var scale: CGFloat {
        switch self {
        case .small: return 0.9
        case .normal: return 1
        case .large: return 1.15
        case .extraLarge: return 1.3
        }
    }

    static let key = "appearance.textSize"
    /// Read outside the main actor too (editor fonts).
    static var current: TextSize { TextSize(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .normal }
}

@MainActor @Observable
final class AppModel {
    private(set) var store: NoteStore?
    private(set) var engine: SyncEngine?
    var destination: Destination = .notes { didSet { if oldValue != destination { path = [] } } }
    var path: [String] = []
    var search = ""
    var searchFocusRequest = 0
    /// New notes that are not saved yet (saved on the first content).
    var drafts: [String: Note] = [:]

    @ObservationIgnored private let defaults = UserDefaults.standard

    var serverURL = "" { didSet { defaults.set(serverURL, forKey: "serverURL") } }
    var sortBy: SortBy = .modified { didSet { defaults.set(sortBy.rawValue, forKey: "sortBy") } }
    var sortAscending = false { didSet { defaults.set(sortAscending, forKey: "sortAscending") } }
    var gridView = true { didSet { defaults.set(gridView, forKey: "gridView") } }
    var autoSortChecked = true { didSet { defaults.set(autoSortChecked, forKey: "autoSortChecked") } }

    // Appearance
    var theme: AppTheme = .system { didSet { defaults.set(theme.rawValue, forKey: "appearance.theme"); applyTheme() } }
    var textSize: TextSize = .normal { didSet { defaults.set(textSize.rawValue, forKey: TextSize.key) } }
    var showPreview = true { didSet { defaults.set(showPreview, forKey: "appearance.showPreview") } }
    var previewLines = 8 { didSet { defaults.set(previewLines, forKey: "appearance.previewLines") } }
    var previewItems = 4 { didSet { defaults.set(previewItems, forKey: "appearance.previewItems") } }
    var showLabels = true { didSet { defaults.set(showLabels, forKey: "appearance.showLabels") } }
    var showImages = true { didSet { defaults.set(showImages, forKey: "appearance.showImages") } }
    var showDate = true { didSet { defaults.set(showDate, forKey: "appearance.showDate") } }

    @ObservationIgnored private var reminderTask: Task<Void, Never>?

    static var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotallyXYZ", isDirectory: true)
    }

    init() {
        defaults.register(defaults: [
            "gridView": true, "autoSortChecked": true, "appearance.showPreview": true, "appearance.previewLines": 8,
            "appearance.previewItems": 4, "appearance.showLabels": true, "appearance.showImages": true,
            "appearance.showDate": true,
        ])
        serverURL = defaults.string(forKey: "serverURL") ?? ""
        sortBy = SortBy(rawValue: defaults.string(forKey: "sortBy") ?? "") ?? .modified
        sortAscending = defaults.bool(forKey: "sortAscending")
        gridView = defaults.bool(forKey: "gridView")
        autoSortChecked = defaults.bool(forKey: "autoSortChecked")
        theme = AppTheme(rawValue: defaults.string(forKey: "appearance.theme") ?? "") ?? .system
        textSize = TextSize.current
        showPreview = defaults.bool(forKey: "appearance.showPreview")
        previewLines = min(10, max(1, defaults.integer(forKey: "appearance.previewLines")))
        previewItems = min(10, max(1, defaults.integer(forKey: "appearance.previewItems")))
        showLabels = defaults.bool(forKey: "appearance.showLabels")
        showImages = defaults.bool(forKey: "appearance.showImages")
        showDate = defaults.bool(forKey: "appearance.showDate")
        #if DEBUG
        // Screenshots and manual tests only; compiled out of release builds.
        let env = ProcessInfo.processInfo.environment
        if let server = env["NXYZ_DEMO_SERVER"].flatMap(APIClient.validate),
           let keys = env["NXYZ_DEMO_KEY"].flatMap({ try? SyncKeys.parse($0) }) {
            try? finishSetup(server: server, keys: keys)
            return
        }
        #endif
        if let url = APIClient.validate(serverURL), let raw = Keychain.load() {
            try? open(url: url, keys: SyncKeys(raw: raw))
        }
    }

    var isConnected: Bool { store != nil }

    /// All windows, Settings included. NSApp is nil before launch; the delegate applies it again then.
    func applyTheme() { NSApp?.appearance = theme.appearance }

    private func open(url: URL, keys: SyncKeys) throws {
        let store = try NoteStore(directory: Self.dataDirectory, keys: keys)
        let engine = SyncEngine(store: store, api: APIClient(baseURL: url, keys: keys))
        store.onLocalChange = { [weak engine] in engine?.schedule() }
        store.onNotesChanged = { [weak self] in self?.scheduleReminders() }
        self.store = store
        self.engine = engine
        scheduleReminders()
        Task { await engine.sync() }
        if NSApp?.isActive ?? true { engine.startLive() }
    }

    // MARK: Setup

    /// Creates the account with a new key. The key is kept only after `finishSetup`.
    func createAccount(server: String, invite: String) async throws -> SyncKeys {
        guard let url = APIClient.validate(server) else { throw APIError.insecureURL }
        let keys = SyncKeys.generate()
        _ = try await APIClient(baseURL: url, keys: keys).createAccount(invite: invite)
        return keys
    }

    func connect(server: String, keyText: String) async throws {
        guard let url = APIClient.validate(server) else { throw APIError.insecureURL }
        let keys = try SyncKeys.parse(keyText)
        _ = try await APIClient(baseURL: url, keys: keys).accountInfo()
        try finishSetup(server: url, keys: keys)
    }

    func finishSetup(server url: URL, keys: SyncKeys) throws {
        wipeLocalData()
        guard Keychain.save(keys.raw) else { throw CocoaError(.fileWriteNoPermission) }
        serverURL = url.absoluteString
        try open(url: url, keys: keys)
    }

    /// Removes the local cache and the key. Notes stay on the server and other devices.
    func disconnect() {
        engine?.stopLive()
        engine = nil
        store = nil
        drafts = [:]
        path = []
        Keychain.delete()
        wipeLocalData()
        ReminderScheduler.removeAll()
    }

    func deleteServerData() async throws {
        try await engine?.api.deleteAccount()
        disconnect()
    }

    private func wipeLocalData() {
        try? FileManager.default.removeItem(at: Self.dataDirectory)
        TempFiles.cleanUp()
    }

    // MARK: Notes

    func note(_ id: String) -> Note? { store?.notes[id] ?? drafts[id] }

    func newNote(_ type: NoteType) {
        guard let store else { return }
        var labels: [String] = []
        if case .label(let name) = destination { labels = [name] }
        if ![.notes, .unlabeled].contains(destination), labels.isEmpty { destination = .notes }
        let note = store.create(type, labels: labels)
        drafts[note.id] = note
        path = [note.id]
    }

    func save(_ note: Note) {
        guard let store else { return }
        if drafts[note.id] != nil {
            guard !note.isEmpty else { drafts[note.id] = note; return }
            drafts[note.id] = nil
        }
        store.save(note)
    }

    /// Like NotallyX: a note left empty is removed when the editor closes.
    func closeEditor(_ id: String) {
        drafts[id] = nil
        if let note = store?.notes[id], note.isEmpty { store?.deleteForever(id) }
        store?.editorClosed(id)  // merges a remote version that arrived meanwhile
    }

    func openNote(_ id: String) {
        guard let note = store?.notes[id] else { return }
        switch note.folder {
        case .notes: if destination != .notes && destination != .reminders && destination != .unlabeled { destination = .notes }
        case .archived: destination = .archived
        case .deleted: destination = .deleted
        }
        path = [id]
    }

    func syncNow() {
        guard let engine else { return }
        Task { await engine.sync() }
    }

    // MARK: Lifecycle

    func becameActive() {
        guard let engine else { return }
        engine.startLive()
        Task { await engine.sync() }
        scheduleReminders()
    }

    func resignedActive() { engine?.stopLive() }

    private func scheduleReminders() {
        reminderTask?.cancel()
        reminderTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let notes = self?.store?.notes.values else { return }
            ReminderScheduler.reschedule(Array(notes))
        }
    }
}
