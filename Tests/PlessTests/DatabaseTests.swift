import Foundation
import MiniTest
import PlessCore

enum DatabaseTests {
    static func register() {
        MiniTest.test("DB: Migration legt Schema an (user_version=2, FTS5 inkl.)") { try createsSchema() }
        MiniTest.test("DB: Document insert + fetch byUUID/bySHA256") { try insertAndFetch() }
        MiniTest.test("DB: doppelte sha256 wirft duplicateSHA256") { try duplicateSHAThrows() }
        MiniTest.test("DB: allDocuments liefert alle Dokumente") { try allDocumentsReturnsAll() }
        MiniTest.test("DB: Correspondent/Category/Tag Roundtrip (inkl. Hierarchie)") { try entityRoundtrip() }
    }

    private static func makeDatabase() throws -> (db: Database, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pless-dbtest-\(UUID().uuidString)", isDirectory: true)
        let vault = try Vault(root: root)
        return (try Database(url: vault.databaseURL), root)
    }

    private static func sampleDocument(sha: String = "sha-\(UUID().uuidString)") -> Document {
        Document(uuid: UUID().uuidString, sha256: sha,
                 filename: "test.pdf", relativePath: "documents/2026/11/test.pdf",
                 title: "Testrechnung", documentDate: "2026-11-15", pageCount: 3, ocrDone: true)
    }

    private static func createsSchema() throws {
        let (db, root) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        try MiniTest.expectEqual(try db.scalarInt("PRAGMA user_version;"), 2)
        try MiniTest.expectEqual(
            try db.scalarInt("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='documents';"), 1)
        try MiniTest.expectEqual(
            try db.scalarInt("SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('correspondents','categories','tags','document_tags');"),
            4)
        try MiniTest.expectEqual(
            try db.scalarInt("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='documents_fts';"), 1)
    }

    private static func insertAndFetch() throws {
        let (db, root) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = sampleDocument()
        let id = try db.insert(doc)
        try MiniTest.expect(id > 0)
        let byUUID = try db.document(byUUID: doc.uuid)
        try MiniTest.expectEqual(byUUID?.id, id)
        try MiniTest.expectEqual(byUUID?.sha256, doc.sha256)
        try MiniTest.expectEqual(byUUID?.title, "Testrechnung")
        try MiniTest.expectEqual(byUUID?.pageCount, 3)
        try MiniTest.expect(byUUID?.ocrDone == true)
        let bySHA = try db.document(bySHA256: doc.sha256)
        try MiniTest.expectEqual(bySHA?.uuid, doc.uuid)
        try MiniTest.expectEqual(try db.document(byUUID: "unbekannt"), nil)
    }

    private static func duplicateSHAThrows() throws {
        let (db, root) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try db.insert(sampleDocument(sha: "dup-sha"))
        try MiniTest.expectThrows(PlessError.duplicateSHA256("dup-sha")) {
            _ = try db.insert(sampleDocument(sha: "dup-sha"))
        }
    }

    private static func allDocumentsReturnsAll() throws {
        let (db, root) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try db.insert(sampleDocument())
        _ = try db.insert(sampleDocument())
        try MiniTest.expectEqual(try db.allDocuments().count, 2)
    }

    private static func entityRoundtrip() throws {
        let (db, root) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try db.insertCorrespondent(name: "Allianz")
        let catId = try db.insertCategory(name: "Rechnungen", color: "#FF0000")
        let subId = try db.insertCategory(name: "Versicherungen", parentId: catId)
        let tagId = try db.insertTag(name: "wichtig", color: "#00FF00")

        try MiniTest.expectEqual(try db.correspondents().map(\.name), ["Allianz"])
        let cats = try db.categories()
        try MiniTest.expectEqual(cats.count, 2)
        try MiniTest.expectEqual(cats.first { $0.id == subId }?.parentId, catId)
        try MiniTest.expectEqual(try db.tags().first?.id, tagId)
    }
}
