import AVFoundation
import NotallyCore
import SwiftUI

/// Images, files and audio recordings of a note. Content is decrypted on demand.
struct AttachmentsView: View {
    let note: Note
    let onRemove: (String) -> Void
    @Environment(AppModel.self) private var model
    @State private var viewing: FileAttachment?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !note.images.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                    ForEach(note.images, id: \.localName) { image in
                        Thumbnail(localName: image.localName, maxPixels: 480)
                            .frame(height: 120)
                            .clipShape(.rect(cornerRadius: 12, style: .continuous))
                            .contentShape(Rectangle())
                            .onTapGesture { viewing = image }
                            .contextMenu { menu(image) }
                    }
                }
            }
            ForEach(note.files, id: \.localName) { file in
                HStack {
                    Image(systemName: "doc")
                    Text(file.originalName).lineLimit(1)
                    Spacer()
                    if model.store?.hasAttachment(file.localName) == false {
                        Image(systemName: "icloud.and.arrow.down").foregroundStyle(.secondary).help("Not downloaded yet")
                    }
                }
                .padding(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.4)))
                .contentShape(Rectangle())
                .onTapGesture { open(file) }
                .contextMenu { menu(file) }
            }
            ForEach(note.audios, id: \.name) { audio in
                AudioRow(audio: audio).contextMenu {
                    Button("Remove", role: .destructive) { onRemove(audio.name) }
                }
            }
        }
        .sheet(item: $viewing) { image in ImageViewer(image: image, onOpen: { open(image) }) }
    }

    @ViewBuilder
    private func menu(_ file: FileAttachment) -> some View {
        Button("Open") { open(file) }
        Button("Remove", role: .destructive) { onRemove(file.localName) }
    }

    private func open(_ file: FileAttachment) {
        guard let store = model.store, store.hasAttachment(file.localName) else { NSSound.beep(); return }
        TempFiles.open(file, store: store)
    }
}

extension FileAttachment: Identifiable {
    public var id: String { localName }
}

struct ImageViewer: View {
    let image: FileAttachment
    let onOpen: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Thumbnail(localName: image.localName, maxPixels: 2400, fill: false)
                .frame(minWidth: 480, idealWidth: 860, minHeight: 360, idealHeight: 640)
            HStack {
                Text(image.originalName).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Open in Preview", action: onOpen)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }
}

struct AudioRow: View {
    let audio: Audio
    @Environment(AppModel.self) private var model
    @State private var player: AVAudioPlayer?
    @State private var playing = false

    var body: some View {
        HStack {
            Button { toggle() } label: { Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill").font(.title2) }
                .buttonStyle(.borderless)
            Text("Audio recording")
            Spacer()
            if let ms = audio.duration {
                Text(Duration.milliseconds(ms).formatted(.time(pattern: .minuteSecond))).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.4)))
        .onDisappear { player?.stop() }
    }

    private func toggle() {
        if playing { player?.pause(); playing = false; return }
        if player == nil, let data = model.store?.attachmentData(audio.name) { player = try? AVAudioPlayer(data: data) }
        guard let player else { NSSound.beep(); return }
        player.play()
        playing = true
        Task {
            while player.isPlaying { try? await Task.sleep(for: .milliseconds(300)) }
            playing = false
        }
    }
}
