#if DEBUG
import AppKit

/// Debug builds only: with NXYZ_DEMO_SNAPSHOT=1 the app renders its main window to PNG files in
/// its temporary directory (light/dark, narrow/wide, list and text editors), then quits.
@MainActor
enum DemoSnapshot {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["NXYZ_DEMO_SNAPSHOT"] == "1" else { return }
        Task {
            let model = AppModel.shared
            try? await Task.sleep(for: .seconds(4))
            let wide = NSSize(width: 1400, height: 900), narrow = NSSize(width: 780, height: 860)
            for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                NSApp.appearance = NSAppearance(named: appearance)
                for (size, width) in [(wide, "wide"), (narrow, "narrow")] {
                    resize(size)
                    try? await Task.sleep(for: .seconds(2))
                    capture("\(name)-\(width)")
                }
                resize(wide)
                for title in ["Grocery List", "Formatting"] {
                    guard let id = model.store?.notes.values.first(where: { $0.title == title })?.id else { continue }
                    model.path = [id]
                    try? await Task.sleep(for: .seconds(2))
                    capture("\(name)-\(title == "Formatting" ? "text" : "list")")
                }
                model.path = []
            }
            NSApp.terminate(nil)
        }
    }

    private static var window: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true }
            ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
    }

    static func resize(_ size: NSSize) {
        guard let window else { return }
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
    }

    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    static func capture(_ name: String) {
        guard let window, let view = window.contentView?.superview else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        var data: Data?
        // The window server image includes glass and materials; obsolete in the SDK, so look it up.
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
            let create = unsafeBitCast(symbol, to: CreateImage.self)
            if let cg = create(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue(), cg.width > 1 {
                data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            }
        }
        if data == nil, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-\(name).png")
        try? data?.write(to: url)
    }
}
#endif
