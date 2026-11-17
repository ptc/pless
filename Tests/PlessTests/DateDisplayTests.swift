import Foundation
import MiniTest
import PlessCore

enum DateDisplayTests {
    static func register() {
        MiniTest.test("DateDisplay: ISO → deutsch (dd.MM.yyyy) und andere Formate") { try formatPatterns() }
        MiniTest.test("DateDisplay: parse akzeptiert Anzeigeformat und ISO, normalisiert auf ISO") { try parseInputs() }
        MiniTest.test("DateDisplay: ungültige Eingaben") { try invalidInputs() }
        MiniTest.test("DateDisplay: resolvePattern — system → OS-Format, sonst 1:1; Roundtrip mit OS-Format") { try resolveSystem() }
    }

    private static func resolveSystem() throws {
        try MiniTest.expectEqual(DateDisplay.resolvePattern("dd.MM.yyyy"), "dd.MM.yyyy")
        try MiniTest.expectEqual(DateDisplay.resolvePattern("yyyy-MM-dd"), "yyyy-MM-dd")
        let sys = DateDisplay.systemPattern()
        try MiniTest.expect(!sys.isEmpty, "systemPattern nicht leer")
        try MiniTest.expect(sys.contains("y") && sys.contains("d"), "systemPattern enthält Jahr und Tag")
        try MiniTest.expectEqual(DateDisplay.resolvePattern("system"), sys)
        // Roundtrip: ISO → OS-Format → zurück nach ISO
        let shown = DateDisplay.format(iso: "2026-02-14", pattern: sys)
        try MiniTest.expectEqual(DateDisplay.parse(shown, pattern: sys), "2026-02-14")
    }

    private static func formatPatterns() throws {
        try MiniTest.expectEqual(DateDisplay.format(iso: "2026-02-14", pattern: "dd.MM.yyyy"), "14.02.2026")
        try MiniTest.expectEqual(DateDisplay.format(iso: "2026-02-14", pattern: "yyyy-MM-dd"), "2026-02-14")
        try MiniTest.expectEqual(DateDisplay.format(iso: "2026-02-14", pattern: "MM/dd/yyyy"), "02/14/2026")
        try MiniTest.expectEqual(DateDisplay.format(iso: nil, pattern: "dd.MM.yyyy"), "")
        try MiniTest.expectEqual(DateDisplay.format(iso: "kein-datum", pattern: "dd.MM.yyyy"), "kein-datum")
    }

    private static func parseInputs() throws {
        // Anzeigeformat deutsch
        try MiniTest.expectEqual(DateDisplay.parse("14.02.2026", pattern: "dd.MM.yyyy"), "2026-02-14")
        // ISO direkt
        try MiniTest.expectEqual(DateDisplay.parse("2026-02-14", pattern: "dd.MM.yyyy"), "2026-02-14")
        // US-Format
        try MiniTest.expectEqual(DateDisplay.parse("02/14/2026", pattern: "MM/dd/yyyy"), "2026-02-14")
        // Leer → nil (Feld leeren erlaubt)
        try MiniTest.expectEqual(DateDisplay.parse("  ", pattern: "dd.MM.yyyy"), nil)
    }

    private static func invalidInputs() throws {
        try MiniTest.expectEqual(DateDisplay.parse("31.02.2026", pattern: "dd.MM.yyyy"), nil) // ungültig
        try MiniTest.expectEqual(DateDisplay.parse("14.02.2026", pattern: "MM/dd/yyyy"), nil) // falsches Format
        try MiniTest.expectEqual(DateDisplay.parse("abc", pattern: "dd.MM.yyyy"), nil)
    }
}
