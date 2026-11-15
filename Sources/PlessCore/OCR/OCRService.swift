import Foundation

/// Arbeitet alle Dokumente mit `ocr_done=0` per TextRecognizer ab (Hintergrund-Queue).
public final class OCRService {
    public let vault: Vault
    public let db: Database
    public let recognizer: TextRecognizer
    private let queue = DispatchQueue(label: "dev.pless.ocr")

    public init(vault: Vault, db: Database, recognizer: TextRecognizer) {
        self.vault = vault
        self.db = db
        self.recognizer = recognizer
    }

    /// Synchron: alle fälligen Dokumente OCRen. Rückgabe: Anzahl bearbeiteter Dokumente.
    @discardableResult
    public func processPending() throws -> Int {
        let pending = try db.documentsNeedingOCR()
        var done = 0
        for doc in pending {
            guard let id = doc.id else { continue }
            let url = vault.root.appendingPathComponent(doc.relativePath)
            let text = try recognizer.recognizeText(inPDF: url)
            try db.setOCRText(documentId: id, text: text, ocrDone: true)
            done += 1
        }
        return done
    }

    /// Async auf Hintergrund-Queue, mit Fortschritt (done, total).
    public func processPendingAsync(onProgress: @escaping (Int, Int) -> Void,
                                    completion: @escaping (Result<Int, Error>) -> Void) {
        queue.async {
            do {
                let pending = try self.db.documentsNeedingOCR()
                var done = 0
                for doc in pending {
                    guard let id = doc.id else { continue }
                    let url = self.vault.root.appendingPathComponent(doc.relativePath)
                    let text = try self.recognizer.recognizeText(inPDF: url)
                    try self.db.setOCRText(documentId: id, text: text, ocrDone: true)
                    done += 1
                    onProgress(done, pending.count)
                }
                completion(.success(done))
            } catch {
                completion(.failure(error))
            }
        }
    }
}
