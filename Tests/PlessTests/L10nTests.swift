import Foundation
import MiniTest
import PlessCore

enum L10nTests {
    static func register() {
        MiniTest.test("L10n: de liefert Key unverändert, en übersetzt, unbekannt → Key") { try basic() }
        MiniTest.test("L10n: TF mit Platzhaltern (%@ / %d) in de und en") { try formats() }
        MiniTest.test("L10n: resolve — de/en direkt, system → OS-Sprache") { try resolveTest() }
    }

    private static func resolveTest() throws {
        try MiniTest.expectEqual(L10n.resolve("de"), "de")
        try MiniTest.expectEqual(L10n.resolve("en"), "en")
        let sys = L10n.systemLanguage()
        try MiniTest.expect(sys == "de" || sys == "en", "systemLanguage liefert de oder en")
        try MiniTest.expectEqual(L10n.resolve("system"), sys)
        try MiniTest.expectEqual(L10n.resolve("unsinn"), "de")   // ungültig → Fallback deutsch
    }

    private static func basic() throws {
        L10n.language = "de"
        try MiniTest.expectEqual(L10n.t("Bearbeiten"), "Bearbeiten")
        L10n.language = "en"
        try MiniTest.expectEqual(L10n.t("Bearbeiten"), "Edit")
        try MiniTest.expectEqual(L10n.t("Posteingang"), "Inbox")
        try MiniTest.expectEqual(L10n.t("gibt es nicht"), "gibt es nicht")   // Fallback
        try MiniTest.expectEqual(L10n.t("cloud.fill"), "cloud.fill")           // SF-Symbol-Namen fallen durch
        L10n.language = "de"
    }

    private static func formats() throws {
        L10n.language = "de"
        try MiniTest.expectEqual(L10n.t("%d ausgewählt", 3), "3 ausgewählt")
        L10n.language = "en"
        try MiniTest.expectEqual(L10n.t("%d ausgewählt", 3), "3 selected")
        try MiniTest.expectEqual(L10n.t("Importiert: %@ → %@", "Rechnung", "documents/2026/11/r.pdf"),
                                "Imported: Rechnung → documents/2026/11/r.pdf")
        L10n.language = "de"
    }
}
