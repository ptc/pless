import Foundation

// MARK: - Sync-Service: Push neuer/geänderter Dokumente nach paperless-ngx (Phase 13)

/// Ein fehlgeschlagener Push (Datei + Fehlermeldung).
public struct SyncFailure: Equatable, Sendable {
    public var filename: String
    public var message: String
    public init(filename: String, message: String) {
        self.filename = filename
        self.message = message
    }
}

/// Ergebnis eines Sync-Durchlaufs.
public struct SyncOutcome: Equatable, Sendable {
    public var uploaded: Int = 0
    public var updated: Int = 0       // Metadaten per PATCH aktualisiert (Datei unverändert)
    public var skipped: Int = 0
    public var failed: [SyncFailure] = []

    public init(uploaded: Int = 0, updated: Int = 0, skipped: Int = 0, failed: [SyncFailure] = []) {
        self.uploaded = uploaded
        self.updated = updated
        self.skipped = skipped
        self.failed = failed
    }
}

/// Ergebnis für ein einzelnes Dokument.
public enum SyncStep: Equatable, Sendable {
    case uploaded(paperlessId: Int)
    case updated(paperlessId: Int)    // Metadaten per PATCH nachgezogen (Datei war schon da)
    case skipped(paperlessId: Int)    // bereits gesynct und auf dem Server vorhanden
}

/// Einweg-Push (Upload) in eine paperless-ngx-Instanz. Idempotent über `sync_map` + Checksum.
/// Läuft immer single-threaded pro Instanz (AppState guardt mit syncRunning und baut den
/// Service pro Lauf frisch) — db/vault/client sind Sendable (Database via FULLMUTEX).
public final class SyncService: @unchecked Sendable {
    private let db: Database
    private let vault: Vault
    private let client: PaperlessClient
    /// Name→ID-Cache pro Durchlauf (spart find-or-create-Aufrufe bei vielen Dokumenten)
    private var nameCache: [String: Int] = [:]

    public init(db: Database, vault: Vault, client: PaperlessClient) {
        self.db = db
        self.vault = vault
        self.client = client
    }

    /// SHA-256 über die kanonischen Metadaten eines Dokuments (Titel, Datum, Korrespondent,
    /// Kategorie, Notizen, Tag-IDs) — ändert sich bei jeder Metadaten-Änderung, nicht bei Datei-Änderung.
    public static func metaHash(doc: Document, tagIds: [Int64]) -> String {
        let parts: [String] = [
            doc.title ?? "",
            doc.documentDate ?? "",
            doc.correspondentId.map { String($0) } ?? "",
            doc.categoryId.map { String($0) } ?? "",
            doc.notes ?? "",
            tagIds.sorted().map { String($0) }.joined(separator: ",")
        ]
        let canonical = parts.joined(separator: "\u{1F}")
        return FileHash.sha256(of: Data(canonical.utf8))
    }

    /// Hash der aktuellen Metadaten eines Dokuments (Tag-IDs aus der DB).
    public func metaHash(of doc: Document) throws -> String {
        guard let id = doc.id else { return Self.metaHash(doc: doc, tagIds: []) }
        return Self.metaHash(doc: doc, tagIds: (try db.tags(for: id)).compactMap { $0.id })
    }

    /// Dokumente, die ein Push-Anlauf anfassen muss: noch nie gesynct, Datei geändert (sha256)
    /// ODER Metadaten geändert (meta_sha256 weicht ab / fehlt — z. B. Kategorie nachträglich gesetzt).
    /// `forceMetadata` erzwingt den Metadaten-Push für alle bereits gesyncten Dokumente (unabhängig vom Hash).
    public func pendingDocuments(forceMetadata: Bool = false) throws -> [Document] {
        var out: [Document] = []
        for doc in try db.allDocuments() {
            guard let id = doc.id else { continue }
            let entry = try db.syncEntry(for: id)
            let meta = try metaHash(of: doc)
            if entry == nil || entry!.sha256 != doc.sha256 || forceMetadata || entry!.metaSha256 != meta {
                out.append(doc)
            }
        }
        return out
    }

    /// Synchronisiert ein einzelnes Dokument. Wirft bei Netzwerk-/Serverfehlern.
    /// `forceMetadata` pusht die Metadaten per PATCH, auch wenn sich am Hash nichts geändert hat.
    public func sync(documentId: Int64, forceMetadata: Bool = false) async throws -> SyncStep {
        guard let doc = try db.document(byId: documentId), let id = doc.id else {
            throw PlessError.notFound("Dokument #\(documentId)")
        }
        let meta = try metaHash(of: doc)
        // Bereits gesynct und Datei unverändert?
        if let entry = try db.syncEntry(for: id), entry.sha256 == doc.sha256 {
            if entry.metaSha256 == meta && !forceMetadata {
                // Datei + Metadaten unverändert → nur prüfen, ob es auf dem Server noch existiert
                if let remoteId = try await client.checksumExists(doc.sha256) {
                    return .skipped(paperlessId: remoteId)
                }
                // auf dem Server nicht mehr vorhanden (gelöscht) → neu hochladen
            } else {
                // Metadaten geändert (z. B. Kategorie/Korrespondent/Tags nachträglich gesetzt)
                // → bestehendes paperless-Dokument per PATCH aktualisieren
                let (correspondentId, documentTypeId, tagIds) = try await resolveMapping(doc)
                let pid = Int(entry.paperlessId)
                let title = doc.title?.isEmpty == false ? doc.title! : (doc.filename as NSString).deletingPathExtension
                try await client.updateDocument(paperlessId: pid, title: title,
                                                created: doc.documentDate, correspondentId: correspondentId,
                                                documentTypeId: documentTypeId, tagIds: tagIds)
                try db.setSyncEntry(documentId: id, paperlessId: entry.paperlessId,
                                    sha256: doc.sha256, metaSha256: meta)
                return .updated(paperlessId: pid)
            }
        }
        let paperlessId = try await upload(doc)
        try db.setSyncEntry(documentId: id, paperlessId: Int64(paperlessId), sha256: doc.sha256, metaSha256: meta)
        return .uploaded(paperlessId: paperlessId)
    }

    /// Synchronisiert alle ausstehenden Dokumente. `progress(done, total)` nach jedem Dokument.
    /// `forceMetadata` erzwingt den Metadaten-Push (PATCH) auch für Dokumente mit unverändertem Hash.
    public func syncAll(forceMetadata: Bool = false, progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> SyncOutcome {
        let pending = try pendingDocuments(forceMetadata: forceMetadata)
        var outcome = SyncOutcome()
        for (i, doc) in pending.enumerated() {
            do {
                guard let id = doc.id else { continue }
                switch try await sync(documentId: id, forceMetadata: forceMetadata) {
                case .uploaded: outcome.uploaded += 1
                case .updated: outcome.updated += 1
                case .skipped: outcome.skipped += 1
                }
            } catch {
                outcome.failed.append(SyncFailure(filename: doc.filename, message: error.localizedDescription))
                if let docId = doc.id { try? db.setSyncState(.notSynced, for: docId) }   // persistiert: Push fehlgeschlagen
            }
            progress?(i + 1, pending.count)
        }
        return outcome
    }

    // MARK: - Pull: Stammdaten aus paperless-ngx importieren

    /// Importiert Document Types als Kategorien und Correspondents als Korrespondenten in den Vault.
    /// Bereits vorhandene Namen (case-insensitiv) werden nicht doppelt angelegt.
    /// Liefert die Anzahl der neu angelegten (Kategorien, Korrespondenten).
    public func pullMetadata() async throws -> (categories: Int, correspondents: Int) {
        var newCategories = 0
        var knownCat = Set((try db.categories()).map { $0.name.lowercased() })
        for resource in try await client.listDocumentTypes() {
            let name = resource.name
            if !knownCat.contains(name.lowercased()) {
                _ = try db.findOrCreateCategory(name: name)
                knownCat.insert(name.lowercased())
                newCategories += 1
            }
        }
        var newCorrespondents = 0
        var knownCorr = Set((try db.correspondents()).map { $0.name.lowercased() })
        for resource in try await client.listCorrespondents() {
            let name = resource.name
            if !knownCorr.contains(name.lowercased()) {
                _ = try db.findOrCreateCorrespondent(name: name)
                knownCorr.insert(name.lowercased())
                newCorrespondents += 1
            }
        }
        return (newCategories, newCorrespondents)
    }

    // MARK: - Mapping & Upload

    /// Mapping: Korrespondent / Kategorie (→ Document Type) / Tags per Name → paperless-ID (find-or-create).
    private func resolveMapping(_ doc: Document) async throws -> (correspondentId: Int?, documentTypeId: Int?, tagIds: [Int]) {
        guard let id = doc.id else { throw PlessError.invalidDocument("Dokument ohne ID") }
        var correspondentId: Int?
        if let cid = doc.correspondentId, let corr = try db.correspondent(id: cid) {
            correspondentId = try await cached("corr:\(corr.name.lowercased())") {
                try await client.findOrCreateCorrespondent(name: corr.name)
            }
        }
        var documentTypeId: Int?
        if let catId = doc.categoryId, let cat = try db.category(id: catId) {
            documentTypeId = try await cached("type:\(cat.name.lowercased())") {
                try await client.findOrCreateDocumentType(name: cat.name)
            }
        }
        var tagIds: [Int] = []
        for tag in try db.tags(for: id) {
            let tid = try await cached("tag:\(tag.name.lowercased())") {
                try await client.findOrCreateTag(name: tag.name)
            }
            tagIds.append(tid)
        }
        return (correspondentId, documentTypeId, tagIds)
    }

    /// Upload eines Dokuments (Datei + Metadaten per post_document).
    private func upload(_ doc: Document) async throws -> Int {
        guard doc.id != nil else { throw PlessError.invalidDocument("Dokument ohne ID") }
        let fileURL = vault.root.appendingPathComponent(doc.relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw PlessError.io("Datei fehlt im Vault: \(doc.relativePath)")
        }
        let fileData = try Data(contentsOf: fileURL)

        let (correspondentId, documentTypeId, tagIds) = try await resolveMapping(doc)

        let title = doc.title?.isEmpty == false ? doc.title! : (doc.filename as NSString).deletingPathExtension
        let created = doc.documentDate ?? String(doc.addedAt.prefix(10))

        let postedId = try await client.postDocument(
            fileData: fileData, filename: doc.filename, title: title, created: created,
            correspondentId: correspondentId, documentTypeId: documentTypeId, tagIds: tagIds)
        if let postedId { return postedId }
        // Antwort ohne ID → über Checksum auflösen (der sha256 des Vault-Files ist bekannt)
        if let remoteId = try await client.checksumExists(doc.sha256) { return remoteId }
        throw PlessError.sync("Upload von „\(doc.filename)“ quittiert, aber keine Dokument-ID ermittelbar")
    }

    private func cached(_ key: String, _ create: () async throws -> Int) async throws -> Int {
        if let hit = nameCache[key] { return hit }
        let id = try await create()
        nameCache[key] = id
        return id
    }
}
