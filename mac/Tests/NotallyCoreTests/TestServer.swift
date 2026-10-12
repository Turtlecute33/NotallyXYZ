import Foundation

/// Runs the real Go server (built to /tmp/nxyz-mac-test-server) on 127.0.0.1:8788.
final class TestServer {
    static let binary = "/tmp/nxyz-mac-test-server"
    static let url = URL(string: "http://127.0.0.1:8788")!
    static let invite = "mac-test-invite-0123456789"
    static var available: Bool { FileManager.default.isExecutableFile(atPath: binary) }

    let dataDir: URL
    private let process = Process()

    init() throws {
        dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("nxyz-server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        process.executableURL = URL(fileURLWithPath: Self.binary)
        process.environment = [
            "DATA_DIR": dataDir.path,
            "LISTEN_ADDR": "127.0.0.1:8788",
            "SIGNUP_TOKEN": Self.invite,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    func waitUntilReady() async throws {
        for _ in 0..<100 {
            if let (_, response) = try? await URLSession.shared.data(from: Self.url.appendingPathComponent("v1/health")),
               (response as? HTTPURLResponse)?.statusCode == 200 { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw URLError(.cannotConnectToHost)
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: dataDir)
    }
}

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nxyz-client-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
