import Foundation

/// Persistierter Sync-Stand eines Dokuments gegenüber paperless-ngx (Spalte `sync_state`, Migration V4).
public enum SyncState: String, Sendable, Equatable {
    /// letzter Push erfolgreich (sync_map-Eintrag mit aktuellem sha256)
    case synced = "synced"
    /// bekannt nicht gepusht: nie hochgeladen, Push fehlgeschlagen oder Datei seit dem letzten Sync geändert
    case notSynced = "not_synced"
    /// Sync nicht konfiguriert / nie gelaufen — Remote-Stand unbekannt
    case unknown = "unknown"
}

public struct Document: Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var uuid: String
    public var sha256: String
    public var filename: String
    public var relativePath: String          // relativ zum Vault, z. B. documents/2026/11/x.pdf
    public var title: String?
    public var correspondentId: Int64?
    public var categoryId: Int64?
    public var documentDate: String?          // ISO yyyy-MM-dd
    public var addedAt: String                // ISO yyyy-MM-dd'T'HH:mm:ss UTC
    public var pageCount: Int
    public var ocrText: String?
    public var ocrDone: Bool
    public var needsReview: Bool
    public var notes: String?
    public var deletedAt: String?             // Soft Delete (Papierkorb)
    public var syncState: SyncState           // persistiert in documents.sync_state (Migration V4)

    public init(id: Int64? = nil, uuid: String, sha256: String, filename: String, relativePath: String,
                title: String? = nil, correspondentId: Int64? = nil, categoryId: Int64? = nil,
                documentDate: String? = nil, addedAt: String? = nil, pageCount: Int = 0,
                ocrText: String? = nil, ocrDone: Bool = false, needsReview: Bool = false,
                notes: String? = nil, deletedAt: String? = nil, syncState: SyncState = .unknown) {
        self.id = id
        self.uuid = uuid
        self.sha256 = sha256
        self.filename = filename
        self.relativePath = relativePath
        self.title = title
        self.correspondentId = correspondentId
        self.categoryId = categoryId
        self.documentDate = documentDate
        self.addedAt = addedAt ?? Timestamp.now()
        self.pageCount = pageCount
        self.ocrText = ocrText
        self.ocrDone = ocrDone
        self.needsReview = needsReview
        self.notes = notes
        self.deletedAt = deletedAt
        self.syncState = syncState
    }
}

enum Timestamp {
    static func now() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.string(from: Date())
    }
}
