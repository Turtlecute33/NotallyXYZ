import Foundation
import Observation

/// Pull, push, blobs and live updates (PROTOCOL.md §6–7). Runs on the main actor; only the
/// network waits are asynchronous, so local edits and remote changes never race.
@MainActor @Observable
public final class SyncEngine {
    public private(set) var isSyncing = false
    public private(set) var lastSync: Date?
    public private(set) var lastError: String?

    @ObservationIgnored public let api: APIClient
    @ObservationIgnored let store: NoteStore
    @ObservationIgnored private var again = false
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var live: Task<Void, Never>?
    /// Cancels the running sync or clean-up.
    @ObservationIgnored private var cancelRunning: (() -> Void)?
    @ObservationIgnored private var stopped = false
    /// Blobs that the server does not have, that are too large or that do not open: not downloaded
    /// again until the app becomes active again.
    @ObservationIgnored private var unavailableBlobs: Set<String> = []

    static let maxBatchBytes = 16 << 20
    static let maxBatchCount = 200

    public init(store: NoteStore, api: APIClient) {
        self.store = store
        self.api = api
    }

    /// Debounced sync after local edits. A later call cancels only the wait, not a running sync.
    public func schedule(after seconds: Double = 2) {
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.scheduled = nil
            await self.sync()
        }
    }

    public func sync() async {
        if isSyncing { again = true; return }
        guard !stopped else { return }
        isSyncing = true
        defer { isSyncing = false; cancelRunning = nil }
        let task = Task {
            repeat {
                again = false
                do {
                    try await runOnce()
                    lastSync = Date()
                    lastError = nil
                } catch {
                    if Task.isCancelled { return }
                    lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            } while again
        }
        cancelRunning = task.cancel
        await task.value
    }

    /// For disconnect: cancels the running sync and every later one.
    public func stop() {
        stopped = true
        stopLive()
        scheduled?.cancel()
        scheduled = nil
        cancelRunning?()
    }

    func runOnce() async throws {
        try await pull()
        for _ in 0..<3 {
            guard try await push() else { break }
            try await pull()  // conflicts: merge, then push again
        }
        await downloadMissingBlobs()
        try store.local.pruneBlobs(keeping: store.referencedBlobIDs)
    }

    func pull() async throws {
        while true {
            let page = try await api.changes(since: store.local.cursor)
            try store.applyRemote(page.changes, cursor: page.seq)
            if !page.more { break }
        }
    }

    /// Returns true if the server reported conflicts.
    func push() async throws -> Bool {
        var dirty = try store.local.dirtyRecords().filter { !store.isHeldBack($0) }
        // Caches of older versions can hold a deletion of a record that the server never had: drop it.
        for record in dirty where record.deleted && record.seq == 0 {
            try store.local.deleteRow(kind: record.kind, id: record.id)
        }
        dirty.removeAll { $0.deleted && $0.seq == 0 }
        guard !dirty.isEmpty else { return false }
        try await uploadBlobs(of: dirty)
        var conflict = false
        var batch: [LocalStore.Record] = []
        var bytes = 0
        func flush() async throws {
            guard !batch.isEmpty else { return }
            let sent = batch
            batch = []
            bytes = 0
            let results = try await api.push(try sent.map {
                OutgoingChange(kind: $0.kind, id: $0.id, base: $0.seq,
                               data: $0.deleted ? try store.sealTombstone(kind: $0.kind, id: $0.id) : $0.sealed ?? Data())
            })
            for result in results {
                guard let record = sent.first(where: { $0.kind == result.kind && $0.id == result.id }) else { continue }
                if result.conflict == true {
                    conflict = true
                } else {
                    try store.local.markPushed(kind: record.kind, id: record.id, seq: result.seq, dirty: record.dirty,
                                               pushed: record.deleted ? nil : record.sealed)
                }
            }
        }
        for record in dirty {
            if !record.deleted && record.sealed == nil { continue }
            let size = record.sealed?.count ?? 0
            if !batch.isEmpty && (bytes + size > Self.maxBatchBytes || batch.count >= Self.maxBatchCount) {
                try await flush()
            }
            batch.append(record)
            bytes += size
        }
        try await flush()
        return conflict
    }

    /// Blobs are uploaded before the notes that reference them. Blobs of the pushed notes that the
    /// server lost (clean-up of another device) are uploaded again from the local cache.
    func uploadBlobs(of records: [LocalStore.Record]) async throws {
        let used = records.filter { $0.kind == "note" }.flatMap { store.notes[$0.id]?.allAttachmentNames ?? [] }
        let ids = Array(Set(try store.local.pendingBlobs() + used.map(store.keys.blobID))).filter { store.local.hasBlob($0) }
        var missing = Set<String>()
        for start in stride(from: 0, to: ids.count, by: 1000) {
            missing.formUnion(try await api.missingBlobs(Array(ids[start..<min(start + 1000, ids.count)])))
        }
        for id in ids {
            if missing.contains(id) {
                do {
                    try await api.putBlob(id: id, file: store.local.blobURL(id))
                } catch APIError.http(413, _) {
                    // Larger than the server allows: stays on this device only. While a note uses it,
                    // it stays pending and the next push tries again. When no note uses it, prune removes it.
                    if store.referencedBlobIDs.contains(id) { continue }
                }
            }
            try store.local.markUploaded(id)
        }
    }

    func downloadMissingBlobs() async {
        for id in store.referencedBlobIDs where !store.local.hasBlob(id) && !unavailableBlobs.contains(id) {
            let key = store.keys.encKey, ad = Seal.ad("blob", id)
            do {
                // Only a blob that opens is kept.
                try await api.getBlob(id: id, to: store.local.blobURL(id)) { try Seal.checkFile($0, key: key, ad: ad) }
                try store.local.addBlob(id, uploaded: true)
            } catch APIError.http(404, _), APIError.badResponse, is SealError {
                unavailableBlobs.insert(id)
            } catch {
                continue  // network error: retried on the next sync
            }
        }
    }

    // MARK: Live updates

    /// Long poll while the app is active. Backs off on errors.
    public func startLive() {
        guard live == nil, !stopped else { return }
        unavailableBlobs = []
        live = Task { [weak self] in
            var delay: Double = 5
            while !Task.isCancelled {
                guard let self else { return }
                // While a sync runs, the cursor does not move and the server answers each poll at once.
                if self.isSyncing { try? await Task.sleep(for: .seconds(1)); continue }
                do {
                    let page = try await self.api.changes(since: self.store.local.cursor, limit: 1, wait: 25)
                    if page.changes.isEmpty { delay = 5; continue }
                    // A separate task, so that stopLive() stops the poll but not a running sync.
                    await Task { await self.sync() }.value
                    if self.lastError != nil && !self.isSyncing {
                        // A failed sync does not move the cursor. Wait as after a failed poll.
                        try? await Task.sleep(for: .seconds(delay))
                        delay = min(delay * 2, 60)
                    } else {
                        delay = 5
                    }
                } catch {
                    if Task.isCancelled { return }
                    try? await Task.sleep(for: .seconds(delay))
                    delay = min(delay * 2, 60)
                }
            }
        }
    }

    public func stopLive() {
        live?.cancel()
        live = nil
    }

    // MARK: Server clean-up

    /// Deletes server blobs that no note references and that are older than 24 hours.
    /// Only after a full sync with nothing pending (PROTOCOL.md §6, Blobs). Never at the same time as a sync.
    public func removeUnusedServerBlobs() async throws -> Int {
        while isSyncing { try await Task.sleep(for: .milliseconds(200)) }
        guard !stopped else { throw CancellationError() }
        isSyncing = true
        defer {
            isSyncing = false
            cancelRunning = nil
            if again { schedule(after: 0) }
        }
        let task = Task {
            try await runOnce()
            guard try !store.local.hasDirty() else { return 0 }
            let referenced = store.referencedBlobIDs
            let cutoff = Int64(Date().timeIntervalSince1970) - 24 * 3600
            var removed = 0
            for blob in try await api.listBlobs() where !referenced.contains(blob.id) && blob.created < cutoff {
                try await api.deleteBlob(id: blob.id)
                removed += 1
            }
            return removed
        }
        cancelRunning = task.cancel
        return try await task.value
    }
}
