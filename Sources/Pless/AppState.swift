import Foundation
import Combine
import PlessCore

enum SidebarSelection: Hashable {
    case all
    case pendingOCR
    case category(String)
    case correspondent(String)
    case tag(String)
}

/// Zustand der Statusleiste — die App sieht nie „kaputt“ aus, sondern zeigt immer, was läuft.
enum StatusKind { case idle, busy, ok, warning, error }

/// Formular-Entwurf für den Edit-Modus (Phase 7).
@MainActor
final class MetadataDraft: ObservableObject {
    @Published var title = ""
    @Published var date = ""              // yyyy-MM-dd
    @Published var correspondentId: Int64?
    @Published var categoryId: Int64?
    @Published var notes = ""
    @Published var tagNames: [String] = []
}

@MainActor
final class AppState: ObservableObject {
    @Published var hits: [SearchHit] = []
    @Published var selection: Int64?
    @Published var searchText: String = ""
    @Published var sidebarSelection: SidebarSelection = .all
    @Published var errorMessage: String?
    @Published var statusKind: StatusKind = .idle
    @Published var statusText = "Bereit"
    @Published var categories: [PlessCore.Category] = []
    @Published var tags: [Tag] = []
    @Published var correspondents: [Correspondent] = []
    @Published var isEditing = false
    @Published var draft: MetadataDraft?
    @Published var inboxCount = 0
    @Published var ocrRunning = false
    private var ocrCancelled = false

    private(set) var vault: Vault?
    private(set) var db: Database?
    private(set) var ingest: IngestService?
    private(set) var ocr: OCRService?
    private(set) var metadata: MetadataService?
    private var watcher: InboxWatcher?

    let vaultPath: URL
    let settings: SettingsStore
    @Published var showSettings = false

    init(vaultPath: URL, settings: SettingsStore) {
        self.vaultPath = vaultPath
        self.settings = settings
        do {
            let v = try Vault(root: vaultPath, inboxOverride: settings.inboxOverride())
            let database = try Database(url: v.databaseURL)
            vault = v
            db = database
            ingest = IngestService(vault: v, db: database)
            metadata = MetadataService(vault: v, db: database, template: settings.namingTemplate)
            let langs = Array(settings.ocrLanguages).sorted()
            ocr = OCRService(vault: v, db: database,
                             recognizer: VisionTextRecognizer(languages: langs.isEmpty ? ["de-DE", "en-US"] : langs),
                             metadata: metadata)
            // Crash-Recovery vor dem Watcher: DB und Dateisystem abgleichen, damit keine
            // Datei verloren geht, wenn die App mitten im Import abstürzt.
            let recovery = try? RecoveryService(vault: v, db: database).recover()
            // Veraltete Thumbnails (z. B. nach Orientierungs-Fix) einmalig löschen —
            // werden beim Anzeigen on demand mit korrekter Orientierung neu gerendert.
            let removedThumbs = v.invalidateThumbnailsIfOutdated()
            watcher = InboxWatcher(vault: v) { [weak self] url in
                Task { @MainActor in self?.ingestInboxFile(url) }
            }
            try? watcher?.start()
            watcher?.scan() // bereits liegende Dateien nach Start aufgreifen
            refresh()
            setStatus(.idle, idleText)
            if let r = recovery, r.total > 0 {
                setStatus(.warning, "Wiederherstellung: \(r.finalized) Dokument(e) finalisiert, \(r.relocated) Pfad(e) korrigiert, \(r.adopted) Datei(en) aus documents/ in den Posteingang übernommen")
            } else if removedThumbs > 0 {
                setStatus(.ok, "\(removedThumbs) alte Thumbnail(s) entfernt — werden mit korrekter Orientierung neu gerendert", autoIdleAfter: 8)
            }
        } catch {
            errorMessage = "Vault konnte nicht geöffnet werden: \(error)"
            setStatus(.error, "Vault konnte nicht geöffnet werden: \(error)")
        }
    }

    deinit {
        watcher?.stop()
    }

    func refresh() {
        guard let db else { return }
        do {
            hits = try db.search(currentFilter())
            categories = try db.categories()
            tags = try db.tags()
            correspondents = try db.correspondents()
            if let sel = selection, !hits.contains(where: { $0.document.id == sel }) {
                selection = hits.first?.document.id
            }
            if selection == nil { selection = hits.first?.document.id } // erstes Dokument vorselektieren
        } catch {
            errorMessage = "Aktualisieren fehlgeschlagen: \(error)"
        }
        updateInboxCount()
        if statusKind == .idle { statusText = idleText }
    }

    var idleText: String { "Bereit — \(hits.count) Dokument(e) im Vault · Posteingang: \(inboxCount)" }

    /// Status setzen; bei `.ok` optional nach `seconds` automatisch zurück auf „Bereit“.
    func setStatus(_ kind: StatusKind, _ text: String, autoIdleAfter seconds: TimeInterval? = nil) {
        statusKind = kind
        statusText = text
        if let seconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self, self.statusKind == .ok else { return }
                self.setStatus(.idle, self.idleText)
            }
        }
    }

    /// Anzahl der PDFs, die aktuell im Posteingang liegen (Badge in der Sidebar).
    func updateInboxCount() {
        guard let vault else { return }
        inboxCount = (try? FileManager.default.contentsOfDirectory(atPath: vault.inboxURL.path))?
            .filter { $0.lowercased().hasSuffix(".pdf") }.count ?? 0
    }

    /// Manuelles Scannen des Posteingangs (Menü/Sidebar).
    func scanInbox() {
        watcher?.scan()
        updateInboxCount()
    }

    /// Führt eine schreibende Aktion aus, fängt Fehler als Alert ab und aktualisiert die UI.
    func run(_ body: () throws -> Void) {
        do {
            try body()
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func currentFilter() -> SearchFilter {
        var f = SearchFilter(query: searchText.isEmpty ? nil : searchText, limit: 500)
        switch sidebarSelection {
        case .all: break
        case .pendingOCR: f.onlyNeedsReview = true
        case .category(let name): f.category = name
        case .correspondent(let name): f.correspondent = name
        case .tag(let name): f.tag = name
        }
        return f
    }

    // MARK: - Import & OCR

    func importFiles(_ urls: [URL]) {
        guard let vault, let ingest else { return }
        setStatus(.busy, urls.count == 1
                ? "Importiere \(urls[0].lastPathComponent)…"
                : "Importiere \(urls.count) Dateien…")
        // Schweres (SHA-256, PDFKit) nicht auf dem Main-Thread — sonst friert die UI.
        DispatchQueue.global(qos: .userInitiated).async {
            var failures: [String] = []
            var duplicates: [Document] = []
            var importedIds: [Int64] = []
            var lastDoc: Document?
            for (i, url) in urls.enumerated() {
                Task { @MainActor in
                    self.setStatus(.busy, "Importiere \(i + 1)/\(urls.count): \(url.lastPathComponent)…")
                }
                do {
                    let staged = try vault.stageIntoInbox(fileAt: url)
                    switch try ingest.process(fileAt: staged) {
                    case .imported(let doc):
                        if let id = doc.id { importedIds.append(id) }
                        lastDoc = doc
                    case .duplicate(let existing):
                        duplicates.append(existing)
                    case .rejected(let reason):
                        failures.append("\(url.lastPathComponent): \(reason)")
                    }
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            Task { @MainActor in
                if !failures.isEmpty {
                    self.setStatus(.error, "Import fehlgeschlagen — \(failures.joined(separator: "; "))")
                    self.errorMessage = "Import fehlgeschlagen — \(failures.joined(separator: "; "))"
                } else if let dup = duplicates.last {
                    var text = "Duplikat: „\(dup.title ?? dup.filename)“ ist bereits im Vault"
                    if let doc = lastDoc { text = "Importiert: \(doc.title ?? doc.filename) · " + text }
                    text += " — nicht erneut importiert (Datei → _abgelehnt/)"
                    self.setStatus(.warning, text)
                } else if let doc = lastDoc {
                    self.setStatus(.ok, "Importiert: \(doc.title ?? doc.filename) → \(doc.relativePath)", autoIdleAfter: 6)
                }
                self.runOCR()
                self.refresh()
                if let last = importedIds.last { self.selection = last } // neues Dokument direkt anzeigen
                else if let dup = duplicates.last, let id = dup.id { self.selection = id } // nur Duplikat: vorhandenes Dokument zeigen
            }
        }
    }

    /// Datei liegt bereits in inbox/ (Watcher) → direkt in die Pipeline (asynchron).
    func ingestInboxFile(_ url: URL) {
        guard let ingest, FileManager.default.fileExists(atPath: url.path) else { return }
        setStatus(.busy, "Posteingang: \(url.lastPathComponent) erkannt — importiere…")
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            var outcome: IngestOutcome?
            do {
                outcome = try ingest.process(fileAt: url)
            } catch {
                failure = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
            Task { @MainActor in
                if let failure {
                    self.setStatus(.error, "Import aus Posteingang fehlgeschlagen — \(failure)")
                    self.errorMessage = "Import aus Posteingang fehlgeschlagen — \(failure)"
                } else if case .imported(let doc) = outcome {
                    self.setStatus(.ok, "Importiert: \(doc.title ?? doc.filename) → \(doc.relativePath)", autoIdleAfter: 6)
                    if let id = doc.id { self.selection = id }
                } else if case .duplicate(let existing) = outcome {
                    self.setStatus(.warning, "Posteingang: Duplikat „\(existing.title ?? existing.filename)“ bereits im Vault — Datei → _abgelehnt/")
                    if let id = existing.id { self.selection = id } // vorhandenes Dokument in der Liste markieren
                } else if case .rejected(let reason) = outcome {
                    self.setStatus(.error, "Posteingang: \(url.lastPathComponent) zurückgewiesen (\(reason)) — Datei → _abgelehnt/")
                }
                self.runOCR()
                self.refresh()
            }
        }
    }

    /// Drag & Drop: file-URL-Provider asynchron auflösen (nie group.wait() auf dem Main-Thread —
    /// sonst Deadlock, wenn die Callbacks über den Main-Runloop kommen) und als Import behandeln.
    @discardableResult
    func dropFiles(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !fileProviders.isEmpty else { return false }
        let sink = URLSink()
        let group = DispatchGroup()
        for p in fileProviders {
            group.enter()
            // loadObject(ofClass:) — loadItem(forTypeIdentifier:) ist ab macOS 27 deprecated
            p.loadObject(ofClass: URL.self) { url, _ in
                if let url { sink.add(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let pdfs = sink.urls.filter { $0.pathExtension.lowercased() == "pdf" }
            if !pdfs.isEmpty { self.importFiles(pdfs) }
        }
        return true
    }

    func runOCR() {
        guard let ocr, !ocr.isRunning else { return }
        ocrRunning = true
        ocr.processPendingAsync(onProgress: { done, total in
            Task { @MainActor in self.setStatus(.busy, "OCR \(done)/\(total)…") }
        }, completion: { result in
            Task { @MainActor in
                self.ocrRunning = false
                switch result {
                case .success(let done):
                    if self.ocrCancelled {
                        self.setStatus(.warning, "OCR abgebrochen (\(done) erledigt) — offen gebliebene Dokumente in der Vorschau manuell starten")
                    }
                case .failure(let e):
                    self.setStatus(.error, "OCR fehlgeschlagen: \(e)")
                    self.errorMessage = "OCR fehlgeschlagen: \(e)"
                }
                self.ocrCancelled = false
                self.refresh()
            }
        })
    }

    /// Bricht den laufenden OCR-Durchlauf ab (Statusleiste „Abbrechen“).
    func cancelOCR() {
        ocrCancelled = true
        ocr?.cancel()
        setStatus(.warning, "OCR wird abgebrochen…")
    }

    /// Startet OCR manuell für ein einzelnes Dokument (Vorschau: „OCR starten“ bei OCR-offen).
    func startOCR(for documentId: Int64) {
        guard let ocr, !ocr.isRunning else { return }
        let title = hits.first { $0.document.id == documentId }?.document.title
        ocrRunning = true
        setStatus(.busy, "OCR läuft für „\(title ?? "Dokument")“…")
        ocr.processAsync(documentId: documentId) { result in
            Task { @MainActor in
                self.ocrRunning = false
                switch result {
                case .success:
                    self.setStatus(.ok, "OCR abgeschlossen: „\(title ?? "Dokument")“ — Text ist indexiert", autoIdleAfter: 6)
                case .failure(let e):
                    self.setStatus(.error, "OCR fehlgeschlagen: \(e)")
                    self.errorMessage = "OCR fehlgeschlagen: \(e)"
                }
                self.refresh()
            }
        }
    }

    // MARK: - Edit-Modus (Phase 7)

    func beginEditing() {
        guard let id = selection,
              let doc = hits.first(where: { $0.document.id == id })?.document,
              let db else { return }
        let d = MetadataDraft()
        d.title = doc.title ?? ""
        d.date = doc.documentDate ?? ""
        d.correspondentId = doc.correspondentId
        d.categoryId = doc.categoryId
        d.notes = doc.notes ?? ""
        d.tagNames = ((try? db.tags(for: id)) ?? []).map { $0.name }
        draft = d
        isEditing = true
    }

    func cancelEditing() {
        isEditing = false
        draft = nil
    }

    /// „Fertig“: Tags synchronisieren, Metadaten speichern (Datei wird ggf. umbenannt), UI aktualisieren.
    func saveEditing() {
        guard let draft, let id = selection, let db, let metadata else { return }
        if !draft.date.isEmpty {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            f.isLenient = false
            guard f.date(from: draft.date) != nil else {
                errorMessage = "Datum ungültig — bitte Format yyyy-MM-dd verwenden"
                return
            }
        }
        do {
            // Tags vor dem Speichern synchronisieren, damit {tags} im Namensschema greift
            let current = (try? db.tags(for: id)) ?? []
            for name in draft.tagNames where !current.contains(where: { $0.name == name }) {
                let tagId = try db.findOrCreateTag(name: name)
                try db.addTagToDocument(documentId: id, tagId: tagId)
            }
            for t in current where !draft.tagNames.contains(t.name) {
                guard let tid = t.id else { continue }
                try db.removeTagFromDocument(documentId: id, tagId: tid)
            }
            _ = try metadata.saveMetadata(
                documentId: id,
                title: draft.title.isEmpty ? nil : draft.title,
                documentDate: draft.date.isEmpty ? nil : draft.date,
                correspondentId: draft.correspondentId,
                categoryId: draft.categoryId,
                notes: draft.notes.isEmpty ? nil : draft.notes)
            isEditing = false
            self.draft = nil
            refresh()
        } catch {
            errorMessage = "Speichern fehlgeschlagen: \(error)"
        }
    }

    // MARK: - Verwaltung: Korrespondenten / Kategorien / Tags

    func addCorrespondent(name: String) { run { try db?.findOrCreateCorrespondent(name: name) } }
    func renameCorrespondent(id: Int64, newName: String) { run { try db?.renameCorrespondent(id: id, newName: newName) } }
    func deleteCorrespondent(id: Int64) { run { try db?.deleteCorrespondent(id: id) } }

    func addCategory(name: String, parentId: Int64? = nil) { run { try db?.findOrCreateCategory(name: name, parentId: parentId) } }
    func updateCategory(id: Int64, name: String, parentId: Int64?, color: String?) {
        run { try db?.updateCategory(id: id, name: name, parentId: parentId, color: color) }
    }
    func deleteCategory(id: Int64) { run { try db?.deleteCategory(id: id) } }

    func addTag(name: String) { run { try db?.findOrCreateTag(name: name) } }
    func updateTag(id: Int64, name: String, color: String?) { run { try db?.updateTag(id: id, name: name, color: color) } }
    func deleteTag(id: Int64) { run { try db?.deleteTag(id: id) } }

    // MARK: - Anzeige-Helfer

    func nameOfCorrespondent(_ id: Int64?) -> String {
        guard let id else { return "" }
        return correspondents.first { $0.id == id }?.name ?? ""
    }

    func nameOfCategory(_ id: Int64?) -> String {
        guard let id else { return "" }
        return categories.first { $0.id == id }?.name ?? ""
    }

    func tagsOf(_ doc: Document) -> [Tag] {
        guard let db, let id = doc.id else { return [] }
        return (try? db.tags(for: id)) ?? []
    }
}

/// Thread-sicherer Sammler für asynchron aufgelöste Drop-URLs.
private final class URLSink: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [URL] = []
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return collected }
    func add(_ url: URL) { lock.lock(); defer { lock.unlock() }; collected.append(url) }
}
