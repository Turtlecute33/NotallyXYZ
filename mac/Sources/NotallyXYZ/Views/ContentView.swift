import NotallyCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
        } detail: {
            NavigationStack(path: $model.path) {
                NotesView(destination: model.destination)
                    .navigationDestination(for: String.self) { id in
                        NoteEditor(id: id, inWindow: false)
                    }
            }
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: String?
    @State private var newName = ""
    @State private var deleting: String?
    @State private var addingLabel = false

    var body: some View {
        @Bindable var model = model
        let labels = model.store?.sortedLabels ?? []
        List(selection: Binding(get: { model.destination }, set: { if let d = $0 { model.destination = d } })) {
            Label("Notes", systemImage: "house").tag(Destination.notes)
            Section("Labels") {
                ForEach(labels) { label in
                    Label(label.value, systemImage: "tag")
                        .tag(Destination.label(label.value))
                        .contextMenu {
                            Button("Rename…") { newName = label.value; renaming = label.value }
                            Button("Delete…", role: .destructive) { deleting = label.value }
                        }
                }
                Label("Unlabeled", systemImage: "tag.slash").tag(Destination.unlabeled)
                Button { newName = ""; addingLabel = true } label: {
                    Label("New Label", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Section {
                Label("Reminders", systemImage: "bell").tag(Destination.reminders)
                Label("Archived", systemImage: "archivebox").tag(Destination.archived)
                Label("Deleted", systemImage: "trash").tag(Destination.deleted)
            }
        }
        .safeAreaInset(edge: .bottom) { SyncStatusBar().padding(10) }
        .alert("Rename label", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let old = renaming {
                    model.store?.renameLabel(old, to: newName)
                    if model.destination == .label(old) { model.destination = .label(newName) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New label", isPresented: $addingLabel) {
            TextField("Name", text: $newName)
            Button("Create") { model.store?.createLabel(newName) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete label “\(deleting ?? "")”? It is removed from all notes. The notes stay.",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Label", role: .destructive) {
                if let value = deleting {
                    model.store?.deleteLabel(value)
                    if model.destination == .label(value) { model.destination = .notes }
                }
            }
        }
    }
}

struct SyncStatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let engine = model.engine {
            HStack(spacing: 6) {
                if engine.isSyncing {
                    ProgressView().controlSize(.mini)
                    Text("Syncing…")
                } else if let error = engine.lastError {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).lineLimit(2).help(error)
                } else if let date = engine.lastSync {
                    Image(systemName: "lock.icloud")
                    Text(Date().timeIntervalSince(date) < 60
                        ? "Synced just now"
                        : "Synced \(Format.relative.localizedString(for: date, relativeTo: Date()))")
                } else {
                    Image(systemName: "lock.icloud")
                    Text("Not synced yet")
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
