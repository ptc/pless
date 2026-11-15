import Foundation

/// Crash-Recovery beim App-Start: gleicht Datenbank und Dateisystem ab, damit keine
/// Datei „verschwindet“, wenn die App mitten im Import abstürzt.
///
/// Abgedeckte Crash-Fenster:
/// 1. DB-Eintrag mit Pfad `inbox/…`, Datei liegt noch in der Inbox (Crash nach insert,
///    vor dem Verschieben) → Datei wird finalisiert (nach `documents/YYYY/MM/` verschoben,
///    DB aktualisiert).
/// 2. Datei wurde verschoben, DB zeigt noch den alten Pfad (Crash nach move, vor dem
///    DB-Update) → Datei wird per SHA-256 im Vault wiedergefunden, DB-Pfad korrigiert.
/// 3. PDF liegt in `documents/`, aber ohne DB-Eintrag → wird in die Inbox verschoben und
///    läuft danach durch den normalen Ingest.
public struct RecoveryService: Sendable {
    public let vault: Vault
    public let db: Database

    public init(vault: Vault, db: Database) {
        self.vault = vault
        self.db = db
    }

    public struct Report: Sendable, Equatable {
        public var finalized: Int   // Fall 1: inbox → documents finalisiert
        public var relocated: Int   // Fall 2: DB-Pfad per SHA korrigiert
        public var adopted: Int     // Fall 3: Waisen-PDF aus documents/ → inbox
        public var total: Int { finalized + relocated + adopted }

        public init(finalized: Int = 0, relocated: Int = 0, adopted: Int = 0) {
            self.finalized = finalized
            self.relocated = relocated
            self.adopted = adopted
        }
    }

    @discardableResult
    public func recover() throws -> Report {
        let fm = FileManager.default
        var report = Report()

        // Fall 2 zuerst: Dokumente, deren Datei am DB-Pfad fehlt, per SHA im Vault suchen.
        for doc in try db.allDocuments() {
            guard let id = doc.id else { continue }
            guard !fm.fileExists(atPath: vault.root.appendingPathComponent(doc.relativePath).path) else { continue }
            if let found = try findBySHA(doc.sha256) {
                let rel = relativePath(of: found)
                try db.updateFileLocation(documentId: id, filename: found.lastPathComponent, relativePath: rel)
                report.relocated += 1
            }
        }

        // Fall 1: DB-Pfad zeigt noch inbox/… und die Datei liegt dort → finalisieren.
        let metadata = MetadataService(vault: vault, db: db)
        for doc in try db.allDocuments() {
            guard let id = doc.id, doc.relativePath.hasPrefix("inbox/"),
                  fm.fileExists(atPath: vault.root.appendingPathComponent(doc.relativePath).path) else { continue }
            _ = try metadata.saveMetadata(documentId: id, title: doc.title, documentDate: doc.documentDate,
                                          correspondentId: doc.correspondentId, categoryId: doc.categoryId,
                                          notes: doc.notes)
            report.finalized += 1
        }

        // Fall 3: Waisen-PDFs unter documents/ (kein DB-Eintrag) → in die Inbox verschieben.
        let known = Set(try db.allDocuments().map { $0.relativePath })
        for pdf in pdfFiles(under: vault.documentsURL) {
            let rel = relativePath(of: pdf)
            guard !known.contains(rel) else { continue }
            let dest = uniqueInboxURL(for: pdf.lastPathComponent)
            try fm.moveItem(at: pdf, to: dest)
            report.adopted += 1
        }

        return report
    }

    // MARK: - Helfer

    /// Sucht rekursiv in documents/, inbox/ (inkl. _abgelehnt/) nach einer PDF mit dem SHA-256.
    private func findBySHA(_ sha: String) throws -> URL? {
        let fm = FileManager.default
        let searchRoots = [vault.documentsURL, vault.inboxURL]
        for rootURL in searchRoots {
            guard let en = fm.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in en {
                let isDir = ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) == true
                if isDir || url.pathExtension.lowercased() != "pdf" { continue }
                if (try? FileHash.sha256(of: url)) == sha { return url }
            }
        }
        return nil
    }

    private func pdfFiles(under dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return en.compactMap { $0 as? URL }.filter { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return !isDir && url.pathExtension.lowercased() == "pdf"
        }
    }

    private func relativePath(of url: URL) -> String {
        // resolvingSymlinksInPath: /var -> /private/var (tmp-Verzeichnis) muss auflösbar sein
        var base = vault.root.resolvingSymlinksInPath().path
        if base.hasSuffix("/") { base.removeLast() }
        let p = url.resolvingSymlinksInPath().path
        let prefix = base + "/"
        if p.hasPrefix(prefix) { return String(p.dropFirst(prefix.count)) }
        return p
    }

    private func uniqueInboxURL(for filename: String) -> URL {
        let fm = FileManager.default
        var dest = vault.inboxURL.appendingPathComponent(filename)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = vault.inboxURL.appendingPathComponent("\(n)_\(filename)")
            n += 1
        }
        return dest
    }
}
