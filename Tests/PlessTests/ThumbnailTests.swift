import Foundation
import MiniTest
import PlessCore

enum ThumbnailTests {
    static func register() {
        MiniTest.test("Thumbnails: PNG aus PDF-Seite (Signatur 89 50 4E 47)") { try pngFromPDF() }
        MiniTest.test("Thumbnails: ungültige Datei → nil") { try pngInvalid() }
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
