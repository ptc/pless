import SwiftUI
import AppKit
import PlessCore

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } content: {
            DocumentListView()
        } detail: {
            DetailView()
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    if let p = state.ocrProgress {
                        ProgressView().scaleEffect(0.7)
                        Text(p).font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("Suchen…", text: Binding(
                        get: { state.searchText },
                        set: { state.searchText = $0; state.refresh() }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
            }
        }
        .alert("Hinweis", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } })) {
            Button("OK") { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        List(selection: Binding(
            get: { state.sidebarSelection },
            set: { state.sidebarSelection = $0 ?? .all })) {
            Section("Bibliothek") {
                Label("Alle Dokumente", systemImage: "tray.full").tag(SidebarSelection.all)
                Label("OCR ausstehend", systemImage: "doc.text.magnifyingglass").tag(SidebarSelection.pendingOCR)
            }
            if let db = state.db {
                let cats = (try? db.categories()) ?? []
                if !cats.isEmpty {
                    Section("Kategorien") {
                        ForEach(cats, id: \.id) {
                            Label($0.name, systemImage: "folder").tag(SidebarSelection.category($0.name))
                        }
                    }
                }
                let tags = (try? db.tags()) ?? []
                if !tags.isEmpty {
                    Section("Tags") {
                        ForEach(tags, id: \.id) {
                            Label($0.name, systemImage: "tag").tag(SidebarSelection.tag($0.name))
                        }
                    }
                }
                let corrs = (try? db.correspondents()) ?? []
                if !corrs.isEmpty {
                    Section("Korrespondenten") {
                        ForEach(corrs, id: \.id) {
                            Label($0.name, systemImage: "person").tag(SidebarSelection.correspondent($0.name))
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: state.sidebarSelection) { _ in state.refresh() }
    }
}

struct DocumentListView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        List(selection: Binding(get: { state.selection }, set: { state.selection = $0 })) {
            ForEach(state.hits, id: \.document.id) { hit in
                DocumentRow(hit: hit).tag(hit.document.id)
            }
        }
    }
}

struct DocumentRow: View {
    @EnvironmentObject var state: AppState
    let hit: SearchHit

    var body: some View {
        let doc = hit.document
        HStack(spacing: 10) {
            if let vault = state.vault {
                ThumbnailView(doc: doc, vault: vault)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.title ?? doc.filename).lineLimit(1)
                HStack(spacing: 6) {
                    let corr = state.nameOfCorrespondent(doc.correspondentId)
                    if !corr.isEmpty { Text(corr) }
                    if let d = doc.documentDate { Text(d) }
                    if doc.needsReview && !doc.ocrDone {
                        Label("OCR", systemImage: "doc.text.magnifyingglass")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
