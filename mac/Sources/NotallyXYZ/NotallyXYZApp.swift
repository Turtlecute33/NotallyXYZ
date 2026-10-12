import AppKit
import NotallyCore
import SwiftUI
import UserNotifications

@main
struct NotallyXYZApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("NotallyXYZ", id: "main") {
            Group {
                if model.isConnected {
                    ContentView()
                } else {
                    SetupView()
                }
            }
            .environment(model)
            .frame(minWidth: 720, minHeight: 480)
        }
        .defaultSize(width: 1120, height: 740)
        .windowToolbarStyle(.unified)
        .commands { AppCommands(model: model) }

        WindowGroup("Note", id: "note", for: String.self) { $id in
            if let id, model.isConnected {
                NoteEditor(id: id, inWindow: true)
                    .environment(model)
                    .frame(minWidth: 420, minHeight: 360)
            }
        }
        .defaultSize(width: 640, height: 720)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 520)
        }
    }
}

extension AppModel {
    static let shared = AppModel()
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") { model.newNote(.note) }
                .keyboardShortcut("n")
                .disabled(!model.isConnected)
            Button("New List") { model.newNote(.list) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!model.isConnected)
        }
        CommandGroup(after: .textEditing) {
            Button("Search Notes") { model.searchFocusRequest += 1 }
                .keyboardShortcut("f")
                .disabled(!model.isConnected)
        }
        CommandMenu("Sync") {
            Button("Sync Now") { model.syncNow() }
                .keyboardShortcut("r")
                .disabled(!model.isConnected)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        SelfTest.runIfRequested()
        TempFiles.cleanUp()
        UNUserNotificationCenter.current().delegate = self
        AppModel.shared.applyTheme()
        #if DEBUG
        DemoSnapshot.runIfRequested()
        #endif
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.becameActive() }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.resignedActive() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.resignedActive() }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if NSApp.isActive { AppModel.shared.becameActive() } }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        TempFiles.cleanUp()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["noteId"] as? String else { return }
        await MainActor.run {
            NSApp.activate()
            AppModel.shared.openNote(id)
        }
    }
}
