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
            guard let page = pdf.page(at: i), let image = render(page: page) else { continue }
            pages.append(try recognize(image: image))
        }
        return pages.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Rendert eine PDF-Seite per CoreGraphics in ein CGImage (funktioniert headless).
    func render(page: PDFPage, dpi: CGFloat = 200) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = dpi / 72.0
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        let space = CGColorSpaceCreateDeviceRGB()
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
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
