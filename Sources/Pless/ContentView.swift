import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PlessCore

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView()
            } content: {
                DocumentListView()
            } detail: {
                DetailView()
            }
            .navigationSplitViewStyle(.balanced)
            .task {
                // Titelleiste zeigt den aktiven Vault, damit immer klar ist, welcher Ordner beobachtet wird
                if let w = NSApp.windows.first { w.title = "Pless — \(state.vaultPath.path)" }
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
            Divider()
            StatusBarView()
        }
        // Drop-Ziel fürs GANZE Fenster (nicht nur Liste) — mit sichtbarem Hinweis beim Dragover
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            state.dropFiles(providers)
        }
        .overlay {
            if dropTargeted {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.accentColor.opacity(0.15))
                        .padding(10)
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10]))
                        .padding(10)
                    Label("PDF hier ablegen zum Importieren", systemImage: "tray.and.arrow.down.fill")
                        .font(.title2).padding(16)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
}

/// Permanente Statusleiste unten: zeigt jederzeit, was die App tut — nie leer/„kaputt“.
struct StatusBarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 6) {
            switch state.statusKind {
            case .idle:
                Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.secondary)
            case .busy:
                ProgressView().scaleEffect(0.55)
            case .ok:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            Text(state.statusText)
                .font(.caption)
                .foregroundStyle(state.statusKind == .error ? .red : .secondary)
                .lineLimit(1)
            Spacer()
            Text("\(state.hits.count) Dokument(e) · Posteingang: \(state.inboxCount)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(Color(nsColor: .windowBackgroundColor))
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
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            state.dropFiles(providers)
        }
        .overlay {
            if state.hits.isEmpty {
                ContentUnavailableView {
                    Label(state.searchText.isEmpty ? "Keine Dokumente" : "Keine Treffer",
                          systemImage: state.searchText.isEmpty ? "doc.text" : "magnifyingglass")
                } description: {
                    Text(state.searchText.isEmpty
                         ? "PDFs per Drag & Drop, über „Ablage > Importieren…“ oder in den Posteingang legen: \(state.vault?.inboxURL.path ?? "<Vault>/inbox")"
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
