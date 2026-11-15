import Foundation
import MiniTest
import PlessCore

enum ProbeTests {
    static func register() {
        MiniTest.test("Probe: System-Frameworks verfügbar (crypto, sqlite, pdfkit, vision)") {
            let report = Probe.ok()
            try MiniTest.expect(report.contains("crypto:ok"))
            try MiniTest.expect(report.contains("sqlite:"))
            try MiniTest.expect(report.contains("pdfkit:yes"))
            try MiniTest.expect(report.contains("vision:yes"))
        }
    }
}
