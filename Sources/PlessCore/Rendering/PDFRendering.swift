import Foundation
import CoreGraphics
import PDFKit

public enum PDFRendering {
    /// Rendert eine PDF-Seite in ein CGImage (headless-tauglich, nur CoreGraphics).
    public static func cgImage(of page: PDFPage, targetWidth: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0, targetWidth > 0 else { return nil }
        let scale = targetWidth / bounds.width
        let w = Int(bounds.width * scale)
        let h = Int(bounds.height * scale)
        guard w > 0, h > 0 else { return nil }
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    public static func cgImage(of url: URL, page index: Int = 0, targetWidth: CGFloat) -> CGImage? {
        guard let pdf = PDFDocument(url: url), let page = pdf.page(at: index) else { return nil }
        return cgImage(of: page, targetWidth: targetWidth)
    }
}
