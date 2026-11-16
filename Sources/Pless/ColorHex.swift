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

// ColorPalette liegt in PlessCore (Core vergibt Auto-Farben beim Anlegen).

extension Color {
    /// Luminanz-basierte Helligkeit — für die Kontrast-Textfarbe auf farbigen Tags.
    var isLight: Bool {
        guard let cg = cgColor, let comps = cg.components, comps.count >= 3 else { return false }
        return (0.299 * comps[0] + 0.587 * comps[1] + 0.114 * comps[2]) > 0.6
    }
}
