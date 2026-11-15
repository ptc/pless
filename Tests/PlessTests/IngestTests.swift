import Foundation
import CoreGraphics
import CoreText
import AppKit
import MiniTest
import PlessCore

enum IngestTests {
    static func register() {
        MiniTest.test("Ingest: SHA-256 (bekannter Digest)") { try shaKnown() }
        MiniTest.test("Ingest: Text-PDF wird importiert (ocrDone, Text in DB, Datei in inbox)") { try textPDFImported() }
        MiniTest.test("Ingest: Duplikat wird erkannt und nach _abgelehnt verschoben") { try duplicateDetected() }
        MiniTest.test("Ingest: ungültige Datei wird rejected und verschoben") { try invalidRejected() }
        MiniTest.test("Ingest: gescanntes PDF → needsReview, ocrDone=false, ocrText=nil") { try scannedPDFNeedsOCR() }
    }

    // MARK: - Fixtures

    private static func makeVault() throws -> (vault: Vault, db: Database, root: URL, srcDir: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pless-ingest-\(UUID().uuidString)", isDirectory: true)
        let vault = try Vault(root: root)
        let db = try Database(url: vault.databaseURL)
        let srcDir = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        return (vault, db, root, srcDir)
    }

    /// Erzeugt ein einseitiges PDF per CoreGraphics (mit oder ohne Textschicht).
    private static func writePDF(text: String?, to url: URL) throws {
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

    // MARK: - Tests

    private static func shaKnown() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pless-sha-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("a.txt")
        try Data("abc".utf8).write(to: f)
        try MiniTest.expectEqual(try FileHash.sha256(of: f),
                                 "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    private static func textPDFImported() throws {
        let (vault, db, root, srcDir) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let src = srcDir.appendingPathComponent("rechnung.pdf")
        try writePDF(text: "Rechnung Nr. 42 von der Allianz", to: src)
        let staged = try vault.stageIntoInbox(fileAt: src)

        let outcome = try IngestService(vault: vault, db: db).process(fileAt: staged)
        guard case .imported(let doc) = outcome else {
            throw TestFailure("erwartet .imported, erhalten \(outcome)")
        }
        try MiniTest.expect(doc.ocrDone)
        try MiniTest.expect(doc.ocrText?.contains("Allianz") == true)
        try MiniTest.expectEqual(doc.pageCount, 1)
        try MiniTest.expectEqual(doc.relativePath, "inbox/rechnung.pdf")
        try MiniTest.expectEqual(try db.allDocuments().count, 1)
        // Datei liegt vorerst noch in der Inbox
        try MiniTest.expect(FileManager.default.fileExists(
            atPath: vault.inboxURL.appendingPathComponent("rechnung.pdf").path))
    }

    private static func duplicateDetected() throws {
        let (vault, db, root, srcDir) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let src1 = srcDir.appendingPathComponent("original.pdf")
        let src2 = srcDir.appendingPathComponent("kopie.pdf")
        try writePDF(text: "Duplikat-Test Inhalt", to: src1)
        try fm.copyItem(at: src1, to: src2) // gleiche Bytes → gleicher SHA-256

        let svc = IngestService(vault: vault, db: db)
        let s1 = try vault.stageIntoInbox(fileAt: src1)
        let s2 = try vault.stageIntoInbox(fileAt: src2)
        _ = try svc.process(fileAt: s1)
        let o2 = try svc.process(fileAt: s2)

        guard case .duplicate = o2 else { throw TestFailure("erwartet .duplicate, erhalten \(o2)") }
        try MiniTest.expectEqual(try db.allDocuments().count, 1)
        try MiniTest.expect(!fm.fileExists(atPath: s2.path)) // aus der Inbox entfernt
        try MiniTest.expect(fm.fileExists(
            atPath: vault.rejectedURL.appendingPathComponent("kopie.pdf").path))
    }

    private static func invalidRejected() throws {
        let (vault, db, root, srcDir) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let src = srcDir.appendingPathComponent("hallo.txt")
        try Data("kein pdf".utf8).write(to: src)
        let staged = try vault.stageIntoInbox(fileAt: src)

        let outcome = try IngestService(vault: vault, db: db).process(fileAt: staged)
        guard case .rejected = outcome else { throw TestFailure("erwartet .rejected, erhalten \(outcome)") }
        try MiniTest.expectEqual(try db.allDocuments().count, 0)
        try MiniTest.expect(fm.fileExists(
            atPath: vault.rejectedURL.appendingPathComponent("hallo.txt").path))
    }

    private static func scannedPDFNeedsOCR() throws {
        let (vault, db, root, srcDir) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let src = srcDir.appendingPathComponent("scan.pdf")
        try writePDF(text: nil, to: src) // nur Grafik, keine Textschicht
        let staged = try vault.stageIntoInbox(fileAt: src)

        let outcome = try IngestService(vault: vault, db: db).process(fileAt: staged)
        guard case .imported(let doc) = outcome else {
            throw TestFailure("erwartet .imported, erhalten \(outcome)")
        }
        try MiniTest.expect(!doc.ocrDone)
        try MiniTest.expect(doc.needsReview)
        try MiniTest.expectEqual(doc.ocrText, nil)
    }
}
