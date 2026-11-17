import Foundation
import CoreGraphics
import PDFKit
import Vision

/// OCR-Qualitätsstufe — mappt auf Vision `VNRequestTextRecognitionLevel`.
public enum OCRQuality: String, CaseIterable, Sendable {
    case fast
    case accurate
    public var recognitionLevel: VNRequestTextRecognitionLevel {
        switch self {
        case .fast: return .fast
        case .accurate: return .accurate
        }
    }
}

/// OCR via Apple Vision (on-device). Sprachen default de+en.
public final class VisionTextRecognizer: TextRecognizer {
    public let languages: [String]
    public let recognitionLevel: VNRequestTextRecognitionLevel
    public let usesLanguageCorrection: Bool
    /// Render-Auflösung fürs Seitenbild (dpi) — höhere Werte erkennen kleine Schrift besser, kosten aber Zeit.
    public let resolutionDPI: Int

    public init(languages: [String] = ["de-DE", "en-US"],
                quality: OCRQuality = .accurate,
                usesLanguageCorrection: Bool = true,
                resolutionDPI: Int = 300) {
        self.languages = languages
        self.recognitionLevel = quality.recognitionLevel
        self.usesLanguageCorrection = usesLanguageCorrection
        self.resolutionDPI = resolutionDPI
    }

    /// Legacy-Init über das Vision-Level direkt (z. B. Tests).
    public convenience init(languages: [String] = ["de-DE", "en-US"],
                            recognitionLevel: VNRequestTextRecognitionLevel) {
        self.init(languages: languages, quality: recognitionLevel == .fast ? .fast : .accurate)
    }

    public func recognizeText(inPDF url: URL) throws -> String {
        guard let pdf = PDFDocument(url: url) else {
            throw PlessError.invalidDocument("kein gültiges PDF: \(url.lastPathComponent)")
        }
        var pages: [String] = []
        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i) else { continue }
            // dpi: Seitenbreite in Punkt * dpi/72
            let targetWidth = page.bounds(for: .mediaBox).width / 72.0 * CGFloat(resolutionDPI)
            guard let image = PDFRendering.cgImage(of: page, targetWidth: targetWidth) else { continue }
            pages.append(try recognize(image: image))
        }
        return pages.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func recognize(image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = languages
        request.recognitionLevel = recognitionLevel
        request.usesLanguageCorrection = usesLanguageCorrection
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
