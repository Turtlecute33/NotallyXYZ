import AppKit
import NotallyCore
import SwiftUI

enum TextStyle { case bold, italic, monospace, strikethrough }

/// Lets the formatting bar reach the focused text view.
@MainActor
final class EditorController {
    weak var textView: RichTextView?

    func toggle(_ style: TextStyle) { textView?.toggle(style) }
    func setLink(_ url: String?) { textView?.setLink(url) }
    func clearFormatting() { textView?.clearFormatting() }
    var selectedLink: String? { textView?.selectedLink }
}

/// NSTextView that grows with its content and maps formatting to span flags.
final class RichTextView: NSTextView {
    var onFormatChange: (() -> Void)?

    override var intrinsicContentSize: NSSize {
        guard let container = textContainer, let manager = layoutManager else { return super.intrinsicContentSize }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(used.height + textContainerInset.height * 2))
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }

    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        let shift = event.modifierFlags.contains(.shift)
        switch (event.charactersIgnoringModifiers?.lowercased(), shift) {
        case ("b", false): toggle(.bold)
        case ("i", false): toggle(.italic)
        case ("x", true): toggle(.strikethrough)
        case ("m", true): toggle(.monospace)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    private var attributeKey: (TextStyle) -> NSAttributedString.Key = { style in
        switch style {
        case .bold: return .nxBold
        case .italic: return .nxItalic
        case .monospace: return .nxMono
        case .strikethrough: return .strikethroughStyle
        }
    }

    func toggle(_ style: TextStyle) {
        guard isEditable, let storage = textStorage else { return }
        let key = attributeKey(style)
        let value: Any = style == .strikethrough ? NSUnderlineStyle.single.rawValue : true
        let range = selectedRange()
        if range.length == 0 {
            var attrs = typingAttributes
            attrs[key] = attrs[key] == nil ? value : nil
            attrs[.font] = SpanText.font(bold: attrs[.nxBold] != nil, italic: attrs[.nxItalic] != nil, mono: attrs[.nxMono] != nil)
            typingAttributes = attrs
            return
        }
        var allSet = true
        storage.enumerateAttribute(key, in: range) { v, _, stop in if v == nil { allSet = false; stop.pointee = true } }
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        if allSet { storage.removeAttribute(key, range: range) } else { storage.addAttribute(key, value: value, range: range) }
        SpanText.applyFonts(storage, range: range)
        storage.endEditing()
        didChangeText()
        onFormatChange?()
    }

    var selectedLink: String? {
        let range = selectedRange()
        guard let storage = textStorage, range.location < storage.length else { return nil }
        let value = storage.attribute(.link, at: range.location, effectiveRange: nil)
        return (value as? String) ?? (value as? URL)?.absoluteString
    }

    func setLink(_ url: String?) {
        guard isEditable, let storage = textStorage else { return }
        let range = selectedRange()
        guard range.length > 0, shouldChangeText(in: range, replacementString: nil) else { return }
        if let url, !url.isEmpty { storage.addAttribute(.link, value: url, range: range) } else { storage.removeAttribute(.link, range: range) }
        didChangeText()
        onFormatChange?()
    }

    func clearFormatting() {
        guard isEditable, let storage = textStorage else { return }
        let range = selectedRange()
        guard range.length > 0, shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        for key in [NSAttributedString.Key.nxBold, .nxItalic, .nxMono, .strikethroughStyle, .link] {
            storage.removeAttribute(key, range: range)
        }
        SpanText.applyFonts(storage, range: range)
        storage.endEditing()
        didChangeText()
        onFormatChange?()
    }
}

struct RichTextEditor: NSViewRepresentable {
    var body: String
    var spans: [Span]
    var editable: Bool
    /// The text size setting; a new value reloads the text with new fonts.
    var fontSize: CGFloat
    let controller: EditorController
    var onChange: (String, [Span]) -> Void
    var onOpenLink: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> RichTextView {
        let view = RichTextView(frame: .zero)
        view.delegate = context.coordinator
        view.isRichText = true
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineFragmentPadding = 0
        view.textContainerInset = .zero
        view.font = SpanText.font(bold: false, italic: false, mono: false)
        view.linkTextAttributes = [.underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
        view.onFormatChange = { [weak coordinator = context.coordinator] in coordinator?.emit() }
        context.coordinator.view = view
        controller.textView = view
        context.coordinator.load(body, spans)
        return view
    }

    func updateNSView(_ view: RichTextView, context: Context) {
        context.coordinator.parent = self
        view.isEditable = editable
        view.appearance = NSAppearance(named: context.environment.colorScheme == .dark ? .darkAqua : .aqua)
        controller.textView = view
        if body != context.coordinator.lastBody || spans != context.coordinator.lastSpans
            || fontSize != context.coordinator.lastFontSize {
            view.font = SpanText.font(bold: false, italic: false, mono: false)
            context.coordinator.load(body, spans)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RichTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        nsView.frame.size.width = width
        nsView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        return CGSize(width: width, height: max(nsView.intrinsicContentSize.height, 22))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        var lastBody = ""
        var lastSpans: [Span] = []
        var lastFontSize: CGFloat = 0
        weak var view: RichTextView?

        init(_ parent: RichTextEditor) { self.parent = parent }

        func load(_ body: String, _ spans: [Span]) {
            lastBody = body
            lastSpans = spans
            lastFontSize = parent.fontSize
            guard let view else { return }
            let selection = view.selectedRanges
            view.textStorage?.setAttributedString(SpanText.editable(body, spans))
            if (selection.last?.rangeValue.upperBound ?? 0) <= (body as NSString).length { view.selectedRanges = selection }
            view.invalidateIntrinsicContentSize()
        }

        func emit() {
            guard let storage = view?.textStorage else { return }
            let body = storage.string
            let spans = SpanText.spans(from: storage)
            guard body != lastBody || spans != lastSpans else { return }
            lastBody = body
            lastSpans = spans
            parent.onChange(body, spans)
        }

        func textDidChange(_ notification: Notification) { emit() }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let value = (link as? String) ?? (link as? URL)?.absoluteString ?? ""
            parent.onOpenLink(value)
            return true
        }
    }
}
