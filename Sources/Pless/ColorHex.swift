import SwiftUI

extension Color {
    /// Aus "#RRGGBB" (oder nil) eine Farbe. nil → nil.
    init?(hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}

/// Feste Farbpalette für Kategorien/Tags (hex, wie in der DB gespeichert).
enum ColorPalette {
    static let presets: [String] = [
        "#FF3B30", "#FF9500", "#FFCC00", "#34C759",
        "#00C7BE", "#007AFF", "#5856D6", "#FF2D55", "#8E8E93"
    ]
}
