import Foundation

/// Encrypted local cache. Records stay sealed exactly as on the server; blobs are sealed files.
final class LocalStore {
    struct Record {
        var kind: String
        var id: String
        var seq: Int64
        var sealed: Data?
        var deleted: Bool
        /// 0 = in sync, otherwise a counter value of the last local change.
        var dirty: Int64
        /// Sealed server version at `seq`: the base of a three-way merge.
        var base: Data?
    }

    struct Pending {
        var id: String
        var seq: Int64
        var sealed: Data?
    }

    let directory: URL
    let blobDir: URL
    private let db: SQLite
    private var dirtyCounter: Int64 = 0

    init(directory: URL) throws {
        self.directory = directory
        blobDir = directory.appendingPathComponent("blobs", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: blobDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let path = directory.appendingPathComponent("cache.sqlite").path
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        db = try SQLite(path: path)
        try db.exec("""
            CREATE TABLE IF NOT EXISTS records(
              kind TEXT NOT NULL, id TEXT NOT NULL, seq INTEGER NOT NULL DEFAULT 0, sealed BLOB,
              deleted INTEGER NOT NULL DEFAULT 0, dirty INTEGER NOT NULL DEFAULT 0, base BLOB,
              PRIMARY KEY(kind, id)) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS pending(
              id TEXT PRIMARY KEY, seq INTEGER NOT NULL, sealed BLOB) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS blobs(
              id TEXT PRIMARY KEY, uploaded INTEGER NOT NULL DEFAULT 0, created INTEGER NOT NULL) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT) WITHOUT ROWID;
            """)
        try db.query("SELECT MAX(dirty) FROM records") { dirtyCounter = $0.int(0) }
    }

    func transaction(_ body: () throws -> Void) throws { try db.transaction(body) }

    // MARK: Records

    private func record(_ row: SQLite.Row) -> Record {
        Record(kind: row.text(0) ?? "", id: row.text(1) ?? "", seq: row.int(2), sealed: row.blob(3),
               deleted: row.int(4) != 0, dirty: row.int(5), base: row.blob(6))
    }

    private static let columns = "kind, id, seq, sealed, deleted, dirty, base"

    func allRecords() throws -> [Record] {
        var out: [Record] = []
        try db.query("SELECT \(Self.columns) FROM records") { out.append(record($0)) }
        return out
    }

    func record(kind: String, id: String) throws -> Record? {
        var out: Record?
        try db.query("SELECT \(Self.columns) FROM records WHERE kind=? AND id=?", [.text(kind), .text(id)]) {
            out = record($0)
        }
        return out
    }

    func dirtyRecords() throws -> [Record] {
        var out: [Record] = []
        try db.query("SELECT \(Self.columns) FROM records WHERE dirty > 0 ORDER BY dirty") { out.append(record($0)) }
        return out
    }

    func hasDirty() throws -> Bool {
        var n: Int64 = 0
        try db.query("SELECT COUNT(*) FROM records WHERE dirty > 0") { n = $0.int(0) }
        return n > 0
    }

    func put(_ r: Record) throws {
        try db.run(
            "INSERT OR REPLACE INTO records(\(Self.columns)) VALUES(?,?,?,?,?,?,?)",
            [.text(r.kind), .text(r.id), .int(r.seq), r.sealed.map { .blob($0) } ?? .null,
             .int(r.deleted ? 1 : 0), .int(r.dirty), r.base.map { .blob($0) } ?? .null])
    }

    func deleteRow(kind: String, id: String) throws {
        try db.run("DELETE FROM records WHERE kind=? AND id=?", [.text(kind), .text(id)])
    }

    func nextDirty() -> Int64 {
        dirtyCounter += 1
        return dirtyCounter
    }

    /// Stores a local change. The server seq stays as the base for the next push.
    func putLocal(kind: String, id: String, sealed: Data?) throws {
        let current = try record(kind: kind, id: id)
        try put(Record(kind: kind, id: id, seq: current?.seq ?? 0, sealed: sealed, deleted: sealed == nil,
                       dirty: nextDirty(), base: current?.base))
    }

    /// After a successful push: the pushed version becomes the base.
    /// Keeps `dirty` if the record changed again meanwhile.
    func markPushed(kind: String, id: String, seq: Int64, dirty: Int64, pushed: Data?) throws {
        let base: SQLValue = pushed.map { .blob($0) } ?? .null
        try db.run("UPDATE records SET seq=?, base=?, dirty=0 WHERE kind=? AND id=? AND dirty=?",
                   [.int(seq), base, .text(kind), .text(id), .int(dirty)])
        if db.changes == 0 {
            try db.run("UPDATE records SET seq=?, base=? WHERE kind=? AND id=?", [.int(seq), base, .text(kind), .text(id)])
        }
    }

    /// Records the server version while the local change stays pending.
    func setServerVersion(kind: String, id: String, seq: Int64, base: Data?) throws {
        try db.run("UPDATE records SET seq=?, base=? WHERE kind=? AND id=?",
                   [.int(seq), base.map { .blob($0) } ?? .null, .text(kind), .text(id)])
    }

    /// Pushes the local copy again, e.g. to repair the server copy.
    func markDirty(kind: String, id: String) throws {
        try db.run("UPDATE records SET dirty=? WHERE kind=? AND id=?", [.int(nextDirty()), .text(kind), .text(id)])
    }

    /// Ids of notes that were never pushed and have local changes.
    func unsyncedNoteIDs() throws -> Set<String> {
        var out = Set<String>()
        try db.query("SELECT id FROM records WHERE kind='note' AND seq=0 AND dirty>0 AND deleted=0") {
            if let id = $0.text(0) { out.insert(id) }
        }
        return out
    }

    // MARK: Pending remote versions (notes open in an editor)

    func putPending(_ p: Pending) throws {
        var current: Int64 = -1
        try db.query("SELECT seq FROM pending WHERE id=?", [.text(p.id)]) { current = $0.int(0) }
        guard p.seq > current else { return }
        try db.run("INSERT OR REPLACE INTO pending(id, seq, sealed) VALUES(?,?,?)",
                   [.text(p.id), .int(p.seq), p.sealed.map { .blob($0) } ?? .null])
    }

    func takePending(_ id: String) throws -> Pending? {
        var out: Pending?
        try db.query("SELECT id, seq, sealed FROM pending WHERE id=?", [.text(id)]) {
            out = Pending(id: $0.text(0) ?? id, seq: $0.int(1), sealed: $0.blob(2))
        }
        if out != nil { try db.run("DELETE FROM pending WHERE id=?", [.text(id)]) }
        return out
    }

    func pendingIDs() throws -> Set<String> {
        var out = Set<String>()
        try db.query("SELECT id FROM pending") { if let id = $0.text(0) { out.insert(id) } }
        return out
    }

    // MARK: Meta

    func meta(_ key: String) throws -> String? {
        var out: String?
        try db.query("SELECT value FROM meta WHERE key=?", [.text(key)]) { out = $0.text(0) }
        return out
    }

    func setMeta(_ key: String, _ value: String?) throws {
        if let value {
            try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?,?)", [.text(key), .text(value)])
        } else {
            try db.run("DELETE FROM meta WHERE key=?", [.text(key)])
        }
    }

    var cursor: Int64 {
        get { (try? meta("cursor")).flatMap { $0.flatMap { Int64($0) } } ?? 0 }
    }

    func setCursor(_ value: Int64) throws { try setMeta("cursor", String(value)) }

    // MARK: Blobs

    func blobURL(_ id: String) -> URL { blobDir.appendingPathComponent(id) }

    func hasBlob(_ id: String) -> Bool { FileManager.default.fileExists(atPath: blobURL(id).path) }

    func addBlob(_ id: String, uploaded: Bool) throws {
        try db.run("INSERT OR REPLACE INTO blobs(id, uploaded, created) VALUES(?,?,?)",
                   [.text(id), .int(uploaded ? 1 : 0), .int(Int64(Date().timeIntervalSince1970))])
    }

    func pendingBlobs() throws -> [String] {
        var out: [String] = []
        try db.query("SELECT id FROM blobs WHERE uploaded=0") { if let id = $0.text(0) { out.append(id) } }
        return out
    }

    func markUploaded(_ id: String) throws {
        try db.run("UPDATE blobs SET uploaded=1 WHERE id=?", [.text(id)])
    }

    /// Removes local blob files that no note references and that are already on the server.
    func pruneBlobs(keeping referenced: Set<String>) throws {
        var removable: [String] = []
        try db.query("SELECT id FROM blobs WHERE uploaded=1") { row in
            if let id = row.text(0), !referenced.contains(id) { removable.append(id) }
        }
        for id in removable {
            try? FileManager.default.removeItem(at: blobURL(id))
            try db.run("DELETE FROM blobs WHERE id=?", [.text(id)])
        }
    }
}
