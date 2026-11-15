import Foundation
import MiniTest
import PlessCore

enum NamingTests {
    static func register() {
        MiniTest.test("Naming: sanitize (Umlaute, Sonderzeichen, Leerzeichen, Länge, Fallback)") { try sanitizeCases() }
        MiniTest.test("Naming: render Default-Template mit vollem Kontext") { try renderDefault() }
        MiniTest.test("Naming: render ohne Korrespondent (keine doppelten __)") { try renderMissing() }
        MiniTest.test("Naming: render mit Tags und eigenem Template") { try renderTagsCustom() }
        MiniTest.test("Naming: uniqueFilename hängt -2, -3 an") { try unique() }
    }

    private static func sanitizeCases() throws {
        try MiniTest.expectEqual(NamingEngine.sanitize("Müller & Söhne: Rechnung!"), "Mueller-Soehne-Rechnung")
        try MiniTest.expectEqual(NamingEngine.sanitize("KFZ-Versicherung 2026"), "KFZ-Versicherung-2026")
        try MiniTest.expectEqual(NamingEngine.sanitize("???"), "dokument")
        try MiniTest.expectEqual(NamingEngine.sanitize(String(repeating: "a", count: 100)),
                                 String(repeating: "a", count: 40))
    }

    private static func renderDefault() throws {
        let name = NamingEngine.render(context: NamingContext(
            date: "2026-02-14", correspondent: "Allianz", title: "KFZ-Versicherung 2026"))
        try MiniTest.expectEqual(name, "2026-02-14_Allianz_KFZ-Versicherung-2026.pdf")
    }

    private static func renderMissing() throws {
        let name = NamingEngine.render(context: NamingContext(date: "2026-02-14", title: "KFZ 2026"))
        try MiniTest.expectEqual(name, "2026-02-14_KFZ-2026.pdf")
    }

    private static func renderTagsCustom() throws {
        let name = NamingEngine.render(template: "{tags}_{title}.pdf", context: NamingContext(
            title: "Abrechnung", tags: ["wichtig", "steuer2026"]))
        try MiniTest.expectEqual(name, "wichtig-steuer2026_Abrechnung.pdf")
    }

    private static func unique() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pless-naming-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try MiniTest.expectEqual(NamingEngine.uniqueFilename(in: dir, desired: "a.pdf"), "a.pdf")
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.pdf"))
        try MiniTest.expectEqual(NamingEngine.uniqueFilename(in: dir, desired: "a.pdf"), "a-2.pdf")
        try Data("x".utf8).write(to: dir.appendingPathComponent("a-2.pdf"))
        try MiniTest.expectEqual(NamingEngine.uniqueFilename(in: dir, desired: "a.pdf"), "a-3.pdf")
    }
}
