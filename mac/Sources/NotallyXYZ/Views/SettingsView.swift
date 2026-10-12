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
        TabView {
            Tab("General", systemImage: "gearshape") { general }
            Tab("Appearance", systemImage: "paintbrush") { AppearanceSettings() }
        }
    }

    @ViewBuilder
    private var general: some View {
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

/// Look of the overview and the editor. The Android, Linux and Windows apps have the same settings.
struct AppearanceSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Theme", selection: $model.theme) {
                    ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Text size", selection: $model.textSize) {
                    ForEach(TextSize.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                Picker("Layout", selection: $model.gridView) {
                    Text("Grid").tag(true)
                    Text("List").tag(false)
                }
                .pickerStyle(.segmented)
                Toggle("Show note preview", isOn: $model.showPreview)
                Picker("Lines of text in preview", selection: $model.previewLines) {
                    ForEach(1...10, id: \.self) { Text("\($0)").tag($0) }
                }
                .disabled(!model.showPreview)
                Picker("Items of lists in preview", selection: $model.previewItems) {
                    ForEach(1...10, id: \.self) { Text("\($0)").tag($0) }
                }
                .disabled(!model.showPreview)
                Picker("Card size", selection: $model.cardSize) {
                    ForEach(CardSize.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show labels on cards", isOn: $model.showLabels)
                Toggle("Show images on cards", isOn: $model.showImages)
                Toggle("Show date on cards", isOn: $model.showDate)
            } header: {
                Text("Notes overview")
            } footer: {
                Text("Without a preview, a card shows the title, labels and images. A note without a title shows its first line. Card size sets the smallest height of all cards, with or without a preview.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 510)  // all rows without scrolling
    }
}
