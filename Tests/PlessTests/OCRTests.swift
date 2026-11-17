import Foundation
import Vision
import MiniTest
import PlessCore

enum OCRTests {
    static func register() {
        MiniTest.test("OCR: pending Dokumente werden per Fake-Recognizer abgearbeitet") { try fakeOCR() }
        MiniTest.test("OCR: keine pending Dokumente → 0") { try nothingPending() }
        MiniTest.test("OCR: async mit Fortschritt (done, total)") { try asyncOCR() }
        MiniTest.test("OCR: cancel() stoppt async-Verarbeitung vorzeitig, Rest bleibt pending") { try cancelStopsAsync() }
        MiniTest.test("OCR: processAsync(documentId:) — manueller Einzelstart") { try singleDocAsync() }
        MiniTest.test("OCR: VisionTextRecognizer konstruierbar (de+en, fast/accurate)") { visionInit() }
        MiniTest.test("OCR: Quality-Mapping fast/accurate + Defaults (Korrektur an, 300 dpi, accurate)") { try qualityMapping() }
    }

    /// Langsamer Recognizer, damit cancel() zwischen zwei Dokumenten greifen kann.
    private final class SlowRecognizer: TextRecognizer {
        let delay: UInt32
        init(delay: UInt32 = 1) { self.delay = delay }
        func recognizeText(inPDF url: URL) throws -> String {
            sleep(delay)
            return "langsam erkannt"
        }
    }

    private static func cancelStopsAsync() throws {
        let (vault, db, root) = try makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        for _ in 0..<3 { _ = try insertPendingDoc(vault: vault, db: db) }
        let svc = OCRService(vault: vault, db: db, recognizer: SlowRecognizer())
        let sem = DispatchSemaphore(value: 0)
        var result: Result<Int, Error>?
        svc.processPendingAsync(onProgress: { done, _ in
            if done == 1 { svc.cancel() } // nach dem ersten Dokument abbrechen
        }, completion: { result = $0; sem.signal() })
        try MiniTest.expectEqual(sem.wait(timeout: .now() + 15), .success)
        guard case .success(let done) = result else { throw TestFailure("erwartet .success, erhalten \(String(describing: result))") }
        try MiniTest.expect(done == 1, "cancel nach 1 → done=\(done)")
        try MiniTest.expect(!svc.isRunning)
        try MiniTest.expectEqual(try db.documentsNeedingOCR().count, 2) // Rest bleibt „OCR offen"
    }

    private static func singleDocAsync() throws {
        let (vault, db, root) = try makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = try insertPendingDoc(vault: vault, db: db)
        let svc = OCRService(vault: vault, db: db, recognizer: FakeTextRecognizer(text: "manuell erkannt"))
        let sem = DispatchSemaphore(value: 0)
        var result: Result<Void, Error>?
        svc.processAsync(documentId: doc.id!) { result = $0; sem.signal() }
        try MiniTest.expectEqual(sem.wait(timeout: .now() + 5), .success)
        guard case .success = result else { throw TestFailure("fehlgeschlagen: \(String(describing: result))") }
        let updated = try db.document(byUUID: doc.uuid)
        try MiniTest.expectEqual(updated?.ocrText, "manuell erkannt")
        try MiniTest.expect(updated?.ocrDone == true)
        try MiniTest.expect(!svc.isRunning)
    }

    private static func makeEnv() throws -> (vault: Vault, db: Database, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pless-ocr-\(UUID().uuidString)", isDirectory: true)
        let vault = try Vault(root: root)
        return (vault, try Database(url: vault.databaseURL), root)
    }

    /// Dokument mit ocrDone=false anlegen (Datei in inbox, Inhalt egal für den Fake).
    private static func insertPendingDoc(vault: Vault, db: Database) throws -> Document {
        let name = "scan-\(UUID().uuidString).pdf"
        try Data("pdf".utf8).write(to: vault.inboxURL.appendingPathComponent(name))
        var doc = Document(uuid: UUID().uuidString, sha256: "sha-\(UUID().uuidString)",
                           filename: name, relativePath: "inbox/\(name)",
                           pageCount: 1, ocrDone: false, needsReview: true)
        doc.id = try db.insert(doc)
        return doc
    }

    private static func fakeOCR() throws {
        let (vault, db, root) = try makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = try insertPendingDoc(vault: vault, db: db)

        let svc = OCRService(vault: vault, db: db, recognizer: FakeTextRecognizer(text: "erkannter Text 123"))
        try MiniTest.expectEqual(try svc.processPending(), 1)

        let updated = try db.document(byUUID: doc.uuid)
        try MiniTest.expectEqual(updated?.ocrText, "erkannter Text 123")
        try MiniTest.expect(updated?.ocrDone == true)
        try MiniTest.expect(updated?.needsReview == false)
        // danach nichts mehr pending
        try MiniTest.expectEqual(try svc.processPending(), 0)
    }

    private static func nothingPending() throws {
        let (vault, db, root) = try makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        let svc = OCRService(vault: vault, db: db, recognizer: FakeTextRecognizer(text: "x"))
        try MiniTest.expectEqual(try svc.processPending(), 0)
    }

    private static func asyncOCR() throws {
        let (vault, db, root) = try makeEnv()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try insertPendingDoc(vault: vault, db: db)

        let svc = OCRService(vault: vault, db: db, recognizer: FakeTextRecognizer(text: "async"))
        let sem = DispatchSemaphore(value: 0)
        var progress: [(Int, Int)] = []
        var result: Result<Int, Error>?
        svc.processPendingAsync(onProgress: { progress.append(($0, $1)) },
                                completion: { result = $0; sem.signal() })
        sem.wait()
        try MiniTest.expectEqual(try result!.get(), 1)
        try MiniTest.expect(progress.count == 1 && progress[0] == (1, 1))
    }

    private static func visionInit() {
        _ = VisionTextRecognizer()
        _ = VisionTextRecognizer(languages: ["de-DE"], recognitionLevel: .fast)
    }

    private static func qualityMapping() throws {
        try MiniTest.expectEqual(OCRQuality.accurate.recognitionLevel, .accurate)
        try MiniTest.expectEqual(OCRQuality.fast.recognitionLevel, .fast)
        try MiniTest.expectEqual(OCRQuality(rawValue: "fast"), .fast)
        try MiniTest.expectEqual(OCRQuality(rawValue: "quatsch"), nil)
        let r = VisionTextRecognizer()
        try MiniTest.expectEqual(r.recognitionLevel, .accurate)
        try MiniTest.expectEqual(r.usesLanguageCorrection, true)
        try MiniTest.expectEqual(r.resolutionDPI, 300)
        let custom = VisionTextRecognizer(languages: ["de-DE"], quality: .fast,
                                          usesLanguageCorrection: false, resolutionDPI: 400)
        try MiniTest.expectEqual(custom.recognitionLevel, .fast)
        try MiniTest.expectEqual(custom.usesLanguageCorrection, false)
        try MiniTest.expectEqual(custom.resolutionDPI, 400)
    }
}
