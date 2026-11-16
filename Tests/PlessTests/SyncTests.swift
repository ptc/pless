import Foundation
import MiniTest
import PlessCore

// MARK: - Fake-Transport: zeichnet Anfragen auf und beantwortet sie aus einem Handler.

final class FakeTransport: HTTPTransport {
    struct Recorded: Sendable {
        var method: String
        var path: String
        var query: String?
        var authorization: String?
        var contentType: String?
        var body: Data?
    }
    private let lock = NSLock()
    private var recorded: [Recorded] = []
    var requests: [Recorded] { lock.lock(); defer { lock.unlock() }; return recorded }
    /// Antwort-Handler: bekommt die aufgezeichnete Anfrage, liefert (status, body).
    var handler: @Sendable (Recorded) -> (Int, Data)

    init(handler: @escaping @Sendable (Recorded) -> (Int, Data)) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (status: Int, data: Data) {
        // rohen Pfad aus der absoluteString nehmen — URL.path streicht den trailing slash,
        // den paperless aber braucht; der Test soll genau das prüfen.
        let abs = request.url?.absoluteString ?? ""
        let base = "https://paperless.test"
        let rawPath = abs.hasPrefix(base) ? String(abs.dropFirst(base.count)) : abs
        let pathOnly = rawPath.split(separator: "?").first.map(String.init) ?? rawPath
        let rec = Recorded(
            method: request.httpMethod ?? "GET",
            path: pathOnly,
            query: request.url?.query,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            body: request.httpBody)
        lock.lock(); recorded.append(rec); lock.unlock()
        return handler(rec)
    }
}

enum SyncTests {
    static func register() {
        MiniTest.test("DB: Migration V3 legt sync_map an (user_version=5 nach V4+V5)") { try migrationV3() }
        MiniTest.test("DB: Migration V4: sync_state-Spalte + Backfill aus sync_map (synced/unknown)") { try migrationV4Backfill() }
        MiniTest.test("DB: sync_state-Transitionen (setSyncEntry→synced, setSyncState, markUnknownAsNotSynced)") { try syncStateTransitions() }
        MiniTest.test("DB: sync_map set/get/delete + meta_sha256-Roundtrip") { try syncMapCrud() }
        MiniTest.test("Client: updateDocument baut PATCH-JSON (null bei leeren Referenzen, tags als Liste)") { try updateDocumentPatch() }
        MiniTest.test("Client: find-or-create legt an bzw. findet vorhanden (case-insensitiv), Token-Header") { try findOrCreate() }
        MiniTest.test("Client: checksumExists liefert ID bzw. nil") { try checksumLookup() }
        MiniTest.test("Client: postDocument baut multipart mit allen Feldern (Datei, Titel, created, IDs, Tags)") { try postDocumentMultipart() }
        MiniTest.test("Client: ping bei 200 true, bei 401 Fehler") { try pingTest() }
        MiniTest.test("SyncService: Push legt sync_map, zweiter Lauf skipped, sha-Wechsel re-upload, Metadaten-Änderung → PATCH, Fehler landen in failed") { try syncServiceEndToEnd() }
    }

    /// Führt einen async-Block synchron aus (MiniTest-Bodies sind nicht async) — wie in OCRTests.
    private static func awaitAsync<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let sem = DispatchSemaphore(value: 0)
        var value: T?
        var thrown: Error?
        Task {
            do { value = try await body() } catch let e { thrown = e }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 30)
        if let thrown { throw thrown }
        return try MiniTest.unwrap(value, "awaitAsync: kein Ergebnis")
    }

    // MARK: - DB / Migration

    private static func makeDB() throws -> (db: Database, root: URL) {
        let root = PDFFixture.tempDir("pless-synctest")
        let vault = try Vault(root: root)
        return (try Database(url: vault.databaseURL), root)
    }

    private static func sampleDoc(sha: String) -> Document {
        Document(uuid: UUID().uuidString, sha256: sha, filename: "test.pdf",
                 relativePath: "documents/2026/11/test.pdf", title: "Testrechnung",
                 documentDate: "2026-11-15", pageCount: 1, ocrDone: true)
    }

    private static func migrationV3() throws {
        let (db, root) = try makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        try MiniTest.expectEqual(try db.scalarInt("PRAGMA user_version;"), 5)
        try MiniTest.expectEqual(
            try db.scalarInt("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='sync_map';"), 1)
        try MiniTest.expectEqual(
            try db.scalarInt("SELECT count(*) FROM pragma_table_info('sync_map') WHERE name='meta_sha256';"), 1)
    }

    /// Baut eine DB auf Stand V3 zurück (Spalten weg, user_version=3), damit applyV4/V5 erneut laufen.
    private static func rewindToV3(_ db: Database) throws {
        try db.execute("ALTER TABLE documents DROP COLUMN sync_state")
        try db.execute("ALTER TABLE sync_map DROP COLUMN meta_sha256")
        try db.execute("PRAGMA user_version = 3")
    }

    private static func migrationV4Backfill() throws {
        let (db, root) = try makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let synced = try db.insert(sampleDoc(sha: "sha-synced"))
        let other = try db.insert(sampleDoc(sha: "sha-other"))
        // sync_map-Eintrag per Roh-SQL, damit sync_state noch nicht gesetzt ist
        try db.execute("INSERT INTO sync_map(document_id, paperless_id, sha256) VALUES(\(synced), 42, 'sha-synced')")
        try rewindToV3(db)
        // Reopen: Migration V4 + V5 laufen erneut (ADD COLUMN sync_state + Backfill, meta_sha256)
        let db2 = try Database(url: Vault(root: root).databaseURL)
        try MiniTest.expectEqual(try db2.scalarInt("PRAGMA user_version;"), 5)
        try MiniTest.expectEqual(try db2.document(byId: synced)?.syncState, .synced)
        try MiniTest.expectEqual(try db2.document(byId: other)?.syncState, .unknown)
        // frisches Dokument ohne sync_map-Eintrag: Default 'unknown'
        let fresh = try db2.insert(sampleDoc(sha: "sha-fresh"))
        try MiniTest.expectEqual(try db2.document(byId: fresh)?.syncState, .unknown)
    }

    private static func syncStateTransitions() throws {
        let (db, root) = try makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try db.insert(sampleDoc(sha: "sa"))
        let b = try db.insert(sampleDoc(sha: "sb"))
        let c = try db.insert(sampleDoc(sha: "sc"))
        try MiniTest.expectEqual(try db.document(byId: a)?.syncState, .unknown)
        // erfolgreicher Push → synced (setSyncEntry setzt beides)
        try db.setSyncEntry(documentId: a, paperlessId: 7, sha256: "sa", metaSha256: "meta-a")
        try MiniTest.expectEqual(try db.document(byId: a)?.syncState, .synced)
        try MiniTest.expectEqual(try db.syncEntry(for: a)?.metaSha256, "meta-a")
        // expliziter State-Wechsel (z. B. Push fehlgeschlagen)
        try db.setSyncState(.notSynced, for: b)
        try MiniTest.expectEqual(try db.document(byId: b)?.syncState, .notSynced)
        // Reconcile: unknown → not_synced (nur nicht gelöschte)
        try db.setSyncState(.unknown, for: c)
        try db.markUnknownAsNotSynced()
        try MiniTest.expectEqual(try db.document(byId: c)?.syncState, .notSynced)
        try MiniTest.expect(try db.document(byId: a)?.syncState == .synced, "synced bleibt synced")
        try MiniTest.expect(try db.document(byId: b)?.syncState == .notSynced, "not_synced bleibt not_synced")
        // auch über search()/SearchHit sichtbar
        let hit = try db.search(SearchFilter(query: nil, limit: 10)).first { $0.document.id == a }
        try MiniTest.expectEqual(hit?.document.syncState, .synced)
    }

    private static func syncMapCrud() throws {
        let (db, root) = try makeDB()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try db.insert(sampleDoc(sha: "aaa"))
        try MiniTest.expectEqual(try db.syncEntry(for: id), nil)
        try db.setSyncEntry(documentId: id, paperlessId: 42, sha256: "aaa", metaSha256: "m1")
        let e = try MiniTest.unwrap(try db.syncEntry(for: id))
        try MiniTest.expectEqual(e.paperlessId, 42)
        try MiniTest.expectEqual(e.sha256, "aaa")
        try MiniTest.expectEqual(e.metaSha256, "m1")
        try MiniTest.expect(!e.syncedAt.isEmpty)
        try MiniTest.expectEqual(try db.document(byId: id)?.syncState, .synced)
        // Upsert: andere paperless-ID + sha + meta
        try db.setSyncEntry(documentId: id, paperlessId: 43, sha256: "bbb", metaSha256: "m2")
        let e2 = try MiniTest.unwrap(try db.syncEntry(for: id))
        try MiniTest.expectEqual(e2.paperlessId, 43)
        try MiniTest.expectEqual(e2.sha256, "bbb")
        try MiniTest.expectEqual(e2.metaSha256, "m2")
        // Upsert ohne meta (nil) → NULL in der Spalte
        try db.setSyncEntry(documentId: id, paperlessId: 43, sha256: "bbb")
        try MiniTest.expectEqual(try db.syncEntry(for: id)?.metaSha256, nil)
        let id2 = try db.insert(sampleDoc(sha: "ccc"))
        try db.setSyncEntry(documentId: id2, paperlessId: 7, sha256: "ccc", metaSha256: "m3")
        try MiniTest.expectEqual(try db.allSyncEntries().count, 2)
        try db.deleteSyncEntry(for: id)
        try MiniTest.expectEqual(try db.syncEntry(for: id), nil)
        try MiniTest.expectEqual(try db.allSyncEntries().count, 1)
    }

    private static func updateDocumentPatch() throws {
        try awaitAsync {
        let transport = FakeTransport { req in
            if req.method == "PATCH" && req.path == "/api/documents/42/" { return (200, json(["id": 42])) }
            return (404, Data())
        }
        let client = PaperlessClient(config: config(), transport: transport)
        try await client.updateDocument(paperlessId: 42, title: "Neu", created: "2026-11-15",
                                        correspondentId: 7, documentTypeId: nil, tagIds: [11, 12])
        let req = try MiniTest.unwrap(transport.requests.first)
        try MiniTest.expectEqual(req.method, "PATCH")
        try MiniTest.expectEqual(req.path, "/api/documents/42/")
        try MiniTest.expectEqual(req.contentType, "application/json")
        try MiniTest.expectEqual(req.authorization, "Token test-token")
        let obj = try JSONSerialization.jsonObject(with: req.body ?? Data()) as? [String: Any]
        try MiniTest.expectEqual(try MiniTest.unwrap(obj)["title"] as? String, "Neu")
        try MiniTest.expectEqual(obj!["created"] as? String, "2026-11-15")
        try MiniTest.expectEqual(obj!["correspondent"] as? Int, 7)
        try MiniTest.expect(obj!["document_type"] is NSNull, "document_type nil → null (löschen in paperless)")
        try MiniTest.expectEqual((obj!["tags"] as? [NSNumber])?.map { $0.intValue }, [11, 12])

        // title/created nil → Felder fehlen ganz (paperless: null nicht erlaubt → 400); Referenzen null = leeren
        try await client.updateDocument(paperlessId: 42, title: nil, created: nil,
                                        correspondentId: nil, documentTypeId: nil, tagIds: [])
        let req2 = try MiniTest.unwrap(transport.requests.last)
        let obj2 = try MiniTest.unwrap(try JSONSerialization.jsonObject(with: req2.body ?? Data()) as? [String: Any])
        try MiniTest.expect(!obj2.keys.contains("title") && !obj2.keys.contains("created"), "nil-Felder weglassen: \(obj2.keys)")
        try MiniTest.expect(obj2["correspondent"] is NSNull && obj2["document_type"] is NSNull)
        try MiniTest.expectEqual((obj2["tags"] as? [NSNumber])?.map { $0.intValue } ?? [], [])
        }
    }

    // MARK: - Client

    private static func config() -> PaperlessConfig {
        PaperlessConfig(baseURL: URL(string: "https://paperless.test/")!, token: "test-token")
    }

    private static func json(_ obj: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: obj)
    }

    private static func emptyList() -> Data {
        json(["count": 0, "next": NSNull(), "previous": NSNull(), "results": []])
    }

    private static func findOrCreate() throws {
        try awaitAsync {
        // Teil A: nicht vorhanden → GETs leer → POST create liefert id 7
        let createTransport = FakeTransport { req in
            if req.path == "/api/correspondents/" && req.method == "GET" { return (200, emptyList()) }
            if req.path == "/api/correspondents/" && req.method == "POST" { return (201, json(["id": 7, "name": "Allianz"])) }
            return (404, Data())
        }
        let createClient = PaperlessClient(config: config(), transport: createTransport)
        let id1 = try await createClient.findOrCreateCorrespondent(name: "Allianz")
        try MiniTest.expectEqual(id1, 7)
        // Token-Header bei jeder Anfrage, Query mit name__iexact, POST als JSON mit name
        try MiniTest.expect(createTransport.requests.allSatisfy { $0.authorization == "Token test-token" })
        try MiniTest.expect((createTransport.requests.first { $0.method == "GET" }?.query ?? "").contains("name__iexact=Allianz"))
        let post = try MiniTest.unwrap(createTransport.requests.first { $0.method == "POST" })
        try MiniTest.expectEqual(post.contentType, "application/json")
        let postBody = try MiniTest.unwrap(String(data: post.body ?? Data(), encoding: .utf8))
        try MiniTest.expect(postBody.contains("\"name\"") && postBody.contains("Allianz"))

        // Teil B: vorhanden (case-insensitiv) → GET-Treffer, kein POST
        let existingTransport = FakeTransport { req in
            if req.path == "/api/correspondents/" && req.method == "GET" {
                return (200, json(["count": 1, "results": [["id": 7, "name": "allianz"]]]))
            }
            return (404, Data())
        }
        let existingClient = PaperlessClient(config: config(), transport: existingTransport)
        let id2 = try await existingClient.findOrCreateCorrespondent(name: "Allianz")
        try MiniTest.expectEqual(id2, 7)
        try MiniTest.expect(existingTransport.requests.allSatisfy { $0.method == "GET" }, "bei vorhandenem Eintrag darf nicht angelegt werden")

        // Teil C: Server ignoriert den Filter und liefert unpassende Ressourcen →
        // KEIN results.first-Fallback, sondern anlegen (sonst landet jede Kategorie als „Arbeitsvertrag“)
        let noisyTransport = FakeTransport { req in
            if req.method == "GET" { return (200, json(["count": 1, "results": [["id": 1, "name": "Arbeitsvertrag"]]])) }
            if req.method == "POST" { return (201, json(["id": 9, "name": "Steuern"])) }
            return (404, Data())
        }
        let noisyClient = PaperlessClient(config: config(), transport: noisyTransport)
        let id3 = try await noisyClient.findOrCreateDocumentType(name: "Steuern")
        try MiniTest.expectEqual(id3, 9)
        try MiniTest.expect(noisyTransport.requests.contains { $0.method == "POST" }, "bei keinem exakten Treffer muss angelegt werden")

        // Teil D: exakter Treffer (case-insensitiv) in voller Liste → richtige ID, kein POST
        let mixedTransport = FakeTransport { req in
            if req.method == "GET" {
                return (200, json(["count": 2, "results": [["id": 1, "name": "Arbeitsvertrag"], ["id": 7, "name": "STEUERN"]]]))
            }
            return (404, Data())
        }
        let mixedClient = PaperlessClient(config: config(), transport: mixedTransport)
        let id4 = try await mixedClient.findOrCreateDocumentType(name: "Steuern")
        try MiniTest.expectEqual(id4, 7)
        try MiniTest.expect(mixedTransport.requests.allSatisfy { $0.method == "GET" }, "bei Treffer in der Liste darf nicht angelegt werden")
        }
    }

    private static func checksumLookup() throws {
        try awaitAsync {
        let transport = FakeTransport { req in
            if req.path == "/api/documents/" && (req.query ?? "").contains("checksum=abc") {
                return (200, json(["count": 1, "results": [["id": 42, "checksum": "abc"]]]))
            }
            return (200, emptyList())
        }
        let client = PaperlessClient(config: config(), transport: transport)
        try MiniTest.expectEqual(try await client.checksumExists("abc"), 42)
        try MiniTest.expectEqual(try await client.checksumExists("unbekannt"), nil)
        }
    }

    private static func postDocumentMultipart() throws {
        try awaitAsync {
        let transport = FakeTransport { req in
            if req.path == "/api/documents/post_document/" && req.method == "POST" {
                return (200, json(["id": 99]))
            }
            return (404, Data())
        }
        let client = PaperlessClient(config: config(), transport: transport)
        let id = try await client.postDocument(
            fileData: Data("PDF-BYTES".utf8), filename: "2026-11-15_Allianz_Test.pdf",
            title: "Testrechnung", created: "2026-11-15",
            correspondentId: 7, documentTypeId: 3, tagIds: [11, 12])
        try MiniTest.expectEqual(id, 99)
        let req = try MiniTest.unwrap(transport.requests.first)
        try MiniTest.expect(req.contentType?.hasPrefix("multipart/form-data; boundary=") == true)
        let body = String(decoding: req.body ?? Data(), as: UTF8.self)
        try MiniTest.expect(body.contains("name=\"document\"; filename=\"2026-11-15_Allianz_Test.pdf\""), "Datei-Feld fehlt")
        try MiniTest.expect(body.contains("application/pdf"))
        try MiniTest.expect(body.contains("PDF-BYTES"))
        try MiniTest.expect(body.contains("name=\"title\"") && body.contains("Testrechnung"))
        try MiniTest.expect(body.contains("name=\"created\"") && body.contains("2026-11-15"))
        try MiniTest.expect(body.contains("name=\"correspondent\"") && body.contains("\r\n7\r\n"))
        try MiniTest.expect(body.contains("name=\"document_type\"") && body.contains("\r\n3\r\n"))
        // Tags als repeated field
        let tagFields = body.components(separatedBy: "name=\"tags\"").count - 1
        try MiniTest.expectEqual(tagFields, 2)
        try MiniTest.expect(body.contains("\r\n11\r\n") && body.contains("\r\n12\r\n"))
        }
    }

    private static func pingTest() throws {
        try awaitAsync {
        let ok = FakeTransport { _ in (200, json(["documents": "https://paperless.test/api/documents/"])) }
        let clientOk = PaperlessClient(config: config(), transport: ok)
        try MiniTest.expect(try await clientOk.ping())
        let bad = FakeTransport { _ in (401, Data("Unauthorized".utf8)) }
        let clientBad = PaperlessClient(config: config(), transport: bad)
        var thrown = false
        do { _ = try await clientBad.ping() } catch { thrown = true }
        try MiniTest.expect(thrown, "401 muss Fehler werfen")
        }
    }

    // MARK: - SyncService Ende-zu-Ende (Fake-Server)

    private static func syncServiceEndToEnd() throws {
        try awaitAsync {
        let root = PDFFixture.tempDir("pless-sync-e2e")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = try Vault(root: root)
        let db = try Database(url: vault.databaseURL)

        // echte PDF-Datei im Vault ablegen
        let folder = try vault.documentsFolder(year: 2026, month: 11)
        let fileURL = folder.appendingPathComponent("test.pdf")
        try PDFFixture.writePDF(text: "Rechnung 2026", to: fileURL)
        let sha = try FileHash.sha256(of: fileURL)

        let corrId = try db.findOrCreateCorrespondent(name: "Allianz")
        let catId = try db.findOrCreateCategory(name: "Rechnungen")
        var doc = sampleDoc(sha: sha)
        doc.correspondentId = corrId
        doc.categoryId = catId
        doc.documentDate = "2026-11-15"
        let docId = try db.insert(doc)
        let tagId = try db.findOrCreateTag(name: "wichtig")
        try db.addTagToDocument(documentId: docId, tagId: tagId)

        // Fake-Server: find-or-create vergibt IDs, post_document liefert 42,
        // Checksum-Suche kennt die „hochgeladenen“ sha256
        var createdIds: [String: Int] = [:]
        var nextId = 100
        var uploadedChecksums: Set<String> = []
        let transport = FakeTransport { req in
            let path = req.path
            if req.method == "PATCH" && path == "/api/documents/42/" { return (200, json(["id": 42])) }
            if req.method == "GET" && path == "/api/documents/" {
                let q = req.query ?? ""
                if let range = q.range(of: "checksum=") {
                    let sha = String(q[range.upperBound...])
                    if uploadedChecksums.contains(sha) {
                        return (200, json(["count": 1, "results": [["id": 42, "checksum": sha]]]))
                    }
                }
                return (200, emptyList())
            }
            if req.method == "GET" { return (200, emptyList()) }   // name__iexact: nichts vorhanden
            if req.method == "POST" && path == "/api/documents/post_document/" {
                // sha aus dem multipart-Body ist aufwendig — wir markieren über den Titel nicht nötig;
                // stattdessen: alle post_document-Antworten merken (für Skipped-Test reicht checksumExists)
                return (200, json(["id": 42]))
            }
            if req.method == "POST" {   // create-Ressource
                nextId += 1
                createdIds[path] = nextId
                return (201, json(["id": nextId, "name": "neu"]))
            }
            return (404, Data())
        }
        let client = PaperlessClient(config: config(), transport: transport)
        let service = SyncService(db: db, vault: vault, client: client)

        // 1. Durchlauf: 1 Dokument pending → Upload
        try MiniTest.expectEqual(try service.pendingDocuments().count, 1)
        var progressCalls: [(Int, Int)] = []
        let outcome1 = try await service.syncAll { done, total in progressCalls.append((done, total)) }
        try MiniTest.expectEqual(outcome1.uploaded, 1)
        try MiniTest.expectEqual(outcome1.skipped, 0)
        try MiniTest.expectEqual(outcome1.failed.count, 0)
        try MiniTest.expect(progressCalls.count == 1 && progressCalls[0] == (1, 1), "Fortschritt 1/1 erwartet: \(progressCalls)")
        let entry = try MiniTest.unwrap(try db.syncEntry(for: docId))
        try MiniTest.expectEqual(entry.paperlessId, 42)
        try MiniTest.expectEqual(entry.sha256, sha)
        // persistierter Sync-Stand nach erfolgreichem Push
        try MiniTest.expectEqual(try db.document(byId: docId)?.syncState, .synced)
        // Metadaten-Hash wurde mitgespeichert
        try MiniTest.expectEqual(entry.metaSha256,
                                SyncService.metaHash(doc: try db.document(byId: docId)!, tagIds: [tagId]))
        // Mapping wurde aufgelöst: correspondent + document_type + tag per find-or-create angelegt
        let post = try MiniTest.unwrap(transport.requests.first { $0.path == "/api/documents/post_document/" })
        let body = String(decoding: post.body ?? Data(), as: UTF8.self)
        try MiniTest.expect(body.contains("name=\"correspondent\""), "Korrespondent-ID im Upload")
        try MiniTest.expect(body.contains("name=\"document_type\""), "Kategorie als Document Type im Upload")
        try MiniTest.expect(body.contains("name=\"tags\""), "Tag im Upload")
        try MiniTest.expect(body.contains("filename=\"test.pdf\""), "Vault-Dateiname bleibt erhalten")
        // find-or-create wurde für all drei Endpunkte aufgerufen
        try MiniTest.expect(transport.requests.contains { $0.path == "/api/correspondents/" && $0.method == "POST" })
        try MiniTest.expect(transport.requests.contains { $0.path == "/api/document_types/" && $0.method == "POST" })
        try MiniTest.expect(transport.requests.contains { $0.path == "/api/tags/" && $0.method == "POST" })

        // 2. Durchlauf: nichts pending (sha gleich) → 0/0/0
        let outcome2 = try await service.syncAll()
        try MiniTest.expect(outcome2.uploaded == 0 && outcome2.skipped == 0 && outcome2.failed.isEmpty,
                            "zweiter Lauf leer erwartet: \(outcome2)")

        // 3. Einzel-Sync mit vorhandenem Eintrag + Server-Treffer → skipped
        uploadedChecksums.insert(sha)
        let step = try await service.sync(documentId: docId)
        try MiniTest.expectEqual(step, .skipped(paperlessId: 42))

        // 4. sha-Wechsel (Datei ersetzt) → Eintrag passt nicht mehr → re-upload
        try db.setSyncEntry(documentId: docId, paperlessId: 42, sha256: "alt", metaSha256: "alt-meta")
        try MiniTest.expectEqual(try service.pendingDocuments().count, 1)
        let outcome4 = try await service.syncAll()
        try MiniTest.expectEqual(outcome4.uploaded, 1)
        try MiniTest.expectEqual(try db.syncEntry(for: docId)?.sha256, sha)
        try MiniTest.expect(try db.syncEntry(for: docId)?.metaSha256 != "alt-meta", "meta_sha256 wird beim Re-Upload neu gesetzt")

        // 4b. Metadaten-Änderung nach dem Sync (Kategorie neu gesetzt) → PATCH, kein Re-Upload
        let cat2 = try db.findOrCreateCategory(name: "Steuern")
        let docBefore = try db.document(byId: docId)!
        try db.updateMetadata(documentId: docId, title: docBefore.title, documentDate: docBefore.documentDate,
                              correspondentId: docBefore.correspondentId, categoryId: cat2, notes: docBefore.notes)
        try MiniTest.expectEqual(try db.document(byId: docId)?.syncState, .notSynced)   // Edit → not_synced
        try MiniTest.expectEqual(try service.pendingDocuments().count, 1)
        let outcome4b = try await service.syncAll()
        try MiniTest.expectEqual(outcome4b.updated, 1)
        try MiniTest.expectEqual(outcome4b.uploaded, 0)
        try MiniTest.expectEqual(outcome4b.skipped, 0)
        let patch = try MiniTest.unwrap(transport.requests.first { $0.method == "PATCH" })
        try MiniTest.expectEqual(patch.path, "/api/documents/42/")
        let patchBody = String(decoding: patch.body ?? Data(), as: UTF8.self)
        try MiniTest.expect(patchBody.contains("\"document_type\":"), "Kategorie als document_type im PATCH: \(patchBody)")
        try MiniTest.expect(!patchBody.contains("name=\"document\""), "kein Datei-Feld beim PATCH")
        let entryAfter = try MiniTest.unwrap(try db.syncEntry(for: docId))
        try MiniTest.expect(entryAfter.sha256 == sha, "Datei-sha bleibt beim PATCH gleich")
        try MiniTest.expectEqual(entryAfter.metaSha256,
                                SyncService.metaHash(doc: try db.document(byId: docId)!, tagIds: [tagId]))
        try MiniTest.expectEqual(try db.document(byId: docId)?.syncState, .synced)   // PATCH erfolgreich → synced
        // danach ist nichts mehr pending
        let outcome4c = try await service.syncAll()
        try MiniTest.expect(outcome4c.uploaded == 0 && outcome4c.updated == 0 && outcome4c.skipped == 0 && outcome4c.failed.isEmpty,
                            "nach PATCH nichts mehr pending: \(outcome4c)")

        // 4d. Forced Sync: Metadaten-Push (PATCH) auch ohne Hash-Änderung — z. B. um falsch gemappte
        // Kategorien (find-or-create-Bug) auf einen Schlag zu korrigieren
        let outcome4d = try await service.syncAll(forceMetadata: true)
        try MiniTest.expectEqual(outcome4d.updated, 1)
        try MiniTest.expectEqual(outcome4d.uploaded, 0)
        try MiniTest.expect(transport.requests.filter { $0.method == "PATCH" }.count >= 2, "Force-Sync muss erneut PATCHen")
        let stepF = try await service.sync(documentId: docId, forceMetadata: true)
        try MiniTest.expectEqual(stepF, .updated(paperlessId: 42))

        // 5. Server-Fehler beim Upload → failed, kein sync_map-Eintrag
        let id5 = try db.insert(sampleDoc(sha: "fehler-sha"))
        let failing = FakeTransport { req in
            if req.path == "/api/documents/post_document/" { return (500, Data("boom".utf8)) }
            if req.method == "GET" { return (200, emptyList()) }
            return (201, json(["id": 1]))
        }
        let failingService = SyncService(db: db, vault: vault, client: PaperlessClient(config: config(), transport: failing))
        let outcome5 = try await failingService.syncAll()
        try MiniTest.expectEqual(outcome5.uploaded, 0)
        try MiniTest.expectEqual(outcome5.failed.count, 1)
        try MiniTest.expectEqual(outcome5.failed[0].filename, "test.pdf")
        try MiniTest.expect(outcome5.failed[0].message.contains("500"), "HTTP-Status in der Meldung: \(outcome5.failed[0].message)")
        try MiniTest.expectEqual(try db.syncEntry(for: id5), nil)
        try MiniTest.expect(try db.document(byId: id5)?.syncState == .notSynced, "fehlgeschlagener Push → not_synced persistiert")
        }
    }
}
