import Foundation
import MiniTest
import PlessCore

enum RecoveryTests {
    static func register() {
        MiniTest.test("Recovery: Crash nach DB-Insert (Datei noch in inbox/) → finalisiert nach documents/") { try finalizesInboxStagedDoc() }
        MiniTest.test("Recovery: Crash nach Datei-Move (DB zeigt noch inbox/) → Pfad per SHA korrigiert") { try relocatesMovedFile() }
        MiniTest.test("Recovery: Waisen-PDF in documents/ ohne DB-Eintrag → in die Inbox verschoben") { try adoptsOrphan() }
        MiniTest.test("Recovery: unbeschädigter Vault → Report leer, nichts angefasst") { try cleanVaultUntouched() }
    }

    private static func makeVault() throws -> (vault: Vault, db: Database, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pless-recovery-\(UUID().uuidString)", isDirectory: true)
        let vault = try Vault(root: root)
        let db = try Database(url: vault.databaseURL)
        return (vault, db, root)
    }

    /// Fall 1: DB-Eintrag mit Pfad inbox/x.pdf, Datei liegt noch dort (Crash vor dem Verschieben).
    private static func finalizesInboxStagedDoc() throws {
        let (vault, db, root) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let pdf = vault.inboxURL.appendingPathComponent("scan.pdf")
        try PDFFixture.writePDF(text: "Rechnung 2026", to: pdf)
        var doc = Document(uuid: UUID().uuidString, sha256: try FileHash.sha256(of: pdf),
                           filename: "scan.pdf", relativePath: "inbox/scan.pdf",
                           pageCount: 1, ocrText: "Rechnung 2026", ocrDone: true)
        doc.id = try db.insert(doc)

        let report = try RecoveryService(vault: vault, db: db).recover()
        try MiniTest.expectEqual(report.finalized, 1)
        let fixed = try db.document(byId: doc.id!)!
        try MiniTest.expect(fixed.relativePath.hasPrefix("documents/"), "Pfad: \(fixed.relativePath)")
        try MiniTest.expect(fm.fileExists(atPath: vault.root.appendingPathComponent(fixed.relativePath).path))
        try MiniTest.expect(!fm.fileExists(atPath: pdf.path))
    }

    /// Fall 2: Datei wurde nach documents/ verschoben, DB zeigt aber noch inbox/ (Crash dazwischen).
    private static func relocatesMovedFile() throws {
        let (vault, db, root) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        // normaler Import → Datei liegt in documents/, DB konsistent
        let srcDir = root.appendingPathComponent("src", isDirectory: true)
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let src = srcDir.appendingPathComponent("rechnung.pdf")
        try PDFFixture.writePDF(text: "Rechnung Nr. 7 von der Musterfirma GmbH", to: src)
        let staged = try vault.stageIntoInbox(fileAt: src)
        let outcome = try IngestService(vault: vault, db: db).process(fileAt: staged)
        guard case .imported(let doc) = outcome else { throw TestFailure("erwartet .imported") }
        let finalRel = doc.relativePath
        // Crash simulieren: DB-Pfad zurück auf inbox/ stellen, Datei bleibt in documents/
        try db.updateFileLocation(documentId: doc.id!, filename: "rechnung.pdf", relativePath: "inbox/rechnung.pdf")

        let report = try RecoveryService(vault: vault, db: db).recover()
        try MiniTest.expectEqual(report.relocated, 1)
        let fixed = try db.document(byId: doc.id!)!
        try MiniTest.expectEqual(fixed.relativePath, finalRel)
        try MiniTest.expect(fm.fileExists(atPath: vault.root.appendingPathComponent(finalRel).path))
    }

    /// Fall 3: PDF liegt in documents/, hat aber keinen DB-Eintrag → landet in der Inbox.
    private static func adoptsOrphan() throws {
        let (vault, db, root) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let folder = try vault.documentsFolder(year: 2026, month: 3)
        let orphan = folder.appendingPathComponent("waise.pdf")
        try PDFFixture.writePDF(text: "verwaistes Dokument", to: orphan)
        try MiniTest.expectEqual(try db.allDocuments().count, 0)

        let report = try RecoveryService(vault: vault, db: db).recover()
        try MiniTest.expectEqual(report.adopted, 1)
        try MiniTest.expect(fm.fileExists(atPath: vault.inboxURL.appendingPathComponent("waise.pdf").path))
        try MiniTest.expect(!fm.fileExists(atPath: orphan.path))
        try MiniTest.expectEqual(try db.allDocuments().count, 0) // Ingest erst danach (Watcher)
    }

    private static func cleanVaultUntouched() throws {
        let (vault, db, root) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let srcDir = root.appendingPathComponent("src", isDirectory: true)
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let src = srcDir.appendingPathComponent("ok.pdf")
        try PDFFixture.writePDF(text: "dies ist ein langer Text für die Textschicht", to: src)
        let staged = try vault.stageIntoInbox(fileAt: src)
        _ = try IngestService(vault: vault, db: db).process(fileAt: staged)

        let report = try RecoveryService(vault: vault, db: db).recover()
        try MiniTest.expectEqual(report.total, 0)
        try MiniTest.expectEqual(try db.allDocuments().count, 1)
    }
}
