import Foundation

/// Beobachtet `<vault>/inbox` per DispatchSource und meldet neue PDF-Dateien (onNewFile).
/// `_abgelehnt/` wird ignoriert. Events werden 0,5 s entprellt, damit halb kopierte
/// Dateien nicht durchrutschen; bereits gemeldete Dateien werden nicht doppelt gemeldet.
public final class InboxWatcher: @unchecked Sendable {
    public let vault: Vault
    public let onNewFile: @Sendable (URL) -> Void
    /// Poll-Intervall als Fallback, falls kqueue-Events verpasst werden (z. B. Rename per Finder).
    public let pollInterval: TimeInterval

    private let queue = DispatchQueue(label: "dev.pless.inboxwatch")
    private var source: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var poll: DispatchSourceTimer?
    private var reported = Set<String>()

    public init(vault: Vault, onNewFile: @escaping @Sendable (URL) -> Void, pollInterval: TimeInterval = 2.0) {
        self.vault = vault
        self.onNewFile = onNewFile
        self.pollInterval = pollInterval
    }

    public func start() throws {
        // Poll IMMER starten — auch wenn das kqueue-Handle nicht aufgeht, bleibt nichts liegen.
        startPolling()
        let fd = open(vault.inboxURL.path, O_EVTONLY)
        guard fd >= 0 else { return } // Poll allein reicht als Fallback
        // write/delete/rename: deckt direktes Schreiben UND temp+rename (Finder) ab
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                            eventMask: [.write, .delete, .rename], queue: queue)
        src.setEventHandler { [weak self] in self?.scheduleScan() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func startPolling() {
        poll?.cancel()
        let p = DispatchSource.makeTimerSource(queue: queue)
        p.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        p.setEventHandler { [weak self] in self?.scanNow() }
        p.resume()
        poll = p
    }

    public func stop() {
        source?.cancel()
        source = nil
        timer?.cancel()
        timer = nil
        poll?.cancel()
        poll = nil
    }

    deinit { stop() }

    /// Manuelles Scannen (z. B. nach dem Start, für Tests): meldet alle neuen PDFs in inbox/.
    public func scan() {
        queue.async { self.scanNow() }
    }

    private func scheduleScan() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.3)
        t.setEventHandler { [weak self] in self?.scanNow() }
        t.resume()
        timer = t
    }

    private func scanNow() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: vault.inboxURL.path) else { return }
        let pdfs = entries.filter { $0.lowercased().hasSuffix(".pdf") }.sorted()
        reported.formIntersection(pdfs) // gemeldete, inzwischen verschobene Dateien vergessen
        for name in pdfs where !reported.contains(name) {
            let url = vault.inboxURL.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            reported.insert(name)
            onNewFile(url)
        }
    }
}
