import Foundation
import MiniTest
import PlessCore

enum MCPTests {
    static func register() {
        MiniTest.test("MCP: initialize liefert protocolVersion + serverInfo") { try initialize() }
        MiniTest.test("MCP: notifications/initialized → keine Antwort, ping → {}") { try pingNotification() }
        MiniTest.test("MCP: tools/list liefert alle 7 Tools mit Schema") { try toolsList() }
        MiniTest.test("MCP: search_documents findet per Volltext, get_document liefert OCR-Text") { try searchAndGet() }
        MiniTest.test("MCP: update_document setzt Metadaten und benennt Datei um") { try updateDocument() }
        MiniTest.test("MCP: assign_tag + list_categories + get_stats") { try tagCategoriesStats() }
        MiniTest.test("MCP: Fehler — unbekannte Methode (-32601), kaputtes JSON (-32700), unbekanntes Tool (isError)") { try errors() }
    }

    // MARK: - Fixtures

    private static func makeEnv() throws -> (server: MCPServer, vault: Vault, db: Database, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pless-mcp-\(UUID().uuidString)", isDirectory: true)
        let vault = try Vault(root: root)
        let db = try Database(url: vault.databaseURL)
        return (MCPServer(vault: vault, db: db), vault, db, root)
    }

    /// Seed: ein per Ingest importiertes Text-PDF (Datei existiert im Vault).
    private static func seedDoc(server: MCPServer, vault: Vault, db: Database, root: URL,
                                name: String, text: String) throws -> Document {
        let srcDir = root.appendingPathComponent("src", isDirectory: true)
        try? FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let src = srcDir.appendingPathComponent(name)
        try PDFFixture.writePDF(text: text, to: src)
        let staged = try vault.stageIntoInbox(fileAt: src)
        guard case .imported(let doc) = try IngestService(vault: vault, db: db).process(fileAt: staged) else {
            throw PlessError.io("Seed-Fixture nicht importiert")
        }
        return doc
    }

    private static func call(_ server: MCPServer, _ line: String) throws -> [String: Any] {
        let resp = try MiniTest.unwrap(server.handleLine(line), "keine Antwort auf: \(line)")
        let obj = try JSONSerialization.jsonObject(with: Data(resp.utf8)) as? [String: Any]
        return try MiniTest.unwrap(obj, "Antwort ist kein JSON-Objekt: \(resp)")
    }

    private static func toolCall(_ server: MCPServer, _ name: String, _ args: [String: Any] = [:]) throws -> [String: Any] {
        let req = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                   "params": ["name": name, "arguments": args]] as [String: Any]
        let data = try JSONSerialization.data(withJSONObject: req)
        let resp = try call(server, String(data: data, encoding: .utf8)!)
        guard let result = resp["result"] as? [String: Any] else {
            throw TestFailure("kein result in Antwort: \(resp)")
        }
        return result
    }

    /// Parst den text-Content eines Tool-Results als JSON.
    private static func payload(_ result: [String: Any]) throws -> Any {
        let content = try MiniTest.unwrap(result["content"] as? [[String: Any]], "kein content")
        let text = try MiniTest.unwrap(content.first?["text"] as? String, "kein text in content")
        return try JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    // MARK: - Tests

    private static func initialize() throws {
        let (server, _, _, root) = try makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        let resp = try call(server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        let result = try MiniTest.unwrap(resp["result"] as? [String: Any])
        try MiniTest.expectEqual(result["protocolVersion"] as? String, MCPServer.protocolVersion)
        let info = try MiniTest.unwrap(result["serverInfo"] as? [String: Any])
        try MiniTest.expectEqual(info["name"] as? String, "pless")
    }

    private static func pingNotification() throws {
        let (server, _, _, root) = try makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        try MiniTest.expect(server.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil,
                            "Notification darf keine Antwort liefern")
        let resp = try call(server, #"{"jsonrpc":"2.0","id":7,"method":"ping"}"#)
        let result = try MiniTest.unwrap(resp["result"] as? [String: Any])
        try MiniTest.expect(result.isEmpty, "ping → leeres result")
        try MiniTest.expectEqual(resp["id"] as? Int, 7)
    }

    private static func toolsList() throws {
        let (server, _, _, root) = try makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        let resp = try call(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let tools = try MiniTest.unwrap(resp["result"] as? [String: Any])["tools"] as? [[String: Any]]
        let names = Set(try MiniTest.unwrap(tools).map { try MiniTest.unwrap($0["name"] as? String) })
        try MiniTest.expectEqual(names, ["search_documents", "get_document", "list_documents",
                                         "list_categories", "update_document", "assign_tag", "get_stats"])
        for t in tools ?? [] {
            try MiniTest.expect(t["inputSchema"] != nil, "Tool ohne inputSchema: \(t["name"] ?? "?")")
        }
    }

    private static func searchAndGet() throws {
        let (server, vault, db, root) = try makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = try seedDoc(server: server, vault: vault, db: db, root: root,
                              name: "police.pdf", text: "Allianz KFZ-Versicherung 2026 Beitrag")

        let r = try toolCall(server, "search_documents", ["query": "Allianz"])
        let arr = try MiniTest.unwrap(try payload(r) as? [[String: Any]])
        try MiniTest.expect(arr.contains { ($0["uuid"] as? String) == doc.uuid }, "Treffer enthält uuid")
        try MiniTest.expect(arr.contains { ($0["snippet"] as? String)?.contains("«") == true }, "Snippet mit «»")

        let g = try toolCall(server, "get_document", ["document": doc.uuid])
        let obj = try MiniTest.unwrap(try payload(g) as? [String: Any])
        try MiniTest.expect((obj["ocr_text"] as? String)?.contains("KFZ-Versicherung") == true, "OCR-Text in get_document")
        try MiniTest.expectEqual(obj["uuid"] as? String, doc.uuid)

        // list_documents ohne Query
        let l = try toolCall(server, "list_documents", ["limit": 10])
        let larr = try MiniTest.unwrap(try payload(l) as? [[String: Any]])
        try MiniTest.expectEqual(larr.count, 1)
    }

    private static func updateDocument() throws {
        let (server, vault, db, root) = try makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = try seedDoc(server: server, vault: vault, db: db, root: root,
                              name: "vertrag.pdf", text: "Vertrag über irgendwas")

        let r = try toolCall(server, "update_document", [
            "document": doc.uuid, "title": "Neuer Titel", "correspondent": "Allianz",
            "category": "Versicherungen", "date": "2026-02-14", "notes": "per KI gesetzt"])
        let obj = try MiniTest.unwrap(try payload(r) as? [String: Any])
        try MiniTest.expectEqual(obj["title"] as? String, "Neuer Titel")
        try MiniTest.expectEqual(obj["correspondent"] as? String, "Allianz")
        try MiniTest.expect(((obj["relative_path"] as? String) ?? "").hasPrefix("documents/2026/02/"),
                            "relative_path: \(obj["relative_path"] ?? "nil")")

        let re = try MiniTest.unwrap(try db.document(byId: doc.id!))
        try MiniTest.expectEqual(re.title, "Neuer Titel")
        try MiniTest.expectEqual(re.documentDate, "2026-02-14")
        try MiniTest.expectEqual(re.notes, "per KI gesetzt")
        try MiniTest.expect(re.filename.contains("Neuer-Titel"), "Datei umbenannt: \(re.filename)")
        try MiniTest.expect(FileManager.default.fileExists(
            atPath: vault.root.appendingPathComponent(re.relativePath).path))
    }

    private static func tagCategoriesStats() throws {
        let (server, vault, db, root) = try makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = try seedDoc(server: server, vault: vault, db: db, root: root,
                              name: "r.pdf", text: "Rechnung Stadtwerke 01.03.2026")

        let t = try toolCall(server, "assign_tag", ["document": doc.uuid, "tag": "wichtig"])
        let tobj = try MiniTest.unwrap(try payload(t) as? [String: Any])
        let tags = try MiniTest.unwrap(tobj["tags"] as? [[String: Any]])
        try MiniTest.expect(tags.contains { $0["name"] as? String == "wichtig" }, "Tag zugewiesen")
        try MiniTest.expectEqual(try db.tags(for: doc.id!).count, 1)

        _ = try toolCall(server, "update_document", ["document": doc.uuid, "category": "Rechnungen"])
        let c = try toolCall(server, "list_categories")
        let cats = try MiniTest.unwrap(try payload(c) as? [[String: Any]])
        try MiniTest.expect(cats.contains { $0["name"] as? String == "Rechnungen" }, "Kategorie in list_categories")

        let s = try toolCall(server, "get_stats")
        let sobj = try MiniTest.unwrap(try payload(s) as? [String: Any])
        try MiniTest.expectEqual(sobj["documents_total"] as? Int, 1)
        try MiniTest.expectEqual(sobj["tags_total"] as? Int, 1)
        let byCat = try MiniTest.unwrap(sobj["by_category"] as? [String: Int])
        try MiniTest.expectEqual(byCat["Rechnungen"], 1)
    }

    private static func errors() throws {
        let (server, _, _, root) = try makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        let unknown = try call(server, #"{"jsonrpc":"2.0","id":1,"method":"gibtsnicht"}"#)
        let err = try MiniTest.unwrap(unknown["error"] as? [String: Any])
        try MiniTest.expectEqual(err["code"] as? Int, -32601)

        let bad = try call(server, "{kaputt")
        let err2 = try MiniTest.unwrap(bad["error"] as? [String: Any])
        try MiniTest.expectEqual(err2["code"] as? Int, -32700)

        let req = ["jsonrpc": "2.0", "id": 9, "method": "tools/call",
                   "params": ["name": "unbekanntes_tool", "arguments": [:]]] as [String: Any]
        let r = try call(server, String(data: try JSONSerialization.data(withJSONObject: req), encoding: .utf8)!)
        let e = try MiniTest.unwrap(r["error"] as? [String: Any], "unbekanntes Tool soll error liefern: \(r)")
        try MiniTest.expectEqual(e["code"] as? Int, -32602)
    }
}
