import NotallyCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showKey = false
    @State private var confirmDisconnect = false
    @State private var confirmDelete = false
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        @Bindable var model = model
        Form {
            if let store = model.store, let engine = model.engine {
                Section("Sync") {
                    LabeledContent("Server", value: engine.api.baseURL.absoluteString)
                    LabeledContent("Status") { SyncStatusBar() }
                    HStack {
                        Button("Sync Now") { model.syncNow() }
                        Spacer()
                        Button(showKey ? "Hide Sync Key" : "Show Sync Key") { showKey.toggle() }
                    }
                    if showKey {
                        KeyBox(text: store.keys.display)
                        Text("Anyone with this key can read your notes. Use it only to connect your own devices.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Lists") {
                    Toggle("Move checked items to the bottom", isOn: $model.autoSortChecked)
                }
                Section("Storage") {
                    HStack {
                        Text("Remove attachments that no note uses from the server (older than 24 hours).")
                        Spacer()
                        Button("Clean Up") { cleanUp(engine) }.disabled(busy)
                    }
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
                Section("Danger zone") {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Disconnect this Mac")
                            Text("Removes the key and the local cache. Notes stay on the server.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Disconnect…") { confirmDisconnect = true }
                    }
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Delete all data on the server")
                            Text("Removes all notes and attachments from the server for every device.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Delete…", role: .destructive) { confirmDelete = true }
                    }
                }
            } else {
                Text("Not connected. Set up sync in the main window.").foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Text("Notes are encrypted on this Mac with AES-256-GCM before they leave it. The local cache is encrypted too. The app sends no analytics and connects only to your server.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Disconnect this Mac?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) { model.disconnect() }
        } message: {
            Text("Make sure you have your sync key. Unsynced changes on this Mac are lost.")
        }
        .confirmationDialog("Delete all data on the server?", isPresented: $confirmDelete) {
            Button("Delete Everything", role: .destructive) {
                Task {
                    do { try await model.deleteServerData() } catch { message = error.localizedDescription }
                }
            }
        } message: {
            Text("This cannot be undone. Other devices keep only their local copies.")
        }
    }

    private func cleanUp(_ engine: SyncEngine) {
        busy = true
        Task {
            defer { busy = false }
            do {
                let n = try await engine.removeUnusedServerBlobs()
                message = n == 0 ? "Nothing to remove." : "Removed \(n) unused attachment\(n == 1 ? "" : "s")."
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
