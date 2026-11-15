import Foundation
import MiniTest
import PlessCore

enum ThumbnailTests {
    static func register() {
        MiniTest.test("Thumbnails: PNG aus PDF-Seite (Signatur 89 50 4E 47)") { try pngFromPDF() }
        MiniTest.test("Thumbnails: ungültige Datei → nil") { try pngInvalid() }
        MiniTest.test("Thumbnails: Orientierung — Text oben im PDF landet oben im Bild") { try orientation() }
    }

    /// writePDF(text: nil) malt ein schwarzes Quadrat bei y=40..240 — das ist UNTEN im PDF
    /// (PDF-Koordinaten: y wächst nach oben). Im gerenderten Bild muss das Quadrat unten liegen.
    private static func orientation() throws {
        let dir = PDFFixture.tempDir("pless-orient")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pdf = dir.appendingPathComponent("o.pdf")
        try PDFFixture.writePDF(text: nil, to: pdf)
        guard let img = PDFRendering.cgImage(of: pdf, targetWidth: 120) else {
            throw TestFailure("kein CGImage gerendert")
        }
        guard let data = img.dataProvider?.data as Data? else { throw TestFailure("keine Pixeldaten") }
        let w = img.width, h = img.height, bpr = img.bytesPerRow
        var topDark = 0, bottomDark = 0
        for row in 0..<h {
            let top = row < h / 2
            for col in 0..<w {
                let off = row * bpr + col * 4
                if Int(data[off + 3]) > 128,
                   Int(data[off]) + Int(data[off + 1]) + Int(data[off + 2]) < 300 {
                    if top { topDark += 1 } else { bottomDark += 1 }
                }
            }
        }
        try MiniTest.expect(bottomDark > 0, "Quadrat-Pixel fehlen komplett")
        try MiniTest.expect(bottomDark > topDark,
                           "Bild ist kopfüber: dunkle Pixel top=\(topDark), bottom=\(bottomDark)")
    }

    private static func pngFromPDF() throws {
        let dir = PDFFixture.tempDir("pless-thumb")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pdf = dir.appendingPathComponent("t.pdf")
        try PDFFixture.writePDF(text: "Thumbnail Test", to: pdf)
        let png = try MiniTest.unwrap(Thumbnails.pngData(for: pdf, width: 120))
        try MiniTest.expect(Array(png.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
        try MiniTest.expect(png.count > 100)
    }

    private static func pngInvalid() throws {
        let dir = PDFFixture.tempDir("pless-thumb")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("x.pdf")
        try Data("kein pdf".utf8).write(to: f)
        try MiniTest.expectEqual(Thumbnails.pngData(for: f), nil)
    }
}
