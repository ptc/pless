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
    public var skipped: Int = 0
    public var failed: [SyncFailure] = []

    public init(uploaded: Int = 0, skipped: Int = 0, failed: [SyncFailure] = []) {
        self.uploaded = uploaded
        self.skipped = skipped
        self.failed = failed
    }
}

/// Ergebnis für ein einzelnes Dokument.
public enum SyncStep: Equatable, Sendable {
    case uploaded(paperlessId: Int)
    case skipped(paperlessId: Int)   // bereits gesynct und auf dem Server vorhanden
}

/// Einweg-Push (Upload) in eine paperless-ngx-Instanz. Idempotent über `sync_map` + Checksum.
public final class SyncService {
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

    /// Dokumente, die noch nie oder seit dem letzten Sync verändert wurden.
    public func pendingDocuments() throws -> [Document] {
        try db.documentsPendingSync()
    }

    /// Synchronisiert ein einzelnes Dokument. Wirft bei Netzwerk-/Serverfehlern.
    public func sync(documentId: Int64) async throws -> SyncStep {
        guard let doc = try db.document(byId: documentId) else {
            throw PlessError.notFound("Dokument #\(documentId)")
        }
        // Bereits gesynct und Datei unverändert? Dann nur prüfen, ob es auf dem Server noch existiert.
        if let entry = try db.syncEntry(for: doc.id ?? 0), entry.sha256 == doc.sha256 {
            if let remoteId = try await client.checksumExists(doc.sha256) {
                return .skipped(paperlessId: remoteId)
            }
            // auf dem Server nicht mehr vorhanden (gelöscht) → neu hochladen
        }
        let paperlessId = try await upload(doc)
        try db.setSyncEntry(documentId: doc.id ?? 0, paperlessId: Int64(paperlessId), sha256: doc.sha256)
        return .uploaded(paperlessId: paperlessId)
    }

    /// Synchronisiert alle ausstehenden Dokumente. `progress(done, total)` nach jedem Dokument.
    public func syncAll(progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> SyncOutcome {
        let pending = try pendingDocuments()
        var outcome = SyncOutcome()
        for (i, doc) in pending.enumerated() {
            do {
                guard let id = doc.id else { continue }
                switch try await sync(documentId: id) {
                case .uploaded: outcome.uploaded += 1
                case .skipped: outcome.skipped += 1
                }
            } catch {
                outcome.failed.append(SyncFailure(filename: doc.filename, message: error.localizedDescription))
            }
            progress?(i + 1, pending.count)
        }
        return outcome
    }

    // MARK: - Upload eines Dokuments

    private func upload(_ doc: Document) async throws -> Int {
        guard let id = doc.id else { throw PlessError.invalidDocument("Dokument ohne ID") }
        let fileURL = vault.root.appendingPathComponent(doc.relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw PlessError.io("Datei fehlt im Vault: \(doc.relativePath)")
        }
        let fileData = try Data(contentsOf: fileURL)

        // Mapping: Korrespondent / Kategorie (→ Document Type) / Tags per Name → paperless-ID
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
