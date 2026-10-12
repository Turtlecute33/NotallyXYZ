import SwiftUI

/// Floating glass bar of a text note, like the NotallyX formatting toolbar.
struct FormattingBar: View {
    let controller: EditorController
    let onLink: () -> Void

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 4) {
                button("link", "Link (select text first)", action: onLink)
                button("bold", "Bold (⌘B)") { controller.toggle(.bold) }
                button("italic", "Italic (⌘I)") { controller.toggle(.italic) }
                button("strikethrough", "Strikethrough (⇧⌘X)") { controller.toggle(.strikethrough) }
                button("chevron.left.forwardslash.chevron.right", "Monospace (⇧⌘M)") { controller.toggle(.monospace) }
                button("eraser", "Clear formatting") { controller.clearFormatting() }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
        }
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 30, height: 26) }
            .buttonStyle(.borderless)
            .help(help)
    }
}
