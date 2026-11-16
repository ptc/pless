import Foundation
import SQLite3

// SQLITE_TRANSIENT ist ein C-Makro ((sqlite3_destructor_type)-1); das CLT-Modul
// exportiert weder Makro noch Typ-Alias — hier als -1 auf den Destruktor-Typ gebildcast.
private typealias SQLiteDestructor = @convention(c) (UnsafeMutableRawPointer?) -> Void
private let kSQLiteTransient: SQLiteDestructor? = unsafeBitCast(-1, to: SQLiteDestructor?.self)

/// SQLite-Zugriff auf `pless.db` im Vault. Schema-Migrationen über `PRAGMA user_version`.
public final class Database {
    private var handle: OpaquePointer?

    public init(url: URL) throws {
        var h: OpaquePointer?
        let rc = sqlite3_open_v2(url.path(percentEncoded: false), &h,
                                 SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "unbekannt"
            if let h { sqlite3_close(h) }
            throw PlessError.database("DB öffnen fehlgeschlagen (rc=\(rc)): \(msg)")
        }
        handle = h
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA foreign_keys=ON;")
        try migrate()
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    // MARK: - Low-Level

    @discardableResult
    public func execute(_ sql: String) throws -> Int32 {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? errMsg()
            sqlite3_free(err)
            throw PlessError.database("SQL fehlgeschlagen: \(msg) [\(sql.prefix(60))]")
        }
        return rc
    }

    public func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw PlessError.database("prepare fehlgeschlagen: \(errMsg()) [\(sql.prefix(60))]")
        }
        return stmt
    }

    public func scalarInt(_ sql: String) throws -> Int64 {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(stmt, 0)
    }

    func errMsg() -> String {
        String(cString: sqlite3_errmsg(handle))
    }

    // MARK: - Migrationen

    func migrate() throws {
        let version = try scalarInt("PRAGMA user_version;")
        if version < 1 { try applyV1() }
        if version < 2 { try applyV2() }
        if version < 3 { try applyV3() }
        if version < 4 { try applyV4() }
    }

    /// V4: persistierter Sync-Stand pro Dokument (`sync_state`: synced / not_synced / unknown).
    /// Backfill: Dokumente mit passendem sync_map-Eintrag sind 'synced', alle anderen 'unknown'.
    func applyV4() throws {
        try execute("""
        BEGIN;
        ALTER TABLE documents ADD COLUMN sync_state TEXT NOT NULL DEFAULT 'unknown';
        UPDATE documents SET sync_state = 'synced'
        WHERE EXISTS (SELECT 1 FROM sync_map s WHERE s.document_id = documents.id AND s.sha256 = documents.sha256);
        PRAGMA user_version = 4;
        COMMIT;
        """)
    }

    /// V3: Sync-Mapping nach paperless-ngx (Phase 13) — pro Dokument die paperless-ID + Stand.
    func applyV3() throws {
        try execute("""
        BEGIN;
        CREATE TABLE IF NOT EXISTS sync_map(
          document_id INTEGER PRIMARY KEY REFERENCES documents(id) ON DELETE CASCADE,
          paperless_id INTEGER NOT NULL,
          sha256 TEXT NOT NULL,
          synced_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%S','now'))
        );
        PRAGMA user_version = 3;
        COMMIT;
        """)
    }

    /// V2: FTS5-Volltextindex über Titel + OCR-Text + Korrespondent, per Trigger synchron gehalten.
    func applyV2() throws {
        try execute("""
        BEGIN;
        CREATE VIRTUAL TABLE IF NOT EXISTS documents_fts USING fts5(
          title, ocr_text, correspondent, tokenize='unicode61'
        );
        INSERT INTO documents_fts(rowid, title, ocr_text, correspondent)
          SELECT id, title, ocr_text,
                 COALESCE((SELECT c.name FROM correspondents c WHERE c.id = documents.correspondent_id), '')
          FROM documents;
        CREATE TRIGGER IF NOT EXISTS documents_ai AFTER INSERT ON documents BEGIN
          INSERT INTO documents_fts(rowid, title, ocr_text, correspondent)
          VALUES (new.id, new.title, new.ocr_text,
                  COALESCE((SELECT c.name FROM correspondents c WHERE c.id = new.correspondent_id), ''));
        END;
        CREATE TRIGGER IF NOT EXISTS documents_ad AFTER DELETE ON documents BEGIN
          DELETE FROM documents_fts WHERE rowid = old.id;
        END;
        CREATE TRIGGER IF NOT EXISTS documents_au AFTER UPDATE ON documents BEGIN
          DELETE FROM documents_fts WHERE rowid = old.id;
          INSERT INTO documents_fts(rowid, title, ocr_text, correspondent)
          VALUES (new.id, new.title, new.ocr_text,
                  COALESCE((SELECT c.name FROM correspondents c WHERE c.id = new.correspondent_id), ''));
        END;
        PRAGMA user_version = 2;
        COMMIT;
        """)
    }

    func applyV1() throws {
        try execute("""
        BEGIN;
        CREATE TABLE IF NOT EXISTS correspondents(
          id INTEGER PRIMARY KEY,
          name TEXT UNIQUE NOT NULL
        );
        CREATE TABLE IF NOT EXISTS categories(
          id INTEGER PRIMARY KEY,
          name TEXT NOT NULL,
          parent_id INTEGER REFERENCES categories(id) ON DELETE SET NULL,
          color TEXT
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_categories_name_parent
          ON categories(name, COALESCE(parent_id, 0));
        CREATE TABLE IF NOT EXISTS tags(
          id INTEGER PRIMARY KEY,
          name TEXT UNIQUE NOT NULL,
          color TEXT
        );
        CREATE TABLE IF NOT EXISTS documents(
          id INTEGER PRIMARY KEY,
          uuid TEXT UNIQUE NOT NULL,
          sha256 TEXT UNIQUE NOT NULL,
          filename TEXT NOT NULL,
          relative_path TEXT NOT NULL,
          title TEXT,
          correspondent_id INTEGER REFERENCES correspondents(id) ON DELETE SET NULL,
          category_id INTEGER REFERENCES categories(id) ON DELETE SET NULL,
          document_date TEXT,
          added_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%S','now')),
          page_count INTEGER NOT NULL DEFAULT 0,
          ocr_text TEXT,
          ocr_done INTEGER NOT NULL DEFAULT 0,
          needs_review INTEGER NOT NULL DEFAULT 0,
          notes TEXT,
          deleted_at TEXT
        );
        CREATE TABLE IF NOT EXISTS document_tags(
          document_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
          tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
          PRIMARY KEY (document_id, tag_id)
        );
        CREATE INDEX IF NOT EXISTS idx_documents_sha256 ON documents(sha256);
        CREATE INDEX IF NOT EXISTS idx_documents_uuid ON documents(uuid);
        PRAGMA user_version = 1;
        COMMIT;
        """)
    }

    // MARK: - Binden / Spalten

    func bind(_ stmt: OpaquePointer, _ i: Int32, _ v: String?) {
        if let v { sqlite3_bind_text(stmt, i, v, -1, kSQLiteTransient) } else { sqlite3_bind_null(stmt, i) }
    }
    func bind(_ stmt: OpaquePointer, _ i: Int32, _ v: Int64?) {
        if let v { sqlite3_bind_int64(stmt, i, v) } else { sqlite3_bind_null(stmt, i) }
    }
    func bind(_ stmt: OpaquePointer, _ i: Int32, _ v: Int) {
        sqlite3_bind_int64(stmt, i, Int64(v))
    }
    func bind(_ stmt: OpaquePointer, _ i: Int32, _ v: Bool) {
        sqlite3_bind_int(stmt, i, v ? 1 : 0)
    }

    func colText(_ s: OpaquePointer, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(s, i) else { return nil }
        return String(cString: c)
    }
    func colInt(_ s: OpaquePointer, _ i: Int32) -> Int64 {
        sqlite3_column_int64(s, i)
    }
    func colOptInt(_ s: OpaquePointer, _ i: Int32) -> Int64? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : sqlite3_column_int64(s, i)
    }

    // MARK: - Documents

    static let documentColumns = "id, uuid, sha256, filename, relative_path, title, correspondent_id, category_id, document_date, added_at, page_count, ocr_text, ocr_done, needs_review, notes, deleted_at, sync_state"

    func mapDocument(_ s: OpaquePointer) -> Document {
        Document(
            id: colInt(s, 0),
            uuid: colText(s, 1) ?? "",
            sha256: colText(s, 2) ?? "",
            filename: colText(s, 3) ?? "",
            relativePath: colText(s, 4) ?? "",
            title: colText(s, 5),
            correspondentId: colOptInt(s, 6),
            categoryId: colOptInt(s, 7),
            documentDate: colText(s, 8),
            addedAt: colText(s, 9) ?? "",
            pageCount: Int(colInt(s, 10)),
            ocrText: colText(s, 11),
            ocrDone: colInt(s, 12) != 0,
            needsReview: colInt(s, 13) != 0,
            notes: colText(s, 14),
            deletedAt: colText(s, 15),
            syncState: SyncState(rawValue: colText(s, 16) ?? "") ?? .unknown
        )
    }

    func fetchDocuments(_ sql: String, _ binds: [String] = []) throws -> [Document] {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        for (i, b) in binds.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), b, -1, kSQLiteTransient)
        }
        var result: [Document] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { result.append(mapDocument(stmt)) }
            else if rc == SQLITE_DONE { break }
            else { throw PlessError.database("fetch: \(errMsg())") }
        }
        return result
    }

    public func allDocuments() throws -> [Document] {
        try fetchDocuments("SELECT \(Self.documentColumns) FROM documents WHERE deleted_at IS NULL ORDER BY added_at DESC, id DESC")
    }

    /// Anzahl Dokumente pro Kategorie-ID (direkt; Unterkategorien nicht eingerechnet).
    public func categoryDocumentCounts() throws -> [Int64: Int] {
        let stmt = try prepare("SELECT category_id, COUNT(*) FROM documents WHERE deleted_at IS NULL AND category_id IS NOT NULL GROUP BY category_id")
        defer { sqlite3_finalize(stmt) }
        var out: [Int64: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            out[colInt(stmt, 0)] = Int(colInt(stmt, 1))
        }
        return out
    }

    /// Anzahl Dokumente pro Korrespondent-ID.
    public func correspondentDocumentCounts() throws -> [Int64: Int] {
        let stmt = try prepare("SELECT correspondent_id, COUNT(*) FROM documents WHERE deleted_at IS NULL AND correspondent_id IS NOT NULL GROUP BY correspondent_id")
        defer { sqlite3_finalize(stmt) }
        var out: [Int64: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            out[colInt(stmt, 0)] = Int(colInt(stmt, 1))
        }
        return out
    }

    public func document(byUUID uuid: String) throws -> Document? {
        try fetchDocuments("SELECT \(Self.documentColumns) FROM documents WHERE uuid = ? AND deleted_at IS NULL", [uuid]).first
    }

    public func document(bySHA256 sha256: String) throws -> Document? {
        try fetchDocuments("SELECT \(Self.documentColumns) FROM documents WHERE sha256 = ? AND deleted_at IS NULL", [sha256]).first
    }

    /// Alle Dokumente, die noch OCR brauchen (nicht gelöscht).
    public func documentsNeedingOCR() throws -> [Document] {
        try fetchDocuments("SELECT \(Self.documentColumns) FROM documents WHERE ocr_done = 0 AND deleted_at IS NULL ORDER BY added_at, id")
    }

    public func setOCRText(documentId: Int64, text: String, ocrDone: Bool) throws {
        let stmt = try prepare("UPDATE documents SET ocr_text = ?, ocr_done = ?, needs_review = 0 WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, text)
        bind(stmt, 2, ocrDone)
        bind(stmt, 3, documentId)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw PlessError.database("setOCRText: \(errMsg())")
        }
    }

    @discardableResult
    public func insert(_ d: Document) throws -> Int64 {
        let stmt = try prepare("""
        INSERT INTO documents(uuid, sha256, filename, relative_path, title, correspondent_id, category_id, document_date, added_at, page_count, ocr_text, ocr_done, needs_review, notes, deleted_at, sync_state)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, d.uuid)
        bind(stmt, 2, d.sha256)
        bind(stmt, 3, d.filename)
        bind(stmt, 4, d.relativePath)
        bind(stmt, 5, d.title)
        bind(stmt, 6, d.correspondentId)
        bind(stmt, 7, d.categoryId)
        bind(stmt, 8, d.documentDate)
        bind(stmt, 9, d.addedAt)
        bind(stmt, 10, d.pageCount)
        bind(stmt, 11, d.ocrText)
        bind(stmt, 12, d.ocrDone)
        bind(stmt, 13, d.needsReview)
        bind(stmt, 14, d.notes)
        bind(stmt, 15, d.deletedAt)
        bind(stmt, 16, d.syncState.rawValue)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_CONSTRAINT {
            let msg = errMsg()
            if msg.contains("sha256") { throw PlessError.duplicateSHA256(d.sha256) }
            throw PlessError.database("Constraint verletzt: \(msg)")
        }
        guard rc == SQLITE_DONE else { throw PlessError.database("insert: \(errMsg())") }
        return sqlite3_last_insert_rowid(handle)
    }

    // MARK: - Einfache Entitäten (Correspondent / Category / Tag)

    func stepInsert(_ stmt: OpaquePointer) throws -> Int64 {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else { throw PlessError.database("insert: \(errMsg())") }
        return sqlite3_last_insert_rowid(handle)
    }

    @discardableResult
    public func insertCorrespondent(name: String) throws -> Int64 {
        let stmt = try prepare("INSERT INTO correspondents(name) VALUES(?)")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, name)
        return try stepInsert(stmt)
    }

    public func correspondents() throws -> [Correspondent] {
        let stmt = try prepare("SELECT id, name FROM correspondents ORDER BY name")
        defer { sqlite3_finalize(stmt) }
        var out: [Correspondent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Correspondent(id: colInt(stmt, 0), name: colText(stmt, 1) ?? ""))
        }
        return out
    }

    @discardableResult
    public func insertCategory(name: String, parentId: Int64? = nil, color: String? = nil) throws -> Int64 {
        // ohne explizite Farbe: nächste Palettenfarbe (jede Kategorie eine andere Farbe)
        let effectiveColor: String
        if let color {
            effectiveColor = color
        } else {
            effectiveColor = ColorPalette.autoColor(existingCount: try scalarInt("SELECT COUNT(*) FROM categories"))
        }
        let stmt = try prepare("INSERT INTO categories(name, parent_id, color) VALUES(?,?,?)")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, name)
        bind(stmt, 2, parentId)
        bind(stmt, 3, effectiveColor)
        return try stepInsert(stmt)
    }

    public func categories() throws -> [Category] {
        let stmt = try prepare("SELECT id, name, parent_id, color FROM categories ORDER BY name")
        defer { sqlite3_finalize(stmt) }
        var out: [Category] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Category(id: colInt(stmt, 0), name: colText(stmt, 1) ?? "",
                                parentId: colOptInt(stmt, 2), color: colText(stmt, 3)))
        }
        return out
    }

    @discardableResult
    public func insertTag(name: String, color: String? = nil) throws -> Int64 {
        let stmt = try prepare("INSERT INTO tags(name, color) VALUES(?,?)")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, name)
        bind(stmt, 2, color)
        return try stepInsert(stmt)
    }

    /// Alle Tags eines Dokuments.
    public func tags(for documentId: Int64) throws -> [Tag] {
        let stmt = try prepare("SELECT t.id, t.name, t.color FROM tags t JOIN document_tags dt ON dt.tag_id = t.id WHERE dt.document_id = ? ORDER BY t.name")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, documentId)
        var out: [Tag] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Tag(id: colInt(stmt, 0), name: colText(stmt, 1) ?? "", color: colText(stmt, 2)))
        }
        return out
    }

    public func tags() throws -> [Tag] {
        let stmt = try prepare("SELECT id, name, color FROM tags ORDER BY name")
        defer { sqlite3_finalize(stmt) }
        var out: [Tag] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Tag(id: colInt(stmt, 0), name: colText(stmt, 1) ?? "", color: colText(stmt, 2)))
        }
        return out
    }
}
