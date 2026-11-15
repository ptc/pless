import Foundation

/// Der Vault: ein Ordner, der alles enthält (pless.db, documents/, inbox/, thumbnails/).
public struct Vault: Sendable {
    public let root: URL
    /// Optionaler eigener Import-Ordner (Settings); Default: `<root>/inbox`.
    public let inboxOverride: URL?

    public var databaseURL: URL { root.appendingPathComponent("pless.db", isDirectory: false) }
    public var documentsURL: URL { root.appendingPathComponent("documents", isDirectory: true) }
    public var inboxURL: URL { inboxOverride ?? root.appendingPathComponent("inbox", isDirectory: true) }
    public var rejectedURL: URL { inboxURL.appendingPathComponent("_abgelehnt", isDirectory: true) }
    public var thumbnailsURL: URL { root.appendingPathComponent("thumbnails", isDirectory: true) }

    /// Format-Version der gerenderten Thumbnails. Bei Rendering-Änderungen (z. B. Orientierungs-Fix)
    /// erhöhen — veraltete Thumbnails werden dann einmalig gelöscht und on demand neu gerendert.
    public static let thumbnailFormatVersion = 2

    /// Löscht alle Dateien in thumbnails/, wenn der Format-Marker fehlt (einmalig pro Version).
    /// Liefert die Anzahl entfernter Dateien.
    @discardableResult
    public func invalidateThumbnailsIfOutdated() -> Int {
        let fm = FileManager.default
        let markerName = ".format-v\(Self.thumbnailFormatVersion)"
        let marker = thumbnailsURL.appendingPathComponent(markerName)
        if fm.fileExists(atPath: marker.path) { return 0 }
        let files = (try? fm.contentsOfDirectory(atPath: thumbnailsURL.path)) ?? []
        var removed = 0
        for f in files where f != markerName {
            try? fm.removeItem(at: thumbnailsURL.appendingPathComponent(f))
            removed += 1
        }
        try? Data().write(to: marker, options: .atomic)
        return removed
    }

    public init(root: URL, inboxOverride: URL? = nil, createIfNeeded: Bool = true) throws {
        self.root = root
        self.inboxOverride = inboxOverride
        let fm = FileManager.default
        if createIfNeeded {
            for dir in [root, documentsURL, inboxURL, rejectedURL, thumbnailsURL] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        } else if !fm.fileExists(atPath: root.path) {
            throw PlessError.vaultNotFound(root)
        }
    }

    /// documents/YYYY/MM (legt den Ordner an).
    public func documentsFolder(year: Int, month: Int) throws -> URL {
        let url = documentsURL.appendingPathComponent(String(format: "%04d/%02d", year, month), isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Verschiebt eine Dokumentdatei innerhalb des Vaults (legt Zielordner an).
    /// Wirft, wenn die Quelle fehlt oder das Ziel bereits existiert.
    public func moveDocumentFile(from relativePath: String, to newRelativePath: String) throws {
        let fm = FileManager.default
        let src = root.appendingPathComponent(relativePath)
        let dst = root.appendingPathComponent(newRelativePath)
        if src == dst { return }
        guard fm.fileExists(atPath: src.path) else {
            throw PlessError.io("Quelldatei fehlt: \(relativePath)")
        }
        if fm.fileExists(atPath: dst.path) {
            throw PlessError.io("Zieldatei existiert bereits: \(newRelativePath)")
        }
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fm.moveItem(at: src, to: dst)
        } catch {
            throw PlessError.io("Umbenennen fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    /// Kopiert eine Datei in die Inbox (Staging vor dem Ingest). Liefert die Ziel-URL.
    /// Die Quelle wird nie verschoben oder gelöscht — eine Datei darf durch den Import
    /// nie an ihrem Ursprungsort verschwinden (Crash-Sicherheit).
    @discardableResult
    public func stageIntoInbox(fileAt source: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else {
            throw PlessError.io("Quelldatei fehlt: \(source.path)")
        }
        var dest = inboxURL.appendingPathComponent(source.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = inboxURL.appendingPathComponent("\(n)_\(source.lastPathComponent)")
            n += 1
        }
        do {
            try fm.copyItem(at: source, to: dest)
        } catch {
            throw PlessError.io("stageIntoInbox fehlgeschlagen: \(error.localizedDescription)")
        }
        return dest
    }
}
