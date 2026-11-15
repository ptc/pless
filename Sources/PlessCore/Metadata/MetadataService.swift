import Foundation

/// Metadaten-Editing inkl. Umbenennen der Datei nach Template.
/// Beim Speichern landet die Datei (ggf. erstmals) unter `documents/YYYY/MM/<template>.pdf`.
public struct MetadataService: Sendable {
    public let vault: Vault
    public let db: Database
    public let template: String

    public init(vault: Vault, db: Database, template: String = NamingEngine.defaultTemplate) {
        self.vault = vault
        self.db = db
        self.template = template
    }

    /// Speichert alle Metadaten-Felder und benennt die Datei nach Template um
    /// (Kollision → `-2`, `-3`, …), sofern sich namensrelevante Felder geändert haben.
    /// Liefert das aktualisierte Dokument.
    @discardableResult
    public func saveMetadata(documentId: Int64, title: String?, documentDate: String?,
                             correspondentId: Int64?, categoryId: Int64?, notes: String?) throws -> Document {
        guard var doc = try db.document(byId: documentId) else {
            throw PlessError.notFound("Dokument id=\(documentId) nicht gefunden")
        }
        try db.updateMetadata(documentId: documentId, title: title, documentDate: documentDate,
                              correspondentId: correspondentId, categoryId: categoryId, notes: notes)
        doc.title = title
        doc.documentDate = documentDate
        doc.correspondentId = correspondentId
        doc.categoryId = categoryId
        doc.notes = notes

        let corrName = correspondentId.flatMap { try? db.correspondent(id: $0)?.name }
        let catName = categoryId.flatMap { try? db.category(id: $0)?.name }
        let tagNames = (try? db.tags(for: documentId).map { $0.name }) ?? []
        let effectiveDate = documentDate ?? String(doc.addedAt.prefix(10))
        let context = NamingContext(
            date: effectiveDate,
            correspondent: corrName,
            category: catName,
            title: title ?? (doc.filename as NSString).deletingPathExtension,
            tags: tagNames
        )
        let desiredName = NamingEngine.render(template: template, context: context)
        let folder = Self.folder(for: effectiveDate)
        let desiredRel = "\(folder)/\(desiredName)"

        var finalRel = desiredRel
        let fm = FileManager.default
        if doc.relativePath != desiredRel,
           fm.fileExists(atPath: vault.root.appendingPathComponent(desiredRel).path) {
            let dir = vault.root.appendingPathComponent(folder, isDirectory: true)
            let unique = NamingEngine.uniqueFilename(in: dir, desired: desiredName)
            finalRel = "\(folder)/\(unique)"
        }
        if finalRel != doc.relativePath {
            try vault.moveDocumentFile(from: doc.relativePath, to: finalRel)
            let name = (finalRel as NSString).lastPathComponent
            try db.updateFileLocation(documentId: documentId, filename: name, relativePath: finalRel)
            doc.filename = name
            doc.relativePath = finalRel
        }
        return doc
    }

    /// `documents/YYYY/MM` aus einem ISO-Datum; ungültig → Monat des heutigen Datums.
    public static func folder(for isoDate: String) -> String {
        let parts = isoDate.split(separator: "-")
        if parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), (1...12).contains(m) {
            return String(format: "documents/%04d/%02d", y, m)
        }
        return folder(for: String(Timestamp.now().prefix(10)))
    }
}
