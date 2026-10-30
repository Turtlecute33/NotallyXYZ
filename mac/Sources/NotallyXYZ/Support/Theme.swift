import AppKit
import NotallyCore
import SwiftUI

/// NotallyX look: pastel cards keep their color in dark mode, text contrasts with the color.
enum Theme {
    static let cardRadius: CGFloat = 16
    static let cardMinWidth: CGFloat = 220
    static let spacing: CGFloat = 12
    static let darkText = Color(red: 0x1A / 255, green: 0x1B / 255, blue: 0x21 / 255)
    static let lightText = Color(red: 0xF1 / 255, green: 0xF0 / 255, blue: 0xF7 / 255)
    static let accent = Color(red: 0x72 / 255, green: 0x85 / 255, blue: 0xD0 / 255)

    static func color(_ value: String) -> Color? {
        guard let c = NoteColor.rgba(value) else { return nil }
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }

    /// Background of a card or editor. DEFAULT blends with the window.
    static func background(_ value: String) -> Color {
        color(value) ?? Color(nsColor: .textBackgroundColor)
    }

    /// Color scheme to use on top of a note color (nil = follow the system).
    static func scheme(for value: String) -> ColorScheme? {
        guard color(value) != nil else { return nil }
        return NoteColor.isLight(value) ? .light : .dark
    }
}

extension View {
    /// Applies the note color and a matching color scheme.
    func noteColored(_ value: String) -> some View {
        modifier(NoteColorModifier(value: value))
    }

    /// Liquid Glass card: tinted with the note color, plain glass for DEFAULT.
    /// Pastel colors keep a light scheme (dark text) in dark mode too, like NotallyX.
    func glassCard(_ value: String) -> some View {
        modifier(GlassCardModifier(value: value))
    }
}

private struct GlassCardModifier: ViewModifier {
    let value: String

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
        if let tint = Theme.color(value) {
            // Explicit text color: glass would otherwise make text vibrant (white in dark mode).
            let light = NoteColor.isLight(value)
            // The color fill keeps the note color when the window is inactive (glass loses its tint).
            content
                .foregroundStyle(light ? Theme.darkText : Theme.lightText)
                .background(tint.opacity(0.78), in: shape)
                .glassEffect(.regular.tint(tint.opacity(0.5)), in: shape)
                .environment(\.colorScheme, light ? .light : .dark)
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}

private struct NoteColorModifier: ViewModifier {
    let value: String

    func body(content: Content) -> some View {
        if let scheme = Theme.scheme(for: value) {
            content.environment(\.colorScheme, scheme)
        } else {
            content
        }
    }
}

enum Format {
    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.dateTimeStyle = .named
        return f
    }()

    static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    static func ago(_ ms: Int64) -> String { ago(date(ms)) }

    static func ago(_ date: Date) -> String {
        abs(date.timeIntervalSinceNow) < 45 ? "just now" : relative.localizedString(for: date, relativeTo: Date())
    }

    static func full(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func repetition(_ r: Repetition) -> String {
        if r.unit == .months, let o = r.occurrence, let d = r.dayOfWeek {
            let day = Calendar.current.weekdaySymbols[(d - 1 + 7) % 7]
            let which = o == -1 ? "last" : ["1st", "2nd", "3rd", "4th"][max(0, min(3, o - 1))]
            return (r.value == 1 ? "Monthly" : "Every \(r.value) months") + " on the \(which) \(day)"
        }
        switch (r.value, r.unit) {
        case (1, .days): return "Daily"
        case (1, .weeks): return "Weekly"
        case (1, .months): return "Monthly"
        case (1, .years): return "Yearly"
        default: return "Every \(r.value) \(r.unit.rawValue.lowercased())"
        }
    }
}
