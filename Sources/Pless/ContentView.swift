import SwiftUI
import AppKit
import UniformTypeIdentifiers
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
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            state.dropFiles(providers)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    if state.isEditing {
                        Button { state.saveEditing() } label: { Image(systemName: "checkmark.circle.fill") }
                            .help("Fertig — speichern (Datei wird ggf. umbenannt)")
                        Button { state.cancelEditing() } label: { Image(systemName: "xmark.circle") }
                            .help("Abbrechen")
                    } else {
                        Button { state.beginEditing() } label: { Image(systemName: "pencil") }
                            .help("Bearbeiten")
                            .disabled(state.selection == nil)
                    }
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

struct DocumentListView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        List(selection: Binding(get: { state.selection }, set: { state.selection = $0 })) {
            ForEach(state.hits, id: \.document.id) { hit in
                DocumentRow(hit: hit).tag(hit.document.id)
            }
        }
        .overlay {
            if state.hits.isEmpty {
                ContentUnavailableView {
                    Label(state.searchText.isEmpty ? "Keine Dokumente" : "Keine Treffer",
                          systemImage: state.searchText.isEmpty ? "doc.text" : "magnifyingglass")
                } description: {
                    Text(state.searchText.isEmpty
                         ? "PDFs per Drag & Drop, über „Ablage > Importieren…“ oder über den Import-Ordner in den Vault legen."
                         : "Die Suche „\(state.searchText)“ hat nichts gefunden — Filter in der Sidebar prüfen.")
                }
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
