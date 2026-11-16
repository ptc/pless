import Foundation
import MiniTest
import PlessCore

enum HeuristicsTests {
    static func register() {
        MiniTest.test("Heuristik: Datum (dd.mm.yyyy, dd.mm.yy, ISO, ungültig)") { try dates() }
        MiniTest.test("Heuristik: alle Datums-Vorschläge (mehrere, dedupliziert, Reihenfolge)") { try datesAll() }
        MiniTest.test("Heuristik: Langform mit Monatsname (8. Oktober 2026 → 2026-10-08)") { try datesLongGerman() }
        MiniTest.test("Heuristik: Korrespondent matchen (case-insensitive, längster gewinnt)") { try correspondent() }
        MiniTest.test("Heuristik: Titel = erste sinnvolle Zeile") { try title() }
        MiniTest.test("Heuristik: Kategorie per Schlüsselwort") { try category() }
        MiniTest.test("Heuristik: suggest kombiniert alles") { try combined() }
    }

    private static func dates() throws {
        try MiniTest.expectEqual(Heuristics.extractDate(from: "Rechnung vom 14.02.2026 bitte zahlen"), "2026-02-14")
        try MiniTest.expectEqual(Heuristics.extractDate(from: "Datum: 01.03.26"), "2026-03-01")
        try MiniTest.expectEqual(Heuristics.extractDate(from: "Vertrag 2026-12-24"), "2026-12-24")
        try MiniTest.expectEqual(Heuristics.extractDate(from: "31.02.2026"), nil)   // ungültig
        try MiniTest.expectEqual(Heuristics.extractDate(from: "32.13.2026"), nil)   // ungültig
        try MiniTest.expectEqual(Heuristics.extractDate(from: "kein Datum hier"), nil)
    }

    private static func datesAll() throws {
        // mehrere Datums-Vorkommen: alle, dedupliziert, in Reihenfolge, ISO + deutsch gemischt
        try MiniTest.expectEqual(
            Heuristics.extractDates(from: "Rechnung vom 14.02.2026, gültig bis 2026-12-24, vom 14.02.2026 erneut"),
            ["2026-02-14", "2026-12-24"])
        try MiniTest.expectEqual(Heuristics.extractDates(from: "01.03.26 und 2026-03-01"), ["2026-03-01"])
        try MiniTest.expectEqual(Heuristics.extractDates(from: "31.02.2026 ungültig, 05.06.2026 ok"), ["2026-06-05"])
        try MiniTest.expectEqual(Heuristics.extractDates(from: "kein Datum"), [])
    }

    private static func datesLongGerman() throws {
        // Langform mit Monatsname → Kurzform (ISO), inkl. Abkürzungen
        try MiniTest.expectEqual(Heuristics.extractDates(from: "Rechnung vom 8. Oktober 2026"), ["2026-10-08"])
        try MiniTest.expectEqual(Heuristics.extractDates(from: "Vertrag vom 14. Februar 2026"), ["2026-02-14"])
        try MiniTest.expectEqual(Heuristics.extractDates(from: "3. Mrz 2026 und 1. Mai 2026"), ["2026-03-03", "2026-05-01"])
        // gemischt mit numerisch/ISO, Reihenfolge nach Vorkommen im Text
        try MiniTest.expectEqual(
            Heuristics.extractDates(from: "Frist 2026-12-24, geschlossen am 8. Oktober 2026, vom 01.03.2026"),
            ["2026-12-24", "2026-10-08", "2026-03-01"])
        // ungültig / kein Monatsname
        try MiniTest.expectEqual(Heuristics.extractDates(from: "32. Oktober 2026"), [])
        try MiniTest.expectEqual(Heuristics.extractDates(from: "8. Sombertag 2026"), [])
        // extractDate (erstes Vorkommen) funktioniert damit auch
        try MiniTest.expectEqual(Heuristics.extractDate(from: "vom 8. Oktober 2026"), "2026-10-08")
    }

    private static func correspondent() throws {
        let known = ["Allianz", "Allianz SE", "Stadtwerke"]
        try MiniTest.expectEqual(Heuristics.matchCorrespondent(from: "Allianz SE Versicherung", known: known), "Allianz SE")
        try MiniTest.expectEqual(Heuristics.matchCorrespondent(from: "die ALLIANZ meldet sich", known: known), "Allianz")
        try MiniTest.expectEqual(Heuristics.matchCorrespondent(from: "Stadtwerke GmbH", known: known), "Stadtwerke")
        try MiniTest.expectEqual(Heuristics.matchCorrespondent(from: "unbekannter Absender", known: known), nil)
    }

    private static func title() throws {
        try MiniTest.expectEqual(Heuristics.extractTitle(from: "Rechnung Nr. 42\n14.02.2026\nAllianz"), "Rechnung Nr. 42")
        try MiniTest.expectEqual(Heuristics.extractTitle(from: "14.02.2026\nSeite 1\nBrief an den Mieter"), "Brief an den Mieter")
        try MiniTest.expectEqual(Heuristics.extractTitle(from: "14.02.2026\n123"), nil)
        try MiniTest.expectEqual(Heuristics.extractTitle(from: "ab"), nil)
    }

    private static func category() throws {
        try MiniTest.expectEqual(Heuristics.suggestCategory(from: "Bitte die Rechnung bezahlen"), "Rechnungen")
        try MiniTest.expectEqual(Heuristics.suggestCategory(from: "Mietvertrag 2026 unterschrieben"), "Mieten")
        try MiniTest.expectEqual(Heuristics.suggestCategory(from: "Hallo Welt"), nil)
    }

    private static func combined() throws {
        let s = Heuristics.suggest(from: "Allianz Versicherung\nPolicennummer 123\nvom 14.02.2026", knownCorrespondents: ["Allianz"])
        try MiniTest.expectEqual(s.title, "Allianz Versicherung")
        try MiniTest.expectEqual(s.documentDate, "2026-02-14")
        try MiniTest.expectEqual(s.correspondentName, "Allianz")
        try MiniTest.expectEqual(s.categoryName, "Versicherungen")
    }
}
