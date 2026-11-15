import Foundation

/// Werte für den Dateinamen-Renderer.
public struct NamingContext: Sendable, Equatable {
    public var date: String?          // yyyy-MM-dd
    public var correspondent: String?
    public var category: String?
    public var title: String?
    public var tags: [String]
    public var fileExtension: String  // z. B. "pdf"

    public init(date: String? = nil, correspondent: String? = nil, category: String? = nil,
                title: String? = nil, tags: [String] = [], fileExtension: String = "pdf") {
        self.date = date
        self.correspondent = correspondent
        self.category = category
        self.title = title
        self.tags = tags
        self.fileExtension = fileExtension
    }
}

/// Dateinamen aus Template rendern, z. B. `{date}_{correspondent}_{title}.pdf`.
public enum NamingEngine {
    public static let defaultTemplate = "{date}_{correspondent}_{title}.pdf"

    public static func render(template: String = defaultTemplate, context: NamingContext) -> String {
        var out = template
        let values: [(String, String)] = [
            ("{date}", context.date ?? ""),
            ("{correspondent}", context.correspondent ?? ""),
            ("{category}", context.category ?? ""),
            ("{title}", context.title ?? ""),
            ("{tags}", context.tags.joined(separator: "-")),
        ]
        for (placeholder, value) in values {
            out = out.replacingOccurrences(of: placeholder, with: value)
        }
        // in Stamm und Extension aufteilen, damit die Extension erhalten bleibt
        var stem = out
        var suffix = ""
        if let dot = out.lastIndex(of: "."), dot != out.startIndex {
            stem = String(out[out.startIndex..<dot])
            suffix = String(out[dot...])
        }
        stem = sanitize(stem, maxLength: 80)
        while stem.contains("__") { stem = stem.replacingOccurrences(of: "__", with: "_") }
        stem = stem.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if stem.isEmpty { stem = "dokument" }
        if suffix.isEmpty { suffix = ".\(context.fileExtension)" }
        return stem + suffix
    }

    /// Umlaute auflösen, Sonderzeichen entfernen, Leerzeichen → "-", max. maxLength Zeichen.
    public static func sanitize(_ input: String, maxLength: Int = 40) -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for (from, to) in [("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss"),
                           ("Ä", "Ae"), ("Ö", "Oe"), ("Ü", "Ue")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        s = s.replacingOccurrences(of: " ", with: "-")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        s = String(String.UnicodeScalarView(s.unicodeScalars.filter { allowed.contains($0) }))
        while s.contains("--") { s = s.replacingOccurrences(of: "--", with: "-") }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if s.count > maxLength {
            s = String(s.prefix(maxLength)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        return s.isEmpty ? "dokument" : s
    }

    /// Kollisionsfreie Variante eines Dateinamens in einem Ordner (`name.pdf` → `name-2.pdf` …).
    public static func uniqueFilename(in directory: URL, desired: String) -> String {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool {
            fm.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
        if !exists(desired) { return desired }
        let ns = desired as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            if !exists(candidate) { return candidate }
            n += 1
        }
    }
}
