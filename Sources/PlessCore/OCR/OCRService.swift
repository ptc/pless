import Foundation

/// Arbeitet alle Dokumente mit `ocr_done=0` per TextRecognizer ab (Hintergrund-Queue).
public final class OCRService {
    public let vault: Vault
    public let db: Database
    public let recognizer: TextRecognizer
    /// Optional: nach dem OCR Heuristik anwenden und Datei ablegen (Phase 9).
    public var metadata: MetadataService?
    private let queue = DispatchQueue(label: "dev.pless.ocr")
    private let lock = NSLock()
    private var cancelled = false
    private var running = false

    public init(vault: Vault, db: Database, recognizer: TextRecognizer, metadata: MetadataService? = nil) {
        self.vault = vault
        self.db = db
        self.recognizer = recognizer
        self.metadata = metadata
    }

    /// Läuft gerade ein OCR-Durchlauf (async)?
    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    /// Bricht den laufenden Durchlauf ab (kooperativ: zwischen zwei Dokumenten wird gestoppt).
    /// Abgebrochene Dokumente bleiben `ocr_done=0` und können später manuell gestartet werden.
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private func beginRun() { lock.lock(); cancelled = false; running = true; lock.unlock() }
    private func endRun() { lock.lock(); running = false; lock.unlock() }

    /// Synchron: alle fälligen Dokumente OCRen. Rückgabe: Anzahl bearbeiteter Dokumente.
    @discardableResult
    public func processPending() throws -> Int {
        beginRun()
        defer { endRun() }
        let pending = try db.documentsNeedingOCR()
        var done = 0
        for doc in pending {
            if isCancelled { break }
            guard let id = doc.id else { continue }
            let url = vault.root.appendingPathComponent(doc.relativePath)
            let text = try recognizer.recognizeText(inPDF: url)
            try db.setOCRText(documentId: id, text: text, ocrDone: true)
            applyMetadataIfPossible(id: id, text: text)
            done += 1
        }
        return done
    }

    /// Async auf Hintergrund-Queue, mit Fortschritt (done, total). Bei cancel() wird nach dem
    /// aktuellen Dokument gestoppt und `completion(.success(done))` mit Teilanzahl geliefert.
    public func processPendingAsync(onProgress: @escaping (Int, Int) -> Void,
                                    completion: @escaping (Result<Int, Error>) -> Void) {
        beginRun()
        queue.async {
            do {
                let pending = try self.db.documentsNeedingOCR()
                var done = 0
                for doc in pending {
                    if self.isCancelled { break }
                    guard let id = doc.id else { continue }
                    let url = self.vault.root.appendingPathComponent(doc.relativePath)
                    let text = try self.recognizer.recognizeText(inPDF: url)
                    try self.db.setOCRText(documentId: id, text: text, ocrDone: true)
                    self.applyMetadataIfPossible(id: id, text: text)
                    done += 1
                    onProgress(done, pending.count)
                }
                self.endRun()
                completion(.success(done))
            } catch {
                self.endRun()
                completion(.failure(error))
            }
        }
    }

    /// Async: genau ein Dokument OCRen (manueller Start aus der Vorschau).
    public func processAsync(documentId: Int64,
                             completion: @escaping (Result<Void, Error>) -> Void) {
        beginRun()
        queue.async {
            do {
                guard !self.isCancelled else { self.endRun(); completion(.success(())); return }
                guard let doc = try self.db.document(byId: documentId) else {
                    throw PlessError.notFound("Dokument id=\(documentId) nicht gefunden")
                }
                let url = self.vault.root.appendingPathComponent(doc.relativePath)
                let text = try self.recognizer.recognizeText(inPDF: url)
                try self.db.setOCRText(documentId: documentId, text: text, ocrDone: true)
                self.applyMetadataIfPossible(id: documentId, text: text)
                self.endRun()
                completion(.success(()))
            } catch {
                self.endRun()
                completion(.failure(error))
            }
        }
    }

    /// Heuristik auf erkannten Text anwenden (best effort — OCR-Ergebnis bleibt auch bei Fehler erhalten).
    private func applyMetadataIfPossible(id: Int64, text: String) {
        guard let metadata else { return }
        _ = try? metadata.applySuggestions(documentId: id, text: text)
    }
}
