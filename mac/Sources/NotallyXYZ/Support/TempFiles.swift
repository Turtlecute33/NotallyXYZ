import AppKit
import NotallyCore

/// Plaintext copies for "open in another app". Private directory, removed on quit and on launch.
enum TempFiles {
    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("NotallyXYZ-open", isDirectory: true)
    }

    @MainActor
    static func open(_ attachment: FileAttachment, store: NoteStore) {
        do {
            let dir = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let safeName = attachment.originalName.replacingOccurrences(of: "/", with: "_")
            let target = dir.appendingPathComponent(safeName.isEmpty ? attachment.localName : safeName)
            try store.exportAttachment(attachment.localName, to: target)
            NSWorkspace.shared.open(target)
        } catch {
            NSSound.beep()
        }
    }

    static func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}
