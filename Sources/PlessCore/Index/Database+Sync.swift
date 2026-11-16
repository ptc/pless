import Foundation
import SQLite3

// MARK: - Sync-Mapping nach paperless-ngx (Phase 13, Migration V3)

/// Eintrag in `sync_map`: welches pless-Dokument wurde wann mit welchem sha256 wohin gepusht.
public struct SyncEntry: Equatable, Sendable {
    public var documentId: Int64
    public var paperlessId: Int64
    public var sha256: String
    public var syncedAt: String

    public init(documentId: Int64, paperlessId: Int64, sha256: String, syncedAt: String) {
        self.documentId = documentId
        self.paperlessId = paperlessId
        self.sha256 = sha256
        self.syncedAt = syncedAt
    }
}

extension Database {

    /// Sync-Eintrag eines Dokuments (nil = noch nie synchronisiert).
    public func syncEntry(for documentId: Int64) throws -> SyncEntry? {
        let stmt = try prepare("SELECT document_id, paperless_id, sha256, synced_at FROM sync_map WHERE document_id = ?")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, documentId)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return SyncEntry(documentId: colInt(stmt, 0), paperlessId: colInt(stmt, 1),
                         sha256: colText(stmt, 2) ?? "", syncedAt: colText(stmt, 3) ?? "")
    }

    public func allSyncEntries() throws -> [SyncEntry] {
        let stmt = try prepare("SELECT document_id, paperless_id, sha256, synced_at FROM sync_map ORDER BY document_id")
        defer { sqlite3_finalize(stmt) }
        var out: [SyncEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(SyncEntry(documentId: colInt(stmt, 0), paperlessId: colInt(stmt, 1),
                                 sha256: colText(stmt, 2) ?? "", syncedAt: colText(stmt, 3) ?? ""))
        }
        return out
    }

    /// Upsert des Sync-Eintrags nach erfolgreichem Push — setzt zugleich `documents.sync_state = 'synced'`.
    public func setSyncEntry(documentId: Int64, paperlessId: Int64, sha256: String) throws {
        let stmt = try prepare("""
        INSERT INTO sync_map(document_id, paperless_id, sha256, synced_at)
        VALUES(?, ?, ?, strftime('%Y-%m-%dT%H:%M:%S','now'))
        ON CONFLICT(document_id) DO UPDATE SET paperless_id = excluded.paperless_id,
          sha256 = excluded.sha256, synced_at = excluded.synced_at
        """)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, documentId)
        bind(stmt, 2, paperlessId)
        bind(stmt, 3, sha256)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw PlessError.database("setSyncEntry: \(errMsg())")
        }
        try setSyncState(.synced, for: documentId)
    }

    /// Persistierten Sync-Stand eines Dokuments setzen (Spalte `sync_state`, Migration V4).
    public func setSyncState(_ state: SyncState, for documentId: Int64) throws {
        let stmt = try prepare("UPDATE documents SET sync_state = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, state.rawValue)
        bind(stmt, 2, documentId)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw PlessError.database("setSyncState: \(errMsg())")
        }
    }

    /// Reconcile: Sobald Sync konfiguriert ist, sind „unknown“-Dokumente bekannt nicht gepusht.
    public func markUnknownAsNotSynced() throws {
        try execute("UPDATE documents SET sync_state = 'not_synced' WHERE sync_state = 'unknown' AND deleted_at IS NULL")
    }

    public func deleteSyncEntry(for documentId: Int64) throws {
        let stmt = try prepare("DELETE FROM sync_map WHERE document_id = ?")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, documentId)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw PlessError.database("deleteSyncEntry: \(errMsg())")
        }
    }

    /// Dokumente, die noch nie gesynct wurden ODER deren sha256 sich seit dem letzten Sync
    /// geändert hat (Datei ersetzt) — also alles, was ein Push-Anlauf anfassen muss.
    public func documentsPendingSync() throws -> [Document] {
        try fetchDocuments("""
        SELECT \(Self.documentColumns) FROM documents d
        WHERE d.deleted_at IS NULL
          AND NOT EXISTS (
            SELECT 1 FROM sync_map s
            WHERE s.document_id = d.id AND s.sha256 = d.sha256
          )
        ORDER BY d.added_at, d.id
        """)
    }
}
