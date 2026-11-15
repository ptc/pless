import Foundation

/// Vorgeschlagene Metadaten aus dem OCR-/Textschicht-Text (Phase 9).
public struct MetadataSuggestion: Sendable, Equatable {
    public var title: String?
    public var documentDate: String?      // yyyy-MM-dd
    public var correspondentName: String?
    public var categoryName: String?

    public init(title: String? = nil, documentDate: String? = nil,
                correspondentName: String? = nil, categoryName: String? = nil) {
        self.title = title
        self.documentDate = documentDate
        self.correspondentName = correspondentName
        self.categoryName = categoryName
    }
}

/// Heuristik: Datum, Korrespondent, Titel und Kategorie aus rohem Text erraten.
public enum Heuristics {

    /// Standard-Schlüsselwörter → Kategorie. Längere Schlüsselwörter werden zuerst geprüft.
    public static let defaultCategoryKeywords: [String: String] = [
        "Mietvertrag": "Mieten",
        "Steuererklärung": "Steuern",
        "Rechnung": "Rechnungen",
        "Mahnung": "Rechnungen",
        "Vertrag": "Verträge",
        "Kündigung": "Verträge",
        "Bescheid": "Bescheide",
        "Versicherung": "Versicherungen",
    ]

    /// Datum erkennen: ISO `2026-02-14` oder deutsch `14.02.2026` / `14.02.26` (z. B. „vom 14.02.2026“).
    /// Liefert das erste gültige Datum als yyyy-MM-dd, sonst nil.
    public static func extractDate(from text: String) -> String? {
        extractDates(from: text).first
    }

    /// Alle gültigen Datums-Vorkommen im Text (ISO + deutsch gemischt), Duplikate entfernt,
    /// in Reihenfolge des Auftretens — als Vorschläge zur Auswahl im Editor.
    public static func extractDates(from text: String) -> [String] {
        guard let re = try? NSRegularExpression(
            pattern: #"\b(20\d{2})-(\d{2})-(\d{2})\b|\b(\d{1,2})\.(\d{1,2})\.(\d{2}|\d{4})\b"#) else { return [] }
        var out: [String] = []
        var seen = Set<String>()
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            func group(_ i: Int) -> String? {
                let r = m.range(at: i)
                guard r.location != NSNotFound, let range = Range(r, in: text) else { return nil }
                return String(text[range])
            }
            let d: String?
            if m.range(at: 1).location != NSNotFound { // ISO-Alternative
                d = validDate(y: Int(group(1)!)!, m: Int(group(2)!)!, d: Int(group(3)!)!)
            } else {                                    // deutsch
                guard let dd = group(4), let mm = group(5), let yy = group(6) else { continue }
                var y = Int(yy)!
                if yy.count == 2 { y += 2000 }
                d = validDate(y: y, m: Int(mm)!, d: Int(dd)!)
            }
            if let d, !seen.contains(d) { seen.insert(d); out.append(d) }
        }
        return out
    }

    /// Korrespondent: bekannter Name kommt im Text vor (case-insensitive, Wortgrenzen).
    /// Bei mehreren Treffern gewinnt der längste (spezifischste) Name.
    public static func matchCorrespondent(from text: String, known: [String]) -> String? {
        let hits = known.compactMap { name -> (String, Int)? in
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\b"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            else { return nil }
            return (name, name.count)
        }
        return hits.sorted { $0.1 > $1.1 }.first?.0
    }

    /// Titel: erste sinnvolle Zeile (kein reines Datum, keine Seitennummer, nicht nur Ziffern).
    public static func extractTitle(from text: String, maxLength: Int = 80) -> String? {
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 3 else { continue }
            if t.range(of: #"^\d{1,2}\.\d{1,2}\.\d{2,4}$"#, options: .regularExpression) != nil { continue }
            if t.range(of: #"^(seite|page)\s*\d+"#, options: [.regularExpression, .caseInsensitive]) != nil { continue }
            if t.allSatisfy({ $0.isNumber || $0.isWhitespace || "-./:".contains($0) }) { continue }
            return String(t.prefix(maxLength))
        }
        return nil
    }

    /// Kategorie-Vorschlag: erstes zutreffendes Schlüsselwort (längstes zuerst).
    public static func suggestCategory(from text: String,
                                       keywords: [String: String] = defaultCategoryKeywords) -> String? {
        for (kw, cat) in keywords.sorted(by: { $0.key.count > $1.key.count }) {
            if text.range(of: kw, options: .caseInsensitive) != nil { return cat }
        }
        return nil
    }

    /// Kombinierter Vorschlag aus einem Text.
    public static func suggest(from text: String, knownCorrespondents: [String] = []) -> MetadataSuggestion {
        MetadataSuggestion(
            title: extractTitle(from: text),
            documentDate: extractDate(from: text),
            correspondentName: matchCorrespondent(from: text, known: knownCorrespondents),
            categoryName: suggestCategory(from: text)
        )
    }

    // MARK: - Helfer

    private static func firstMatch(of pattern: String, in text: String, groups: Int) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        guard let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges == groups + 1 else { return nil }
        return (1...groups).map { i in
            let r = m.range(at: i)
            return String(text[Range(r, in: text)!])
        }
    }

    private static func validDate(y: Int, m: Int, d: Int) -> String? {
        guard (1...12).contains(m), (1...31).contains(d) else { return nil }
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d
        let cal = Calendar.current
        guard let date = cal.date(from: c) else { return nil }
        let back = cal.dateComponents([.year, .month, .day], from: date)
        guard back.year == y, back.month == m, back.day == d else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
