import NotallyCore
import SwiftUI
import UniformTypeIdentifiers

/// Note editor, like NotallyX `EditActivity`: note color as background, title, dates, content,
/// attachments and labels. Changes are saved after a short pause and when the editor closes.
struct NoteEditor: View {
    let id: String
    let inWindow: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var note: Note?
    @State private var lastSaved: Note?
    @State private var saveError: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var controller = EditorController()
    @State private var showLabels = false
    @State private var showColors = false
    @State private var showReminders = false
    @State private var importing: NoteStore.AttachmentKind?
    @State private var linkText = ""
    @State private var editingLink = false

    var body: some View {
        Group {
            if let note {
                content(note)
                    .scrollEdgeEffectStyle(.soft, for: .top)
                    .background { Theme.background(note.color).backgroundExtensionEffect().ignoresSafeArea() }
                    .noteColored(note.color)
                    .toolbar { toolbar(note) }
                    .navigationTitle(note.title.isEmpty ? (note.type == .list ? "List" : "Note") : note.title)
                    .toolbar(removing: .title)
                    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            } else {
                ContentUnavailableView("Note not found", systemImage: "questionmark.square.dashed")
            }
        }
        .onAppear {
            model.store?.editorOpened(id)
            note = model.note(id)
            lastSaved = note
        }
        .onDisappear {
            flush()
            model.closeEditor(id)
        }
        .onChange(of: model.note(id)) { _, remote in
            // Take remote changes while nothing local is pending.
            if saveTask == nil, let remote, remote != lastSaved {
                note = remote
                lastSaved = remote
            }
        }
        .sheet(isPresented: $showReminders) { RemindersSheet(note: binding(\.reminders, content: false)) }
        .fileImporter(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
                      allowedContentTypes: importing == .image ? [.image] : [.item],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result, let kind = importing { attach(urls, kind) }
        }
        .alert("Link", isPresented: $editingLink) {
            TextField("https://…", text: $linkText)
            Button("Set") { controller.setLink(linkText.trimmingCharacters(in: .whitespaces)) }
            Button("Remove", role: .destructive) { controller.setLink(nil) }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ note: Note) -> some View {
        let editable = !note.isReadOnly && note.folder != .deleted
        switch note.type {
        case .note:
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    header(note, editable: editable)
                    RichTextEditor(body: note.body, spans: note.spans, editable: editable,
                                   fontSize: 14 * model.textSize.scale, controller: controller,
                                   onChange: { body, spans in update(content: true) { $0.body = body; $0.spans = spans } },
                                   onOpenLink: openLink)
                        .frame(minHeight: 240, alignment: .top)
                    footer(note)
                }
                .padding(.horizontal, 32).padding(.top, 12).padding(.bottom, 90)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .overlay(alignment: .bottom) {
                if editable {
                    FormattingBar(controller: controller) {
                        linkText = controller.selectedLink ?? ""
                        editingLink = true
                    }
                    .padding(.bottom, 20)
                }
            }
        case .list:
            List {
                Section { header(note, editable: editable) }
                ListEditor(items: Binding(get: { self.note?.items ?? [] }, set: { items in update(content: true) { $0.items = items } }),
                           editable: editable, autoSort: model.autoSortChecked,
                           fontSize: 14 * model.textSize.scale, onChange: {})
                Section { footer(note) }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .contentMargins(.horizontal, 24, for: .scrollContent)
            .environment(\.defaultMinListRowHeight, 26)
        }
    }

    private func header(_ note: Note, editable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: binding(\.title, content: true), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 22 * model.textSize.scale, weight: .medium))
                .disabled(!editable)
            Text("Created \(Format.full(Format.date(note.timestamp)))  ·  Modified \(Format.ago(note.modifiedTimestamp))")
                .font(.caption).foregroundStyle(.secondary)
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            Divider().padding(.top, 4)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func footer(_ note: Note) -> some View {
        AttachmentsView(note: note, onRemove: removeAttachment)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        if !note.labels.isEmpty {
            LabelChips(labels: note.labels)
                .onTapGesture { showLabels = true }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(_ note: Note) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if note.folder == .deleted {
                Button("Restore", systemImage: "arrow.uturn.backward") { move(.notes) }
                Button("Delete Forever", systemImage: "trash.slash") {
                    model.store?.deleteForever(id)
                    close()
                }
            } else {
                Button(note.pinned ? "Unpin" : "Pin", systemImage: note.pinned ? "pin.fill" : "pin") {
                    update(content: false) { $0.pinned.toggle() }
                }
                .help(note.pinned ? "Unpin" : "Pin")
                Button("Reminders", systemImage: note.reminders.isEmpty ? "bell" : "bell.badge") { showReminders = true }
                    .help("Reminders")
                Button("Labels", systemImage: "tag") { showLabels = true }
                    .help("Labels")
                    .popover(isPresented: $showLabels) { LabelPicker(selected: binding(\.labels, content: false)) }
                Button("Color", systemImage: "paintpalette") { showColors = true }
                    .help("Color")
                    .popover(isPresented: $showColors) { ColorPickerView(color: binding(\.color, content: false)) }
                Menu {
                    Button("Add Images…") { importing = .image }
                    Button("Add Files…") { importing = .file }
                } label: { Label("Attach", systemImage: "paperclip") }
                    .help("Attach images or files")
                Button(note.isReadOnly ? "Edit" : "Read only", systemImage: note.isReadOnly ? "pencil" : "book") {
                    update(content: false) { $0.viewMode = $0.isReadOnly ? "EDIT" : "READ_ONLY" }
                }
                .help(note.isReadOnly ? "Switch to edit mode" : "Switch to read-only mode")
                Menu {
                    if !inWindow { Button("Open in New Window") { openWindow(id: "note", value: id) } }
                    Button("Duplicate") { if let copy = model.store?.duplicate(id) { model.path = [copy.id] } }
                    if note.type == .list {
                        Divider()
                        Button("Check All") { update(content: true) { n in setAll(&n, true) } }
                        Button("Uncheck All") { update(content: true) { n in setAll(&n, false) } }
                        Button("Delete Checked Items") { update(content: true) { ListOps.deleteChecked(&$0.items) } }
                    }
                    Divider()
                    if note.folder == .archived {
                        Button("Unarchive") { move(.notes) }
                    } else {
                        Button("Archive") { move(.archived) }
                    }
                    Button("Delete") { move(.deleted) }
                } label: { Label("More", systemImage: "ellipsis.circle") }
            }
        }
    }

    // MARK: Changes

    private func binding<T>(_ path: WritableKeyPath<Note, T>, content: Bool) -> Binding<T> {
        Binding(get: { note![keyPath: path] }, set: { value in update(content: content) { $0[keyPath: path] = value } })
    }

    private func update(content: Bool, _ change: (inout Note) -> Void) {
        guard var n = note else { return }
        change(&n)
        if content { n.modifiedTimestamp = Note.now() }
        note = n
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(content ? 700 : 0))
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    private func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard var n = note else { return }
        if n.type == .list { n.items = ListOps.normalized(n.items.filter { !$0.body.isEmpty }, autoSort: model.autoSortChecked) }
        guard n != lastSaved else { return }
        model.save(n)
        // After a save that did not work, lastSaved stays, so the next flush tries again.
        if model.note(id) == n {
            lastSaved = n
            saveError = nil
        } else {
            saveError = model.store?.saveError
        }
    }

    private func setAll(_ n: inout Note, _ checked: Bool) {
        for i in n.items.indices where !n.items[i].isChild { ListOps.setChecked(&n.items, at: i, checked) }
        n.items = ListOps.normalized(n.items, autoSort: model.autoSortChecked)
    }

    private func move(_ folder: Folder) {
        update(content: false) { $0.folder = folder; $0.modifiedTimestamp = Note.now() }
        flush()
        close()
    }

    private func close() {
        if inWindow { NSApp.keyWindow?.close() } else if model.path.last == id { model.path.removeLast() }
    }

    private func openLink(_ value: String) {
        if value.hasPrefix("note://") {
            let target = value.dropFirst("note://".count).split(separator: "/").first.map(String.init) ?? ""
            if model.store?.notes[target] != nil { model.path.append(target) } else { NSSound.beep() }
            return
        }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "tel"].contains(scheme) else { NSSound.beep(); return }
        NSWorkspace.shared.open(url)
    }

    private func attach(_ urls: [URL], _ kind: NoteStore.AttachmentKind) {
        guard let store = model.store else { return }
        var added: [FileAttachment] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            if let a = try? store.importAttachment(from: url, mimeType: mime) { added.append(a) }
        }
        update(content: false) { n in
            if kind == .image { n.images += added } else { n.files += added }
        }
    }

    private func removeAttachment(_ name: String) {
        update(content: false) { n in
            n.images.removeAll { $0.localName == name }
            n.files.removeAll { $0.localName == name }
            n.audios.removeAll { $0.name == name }
        }
    }
}

extension NoteStore {
    enum AttachmentKind { case image, file }
}
