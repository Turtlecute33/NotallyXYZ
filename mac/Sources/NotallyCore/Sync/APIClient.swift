import Foundation

public enum APIError: Error, Equatable, LocalizedError {
    case insecureURL
    case unauthorized
    case http(Int, String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .insecureURL: return "The server address must start with https:// (http:// only for localhost)."
        case .unauthorized: return "The server does not know this sync key."
        case .http(let status, let code): return "Server error \(status)\(code.isEmpty ? "" : ": \(code)")."
        case .badResponse: return "Unexpected server response."
        }
    }
}

public struct RemoteChange: Decodable, Sendable {
    public let kind: String
    public let id: String
    public let seq: Int64
    public let deleted: Bool
    public let data: Data?
}

public struct ChangesPage: Decodable, Sendable {
    public let changes: [RemoteChange]
    public let seq: Int64
    public let more: Bool
}

/// A deletion also carries `data`: the sealed tombstone (PROTOCOL.md §5).
public struct OutgoingChange: Encodable, Sendable {
    public let kind: String
    public let id: String
    public let base: Int64
    public let deleted: Bool
    public let data: Data
}

public struct PushResult: Decodable, Sendable {
    public let kind: String
    public let id: String
    public let seq: Int64
    public let conflict: Bool?
}

public struct BlobInfo: Decodable, Sendable {
    public let id: String
    public let size: Int64
    public let created: Int64
}

/// HTTP client for PROTOCOL.md §6. Ephemeral session: no cookies, no cache, no credential store.
public final class APIClient: Sendable {
    public let baseURL: URL
    private let bearer: String
    private let session: URLSession

    public init(baseURL: URL, keys: SyncKeys) {
        self.baseURL = baseURL
        bearer = keys.bearer
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 90
        config.httpAdditionalHeaders = ["User-Agent": "NotallyXYZ"]
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    /// Accepts https, or http only for loopback addresses (local testing).
    public static func validate(_ text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let host = url.host, !host.isEmpty, url.query == nil,
              url.user == nil, url.password == nil else { return nil }
        switch url.scheme?.lowercased() {
        case "https": return url
        case "http": return ["localhost", "127.0.0.1", "::1"].contains(host) ? url : nil
        default: return nil
        }
    }

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [], json: Encodable? = nil) throws -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(json)
        }
        return req
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw APIError.unauthorized }
            let code = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? ""
            throw APIError.http(http.statusCode, code)
        }
    }

    private func send<T: Decodable>(_ req: URLRequest, as: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: req)
        try check(response, data)
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw APIError.badResponse }
    }

    private func send(_ req: URLRequest) async throws {
        let (data, response) = try await session.data(for: req)
        try check(response, data)
    }

    // MARK: Account

    /// Returns true if the account was created, false if it already existed.
    public func createAccount(invite: String) async throws -> Bool {
        let result = try await send(try request("POST", "v1/account", json: ["invite": invite]), as: [String: Bool].self)
        return result["created"] ?? false
    }

    public func accountInfo() async throws -> [String: Int64] {
        try await send(try request("GET", "v1/account"), as: [String: Int64].self)
    }

    public func deleteAccount() async throws {
        try await send(try request("DELETE", "v1/account"))
    }

    // MARK: Records

    public func changes(since: Int64, limit: Int = 500, wait: Int = 0) async throws -> ChangesPage {
        var req = try request("GET", "v1/changes", query: [
            URLQueryItem(name: "since", value: String(since)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "wait", value: String(wait)),
        ])
        req.timeoutInterval = TimeInterval(wait + 60)
        return try await send(req, as: ChangesPage.self)
    }

    public func push(_ changes: [OutgoingChange]) async throws -> [PushResult] {
        struct Body: Encodable { let changes: [OutgoingChange] }
        struct Results: Decodable { let results: [PushResult] }
        return try await send(try request("POST", "v1/changes", json: Body(changes: changes)), as: Results.self).results
    }

    // MARK: Blobs

    public func missingBlobs(_ ids: [String]) async throws -> [String] {
        struct Missing: Decodable { let missing: [String] }
        return try await send(try request("POST", "v1/blobs/missing", json: ["ids": ids]), as: Missing.self).missing
    }

    public func putBlob(id: String, file: URL) async throws {
        var req = try request("PUT", "v1/blobs/\(id)")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 1800
        let (data, response) = try await session.upload(for: req, fromFile: file)
        try check(response, data)
    }

    /// Largest blob that this client keeps. It is fixed, because the server could report any limit.
    static let maxBlobDownload = 1 << 30

    /// Downloads into `target` (written only on success).
    public func getBlob(id: String, to target: URL) async throws {
        var req = try request("GET", "v1/blobs/\(id)")
        req.timeoutInterval = 1800
        let (temp, response) = try await session.download(for: req)
        defer { try? FileManager.default.removeItem(at: temp) }
        try check(response, Data())
        let size = try temp.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Self.maxBlobDownload else { throw APIError.badResponse }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temp, to: target)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    public func listBlobs() async throws -> [BlobInfo] {
        struct List: Decodable { let blobs: [BlobInfo] }
        return try await send(try request("GET", "v1/blobs"), as: List.self).blobs
    }

    public func deleteBlob(id: String) async throws {
        try await send(try request("DELETE", "v1/blobs/\(id)"))
    }
}

/// Redirects are not followed, like in the other clients: `check` gets the 3xx response.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
