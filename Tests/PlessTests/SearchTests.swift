import Foundation
import MiniTest
import PlessCore

enum SearchTests {
    static func register() {
        MiniTest.test("Search: ftsQuery baut sicheren MATCH-Ausdruck") { try ftsQueryCases() }
        MiniTest.test("Search: Volltext findet Dokument, Snippet mit « »)") { try fulltextFinds() }
        MiniTest.test("Search: Filter Kategorie/Korrespondent/Tag/Datum") { try filtersWork() }
        MiniTest.test("Search: ohne Query liefern Filter alle Treffer") { try noQueryReturnsFiltered() }
        MiniTest.test("Search: FTS bleibt nach UPDATE synchron (Trigger)") { try ftsSyncOnUpdate() }
    }

    // MARK: - Fixtures

    /// Vault mit zwei Dokumenten: d1 (Allianz/Rechnungen/wichtig, 2026-02-14), d2 (Stadtwerke, 2026-05-01).
    private static func makeEnv() throws -> (vault: Vault, db: Database, root: URL, d1: Document, d2: Document) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pless-search-\(UUID().uuidString)", isDirectory: true)
        let vault = try Vault(root: root)
        let db = try Database(url: vault.databaseURL)

        let corrId = try db.insertCorrespondent(name: "Allianz")
        let catId = try db.insertCategory(name: "Rechnungen")
        let tagId = try db.insertTag(name: "wichtig")

        var d1 = Document(uuid: UUID().uuidString, sha256: "sha1-\(UUID().uuidString)",
                          filename: "d1.pdf", relativePath: "inbox/d1.pdf",
                          title: "KFZ-Versicherung", correspondentId: corrId, categoryId: catId,
                          documentDate: "2026-02-14", pageCount: 2,
                          ocrText: "Allianz Versicherung 2026 Beitrag", ocrDone: true)
        d1.id = try db.insert(d1)
        try db.execute("INSERT INTO document_tags(document_id, tag_id) VALUES (\(d1.id!), \(tagId))")

        var d2 = Document(uuid: UUID().uuidString, sha256: "sha2-\(UUID().uuidString)",
                          filename: "d2.pdf", relativePath: "inbox/d2.pdf",
                          title: "Stromrechnung", documentDate: "2026-05-01", pageCount: 1,
                          ocrText: "Stadtwerke Rechnung Mai", ocrDone: true)
        d2.id = try db.insert(d2)
        return (vault, db, root, d1, d2)
    }

    // MARK: - Tests

    private static func ftsQueryCases() throws {
        try MiniTest.expectEqual(Database.ftsQuery("Allianz Rechnung"), "\"Allianz\" AND \"Rechnung\"")
        try MiniTest.expectEqual(Database.ftsQuery("   "), nil)
        try MiniTest.expectEqual(Database.ftsQuery(""), nil)
        try MiniTest.expectEqual(Database.ftsQuery("a\"b"), "\"a\"\"b\"")
    }

    private static func fulltextFinds() throws {
        let (vault, db, root, d1, _) = try makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = vault
        let hits = try db.search(SearchFilter(query: "Allianz"))
        try MiniTest.expectEqual(hits.count, 1)
        try MiniTest.expectEqual(hits[0].document.uuid, d1.uuid)
        try MiniTest.expect(hits[0].snippet.contains("«Allianz»"))
        // Mehrere Begriffe: beide müssen matchen
        try MiniTest.expectEqual(try db.search(SearchFilter(query: "Allianz Versicherung")).count, 1)
        try MiniTest.expectEqual(try db.search(SearchFilter(query: "Allianz Stadtwerke")).count, 0)
    }

    private static func filtersWork() throws {
        let (_, db, root, d1, d2) = try makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        try MiniTest.expectEqual(try db.search(SearchFilter(category: "Rechnungen")).map(\.document.uuid), [d1.uuid])
        try MiniTest.expectEqual(try db.search(SearchFilter(correspondent: "Allianz")).map(\.document.uuid), [d1.uuid])
        try MiniTest.expectEqual(try db.search(SearchFilter(tag: "wichtig")).map(\.document.uuid), [d1.uuid])
        try MiniTest.expectEqual(try db.search(SearchFilter(fromDate: "2026-03-01")).map(\.document.uuid), [d2.uuid])
        try MiniTest.expectEqual(try db.search(SearchFilter(fromDate: "2026-01-01", toDate: "2026-03-01")).map(\.document.uuid), [d1.uuid])
        // Kombination Volltext + Filter
        try MiniTest.expectEqual(try db.search(SearchFilter(query: "Allianz", category: "Rechnungen")).map(\.document.uuid), [d1.uuid])
        try MiniTest.expectEqual(try db.search(SearchFilter(query: "Versicherung", correspondent: "Allianz")).count, 1)
        try MiniTest.expectEqual(try db.search(SearchFilter(query: "Rechnung")).map(\.document.uuid), [d2.uuid])
    }

    private static func noQueryReturnsFiltered() throws {
        let (_, db, root, _, _) = try makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        try MiniTest.expectEqual(try db.search(SearchFilter()).count, 2)
        try MiniTest.expectEqual(try db.search(SearchFilter(limit: 1)).count, 1)
    }

    private static func ftsSyncOnUpdate() throws {
        let (_, db, root, _, d2) = try makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        try MiniTest.expectEqual(try db.search(SearchFilter(query: "Allianz")).count, 1)
        // OCR-Text nachträglich geändert → Trigger aktualisiert FTS
        try db.setOCRText(documentId: d2.id!, text: "nachgereicht: Allianz erstattet", ocrDone: true)
        let hits = try db.search(SearchFilter(query: "Allianz"))
        try MiniTest.expectEqual(hits.count, 2)
    }
}
