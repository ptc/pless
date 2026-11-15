import Foundation
import MiniTest
import PlessCore

enum MetadataTests {
    static func register() {
        MiniTest.test("Metadata: saveMetadata setzt Felder und legt Datei nach documents/YYYY/MM") { try saveMovesFile() }
        MiniTest.test("Metadata: erneutes Speichern benennt Datei um (FTS synchron)") { try renameOnChange() }
        MiniTest.test("Metadata: Kollision erzeugt -2 Suffix") { try collisionSuffix() }
        MiniTest.test("Metadata: Datumswechsel verschiebt in anderen Ordner") { try dateChangeMovesFolder() }
        MiniTest.test("Metadata: Ordner-Heuristik aus Datum, Fallback heute") { try folderHeuristic() }
        MiniTest.test("Metadata: Tags findOrCreate/add/remove") { try tagAssign() }
        MiniTest.test("Metadata: Kategorie rename/Farbe/Verschachteln/Zyklus/delete") { try categoryManagement() }
        MiniTest.test("Metadata: Korrespondent rename/delete (Referenz wird NULL)") { try correspondentManagement() }
        MiniTest.test("Metadata: Tag rename/delete (Cascade auf document_tags)") { try tagRenameDelete() }
        MiniTest.test("Metadata: OCR mit metadata wendet Heuristik an und legt Datei ab") { try ocrAppliesSuggestions() }
        MiniTest.test("Metadata: Bulk-Muster — Kategorie auf mehrere Docs, andere Felder bleiben; Tag idempotent") { try bulkPattern() }
    }

    /// Simuliert die Bulk-Operation aus der UI: Kategorie per saveMetadata setzen (Titel/Datum/
    /// Korrespondent bleiben erhalten), Tag per findOrCreate + addTagToDocument (INSERT OR IGNORE).
    private static func bulkPattern() throws {
        let (vault, db, root, srcDir) = try makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        let d1 = try ingestOne(db: db, vault: vault, srcDir: srcDir, name: "a.pdf", text: "Inhalt A")
        let d2 = try ingestOne(db: db, vault: vault, srcDir: srcDir, name: "b.pdf", text: "Inhalt B")
        let corrId = try db.findOrCreateCorrespondent(name: "Allianz")
        let catId = try db.findOrCreateCategory(name: "Verträge")
        let svc = MetadataService(vault: vault, db: db)

        // wie AppState.bulkAssign: Kategorie setzen, vorhandene Felder mitgeben
        for d in [d1, d2] {
            let cur = try db.document(byId: d.id!)!
            _ = try svc.saveMetadata(documentId: d.id!, title: cur.title, documentDate: cur.documentDate,
                                     correspondentId: corrId, categoryId: catId, notes: cur.notes)
            let tid = try db.findOrCreateTag(name: "wichtig")
            try db.addTagToDocument(documentId: d.id!, tagId: tid)
            try db.addTagToDocument(documentId: d.id!, tagId: tid) // doppelt → OR IGNORE
        }
        for d in [d1, d2] {
            let cur = try db.document(byId: d.id!)!
            try MiniTest.expectEqual(cur.categoryId, catId)
            try MiniTest.expectEqual(cur.correspondentId, corrId)
            try MiniTest.expectEqual(cur.title, d.title) // Titel unverändert
            try MiniTest.expectEqual(try db.tags(for: d.id!).count, 1) // Tag nur einmal
        }
        try MiniTest.expectEqual(try db.tags().count, 1) // findOrCreate legt Tag nur einmal an
    }

    // MARK: - Fixtures

    private static func makeEnv() throws -> (vault: Vault, db: Database, root: URL, srcDir: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pless-meta-\(UUID().uuidString)", isDirectory: true)
        let vault = try Vault(root: root)
        let db = try Database(url: vault.databaseURL)
        let srcDir = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        return (vault, db, root, srcDir)
    }

    private static func ingestOne(db: Database, vault: Vault, srcDir: URL, name: String, text: String) throws -> Document {
        let src = srcDir.appendingPathComponent(name)
        try PDFFixture.writePDF(text: text, to: src)
        let staged = try vault.stageIntoInbox(fileAt: src)
        guard case .imported(let doc) = try IngestService(vault: vault, db: db).process(fileAt: staged) else {
            throw PlessError.io("Test-Fixture nicht importiert: \(name)")
        }
        return doc
    }

    // MARK: - Tests

    private static func saveMovesFile() throws {
        let (vault, db, root, srcDir) = try makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = try ingestOne(db: db, vault: vault, srcDir: srcDir, name: "rechnung.pdf",
                                text: "Rechnung Nr. 42 von der Allianz")
        let corrId = try db.findOrCreateCorrespondent(name: "Allianz")
        let catId = try db.findOrCreateCategory(name: "Rechnungen")

        let updated = try MetadataService(vault: vault, db: db).saveMetadata(
            documentId: doc.id!, title: "KFZ-Versicherung 2026", documentDate: "2026-02-14",
            correspondentId: corrId, categoryId: catId, notes: "bitte prüfen")

        try MiniTest.expect(updated.relativePath == "documents/2026/02/2026-02-14_Allianz_KFZ-Versicherung-2026.pdf",
                        "Pfad: \(updated.relativePath)")
        try MiniTest.expect(updated.filename == "2026-02-14_Allianz_KFZ-Versicherung-2026.pdf",
                        "Datei: \(updated.filename)")
        let fm = FileManager.default
        try MiniTest.expect(fm.fileExists(atPath: vault.root.appendingPathComponent(updated.relativePath).path),
                        "Datei liegt im Vault")
        try MiniTest.expect(!fm.fileExists(atPath: vault.inboxURL.appendingPathComponent("rechnung.pdf").path),
                        "Inbox-Datei ist weg")
        let reloaded = try MiniTest.unwrap(try db.document(byId: doc.id!))
        try MiniTest.expect(reloaded.title == "KFZ-Versicherung 2026", "Titel in DB")
        try MiniTest.expect(reloaded.notes == "bitte prüfen", "Notizen in DB")
        try MiniTest.expect(reloaded.documentDate == "2026-02-14", "Datum in DB")
        try MiniTest.expect(reloaded.relativePath == updated.relativePath, "Pfad in DB")
    }

    private static func renameOnChange() throws {
        let (vault, db, root, srcDir) = try makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = try ingestOne(db: db, vault: vault, srcDir: srcDir, name: "a.pdf", text: "Inhalt A")
        let corrId = try db.findOrCreateCorrespondent(name: "Allianz")
        let svc = MetadataService(vault: vault, db: db)
        let first = try svc.saveMetadata(documentId: doc.id!, title: "Alt", documentDate: "2026-02-14",
                                         correspondentId: corrId, categoryId: nil, notes: nil)

        let second = try svc.saveMetadata(documentId: doc.id!, title: "NeuTitel", documentDate: "2026-02-14",
                                          correspondentId: corrId, categoryId: nil, notes: nil)
        try MiniTest.expect(second.relativePath == "documents/2026/02/2026-02-14_Allianz_NeuTitel.pdf",
                        "neuer Pfad: \(second.relativePath)")
        let fm = FileManager.default
        try MiniTest.expect(fm.fileExists(atPath: vault.root.appendingPathComponent(second.relativePath).path),
                        "neue Datei existiert")
        try MiniTest.expect(!fm.fileExists(atPath: vault.root.appendingPathComponent(first.relativePath).path),
                        "alte Datei ist weg")
        // FTS-Trigger: neuer Titel ist suchbar
        let hits = try db.search(SearchFilter(query: "NeuTitel"))
        try MiniTest.expect(hits.contains { $0.document.id == doc.id }, "FTS findet NeuTitel")
    }

    private static func collisionSuffix() throws {
        let (vault, db, root, srcDir) = try makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        let d1 = try ingestOne(db: db, vault: vault, srcDir: srcDir, name: "a.pdf", text: "Inhalt A")
        let d2 = try ingestOne(db: db, vault: vault, srcDir: srcDir, name: "b.pdf", text: "Inhalt B")
        let corrId = try db.findOrCreateCorrespondent(name: "Allianz")
        let svc = MetadataService(vault: vault, db: db)
        _ = try svc.saveMetadata(documentId: d1.id!, title: "Vertrag", documentDate: "2026-02-14",
                                 correspondentId: corrId, categoryId: nil, notes: nil)
        let second = try svc.saveMetadata(documentId: d2.id!, title: "Vertrag", documentDate: "2026-02-14",
                                          correspondentId: corrId, categoryId: nil, notes: nil)
        try MiniTest.expect(second.relativePath == "documents/2026/02/2026-02-14_Allianz_Vertrag-2.pdf",
                        "Kollisionspfad: \(second.relativePath)")
        try MiniTest.expect(FileManager.default.fileExists(atPath: vault.root.appendingPathComponent(second.relativePath).path),
                        "Kollisionsdatei existiert")
    }

    private static func dateChangeMovesFolder() throws {
        let (vault, db, root, srcDir) = try makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = try ingestOne(db: db, vault: vault, srcDir: srcDir, name: "a.pdf", text: "Inhalt A")
        let svc = MetadataService(vault: vault, db: db)
        let feb = try svc.saveMetadata(documentId: doc.id!, title: "Brief", documentDate: "2026-02-14",
                                       correspondentId: nil, categoryId: nil, notes: nil)
        try MiniTest.expect(feb.relativePath.hasPrefix("documents/2026/02/"), "Februar-Ordner: \(feb.relativePath)")
        let mai = try svc.saveMetadata(documentId: doc.id!, title: "Brief", documentDate: "2026-05-01",
                                       correspondentId: nil, categoryId: nil, notes: nil)
        try MiniTest.expect(mai.relativePath.hasPrefix("documents/2026/05/"), "Mai-Ordner: \(mai.relativePath)")
        try MiniTest.expect(!FileManager.default.fileExists(atPath: vault.root.appendingPathComponent(feb.relativePath).path),
                        "alte Datei ist weg")
    }

    private static func folderHeuristic() throws {
        try MiniTest.expect(MetadataService.folder(for: "2026-02-14") == "documents/2026/02", "gültiges Datum")
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: Date())
        try MiniTest.expect(MetadataService.folder(for: "unsinn") == MetadataService.folder(for: today),
                        "Fallback auf heute (\(today))")
    }

    private static func tagAssign() throws {
        let (vault, db, root, srcDir) = try makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = try ingestOne(db: db, vault: vault, srcDir: srcDir, name: "a.pdf", text: "Inhalt A")
        let t1 = try db.findOrCreateTag(name: "wichtig")
        let t2 = try db.findOrCreateTag(name: "wichtig")
        try MiniTest.expect(t1 == t2, "findOrCreate ist idempotent")
        try db.addTagToDocument(documentId: doc.id!, tagId: t1)
        try db.addTagToDocument(documentId: doc.id!, tagId: t1) // doppelt → OR IGNORE
        try MiniTest.expect(try db.tags(for: doc.id!).count == 1, "Tag genau einmal zugewiesen")
        try db.removeTagFromDocument(documentId: doc.id!, tagId: t1)
        try MiniTest.expect(try db.tags(for: doc.id!).isEmpty, "Tag entfernt")
    }

    private static func categoryManagement() throws {
        let (vault, db, root, srcDir) = try makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootId = try db.findOrCreateCategory(name: "Root")
        let childId = try db.findOrCreateCategory(name: "Kind", parentId: rootId)
        try db.updateCategory(id: childId, name: "KindNeu", parentId: rootId, color: "#FF3B30")
        let c = try MiniTest.unwrap(try db.category(id: childId))
        try MiniTest.expect(c.name == "KindNeu" && c.color == "#FF3B30" && c.parentId == rootId, "Kategorie aktualisiert")

        var threw = false
        do { try db.updateCategory(id: rootId, name: "Root", parentId: rootId, color: nil) } catch { threw = true }
        try MiniTest.expect(threw, "Selbst als Elternteil verboten")
        threw = false
        do { try db.updateCategory(id: rootId, name: "Root", parentId: childId, color: nil) } catch { threw = true }
        try MiniTest.expect(threw, "Zyklus (Nachfahre als Elternteil) verboten")

        let doc = try ingestOne(db: db, vault: vault, srcDir: srcDir, name: "a.pdf", text: "Inhalt A")
        try db.updateMetadata(documentId: doc.id!, title: nil, documentDate: nil,
                              correspondentId: nil, categoryId: childId, notes: nil)
        try db.deleteCategory(id: childId)
        let re = try MiniTest.unwrap(try db.document(byId: doc.id!))
        try MiniTest.expect(re.categoryId == nil, "Löschen setzt category_id auf NULL")
        try MiniTest.expect(try db.category(id: childId) == nil, "Kategorie weg")
    }

    private static func correspondentManagement() throws {
        let (vault, db, root, srcDir) = try makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = try ingestOne(db: db, vault: vault, srcDir: srcDir, name: "a.pdf", text: "Inhalt A")
        let cid = try db.findOrCreateCorrespondent(name: "Allianz")
        try db.updateMetadata(documentId: doc.id!, title: nil, documentDate: nil,
                              correspondentId: cid, categoryId: nil, notes: nil)
        try db.renameCorrespondent(id: cid, newName: "Allianz SE")
        try MiniTest.expect(try db.correspondent(id: cid)?.name == "Allianz SE", "umbenannt")
        try MiniTest.expect(try MiniTest.unwrap(try db.document(byId: doc.id!)).correspondentId == cid,
                        "Dokument-Referenz bleibt bei Umbenennen")
        try db.deleteCorrespondent(id: cid)
        try MiniTest.expect(try MiniTest.unwrap(try db.document(byId: doc.id!)).correspondentId == nil,
                        "Löschen setzt correspondent_id auf NULL")
        try MiniTest.expect(try db.correspondent(named: "Allianz SE") == nil, "Korrespondent weg")
    }

    /// Gescanntes PDF (kein Textlayer) landet nach OCR inkl. Heuristik in documents/.
    private static func ocrAppliesSuggestions() throws {
        let (vault, db, root, srcDir) = try makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        // gescanntes PDF: Datei in inbox, DB-Eintrag mit ocrDone=false
        let src = srcDir.appendingPathComponent("scan.pdf")
        try PDFFixture.writePDF(text: nil, to: src)
        let staged = try vault.stageIntoInbox(fileAt: src)
        guard case .imported(let doc) = try IngestService(vault: vault, db: db).process(fileAt: staged) else {
            throw PlessError.io("Fixture nicht importiert")
        }
        try MiniTest.expect(doc.needsReview, "gescannt → needsReview")
        try MiniTest.expectEqual(doc.relativePath, "inbox/scan.pdf")

        let stadtwerkeId = try db.insertCorrespondent(name: "Stadtwerke")
        let metadata = MetadataService(vault: vault, db: db)
        let ocr = OCRService(vault: vault, db: db,
                             recognizer: FakeTextRecognizer(text: "Stadtwerke Rechnung vom 01.03.2026"),
                             metadata: metadata)
        try MiniTest.expectEqual(try ocr.processPending(), 1)

        let re = try MiniTest.unwrap(try db.document(byId: doc.id!))
        try MiniTest.expect(re.ocrDone, "OCR fertig")
        try MiniTest.expect(!re.needsReview, "Review erledigt")
        try MiniTest.expect(re.title?.hasPrefix("Stadtwerke Rechnung") == true, "Titel: \(re.title ?? "nil")")
        try MiniTest.expectEqual(re.documentDate, "2026-03-01")
        try MiniTest.expectEqual(re.correspondentId, stadtwerkeId)
        try MiniTest.expect(re.relativePath.hasPrefix("documents/2026/03/"), "Pfad: \(re.relativePath)")
        try MiniTest.expect(re.filename.contains("Stadtwerke"), "Datei: \(re.filename)")
        try MiniTest.expect(FileManager.default.fileExists(
            atPath: vault.root.appendingPathComponent(re.relativePath).path))
        try MiniTest.expect(!FileManager.default.fileExists(atPath: staged.path), "Inbox-Datei weg")
    }

    private static func tagRenameDelete() throws {
        let (vault, db, root, srcDir) = try makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = try ingestOne(db: db, vault: vault, srcDir: srcDir, name: "a.pdf", text: "Inhalt A")
        let tid = try db.findOrCreateTag(name: "alt")
        try db.addTagToDocument(documentId: doc.id!, tagId: tid)
        try db.updateTag(id: tid, name: "neu", color: "#00FF00")
        try MiniTest.expect(try db.tag(named: "neu")?.color == "#00FF00", "Tag umbenannt + Farbe")
        try db.deleteTag(id: tid)
        try MiniTest.expect(try db.tags(for: doc.id!).isEmpty, "Cascade entfernt document_tags")
        try MiniTest.expect(try db.tag(named: "neu") == nil, "Tag weg")
    }
}
