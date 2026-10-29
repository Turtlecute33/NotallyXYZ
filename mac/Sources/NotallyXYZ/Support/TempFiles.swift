import AppKit
import NotallyCore

/// Plaintext copies for "open in another app". Private directory, removed on quit and on launch.
enum TempFiles {
    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("NotallyXYZ-open", isDirectory: true)
    }

    /// Files of these types can run code, install software or open a link. Show them in Finder, do not open them.
    private static let risky: Set<String> = [
        "exe", "bat", "cmd", "com", "msi", "ps1", "vbs", "vbe", "js", "jse", "wsf", "hta", "scr", "lnk", "jar",
        "desktop", "sh", "appimage", "run", "py", "reg", "cpl", "msc", "pif", "url", "html", "htm", "svg",
        "terminal", "command", "tool", "pkg", "mpkg", "dmg", "webloc", "inetloc", "fileloc", "webarchive",
        "shortcut", "workflow", "scpt", "applescript", "mobileconfig", "xhtml", "xht", "shtml", "afploc", "ftploc",
        "mailloc", "newsloc",
    ]

    @MainActor
    static func open(_ attachment: FileAttachment, store: NoteStore) {
        do {
            let dir = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let name = Payload.isSafeFileName(attachment.originalName) ? attachment.originalName : attachment.localName
            let target = dir.appendingPathComponent(name)
            try store.exportAttachment(attachment.localName, to: target)
            if risky.contains(target.pathExtension.lowercased()) {
                NSWorkspace.shared.activateFileViewerSelecting([target])
            } else {
                NSWorkspace.shared.open(target)
            }
        } catch {
            NSSound.beep()
        }
    }

    static func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}
