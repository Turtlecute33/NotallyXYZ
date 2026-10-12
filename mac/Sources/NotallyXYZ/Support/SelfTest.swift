import Foundation
import NotallyCore
import UserNotifications

/// `NotallyXYZ --selftest`: checks Keychain, notifications and storage inside the signed app
/// (sandbox and signature apply), prints the result and exits.
@MainActor
enum SelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--selftest") else { return }
        var ok = true
        func check(_ name: String, _ pass: Bool, _ detail: String = "") {
            print("\(pass ? "PASS" : "FAIL") \(name) \(detail)")
            ok = ok && pass
        }
        let key = SyncKeys.generate().raw
        check("keychain save", Keychain.save(key, account: "selftest"))
        check("keychain load", Keychain.load(account: "selftest") == key)
        Keychain.delete(account: "selftest")
        check("keychain delete", Keychain.load(account: "selftest") == nil)

        let dir = AppModel.dataDirectory.deletingLastPathComponent().appendingPathComponent("NotallyXYZ-selftest")
        let store = try? NoteStore(directory: dir, keys: SyncKeys(raw: key))
        check("storage", store != nil, dir.path)
        try? FileManager.default.removeItem(at: dir)

        let done = DispatchSemaphore(value: 0)
        var status = "unknown"
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            status = "\(settings.authorizationStatus.rawValue)"
            done.signal()
        }
        check("notifications", done.wait(timeout: .now() + 5) == .success, "authorizationStatus=\(status)")
        print(ok ? "SELFTEST OK" : "SELFTEST FAILED")
        exit(ok ? 0 : 1)
    }
}
