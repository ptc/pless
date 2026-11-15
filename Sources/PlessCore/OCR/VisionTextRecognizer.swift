import Foundation
import CoreGraphics
import PDFKit
import Vision

/// OCR via Apple Vision (on-device). Sprachen default de+en.
public final class VisionTextRecognizer: TextRecognizer {
    public let languages: [String]
    public let recognitionLevel: VNRequestTextRecognitionLevel

    public init(languages: [String] = ["de-DE", "en-US"],
                recognitionLevel: VNRequestTextRecognitionLevel = .accurate) {
        self.languages = languages
        self.recognitionLevel = recognitionLevel
    }

    public func recognizeText(inPDF url: URL) throws -> String {
        guard let pdf = PDFDocument(url: url) else {
            throw PlessError.invalidDocument("kein gültiges PDF: \(url.lastPathComponent)")
        }
        var pages: [String] = []
        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i) else { continue }
            // 200 dpi: Seitenbreite in Punkt * 200/72
            let targetWidth = page.bounds(for: .mediaBox).width / 72.0 * 200
            guard let image = PDFRendering.cgImage(of: page, targetWidth: targetWidth) else { continue }
            pages.append(try recognize(image: image))
        }
        return pages.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func recognize(image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = languages
        request.recognitionLevel = recognitionLevel
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
