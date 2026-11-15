import Foundation
import MiniTest
import PlessCore

enum IngestTests {
    static func register() {
        MiniTest.test("Ingest: SHA-256 (bekannter Digest)") { try shaKnown() }
        MiniTest.test("Ingest: Text-PDF wird importiert (ocrDone, Heuristik, Datei nach documents/)") { try textPDFImported() }
        MiniTest.test("Ingest: Heuristik setzt Datum/Korrespondent/Titel + documents/2026/02") { try textPDFHeuristics() }
        MiniTest.test("Ingest: Duplikat wird erkannt und nach _abgelehnt verschoben") { try duplicateDetected() }
        MiniTest.test("Ingest: ungültige Datei wird rejected und verschoben") { try invalidRejected() }
        MiniTest.test("Ingest: gescanntes PDF → needsReview, ocrDone=false, ocrText=nil") { try scannedPDFNeedsOCR() }
        MiniTest.test("Ingest: paralleler Import derselben Datei → einer imported, einer duplicate (kein harter Fehler)") { try concurrentSameContent() }
    }

    /// Simuliert den Watcher-Race (doppelte Lieferung): zwei Kopien, gleicher Inhalt,
    /// werden parallel verarbeitet — einer gewinnt, der andere muss .duplicate liefern.
    private static func concurrentSameContent() throws {
        let (vault, db, root, srcDir) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let src = srcDir.appendingPathComponent("d.pdf")
        try PDFFixture.writePDF(text: "Inhalt für den nebenläufigen Import-Test", to: src)
        try fm.copyItem(at: src, to: srcDir.appendingPathComponent("d2.pdf"))
        let svc = IngestService(vault: vault, db: db)
        let s1 = try vault.stageIntoInbox(fileAt: srcDir.appendingPathComponent("d.pdf"))
        let s2 = try vault.stageIntoInbox(fileAt: srcDir.appendingPathComponent("d2.pdf"))

        var outcomes: [IngestOutcome?] = [nil, nil]
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            outcomes[i] = try? svc.process(fileAt: i == 0 ? s1 : s2)
        }
        let count: (IngestOutcome) -> Bool = { o in
            if case .imported = o { return true }
            if case .duplicate = o { return true }
            return false
        }
        try MiniTest.expect(outcomes.allSatisfy { $0 != nil && count($0!) }, "kein Ergebnis darf nil (Throw) sein: \(outcomes)")
        let imported = outcomes.filter { if case .imported = $0 { return true }; return false }.count
        let dups = outcomes.filter { if case .duplicate = $0 { return true }; return false }.count
        try MiniTest.expectEqual(imported, 1)
        try MiniTest.expectEqual(dups, 1)
        try MiniTest.expectEqual(try db.allDocuments().count, 1)
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
        try PDFFixture.writePDF(text: "Rechnung Nr. 42 von der Allianz", to: src)
        let staged = try vault.stageIntoInbox(fileAt: src)

        let outcome = try IngestService(vault: vault, db: db).process(fileAt: staged)
        guard case .imported(let doc) = outcome else {
            throw TestFailure("erwartet .imported, erhalten \(outcome)")
        }
        try MiniTest.expect(doc.ocrDone)
        try MiniTest.expect(doc.ocrText?.contains("Allianz") == true)
        try MiniTest.expectEqual(doc.pageCount, 1)
        try MiniTest.expectEqual(try db.allDocuments().count, 1)
        // Phase 9: Heuristik hat zugeschlagen, Datei liegt mit generiertem Namen in documents/YYYY/MM
        try MiniTest.expectEqual(doc.title, "Rechnung Nr. 42 von der Allianz")
        try MiniTest.expect(doc.relativePath.hasPrefix("documents/"), "Pfad: \(doc.relativePath)")
        try MiniTest.expect(doc.filename.contains("Rechnung-Nr-42"), "Datei: \(doc.filename)")
        try MiniTest.expect(try db.category(named: "Rechnungen") != nil, "Kategorie per Schlüsselwort angelegt")
        try MiniTest.expect(FileManager.default.fileExists(
            atPath: vault.root.appendingPathComponent(doc.relativePath).path))
        try MiniTest.expect(!FileManager.default.fileExists(
            atPath: vault.inboxURL.appendingPathComponent("rechnung.pdf").path))
    }

    private static func textPDFHeuristics() throws {
        let (vault, db, root, srcDir) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let corrId = try db.insertCorrespondent(name: "Allianz")
        let src = srcDir.appendingPathComponent("police.pdf")
        try PDFFixture.writePDF(text: "Allianz Versicherung\nPolicen-Nr. 99\nvom 14.02.2026", to: src)
        let staged = try vault.stageIntoInbox(fileAt: src)

        let outcome = try IngestService(vault: vault, db: db).process(fileAt: staged)
        guard case .imported(let doc) = outcome else {
            throw TestFailure("erwartet .imported, erhalten \(outcome)")
        }
        try MiniTest.expectEqual(doc.documentDate, "2026-02-14")
        try MiniTest.expectEqual(doc.correspondentId, corrId)
        try MiniTest.expect(doc.title?.hasPrefix("Allianz Versicherung") == true, "Titel: \(doc.title ?? "nil")")
        try MiniTest.expect(doc.relativePath.hasPrefix("documents/2026/02/"), "Pfad: \(doc.relativePath)")
        try MiniTest.expect(doc.filename.contains("Allianz"), "Datei: \(doc.filename)")
    }

    private static func duplicateDetected() throws {
        let (vault, db, root, srcDir) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let src1 = srcDir.appendingPathComponent("original.pdf")
        let src2 = srcDir.appendingPathComponent("kopie.pdf")
        try PDFFixture.writePDF(text: "Duplikat-Test Inhalt", to: src1)
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
        try PDFFixture.writePDF(text: nil, to: src) // nur Grafik, keine Textschicht
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
