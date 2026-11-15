import Foundation
import CoreGraphics
import CoreText
import AppKit
import PlessCore

/// Erzeugt Test-PDFs (mit/ohne Textschicht) und temporäre Verzeichnisse.
enum PDFFixture {
    static func tempDir(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }

    /// Einseitiges PDF per CoreGraphics. `text == nil` → „gescannt" (nur Grafik, keine Textschicht).
    static func writePDF(text: String?, to url: URL) throws {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else {
            throw PlessError.io("CGDataConsumer fehlgeschlagen")
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw PlessError.io("PDF-Kontext konnte nicht erzeugt werden")
        }
        ctx.beginPDFPage(nil)
        if let text {
            let attr = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
            let line = CTLineCreateWithAttributedString(attr as CFAttributedString)
            ctx.textPosition = CGPoint(x: 40, y: 800)
            CTLineDraw(line, ctx)
        } else {
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(CGRect(x: 40, y: 40, width: 200, height: 200))
        }
        ctx.endPDFPage()
        ctx.closePDF()
        try (data as Data).write(to: url, options: .atomic)
    }
}
