import Foundation

/// The 12 NotallyX presets (`Color.kt`). Stored as `#RRGGBB`, or "DEFAULT".
public enum NoteColor {
    public static let defaultValue = "DEFAULT"

    public static let presets: [(name: String, hex: String)] = [
        ("Default", defaultValue),
        ("Coral", "#FAAFA9"), ("Orange", "#FFCC80"), ("Sand", "#FFF8B9"), ("Storm", "#AFCCDC"),
        ("Fog", "#D3E4EC"), ("Sage", "#B4DED4"), ("Mint", "#E2F6D3"), ("Dusk", "#D3BFDB"),
        ("Flower", "#F8BBD0"), ("Blossom", "#F5E2DC"), ("Clay", "#E9E3D3"),
    ]

    /// RGBA components 0...1, or nil for DEFAULT / invalid values.
    public static func rgba(_ value: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        guard value.hasPrefix("#") else { return nil }
        let hex = String(value.dropFirst())
        guard let n = UInt64(hex, radix: 16) else { return nil }
        switch hex.count {
        case 6:
            return (Double((n >> 16) & 0xFF) / 255, Double((n >> 8) & 0xFF) / 255, Double(n & 0xFF) / 255, 1)
        case 8:
            return (Double((n >> 16) & 0xFF) / 255, Double((n >> 8) & 0xFF) / 255, Double(n & 0xFF) / 255,
                    Double((n >> 24) & 0xFF) / 255)
        default:
            return nil
        }
    }

    /// Relative luminance > 0.5 means dark text, like `isLightColor()` on Android.
    public static func isLight(_ value: String) -> Bool {
        guard let c = rgba(value) else { return true }
        func lin(_ x: Double) -> Double { x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b) > 0.5
    }

    public static func hex(r: Double, g: Double, b: Double) -> String {
        String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}
