import Foundation

public enum IngestOutcome: Equatable, Sendable {
    case imported(Document)
    case duplicate(existing: Document)
    case rejected(reason: String)
}

/// Verarbeitet eine in die Inbox gestagete Datei:
/// SHA-256-Dedup → Textextraktion (PDFKit) → DB-Eintrag (Datei bleibt vorerst in inbox/,
/// finale Ablage mit generiertem Namen folgt mit den Metadaten in späteren Phasen).
public struct IngestService: Sendable {
    public let vault: Vault
    public let db: Database

    public init(vault: Vault, db: Database) {
        self.vault = vault
        self.db = db
    }

    public func process(fileAt url: URL) throws -> IngestOutcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw PlessError.io("Datei fehlt: \(url.path)")
        }
        let sha = try FileHash.sha256(of: url)
        if let existing = try db.document(bySHA256: sha) {
            try? moveToRejected(url)
            return .duplicate(existing: existing)
        }

        let extraction: TextExtraction.Result
        do {
            extraction = try TextExtraction.extract(from: url)
        } catch {
            try? moveToRejected(url)
            return .rejected(reason: "kein gültiges PDF")
        }

        var doc = Document(
            uuid: UUID().uuidString,
            sha256: sha,
            filename: url.lastPathComponent,
            relativePath: "inbox/\(url.lastPathComponent)",
            pageCount: extraction.pageCount,
            ocrText: extraction.hasTextLayer ? extraction.text : nil,
            ocrDone: extraction.hasTextLayer,
            needsReview: !extraction.hasTextLayer
        )
        doc.id = try db.insert(doc)
        return .imported(doc)
    }

    @discardableResult
    private func moveToRejected(_ url: URL) throws -> URL {
        let fm = FileManager.default
        var dest = vault.rejectedURL.appendingPathComponent(url.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = vault.rejectedURL.appendingPathComponent("\(n)_\(url.lastPathComponent)")
            n += 1
        }
        try fm.moveItem(at: url, to: dest)
        return dest
    }
}
