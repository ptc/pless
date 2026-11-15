import Foundation

/// Datums-Anzeige: In der DB liegt ISO `yyyy-MM-dd`, angezeigt wird das konfigurierte
/// Format (Default deutsch `dd.MM.yyyy`, Locale de_DE).
public enum DateDisplay {

    /// ISO-Datum (yyyy-MM-dd) → Anzeigeformat. Ungültige/unbekannte Eingabe wird 1:1 zurückgegeben.
    public static func format(iso: String?, pattern: String) -> String {
        guard let iso, !iso.isEmpty else { return "" }
        let inF = DateFormatter()
        inF.locale = Locale(identifier: "en_US_POSIX")
        inF.dateFormat = "yyyy-MM-dd"
        inF.isLenient = false
        guard let d = inF.date(from: iso) else { return iso }
        let outF = DateFormatter()
        outF.locale = Locale(identifier: "de_DE")
        outF.dateFormat = pattern
        return outF.string(from: d)
    }

    /// Eingabe im Anzeigeformat (oder ISO) → ISO yyyy-MM-dd; nil bei ungültiger Eingabe.
    public static func parse(_ input: String, pattern: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        let isoF = DateFormatter()
        isoF.locale = Locale(identifier: "en_US_POSIX")
        isoF.dateFormat = "yyyy-MM-dd"
        isoF.isLenient = false
        if let d = isoF.date(from: s) { return isoF.string(from: d) } // ISO direkt
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = pattern
        f.isLenient = false
        guard let d = f.date(from: s) else { return nil }
        return isoF.string(from: d)
    }
}
