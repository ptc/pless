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
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            Text(state.statusText)
                .font(.caption)
                .foregroundStyle(state.statusKind == .error ? .red
                                : state.statusKind == .warning ? .orange : .secondary)
                .lineLimit(1)
            if state.ocrRunning, state.statusKind == .busy {
                Button("Abbrechen") { state.cancelOCR() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .help("Laufenden OCR-Durchlauf abbrechen")
            }
            Spacer()
            Text("\(state.hits.count) Dokument(e) · Posteingang: \(state.inboxCount)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Dokumentliste als Thumbnail-Gitter, gruppiert nach Jahr/Monat (Datum des Dokuments,
/// Fallback: Importdatum) mit Trenner-Überschrift pro Monat.
struct DocumentListView: View {
    @EnvironmentObject var state: AppState

    /// Gruppierung: key "yyyy-MM" → (key, „Februar 2026“, Treffer), absteigend sortiert.
    private var groups: [(key: String, label: String, hits: [SearchHit])] {
        let df = DateFormatter()
        df.locale = Locale(identifier: "de_DE")
        df.dateFormat = "MMMM yyyy"
        var dict: [String: [SearchHit]] = [:]
        for h in state.hits {
            let d = h.document.documentDate ?? h.document.addedAt
            dict[String(d.prefix(7)), default: []].append(h)
        }
        return dict.keys.sorted(by: >).map { key in
            let parts = key.split(separator: "-")
            var label = key
            if parts.count == 2, let y = Int(parts[0]), let m = Int(parts[1]) {
                var c = DateComponents()
                c.year = y
                c.month = m
                if let date = Calendar.current.date(from: c) { label = df.string(from: date) }
            }
            return (key, label, dict[key] ?? [])
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(groups, id: \.key) { g in
                    Text(g.label)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .padding(.top, g.key == groups.first?.key ? 0 : 8)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 14)], spacing: 14) {
                        ForEach(g.hits, id: \.document.id) { hit in
                            DocumentCard(hit: hit, selected: state.selection == hit.document.id)
                                .onTapGesture {
                                    if let id = hit.document.id { state.selection = id }
                                }
                        }
                    }
                }
            }
            .padding(12)
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

struct DocumentCard: View {
    @EnvironmentObject var state: AppState
    let hit: SearchHit
    let selected: Bool

    var body: some View {
        let doc = hit.document
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                if let vault = state.vault {
                    ThumbnailView(doc: doc, vault: vault, width: nil, height: 170)
                } else {
                    Image(systemName: "doc.text").resizable().aspectRatio(contentMode: .fit)
                        .foregroundStyle(.secondary).frame(height: 170)
                }
                if doc.needsReview && !doc.ocrDone {
                    Label("OCR", systemImage: "doc.text.magnifyingglass")
                        .font(.caption2).padding(4)
                        .background(.orange.opacity(0.9), in: Capsule())
                        .foregroundStyle(.white).padding(4)
                }
            }
            Text(doc.title ?? doc.filename).font(.caption).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                let corr = state.nameOfCorrespondent(doc.correspondentId)
                if !corr.isEmpty { Text(corr) }
                if let d = doc.documentDate { Text(d) }
            }
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2.5)
        }
        .contentShape(Rectangle())
    }
}
