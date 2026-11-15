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

@MainActor
final class AppState: ObservableObject {
    @Published var hits: [SearchHit] = []
    @Published var selection: Int64?
    @Published var searchText: String = ""
    @Published var sidebarSelection: SidebarSelection = .all
    @Published var errorMessage: String?
    @Published var ocrProgress: String?

    private(set) var vault: Vault?
    private(set) var db: Database?
    private(set) var ingest: IngestService?
    private(set) var ocr: OCRService?

    let vaultPath: URL

    init(vaultPath: URL) {
        self.vaultPath = vaultPath
        do {
            let v = try Vault(root: vaultPath)
            let database = try Database(url: v.databaseURL)
            vault = v
            db = database
            ingest = IngestService(vault: v, db: database)
            ocr = OCRService(vault: v, db: database, recognizer: VisionTextRecognizer())
            refresh()
        } catch {
            errorMessage = "Vault konnte nicht geöffnet werden: \(error)"
        }
    }

    func refresh() {
        guard let db else { return }
        do {
            hits = try db.search(currentFilter())
            if let sel = selection, !hits.contains(where: { $0.document.id == sel }) {
                selection = hits.first?.document.id
            }
        } catch {
            errorMessage = "Suche fehlgeschlagen: \(error)"
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

    func importFiles(_ urls: [URL]) {
        guard let vault, let ingest else { return }
        for url in urls {
            do {
                let staged = try vault.stageIntoInbox(fileAt: url)
                _ = try ingest.process(fileAt: staged)
            } catch {
                errorMessage = "Import fehlgeschlagen (\(url.lastPathComponent)): \(error)"
            }
        }
        runOCR()
        refresh()
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

    func nameOfCorrespondent(_ id: Int64?) -> String {
        guard let id, let db else { return "" }
        return (try? db.correspondents().first { $0.id == id }?.name) ?? ""
    }

    func nameOfCategory(_ id: Int64?) -> String {
        guard let id, let db else { return "" }
        return (try? db.categories().first { $0.id == id }?.name) ?? ""
    }

    func tagsOf(_ doc: Document) -> [Tag] {
        guard let db, let id = doc.id else { return [] }
        return (try? db.tags(for: id)) ?? []
    }
}
