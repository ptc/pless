import Foundation

/// MCP-Server (Model Context Protocol) über stdio: JSON-RPC 2.0, eine JSON-Nachricht pro Zeile.
/// UI-frei und testbar über `handleLine(_:)`; `runStdio()` liest stdin bis EOF (CLI: `pless mcp`).
public final class MCPServer {
    public static let protocolVersion = "2025-06-18"

    public let vault: Vault
    public let db: Database
    private let metadata: MetadataService

    public init(vault: Vault, db: Database) {
        self.vault = vault
        self.db = db
        self.metadata = MetadataService(vault: vault, db: db)
        // Crash-Recovery beim Start: verwaiste/fehlende Dateien wiederfinden
        _ = try? RecoveryService(vault: vault, db: db).recover()
    }

    // MARK: - JSON-RPC

    /// Verarbeitet eine JSON-RPC-Zeile. Liefert die Antwort als Zeile oder nil (Notification).
    public func handleLine(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let method = obj["method"] as? String
        else {
            return errorResponse(id: NSNull(), code: -32700, message: "Parse error")
        }
        let id: Any = obj["id"] ?? NSNull()
        let params = obj["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            return result(id, [
                "protocolVersion": Self.protocolVersion,
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "pless", "version": "0.1.0"],
            ])
        case "notifications/initialized":
            return nil
        case "ping":
            return result(id, [:])
        case "tools/list":
            return result(id, ["tools": Self.toolSchemas])
        case "tools/call":
            return handleToolCall(id, params)
        default:
            return errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    /// stdio-Schleife: eine JSON-RPC-Nachricht pro Zeile lesen, Antworten schreiben. EOF → 0.
    @discardableResult
    public func runStdio() -> Int32 {
        while let line = readLine(strippingNewline: true) {
            if let response = handleLine(line) {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            }
        }
        return 0
    }

    // MARK: - Antworten

    private func result(_ id: Any, _ result: [String: Any]) -> String {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func errorResponse(id: Any, code: Int, message: String) -> String {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func encode(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func jsonString(_ obj: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - tools/call

    private func handleToolCall(_ id: Any, _ params: [String: Any]) -> String {
        guard let name = params["name"] as? String else {
            return errorResponse(id: id, code: -32602, message: "params.name fehlt")
        }
        let args = params["arguments"] as? [String: Any] ?? [:]
        do {
            let payload: Any
            switch name {
            case "search_documents": payload = try toolSearch(args)
            case "get_document": payload = try toolGetDocument(args)
            case "list_documents": payload = try toolListDocuments(args)
            case "list_categories": payload = try toolListCategories()
            case "update_document": payload = try toolUpdateDocument(args)
            case "assign_tag": payload = try toolAssignTag(args)
            case "get_stats": payload = try toolGetStats()
            default:
                return errorResponse(id: id, code: -32602, message: "Unbekanntes Tool: \(name)")
            }
            let text = try Self.jsonString(payload)
            return result(id, ["content": [["type": "text", "text": text]]])
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return result(id, ["content": [["type": "text", "text": message]], "isError": true])
        }
    }

    // MARK: - Tools

    private func toolSearch(_ args: [String: Any]) throws -> [[String: Any]] {
        var filter = SearchFilter(limit: (args["limit"] as? Int) ?? 20)
        if let q = args["query"] as? String { filter.query = q }
        if let v = args["tag"] as? String { filter.tag = v }
        if let v = args["correspondent"] as? String { filter.correspondent = v }
        if let v = args["category"] as? String { filter.category = v }
        if let v = args["from"] as? String { filter.fromDate = v }
        if let v = args["to"] as? String { filter.toDate = v }
        return try db.search(filter).map { hit in
            var j = try docJSON(hit.document)
            j["snippet"] = hit.snippet
            j["rank"] = hit.rank
            return j
        }
    }

    private func toolListDocuments(_ args: [String: Any]) throws -> [[String: Any]] {
        var filter = SearchFilter(limit: (args["limit"] as? Int) ?? 50, offset: (args["offset"] as? Int) ?? 0)
        if let v = args["tag"] as? String { filter.tag = v }
        if let v = args["correspondent"] as? String { filter.correspondent = v }
        if let v = args["category"] as? String { filter.category = v }
        if let v = args["from"] as? String { filter.fromDate = v }
        if let v = args["to"] as? String { filter.toDate = v }
        return try db.search(filter).map { try docJSON($0.document) }
    }

    private func toolGetDocument(_ args: [String: Any]) throws -> [String: Any] {
        let doc = try findDocument(args)
        var j = try docJSON(doc)
        j["ocr_text"] = doc.ocrText ?? NSNull()
        return j
    }

    private func toolListCategories() throws -> [[String: Any]] {
        try db.categories().map { c in
            ["id": c.id ?? 0, "name": c.name, "parent_id": Self.opt(c.parentId), "color": Self.opt(c.color)]
        }
    }

    private func toolUpdateDocument(_ args: [String: Any]) throws -> [String: Any] {
        let doc = try findDocument(args)
        guard let id = doc.id else { throw PlessError.notFound("Dokument ohne id") }
        var title = doc.title, date = doc.documentDate, notes = doc.notes
        var corrId = doc.correspondentId, catId = doc.categoryId
        if let v = args["title"] as? String { title = v.isEmpty ? nil : v }
        if let v = args["date"] as? String { date = v.isEmpty ? nil : v }
        if let v = args["notes"] as? String { notes = v.isEmpty ? nil : v }
        if let v = args["correspondent"] as? String { corrId = v.isEmpty ? nil : try db.findOrCreateCorrespondent(name: v) }
        if let v = args["category"] as? String { catId = v.isEmpty ? nil : try db.findOrCreateCategory(name: v) }
        let updated = try metadata.saveMetadata(documentId: id, title: title, documentDate: date,
                                                correspondentId: corrId, categoryId: catId, notes: notes)
        return try docJSON(updated)
    }

    private func toolAssignTag(_ args: [String: Any]) throws -> [String: Any] {
        let doc = try findDocument(args)
        guard let id = doc.id, let tagName = args["tag"] as? String, !tagName.isEmpty else {
            throw PlessError.invalidDocument("assign_tag braucht document + tag")
        }
        let tagId = try db.findOrCreateTag(name: tagName)
        try db.addTagToDocument(documentId: id, tagId: tagId)
        let tags = try db.tags(for: id)
        return ["document": doc.uuid, "tags": tags.map { ["id": $0.id ?? 0, "name": $0.name, "color": Self.opt($0.color)] }]
    }

    private func toolGetStats() throws -> [String: Any] {
        let docs = try db.allDocuments()
        var byYear: [String: Int] = [:]
        var byCorrespondent: [String: Int] = [:]
        var byCategory: [String: Int] = [:]
        for d in docs {
            let year = String((d.documentDate ?? d.addedAt).prefix(4))
            byYear[year, default: 0] += 1
            if let cid = d.correspondentId, let c = try? db.correspondent(id: cid) {
                byCorrespondent[c.name, default: 0] += 1
            }
            if let cid = d.categoryId, let c = try? db.category(id: cid) {
                byCategory[c.name, default: 0] += 1
            }
        }
        let inboxFiles = (try? FileManager.default.contentsOfDirectory(atPath: vault.inboxURL.path))?
            .filter { $0.lowercased().hasSuffix(".pdf") }.count ?? 0
        return [
            "documents_total": docs.count,
            "needs_review": docs.filter { $0.needsReview }.count,
            "inbox_files": inboxFiles,
            "by_year": byYear,
            "by_correspondent": byCorrespondent,
            "by_category": byCategory,
            "tags_total": (try? db.tags().count) ?? 0,
        ]
    }

    // MARK: - Helfer

    /// Optional → JSON-Wert (nil wird NSNull), ohne Coercion-Fallen im Dictionary-Literal.
    private static func opt(_ v: Any?) -> Any { v ?? NSNull() }

    private func findDocument(_ args: [String: Any]) throws -> Document {
        guard let key = args["document"] as? String, !key.isEmpty else {
            throw PlessError.invalidDocument("Param 'document' (uuid oder sha256) fehlt")
        }
        if key.count == 64, key.allSatisfy({ $0.isHexDigit }) {
            if let d = try db.document(bySHA256: key) { return d }
        }
        if let d = try db.document(byUUID: key) { return d }
        throw PlessError.notFound("Dokument nicht gefunden: \(key)")
    }

    private func docJSON(_ d: Document) throws -> [String: Any] {
        func jnull(_ v: String?) -> Any { v ?? NSNull() }
        let corrName: String? = d.correspondentId.flatMap { (try? db.correspondent(id: $0))?.name }
        let catName: String? = d.categoryId.flatMap { (try? db.category(id: $0))?.name }
        return [
            "id": d.id ?? 0,
            "uuid": d.uuid,
            "sha256": d.sha256,
            "filename": d.filename,
            "relative_path": d.relativePath,
            "title": jnull(d.title),
            "correspondent": jnull(corrName),
            "category": jnull(catName),
            "document_date": jnull(d.documentDate),
            "added_at": d.addedAt,
            "page_count": d.pageCount,
            "ocr_done": d.ocrDone,
            "needs_review": d.needsReview,
            "notes": jnull(d.notes),
        ]
    }

    // MARK: - Tool-Schemas

    private static func schema(_ props: [String: Any], _ required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": props, "required": required]
    }

    private static let str = ["type": "string"]
    private static let int = ["type": "integer"]

    public static let toolSchemas: [[String: Any]] = [
        ["name": "search_documents", "description": "Volltextsuche (FTS5) über Titel, OCR-Text und Korrespondent, mit optionalen Filtern. Liefert Treffer mit Snippet und bm25-Rank.",
         "inputSchema": schema(["query": str, "limit": int, "tag": str, "correspondent": str, "category": str, "from": str, "to": str])],
        ["name": "get_document", "description": "Metadaten + kompletter OCR-Text eines Dokuments (uuid oder sha256).",
         "inputSchema": schema(["document": str], ["document"])],
        ["name": "list_documents", "description": "Paginierte Liste aller Dokumente, optional gefiltert.",
         "inputSchema": schema(["tag": str, "correspondent": str, "category": str, "from": str, "to": str, "limit": int, "offset": int])],
        ["name": "list_categories", "description": "Alle Kategorien inkl. parent_id (für den Baum).",
         "inputSchema": schema([:])],
        ["name": "update_document", "description": "Metadaten setzen (Titel, Datum, Korrespondent, Kategorie, Notizen). Benennt die Datei ggf. nach Template um. Leere Strings löschen das Feld.",
         "inputSchema": schema(["document": str, "title": str, "correspondent": str, "category": str, "date": str, "notes": str], ["document"])],
        ["name": "assign_tag", "description": "Tag anlegen (falls nicht vorhanden) und dem Dokument zuweisen.",
         "inputSchema": schema(["document": str, "tag": str], ["document", "tag"])],
        ["name": "get_stats", "description": "Statistik: Anzahl Dokumente, Aufteilung pro Jahr/Korrespondent/Kategorie, Tags, Inbox-Stand.",
         "inputSchema": schema([:])],
    ]
}
