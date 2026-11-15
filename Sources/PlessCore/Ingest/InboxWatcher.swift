import Foundation

/// Beobachtet `<vault>/inbox` per DispatchSource und meldet neue PDF-Dateien (onNewFile).
/// `_abgelehnt/` wird ignoriert. Events werden 0,5 s entprellt, damit halb kopierte
/// Dateien nicht durchrutschen; bereits gemeldete Dateien werden nicht doppelt gemeldet.
public final class InboxWatcher: @unchecked Sendable {
    public let vault: Vault
    public let onNewFile: @Sendable (URL) -> Void

    private let queue = DispatchQueue(label: "dev.pless.inboxwatch")
    private var source: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var reported = Set<String>()

    public init(vault: Vault, onNewFile: @escaping @Sendable (URL) -> Void) {
        self.vault = vault
        self.onNewFile = onNewFile
    }

    public func start() throws {
        let fd = open(vault.inboxURL.path, O_EVTONLY)
        guard fd >= 0 else {
            throw PlessError.io("inbox nicht beobachtbar: \(vault.inboxURL.path)")
        }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: queue)
        src.setEventHandler { [weak self] in self?.scheduleScan() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    public func stop() {
        source?.cancel()
        source = nil
        timer?.cancel()
        timer = nil
    }

    deinit { stop() }

    /// Manuelles Scannen (z. B. nach dem Start, für Tests): meldet alle neuen PDFs in inbox/.
    public func scan() {
        queue.async { self.scanNow() }
    }

    private func scheduleScan() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5)
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
