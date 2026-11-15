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
    @Published var ocrProgress: String?
    @Published var categories: [PlessCore.Category] = []
    @Published var tags: [Tag] = []
    @Published var correspondents: [Correspondent] = []
    @Published var isEditing = false
    @Published var draft: MetadataDraft?
    @Published var inboxCount = 0
    @Published var statusMessage: String?

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
            watcher = InboxWatcher(vault: v) { [weak self] url in
                Task { @MainActor in self?.ingestInboxFile(url) }
            }
            try? watcher?.start()
            watcher?.scan() // bereits liegende Dateien nach Start aufgreifen
            refresh()
        } catch {
            errorMessage = "Vault konnte nicht geöffnet werden: \(error)"
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
        } catch {
            errorMessage = "Aktualisieren fehlgeschlagen: \(error)"
        }
        updateInboxCount()
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
        // Schweres (SHA-256, PDFKit) nicht auf dem Main-Thread — sonst friert die UI.
        DispatchQueue.global(qos: .userInitiated).async {
            var failures: [String] = []
            var importedIds: [Int64] = []
            for url in urls {
                do {
                    let staged = try vault.stageIntoInbox(fileAt: url)
                    if case .imported(let doc) = try ingest.process(fileAt: staged), let id = doc.id {
                        importedIds.append(id)
                    }
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            Task { @MainActor in
                if !failures.isEmpty {
                    self.errorMessage = "Import fehlgeschlagen — \(failures.joined(separator: "; "))"
                }
                self.statusMessage = failures.isEmpty ? "\(importedIds.count) Dokument(e) importiert" : nil
                self.runOCR()
                self.refresh()
                if let last = importedIds.last { self.selection = last } // neues Dokument direkt anzeigen
            }
        }
    }

    /// Datei liegt bereits in inbox/ (Watcher) → direkt in die Pipeline (asynchron).
    func ingestInboxFile(_ url: URL) {
        guard let ingest, FileManager.default.fileExists(atPath: url.path) else { return }
        statusMessage = "Importiere \(url.lastPathComponent)…"
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
                    self.errorMessage = "Import aus Posteingang fehlgeschlagen — \(failure)"
                }
                self.statusMessage = nil
                self.runOCR()
                self.refresh()
                if case .imported(let doc)? = outcome, let id = doc.id { self.selection = id }
            }
        }
    }

    /// Drag & Drop: file-URL-Provider asynchron auflösen (nie group.wait() auf dem Main-Thread —
    /// sonst Deadlock, wenn die Callbacks über den Main-Runloop kommen) und als Import behandeln.
    @discardableResult
    func dropFiles(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier("public.file-url") }
        guard !fileProviders.isEmpty else { return false }
        let sink = URLSink()
        let group = DispatchGroup()
        for p in fileProviders {
            group.enter()
            p.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                if let url = item as? URL { sink.add(url) }
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
        guard let ocr else { return }
        ocr.processPendingAsync(onProgress: { done, total in
            Task { @MainActor in self.ocrProgress = "OCR \(done)/\(total)" }
        }, completion: { result in
            Task { @MainActor in
                self.ocrProgress = nil
                if case .failure(let e) = result { self.errorMessage = "OCR fehlgeschlagen: \(e)" }
                self.refresh()
            }
        })
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
