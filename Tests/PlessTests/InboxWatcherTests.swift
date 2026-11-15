import Foundation
import MiniTest
import PlessCore

enum InboxWatcherTests {
    static func register() {
        MiniTest.test("InboxWatcher: meldet neue PDF in inbox/") { try watcherFires() }
        MiniTest.test("InboxWatcher: _abgelehnt/ wird ignoriert") { try rejectedIgnored() }
        MiniTest.test("InboxWatcher: stop() beendet die Meldungen") { try stopWorks() }
        MiniTest.test("InboxWatcher: scan() meldet vorhandene PDFs genau einmal") { try scanOnce() }
        MiniTest.test("InboxWatcher: Rename in die Inbox (Finder: temp + umbenennen) wird erkannt") { try renameDetected() }
    }

    private static func makeVault() throws -> (vault: Vault, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pless-watch-\(UUID().uuidString)", isDirectory: true)
        return (try Vault(root: root), root)
    }

    /// Wartet bis `cond` wahr ist (max. timeout Sekunden). Liefert false bei Timeout.
    private static func waitFor(_ timeout: TimeInterval = 4, _ cond: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return cond()
    }

    private static func writeDummyPDF(_ name: String, into dir: URL) throws {
        try PDFFixture.writePDF(text: "Watcher-Test \(name)", to: dir.appendingPathComponent(name))
    }

    private static func watcherFires() throws {
        let (vault, root) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let got = URLBox()
        let watcher = InboxWatcher(vault: vault) { url in got.append(url) }
        try watcher.start()
        defer { watcher.stop() }

        try writeDummyPDF("neu.pdf", into: vault.inboxURL)
        let ok = waitFor { !got.value.isEmpty }
        try MiniTest.expect(ok, "Watcher hat nicht gefeuert")
        try MiniTest.expect(got.value.contains { $0.lastPathComponent == "neu.pdf" }, "neu.pdf gemeldet")
    }

    private static func rejectedIgnored() throws {
        let (vault, root) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let got = URLBox()
        let watcher = InboxWatcher(vault: vault) { url in got.append(url) }
        try watcher.start()
        defer { watcher.stop() }

        try writeDummyPDF("dup.pdf", into: vault.rejectedURL)
        let fired = waitFor(1.5) { !got.value.isEmpty }
        try MiniTest.expect(!fired, "_abgelehnt/ darf nicht gemeldet werden")
    }

    private static func stopWorks() throws {
        let (vault, root) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let got = URLBox()
        let watcher = InboxWatcher(vault: vault) { url in got.append(url) }
        try watcher.start()
        watcher.stop()
        try writeDummyPDF("nach-stop.pdf", into: vault.inboxURL)
        let fired = waitFor(1.5) { !got.value.isEmpty }
        try MiniTest.expect(!fired, "nach stop() darf nichts mehr gemeldet werden")
    }

    private static func renameDetected() throws {
        let (vault, root) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let got = URLBox()
        let watcher = InboxWatcher(vault: vault, pollInterval: 0.2) { url in got.append(url) }
        try watcher.start()
        defer { watcher.stop() }

        // Finder-style: erst Temp-Datei in die Inbox, dann per Rename auf .pdf umbenennen
        try PDFFixture.writePDF(text: "Rename-Test", to: vault.inboxURL.appendingPathComponent(".tmp-partial"))
        try FileManager.default.moveItem(at: vault.inboxURL.appendingPathComponent(".tmp-partial"),
                                         to: vault.inboxURL.appendingPathComponent("neu.pdf"))
        let ok = waitFor(4) { got.value.contains { $0.lastPathComponent == "neu.pdf" } }
        try MiniTest.expect(ok, "Rename nicht erkannt: \(got.value.map { $0.lastPathComponent })")
    }

    private static func scanOnce() throws {
        let (vault, root) = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeDummyPDF("a.pdf", into: vault.inboxURL)
        try writeDummyPDF("b.pdf", into: vault.inboxURL)
        try writeDummyPDF("c.txt", into: vault.inboxURL) // keine PDF → ignorieren

        let got = URLBox()
        let watcher = InboxWatcher(vault: vault) { url in got.append(url) }
        watcher.scan()
        let ok = waitFor { got.value.count >= 2 }
        try MiniTest.expect(ok, "scan() meldet vorhandene PDFs")
        try MiniTest.expect(got.value.allSatisfy { $0.lastPathComponent.hasSuffix(".pdf") }, "nur PDFs")
        // zweiter scan ohne neue Datei: keine Doppelmeldung
        watcher.scan()
        _ = waitFor(0.5) { got.value.count >= 3 }
        try MiniTest.expect(got.value.count == 2, "keine Doppelmeldung: \(got.value.count)")
    }
}

/// Thread-sichere URL-Sammlung für Watcher-Callbacks (laufen auf Hintergrund-Queue).
private final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    var value: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    func append(_ url: URL) { lock.lock(); defer { lock.unlock() }; urls.append(url) }
}
