import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum Thumbnails {
    /// PNG-Thumbnail der ersten (oder gewählten) PDF-Seite.
    public static func pngData(for url: URL, page: Int = 0, width: CGFloat = 120) -> Data? {
        guard let img = PDFRendering.cgImage(of: url, page: page, targetWidth: width) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
