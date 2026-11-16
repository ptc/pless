import Foundation

// MARK: - paperless-ngx REST-Client (Phase 13)
//
// Einweg-Push zu einer self-hosted paperless-ngx-Instanz. Der Transport ist injizierbar:
// die App nutzt URLSession, die Tests einen Fake — so ist der Client komplett ohne Netz testbar.

/// URL + API-Token der paperless-Instanz.
public struct PaperlessConfig: Equatable, Sendable {
    public var baseURL: URL          // z. B. https://paperless.example.local
    public var token: String

    public init(baseURL: URL, token: String) {
        // kein abschließender Slash — Pfade werden unten mit führendem "/" angehängt
        var u = baseURL
        while u.path.hasSuffix("/") && u.path.count > 1 {
            u.deleteLastPathComponent()
        }
        self.baseURL = u
        self.token = token
    }
}

/// Transport-Protokoll: führt eine HTTP-Anfrage aus und liefert Status + Body.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (status: Int, data: Data)
}

/// Produktiver Transport über URLSession.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func send(_ request: URLRequest) async throws -> (status: Int, data: Data) {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, data)
    }
}

/// Benannte paperless-Ressource (Correspondent / Document Type / Tag): id + name.
public struct NamedResource: Equatable, Sendable {
    public var id: Int
    public var name: String
    public init(id: Int, name: String) { self.id = id; self.name = name }
}

/// Antwort-Helfer: JSON-Objekt oder -Liste aus dem Body.
public enum PaperlessResponse {
    public static func json(_ data: Data) throws -> Any {
        guard !data.isEmpty else { throw PlessError.sync("leere Antwort vom Server") }
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw PlessError.sync("Antwort ist kein JSON: \(String(data: data, encoding: .utf8)?.prefix(120) ?? "?")")
        }
    }

    /// Paginierte Liste: paperless liefert {"count": n, "results": [ … ]}.
    public static func results(_ data: Data) throws -> [[String: Any]] {
        let obj = try json(data)
        if let dict = obj as? [String: Any], let arr = dict["results"] as? [[String: Any]] { return arr }
        if let arr = obj as? [[String: Any]] { return arr }
        if let dict = obj as? [String: Any] { return [dict] }
        throw PlessError.sync("unerwartetes Listen-Format vom Server")
    }

    public static func object(_ data: Data) throws -> [String: Any] {
        if let dict = try json(data) as? [String: Any] { return dict }
        throw PlessError.sync("unerwartetes Objekt-Format vom Server")
    }
}

/// Client für die paperless-ngx-API (Token-Auth, JSON + multipart).
public final class PaperlessClient: Sendable {
    public let config: PaperlessConfig
    private let transport: HTTPTransport

    public init(config: PaperlessConfig, transport: HTTPTransport) {
        self.config = config
        self.transport = transport
    }

    // MARK: - Low-Level

    private func request(_ method: String, path: String, query: [String: String] = [:],
                         body: Data? = nil, contentType: String? = nil) -> URLRequest {
        // Pfad per String anhängen — appendPathComponent würde den nötigen trailing slash
        // („/api/documents/“) unterschlagen, paperless/Django verlangt ihn aber.
        // `path` darf auch eine absolute URL sein (Paginierung: `next` aus der Server-Antwort).
        var components: URLComponents
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            components = URLComponents(string: path)!
        } else {
            var base = config.baseURL.absoluteString
            if !base.hasSuffix("/") { base += "/" }
            let rel = path.hasPrefix("/") ? String(path.dropFirst()) : path
            components = URLComponents(string: base + rel)!
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        req.setValue("Token \(config.token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue(contentType ?? "application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func send(_ req: URLRequest, acceptable: ClosedRange<Int>) async throws -> Data {
        let (status, data) = try await transport.send(req)
        guard acceptable.contains(status) else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw PlessError.sync("HTTP \(status) bei \(req.httpMethod ?? "?") \(req.url?.path ?? "") — \(snippet)")
        }
        return data
    }

    /// GET auf eine paginierte Listen-Ressource → results-Array (nur erste Seite).
    private func list(path: String, query: [String: String] = [:]) async throws -> [[String: Any]] {
        let data = try await send(request("GET", path: path, query: query), acceptable: 200...299)
        return try PaperlessResponse.results(data)
    }

    /// GET auf eine Listen-Ressource mit Paginierung: folgt `next`, bis null → alle results.
    private func listAll(path: String, query: [String: String] = [:]) async throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        var req = request("GET", path: path, query: query)
        while true {
            let data = try await send(req, acceptable: 200...299)
            let obj = try PaperlessResponse.object(data)
            if let arr = obj["results"] as? [[String: Any]] { out.append(contentsOf: arr) }
            guard let next = obj["next"] as? String, !next.isEmpty else { break }
            req = request("GET", path: next)   // absolute URL aus der Antwort
        }
        return out
    }

    /// Alle benannten Ressourcen eines Endpunkts (paginiert) — für Pull-Import.
    public func listNamed(endpoint: String) async throws -> [NamedResource] {
        try await listAll(path: endpoint).compactMap { item in
            guard let id = item["id"] as? Int, let name = item["name"] as? String else { return nil }
            return NamedResource(id: id, name: name)
        }
    }

    public func listCorrespondents() async throws -> [NamedResource] {
        try await listNamed(endpoint: "/api/correspondents/")
    }

    /// paperless Document Types (→ pless-Kategorien beim Pull-Import).
    public func listDocumentTypes() async throws -> [NamedResource] {
        try await listNamed(endpoint: "/api/document_types/")
    }

    public func listTags() async throws -> [NamedResource] {
        try await listNamed(endpoint: "/api/tags/")
    }

    /// POST JSON → Antwort-Objekt.
    private func postJSON(path: String, body: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: body)
        let resp = try await send(request("POST", path: path, body: data, contentType: "application/json"),
                                  acceptable: 200...299)
        return try PaperlessResponse.object(resp)
    }

    // MARK: - Ping / Verbindungstest

    /// `GET /api/` mit Token — liefert die API-Wurzel (200) wenn URL + Token stimmen.
    public func ping() async throws -> Bool {
        _ = try await send(request("GET", path: "/api/"), acceptable: 200...299)
        return true
    }

    // MARK: - Find-or-create für benannte Ressourcen (Correspondent / Tag / Document Type)

    /// Liefert die ID der benannten Ressource; legt sie an, falls es sie (case-insensitiv) nicht gibt.
    /// paperless filtert `?name__iexact=` (neuere Versionen); ältere nur `?name=` — beides wird versucht.
    /// WICHTIG: nur ein exakter (case-insensitiver) Name-Treffer zählt — nie `results.first` nehmen:
    /// ignoriert der Server den Filter, käme sonst immer die erste Ressource des Servers zurück
    /// (z. B. landet dann jede Kategorie als „Arbeitsvertrag“).
    public func findOrCreate(endpoint: String, name: String) async throws -> Int {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PlessError.sync("\(endpoint): leerer Name") }
        for param in ["name__iexact", "name"] {
            let results = try await list(path: endpoint, query: [param: trimmed])
            if let hit = results.first(where: { ($0["name"] as? String)?.lowercased() == trimmed.lowercased() }),
               let id = hit["id"] as? Int {
                return id
            }
        }
        let created = try await postJSON(path: endpoint, body: ["name": trimmed])
        guard let id = created["id"] as? Int else {
            throw PlessError.sync("\(endpoint): Antwort ohne id — \(created)")
        }
        return id
    }

    public func findOrCreateCorrespondent(name: String) async throws -> Int {
        try await findOrCreate(endpoint: "/api/correspondents/", name: name)
    }

    public func findOrCreateTag(name: String) async throws -> Int {
        try await findOrCreate(endpoint: "/api/tags/", name: name)
    }

    /// pless-Kategorie landet als paperless Document Type.
    public func findOrCreateDocumentType(name: String) async throws -> Int {
        try await findOrCreate(endpoint: "/api/document_types/", name: name)
    }

    // MARK: - Checksum-Suche (Idempotenz)

    /// paperless-ID des Dokuments mit diesem sha256, falls vorhanden.
    public func checksumExists(_ sha256: String) async throws -> Int? {
        let results = try await list(path: "/api/documents/", query: ["checksum": sha256])
        return results.first?["id"] as? Int
    }

    // MARK: - Dokument hochladen (multipart)

    /// Metadaten eines vorhandenen paperless-Dokuments aktualisieren: `PATCH /api/documents/<id>/`.
    /// nil-Referenzen (correspondent / document_type) werden als null gesendet → werden in paperless geleert.
    /// title/created fehlen lokal → Feld wird ganz weggelassen (paperless erlaubt dort kein null, PATCH würde sonst 400 liefern).
    public func updateDocument(paperlessId: Int, title: String?, created: String?,
                               correspondentId: Int?, documentTypeId: Int?, tagIds: [Int]) async throws {
        var body: [String: Any] = [
            "correspondent": correspondentId.map { $0 as Any } ?? NSNull(),
            "document_type": documentTypeId.map { $0 as Any } ?? NSNull(),
            "tags": tagIds
        ]
        if let title { body["title"] = title }
        if let created { body["created"] = created }
        let data = try JSONSerialization.data(withJSONObject: body)
        _ = try await send(request("PATCH", path: "/api/documents/\(paperlessId)/", body: data,
                                   contentType: "application/json"),
                            acceptable: 200...299)
    }

    /// `POST /api/documents/post_document/` — Datei + Metadaten. Liefert die paperless-ID,
    /// soweit sie aus der Antwort gelesen werden kann (sonst nil → Aufrufer löst per Checksum auf).
    @discardableResult
    public func postDocument(fileData: Data, filename: String, title: String,
                             created: String?, correspondentId: Int?, documentTypeId: Int?,
                             tagIds: [Int]) async throws -> Int? {
        let boundary = "pless-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        func fileField(_ name: String, _ filename: String, _ data: Data, _ mime: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n".data(using: .utf8)!)
        }
        fileField("document", filename, fileData, "application/pdf")
        field("title", title)
        if let created { field("created", created) }
        if let correspondentId { field("correspondent", String(correspondentId)) }
        if let documentTypeId { field("document_type", String(documentTypeId)) }
        for t in tagIds { field("tags", String(t)) }   // repeated field = Liste
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let req = request("POST", path: "/api/documents/post_document/", body: body,
                          contentType: "multipart/form-data; boundary=\(boundary)")
        let resp = try await send(req, acceptable: 200...299)
        // Antwort kann JSON-Objekt {"id": …}, schlichtes Int oder Text sein — alles tolerant lesen
        if let obj = try? PaperlessResponse.object(resp), let id = obj["id"] as? Int { return id }
        if let arr = try? JSONSerialization.jsonObject(with: resp) as? [String: Any], let id = arr["id"] as? Int { return id }
        if let s = String(data: resp, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), let id = Int(s) { return id }
        return nil
    }
}
