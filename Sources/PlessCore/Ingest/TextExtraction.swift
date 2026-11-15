import Foundation
import PDFKit

public enum TextExtraction {
    public struct Result: Sendable, Equatable {
        public var text: String
        public var pageCount: Int
        public var hasTextLayer: Bool
    }

    /// Textschicht eines PDF auslesen. `hasTextLayer=false` → OCR nötig (Phase 4).
    public static func extract(from url: URL) throws -> Result {
        guard let pdf = PDFDocument(url: url) else {
            throw PlessError.invalidDocument("kein gültiges PDF: \(url.lastPathComponent)")
        }
        let pageCount = pdf.pageCount
        var parts: [String] = []
        for i in 0..<pageCount {
            if let page = pdf.page(at: i), let t = page.string {
                parts.append(t)
            }
        }
        let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // Heuristik: zu wenig Text pro Seite → vermutlich gescannt
        let hasTextLayer = text.count >= max(20, pageCount * 5)
        return Result(text: text, pageCount: pageCount, hasTextLayer: hasTextLayer)
    }
}
