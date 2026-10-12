import AppKit
import NotallyCore
import SwiftUI

extension NSAttributedString.Key {
    static let nxBold = NSAttributedString.Key("nxBold")
    static let nxItalic = NSAttributedString.Key("nxItalic")
    static let nxMono = NSAttributedString.Key("nxMono")
}

/// Converts between the synced `spans` model and attributed strings.
/// Span offsets are UTF-16 indices, the same as Java strings and NSString.
enum SpanText {
    static let fontSize: CGFloat = 14

    /// Read-only preview for cards.
    static func attributed(_ body: String, _ spans: [Span]) -> AttributedString {
        let ns = NSMutableAttributedString(string: body)
        apply(spans, to: ns)
        var out = AttributedString(body)
        ns.enumerateAttributes(in: NSRange(location: 0, length: ns.length)) { attrs, range, _ in
            guard let r = Range(range, in: out) else { return }
            var intent: InlinePresentationIntent = []
            if attrs[.nxBold] != nil { intent.insert(.stronglyEmphasized) }
            if attrs[.nxItalic] != nil { intent.insert(.emphasized) }
            if attrs[.nxMono] != nil { intent.insert(.code) }
            if attrs[.strikethroughStyle] != nil { intent.insert(.strikethrough) }
            if !intent.isEmpty { out[r].inlinePresentationIntent = intent }
            if attrs[.link] != nil { out[r].underlineStyle = .single }
        }
        return out
    }

    /// Editable text for the NSTextView.
    static func editable(_ body: String, _ spans: [Span], color: NSColor = .textColor) -> NSAttributedString {
        let ns = NSMutableAttributedString(string: body, attributes: [.foregroundColor: color])
        apply(spans, to: ns)
        applyFonts(ns, range: NSRange(location: 0, length: ns.length))
        return ns
    }

    static func apply(_ spans: [Span], to ns: NSMutableAttributedString) {
        let length = ns.length
        for span in spans {
            let start = max(0, min(span.start, length)), end = max(start, min(span.end, length))
            guard end > start else { continue }
            let range = NSRange(location: start, length: end - start)
            if span.bold { ns.addAttribute(.nxBold, value: true, range: range) }
            if span.italic { ns.addAttribute(.nxItalic, value: true, range: range) }
            if span.monospace { ns.addAttribute(.nxMono, value: true, range: range) }
            if span.strikethrough { ns.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
            if span.link, let data = span.linkData, !data.isEmpty { ns.addAttribute(.link, value: data, range: range) }
        }
    }

    static func font(bold: Bool, italic: Bool, mono: Bool) -> NSFont {
        var font = mono
            ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: bold ? .bold : .regular)
            : NSFont.systemFont(ofSize: fontSize, weight: bold ? .bold : .regular)
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    /// Derives the visible font from the span flags.
    static func applyFonts(_ ns: NSMutableAttributedString, range: NSRange) {
        ns.enumerateAttributes(in: range) { attrs, r, _ in
            ns.addAttribute(.font, value: font(bold: attrs[.nxBold] != nil, italic: attrs[.nxItalic] != nil,
                                               mono: attrs[.nxMono] != nil), range: r)
        }
    }

    /// Spans from the attributed text. Adjacent runs with the same flags are merged.
    static func spans(from ns: NSAttributedString) -> [Span] {
        var out: [Span] = []
        ns.enumerateAttributes(in: NSRange(location: 0, length: ns.length)) { attrs, range, _ in
            let linkValue: String? = (attrs[.link] as? String) ?? (attrs[.link] as? URL)?.absoluteString
            let span = Span(start: range.location, end: range.location + range.length,
                            bold: attrs[.nxBold] != nil, italic: attrs[.nxItalic] != nil,
                            monospace: attrs[.nxMono] != nil, strikethrough: attrs[.strikethroughStyle] != nil,
                            link: linkValue != nil, linkData: linkValue)
            guard span.isUseful else { return }
            if var last = out.last, last.end == span.start, last.bold == span.bold, last.italic == span.italic,
               last.monospace == span.monospace, last.strikethrough == span.strikethrough,
               last.link == span.link, last.linkData == span.linkData {
                last.end = span.end
                out[out.count - 1] = last
            } else {
                out.append(span)
            }
        }
        return out
    }
}
