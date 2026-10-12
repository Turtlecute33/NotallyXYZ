import NotallyCore
import SwiftUI

struct NotesView: View {
    let destination: Destination
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool
    @State private var confirmEmptyBin = false

    var body: some View {
        @Bindable var model = model
        let notes = filtered()
        let pinned = notes.filter(\.pinned)
        let others = notes.filter { !$0.pinned }
        ScrollView {
            if notes.isEmpty {
                ContentUnavailableView(emptyText, systemImage: emptyIcon)
                    .padding(.top, 120)
            } else {
                GlassEffectContainer(spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        if !pinned.isEmpty && destination != .deleted {
                            header("Pinned")
                            cards(pinned)
                            if !others.isEmpty { header("Others").padding(.top, 8) }
                        }
                        cards(destination == .deleted ? notes : others)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 96)  // room for the floating buttons
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .overlay(alignment: .bottomTrailing) {
            if destination != .deleted && destination != .archived { newButtons }
        }
        .navigationTitle(destination.title)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar { toolbar }
        .searchable(text: $model.search, placement: .toolbar, prompt: "Search")
        .searchFocused($searchFocused)
        .onChange(of: model.searchFocusRequest) { searchFocused = true }
        .confirmationDialog("Delete all notes in the bin forever?", isPresented: $confirmEmptyBin) {
            Button("Empty Bin", role: .destructive) { model.store?.emptyBin() }
        }
    }

    /// Floating buttons like the NotallyX FAB.
    private var newButtons: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Button { model.newNote(.list) } label: {
                    Label("New List", systemImage: "checklist").labelStyle(.iconOnly).font(.title3).frame(width: 28, height: 28)
                }
                .buttonStyle(.glass)
                .help("New list (⇧⌘N)")
                Button { model.newNote(.note) } label: {
                    Label("New Note", systemImage: "square.and.pencil").font(.title3.weight(.medium)).frame(height: 28)
                }
                .buttonStyle(.glassProminent)
                .help("New note (⌘N)")
            }
            .controlSize(.large)
        }
        .padding(24)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var model = model
        ToolbarItemGroup(placement: .primaryAction) {
            if destination == .deleted {
                Button("Empty Bin", systemImage: "trash.slash") { confirmEmptyBin = true }
                    .help("Empty bin")
            }
            Menu {
                Picker("Sort by", selection: $model.sortBy) {
                    ForEach(SortBy.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Order", selection: $model.sortAscending) {
                    Text("Descending").tag(false)
                    Text("Ascending").tag(true)
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort notes")
            Button(model.gridView ? "List" : "Grid", systemImage: model.gridView ? "list.bullet" : "square.grid.2x2") {
                model.gridView.toggle()
            }
            .help(model.gridView ? "Show as list" : "Show as grid")
        }
    }

    private func header(_ text: String) -> some View {
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 6)
    }

    @ViewBuilder
    private func cards(_ notes: [Note]) -> some View {
        let content = ForEach(notes) { note in
            NoteCard(note: note, sortBy: model.sortBy, search: model.search)
                .onTapGesture { model.path = [note.id] }
                .contextMenu { NoteMenu(note: note) }
        }
        if model.gridView {
            MasonryLayout(minColumnWidth: Theme.cardMinWidth, spacing: Theme.spacing) { content }
        } else {
            LazyVStack(spacing: Theme.spacing) { content }.frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
    }

    private var emptyText: String {
        if !model.search.isEmpty { return "No results" }
        switch destination {
        case .deleted: return "The bin is empty"
        case .archived: return "No archived notes"
        case .reminders: return "No reminders"
        default: return "No notes yet"
        }
    }

    private var emptyIcon: String {
        switch destination {
        case .deleted: return "trash"
        case .archived: return "archivebox"
        case .reminders: return "bell"
        default: return model.search.isEmpty ? "note.text" : "magnifyingglass"
        }
    }

    private func filtered() -> [Note] {
        guard let store = model.store else { return [] }
        let query = model.search.trimmingCharacters(in: .whitespaces)
        var notes = store.notes.values.filter { note in
            switch destination {
            case .notes: return note.folder == .notes
            case .reminders: return note.folder == .notes && !note.reminders.isEmpty
            case .unlabeled: return note.folder == .notes && note.labels.isEmpty
            case .archived: return note.folder == .archived
            case .deleted: return note.folder == .deleted
            case .label(let name): return note.folder != .deleted && note.labels.contains(name)
            }
        }
        if !query.isEmpty {
            notes = notes.filter { n in
                n.title.localizedCaseInsensitiveContains(query) || n.body.localizedCaseInsensitiveContains(query)
                    || n.items.contains { $0.body.localizedCaseInsensitiveContains(query) }
                    || n.labels.contains { $0.localizedCaseInsensitiveContains(query) }
            }
        }
        if destination == .reminders {
            return notes.sorted { ($0.nextReminder ?? .distantFuture) < ($1.nextReminder ?? .distantFuture) }
        }
        let asc = model.sortAscending
        return notes.sorted { a, b in
            let result: Bool
            switch model.sortBy {
            case .modified: result = a.modifiedTimestamp == b.modifiedTimestamp ? a.id < b.id : a.modifiedTimestamp < b.modifiedTimestamp
            case .created: result = a.timestamp == b.timestamp ? a.id < b.id : a.timestamp < b.timestamp
            case .title:
                let order = a.title.localizedCaseInsensitiveCompare(b.title)
                result = order == .orderedSame ? a.id < b.id : order == .orderedAscending
            case .color: result = a.color == b.color ? a.timestamp < b.timestamp : a.color < b.color
            }
            return asc ? result : !result
        }
    }
}
