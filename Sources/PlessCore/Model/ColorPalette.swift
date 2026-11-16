import Foundation

/// Feste Farbpalette für Kategorien/Tags (hex, wie in der DB gespeichert).
/// Beim Anlegen einer Kategorie ohne explizite Farbe wird automatisch die nächste
/// Palettenfarbe vergeben — so hat jede Kategorie eine andere Farbe.
public enum ColorPalette {
    public static let presets: [String] = [
        "#FF3B30", "#FF9500", "#FFCC00", "#34C759",
        "#00C7BE", "#007AFF", "#5856D6", "#FF2D55", "#8E8E93"
    ]

    /// Automatische Farbe für die n-te Kategorie (Reihenfolge der Anlage).
    public static func autoColor(existingCount: Int64) -> String {
        presets[Int(existingCount) % presets.count]
    }
}
