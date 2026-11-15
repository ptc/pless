import Foundation

/// OCR-Schnittstelle: Text aus einem PDF erkennen (on-device, kein Cloud).
public protocol TextRecognizer: Sendable {
    func recognizeText(inPDF url: URL) throws -> String
}

/// Fake für Tests.
public final class FakeTextRecognizer: TextRecognizer {
    public let text: String
    public init(text: String) { self.text = text }
    public func recognizeText(inPDF url: URL) throws -> String { text }
}
