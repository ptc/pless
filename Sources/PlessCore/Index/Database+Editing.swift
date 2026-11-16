import Foundation
import SQLite3

// MARK: - Editing: Metadaten-Updates, Datei-Umzug, Entity-Verwaltung (Phase 7)

extension Database {

    /// Führt ein UPDATE/DELETE mit Bind-Closure aus.
    private func exec(_ sql: String, _ bind: (OpaquePointer) -> Void) throws {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw PlessError.database("exec fehlgeschlagen: \(errMsg()) [\(sql.prefix(60))]")
        }
    }

    // MARK: - Dokumente

    public func document(byId id: Int64) throws -> Document? {
        let stmt = try prepare("SELECT \(Self.documentColumns) FROM documents WHERE id = ? AND deleted_at IS NULL")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return mapDocument(stmt)
    }

    /// Setzt alle editierbaren Metadaten-Felder (nil = NULL). FTS-Trigger hält den Index synchron.
    /// Metadaten-Änderung macht den Sync-Stand „not_synced" (Remote ist veraltet → nächster Sync per PATCH).
    public func updateMetadata(documentId: Int64, title: String?, documentDate: String?,
                               correspondentId: Int64?, categoryId: Int64?, notes: String?) throws {
        try exec("UPDATE documents SET title = ?, document_date = ?, correspondent_id = ?, category_id = ?, notes = ? WHERE id = ?") {
            bind($0, 1, title)
            bind($0, 2, documentDate)
            bind($0, 3, correspondentId)
            bind($0, 4, categoryId)
            bind($0, 5, notes)
            bind($0, 6, documentId)
        }
        try setSyncState(.notSynced, for: documentId)
    }

    /// Aktualisiert filename + relative_path nach einem Datei-Umzug im Vault.
    public func updateFileLocation(documentId: Int64, filename: String, relativePath: String) throws {
        try exec("UPDATE documents SET filename = ?, relative_path = ? WHERE id = ?") {
            bind($0, 1, filename)
            bind($0, 2, relativePath)
            bind($0, 3, documentId)
        }
    }

    // MARK: - Korrespondenten

    public func correspondent(named name: String) throws -> Correspondent? {
        let stmt = try prepare("SELECT id, name FROM correspondents WHERE name = ?")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, name)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Correspondent(id: colInt(stmt, 0), name: colText(stmt, 1) ?? "")
    }

    public func correspondent(id: Int64) throws -> Correspondent? {
        let stmt = try prepare("SELECT id, name FROM correspondents WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Correspondent(id: colInt(stmt, 0), name: colText(stmt, 1) ?? "")
    }

    @discardableResult
    public func findOrCreateCorrespondent(name: String) throws -> Int64 {
        if let existing = try correspondent(named: name), let id = existing.id { return id }
        return try insertCorrespondent(name: name)
    }

    public func renameCorrespondent(id: Int64, newName: String) throws {
        try exec("UPDATE correspondents SET name = ? WHERE id = ?") {
            bind($0, 1, newName)
            bind($0, 2, id)
        }
    }

    /// Löschen: Dokumente verlieren die Referenz (SET NULL), dann DELETE.
    public func deleteCorrespondent(id: Int64) throws {
        try exec("UPDATE documents SET correspondent_id = NULL WHERE correspondent_id = ?") { bind($0, 1, id) }
        try exec("DELETE FROM correspondents WHERE id = ?") { bind($0, 1, id) }
    }

    // MARK: - Kategorien

    public func category(named name: String) throws -> Category? {
        let stmt = try prepare("SELECT id, name, parent_id, color FROM categories WHERE name = ?")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, name)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Category(id: colInt(stmt, 0), name: colText(stmt, 1) ?? "",
                        parentId: colOptInt(stmt, 2), color: colText(stmt, 3))
    }

    public func category(id: Int64) throws -> Category? {
        let stmt = try prepare("SELECT id, name, parent_id, color FROM categories WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Category(id: colInt(stmt, 0), name: colText(stmt, 1) ?? "",
                        parentId: colOptInt(stmt, 2), color: colText(stmt, 3))
    }

    @discardableResult
    public func findOrCreateCategory(name: String, parentId: Int64? = nil) throws -> Int64 {
        if let existing = try category(named: name), let id = existing.id { return id }
        return try insertCategory(name: name, parentId: parentId)
    }

    /// Umbenennen / Farbe / Verschachteln. Wirft bei Zyklus (parentId = id oder Nachfahre von id).
    public func updateCategory(id: Int64, name: String, parentId: Int64?, color: String?) throws {
        if let p = parentId {
            var seen = Set<Int64>()
            var cur: Int64? = p
            while let c = cur, !seen.contains(c) {
                if c == id { throw PlessError.invalidDocument("Kategorie kann nicht ihr eigenes Elternteil sein") }
                seen.insert(c)
                cur = try category(id: c)?.parentId
            }
        }
        try exec("UPDATE categories SET name = ?, parent_id = ?, color = ? WHERE id = ?") {
            bind($0, 1, name)
            bind($0, 2, parentId)
            bind($0, 3, color)
            bind($0, 4, id)
        }
    }

    public func deleteCategory(id: Int64) throws {
        try exec("UPDATE documents SET category_id = NULL WHERE category_id = ?") { bind($0, 1, id) }
        try exec("UPDATE categories SET parent_id = NULL WHERE parent_id = ?") { bind($0, 1, id) }
        try exec("DELETE FROM categories WHERE id = ?") { bind($0, 1, id) }
    }

    // MARK: - Tags

    public func tag(named name: String) throws -> Tag? {
        let stmt = try prepare("SELECT id, name, color FROM tags WHERE name = ?")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, name)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Tag(id: colInt(stmt, 0), name: colText(stmt, 1) ?? "", color: colText(stmt, 2))
    }

    @discardableResult
    public func findOrCreateTag(name: String, color: String? = nil) throws -> Int64 {
        if let existing = try tag(named: name), let id = existing.id { return id }
        return try insertTag(name: name, color: color)
    }

    public func updateTag(id: Int64, name: String, color: String?) throws {
        try exec("UPDATE tags SET name = ?, color = ? WHERE id = ?") {
            bind($0, 1, name)
            bind($0, 2, color)
            bind($0, 3, id)
        }
    }

    /// Löschen: document_tags hat ON DELETE CASCADE.
    public func deleteTag(id: Int64) throws {
        try exec("DELETE FROM tags WHERE id = ?") { bind($0, 1, id) }
    }

    public func addTagToDocument(documentId: Int64, tagId: Int64) throws {
        try exec("INSERT OR IGNORE INTO document_tags(document_id, tag_id) VALUES(?, ?)") {
            bind($0, 1, documentId)
            bind($0, 2, tagId)
        }
        try setSyncState(.notSynced, for: documentId)
    }

    public func removeTagFromDocument(documentId: Int64, tagId: Int64) throws {
        try exec("DELETE FROM document_tags WHERE document_id = ? AND tag_id = ?") {
            bind($0, 1, documentId)
            bind($0, 2, tagId)
        }
        try setSyncState(.notSynced, for: documentId)
    }
}
