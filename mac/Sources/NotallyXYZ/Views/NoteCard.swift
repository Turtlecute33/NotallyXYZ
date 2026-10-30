import NotallyCore
import SwiftUI

/// One note in the overview, laid out like NotallyX `recycler_base_note.xml`.
struct NoteCard: View {
    let note: Note
    let sortBy: SortBy
    @Environment(AppModel.self) private var model

    private var scale: CGFloat { model.textSize.scale }
    /// Without a preview, an untitled note still shows its first line.
    private var maxLines: Int { model.showPreview ? model.previewLines : note.title.isEmpty ? 1 : 0 }
    private var maxItems: Int { model.showPreview ? model.previewItems : note.title.isEmpty ? 1 : 0 }
    private var image: FileAttachment? { model.showImages ? note.images.first : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image {
                // A 4:3 box sized by the card width; the image is cropped into it.
                Thumbnail(localName: image.localName, maxPixels: 640)
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .topTrailing) {
                        if note.images.count > 1 {
                            Label("\(note.images.count)", systemImage: "photo")
                                .font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                                .glassEffect(.regular, in: .capsule)
                                .padding(8)
                        }
                    }
                    .padding(.bottom, 4)
            }
            VStack(alignment: .leading, spacing: 6) {
                if !note.title.isEmpty {
                    Text(note.title).font(.system(size: 15 * scale, weight: .medium)).lineLimit(2)
                }
                if model.showDate || !note.reminders.isEmpty || !note.audios.isEmpty { meta }
                if let file = note.files.first {
                    Label(note.files.count > 1 ? "\(file.originalName) +\(note.files.count - 1)" : file.originalName,
                          systemImage: "doc")
                        .font(.caption).lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .overlay(Capsule().stroke(.secondary.opacity(0.5)))
                }
                content
                if model.showLabels && !note.labels.isEmpty { LabelChips(labels: note.labels) }
            }
            .padding(.horizontal, 14)
            .padding(.top, image == nil ? 12 : 0)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, minHeight: model.cardSize.minHeight * scale, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)  // always the full height it needs
        .clipShape(.rect(cornerRadius: Theme.cardRadius, style: .continuous))
        .glassCard(note.color)
        .contentShape(.rect(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    /// Date, reminder and audio markers. Stacks vertically when the card is narrow.
    private var meta: some View {
        let date = sortBy == .created ? "Created \(Format.ago(note.timestamp))" : "Modified \(Format.ago(note.modifiedTimestamp))"
        let marks = HStack(spacing: 6) {
            if let next = note.nextReminder {
                Label(next.formatted(.dateTime.day().month(.abbreviated).hour().minute()), systemImage: "bell")
                    .font(.caption2).lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(Capsule().stroke(.secondary.opacity(0.5)))
            } else if !note.reminders.isEmpty {
                Image(systemName: "bell.slash").font(.caption2).foregroundStyle(.secondary)
            }
            if !note.audios.isEmpty { Image(systemName: "waveform").font(.caption2).foregroundStyle(.secondary) }
        }
        let dateText = model.showDate ? Text(date).font(.caption).foregroundStyle(.secondary).lineLimit(1) : nil
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { dateText; marks }
            VStack(alignment: .leading, spacing: 4) { dateText; marks }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch note.type {
        case .note:
            if !note.body.isEmpty && maxLines > 0 {
                Text(SpanText.attributed(note.body, note.spans))
                    .font(.system(size: 13 * scale))
                    .lineSpacing(2)
                    .lineLimit(maxLines)
            }
        case .list:
            // A parent shows as checked when all its children are, like the Android card.
            let items = ListOps.normalized(note.items, autoSort: false)
            if maxItems > 0 && !items.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(items.prefix(maxItems)) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: item.checked ? "checkmark.square.fill" : "square")
                                .font(.system(size: 12 * scale))
                            Text(item.body).font(.system(size: 13 * scale)).lineLimit(1)
                                .foregroundStyle(item.checked ? .secondary : .primary)
                        }
                        .padding(.leading, item.isChild ? 18 : 0)
                    }
                    if items.count > maxItems {
                        Label("\(items.count - maxItems)", systemImage: "plus")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct LabelChips: View {
    let labels: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(labels.prefix(4), id: \.self) { label in
                Text(label).font(.caption).lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .overlay(Capsule().stroke(.secondary.opacity(0.5)))
            }
            if labels.count > 4 { Text("+\(labels.count - 4)").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// Context menu actions of a note (overview and editor).
struct NoteMenu: View {
    let note: Note
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if note.folder == .deleted {
            Button("Restore") { move(.notes) }
            Button("Delete Forever", role: .destructive) { model.store?.deleteForever(note.id) }
        } else {
            Button("Open in New Window") { openWindow(id: "note", value: note.id) }
            Divider()
            Button(note.pinned ? "Unpin" : "Pin") { var n = note; n.pinned.toggle(); model.save(n) }
            Menu("Color") {
                ForEach(NoteColor.presets, id: \.hex) { preset in
                    Button(preset.name) { var n = note; n.color = preset.hex; model.save(n) }
                }
            }
            Button("Duplicate") { _ = model.store?.duplicate(note.id) }
            Divider()
            if note.folder == .archived {
                Button("Unarchive") { move(.notes) }
            } else {
                Button("Archive") { move(.archived) }
            }
            Button("Delete") { move(.deleted) }
        }
    }

    private func move(_ folder: Folder) {
        var n = note
        n.folder = folder
        n.modifiedTimestamp = Note.now()
        model.save(n)
        if model.path.last == note.id { model.path.removeLast() }
    }
}
