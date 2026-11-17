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
                    .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 340)
            } content: {
                DocumentListView()
                    .navigationSplitViewColumnWidth(min: 280, ideal: 340)
            } detail: {
                DetailView()
                    .navigationSplitViewColumnWidth(min: 340, ideal: 400, max: 520)
            }
            .navigationSplitViewStyle(.balanced)
            .task {
                // Titelleiste zeigt den aktiven Vault, damit immer klar ist, welcher Ordner beobachtet wird
                if let w = NSApp.windows.first { w.title = "Pless — \(state.vaultPath.path)" }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    // Ein Dropdown-Button mit einem Symbol (Wolke + ein Pfeil): Klick öffnet
                    // das Menü, „Jetzt synchronisieren“ ist der Default-Eintrag (Enter)
                    Menu {
                        Button { state.syncAll() } label: {
                            Label(T("Jetzt synchronisieren"), systemImage: "cloud.arrow.up.fill")
                        }
                        .keyboardShortcut(.defaultAction)
                        Button { state.syncAll(forceMetadata: true) } label: {
                            Label(T("Metadaten aktualisieren"), systemImage: "pencil.circle.fill")
                        }
                        Divider()
                        Button { state.pullFromPaperless() } label: {
                            Label(T("Aus paperless importieren"), systemImage: "tray.and.arrow.down.fill")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if state.syncRunning {
                                ProgressView().controlSize(.small)
                            } else {
                                syncCloudIcon
                            }
                            Text(T("Sync"))
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .disabled(state.syncRunning)
                    .help(state.syncConfigured()
                          ? T("Zu paperless-ngx synchronisieren (Einweg-Push) — Menü: jetzt synchronisieren, Metadaten aktualisieren, Import aus paperless")
                          : T("paperless-URL + API-Token in den Einstellungen (Cmd+,) konfigurieren"))
                }
                ToolbarItem(placement: .primaryAction) {
                    // Bearbeiten/Fertig liegt in der Detail-Vorschau (DetailView-Toolbar)
                    TextField(T("Suchen…"), text: Binding(
                        get: { state.searchText },
                        set: { state.searchText = $0; state.refresh() }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
            }
            .alert(T("Hinweis"), isPresented: Binding(
                get: { state.errorMessage != nil },
                set: { if !$0 { state.errorMessage = nil } })) {
                Button(T("OK")) { state.errorMessage = nil }
            } message: {
                Text(state.errorMessage ?? "")
            }
            if state.selectionSet.count > 1 {
                Divider()
                BulkActionBar()
            }
            Divider()
            StatusBarView()
        }
        // Drop-Ziel fürs GANZE Fenster (nicht nur Liste) — mit sichtbarem Hinweis beim Dragover
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            state.dropFiles(providers)
        }
        .id(state.effectiveLanguage)   // Sprachwechsel → komplettes Re-Render aller T()-Strings
        .overlay {
            if dropTargeted {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.accentColor.opacity(0.15))
                        .padding(10)
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10]))
                        .padding(10)
                    Label(T("PDF hier ablegen zum Importieren"), systemImage: "tray.and.arrow.down.fill")
                        .font(.title2).padding(16)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    /// Sync-Symbol: Wolke + ein Pfeil, selbst komponiert — das SF-Symbol cloud.arrow.up
    /// rendert im Toolbar-Maßstab mit zu dünner Wolke (nur der Pfeil sichtbar).
    private var syncCloudIcon: some View {
        ZStack {
            Image(systemName: "cloud.fill")
                .font(.system(size: 13, weight: .semibold))
            Image(systemName: "arrow.up")
                .font(.system(size: 6, weight: .black))
                .foregroundStyle(Color(nsColor: .controlBackgroundColor))
                .offset(y: 0.5)
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
                Button(T("Abbrechen")) { state.cancelOCR() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .help(T("Laufenden OCR-Durchlauf abbrechen"))
            }
            Spacer()
            Text(TF("%d Dokument(e) · Posteingang: %d", state.hits.count, state.inboxCount))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Bulk-Leiste über der Statusleiste: Kategorie und/oder Tag auf die Mehrfachauswahl setzen.
struct BulkActionBar: View {
    @EnvironmentObject var state: AppState
    @State private var categoryId: Int64?
    @State private var tag = ""

    var body: some View {
        HStack(spacing: 10) {
            Label(TF("%d ausgewählt", state.selectionSet.count), systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.tint)
            Picker(T("Kategorie"), selection: $categoryId) {
                Text(T("Kategorie nicht ändern")).tag(nil as Int64?)
                ForEach(state.categories.filter { $0.id != nil }, id: \.id) { c in
                    Text(c.name).tag(c.id)
                }
            }
            .labelsHidden()
            .frame(width: 190)
            TextField(T("Tag zuweisen…"), text: $tag)
                .textFieldStyle(.roundedBorder)
                .frame(width: 170)
                .onSubmit(apply)
            Button(T("Zuweisen")) { apply() }
                .disabled(categoryId == nil && tag.trimmingCharacters(in: .whitespaces).isEmpty)
                .help(T("Kategorie und/oder Tag auf alle ausgewählten Dokumente setzen"))
            Spacer()
            Button(T("Alle auswählen")) { state.selectAll() }
                .help(T("Alle sichtbaren Dokumente auswählen (Cmd+A)"))
            Button(T("Aufheben")) { state.clearSelection() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func apply() {
        let cleanTag = tag.trimmingCharacters(in: .whitespaces)
        let r = state.bulkAssign(categoryId: categoryId, tagName: cleanTag.isEmpty ? nil : cleanTag)
        if r.failed.isEmpty {
            state.setStatus(.ok, TF("%d Dokument(e) aktualisiert (Kategorie/Tag)", r.ok), autoIdleAfter: 6)
        } else {
            state.setStatus(.error, TF("Bulk: %d ok, %d fehlgeschlagen — %@", r.ok, r.failed.count, r.failed.joined(separator: "; ")))
            state.errorMessage = TF("Bulk-Operation: %@", r.failed.joined(separator: "; "))
        }
        tag = ""
        categoryId = nil
    }
}

/// Dokumentliste als Thumbnail-Gitter, gruppiert nach Jahr/Monat (Datum des Dokuments,
/// Fallback: Importdatum) mit Trenner-Überschrift pro Monat.
struct DocumentListView: View {
    @EnvironmentObject var state: AppState
    /// Sidebar-Drag (Kategorie/Tag) über der Liste aktiv → alle selektierten Karten gestrichelt
    @State private var sidebarDropTargeted = false

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
                            DocumentCard(hit: hit,
                                         selected: hit.document.id.map { state.selectionSet.contains($0) } ?? false,
                                         active: hit.document.id == state.selection,
                                         bulkHighlight: sidebarDropTargeted)
                                .onTapGesture {
                                    guard let id = hit.document.id, !state.isEditing else { return }
                                    let mods = NSEvent.modifierFlags
                                    state.select(id,
                                                 additive: mods.contains(.command),
                                                 range: mods.contains(.shift))
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
        // Kategorie/Tag aus der Sidebar auf die Mehrfachauswahl ziehen (Listenfläche)
        .onDrop(of: [.plainText], isTargeted: $sidebarDropTargeted) { providers in
            guard let first = state.selectionSet.first, let p = providers.first else { return false }
            p.loadObject(ofClass: NSString.self) { obj, _ in
                if let s = (obj as? NSString) as String? {
                    DispatchQueue.main.async { state.dropAssign(s, on: first) }
                }
            }
            return true
        }
        .overlay {
            if state.hits.isEmpty {
                ContentUnavailableView {
                    Label(state.searchText.isEmpty ? "Keine Dokumente" : "Keine Treffer",
                          systemImage: state.searchText.isEmpty ? "doc.text" : "magnifyingglass")
                } description: {
                    Text(state.searchText.isEmpty
                         ? TF("PDFs per Drag & Drop, über „Ablage > Importieren…“ oder in den Posteingang legen: %@", state.vault?.inboxURL.path ?? "<Vault>/inbox")
                         : TF("Die Suche „%@“ hat nichts gefunden — Filter in der Sidebar prüfen.", state.searchText))
                }
            }
        }
    }
}

/// Wolken-Symbol für den persistierten Sync-Stand (Phase 13): synced / not synced / unknown.
enum SyncCloudBadge {
    static func symbol(_ state: SyncState) -> String {
        switch state {
        case .synced: return T("cloud.fill")
        case .notSynced, .unknown: return T("cloud")   // unknown bekommt zusätzlich ein „?“ (s. icon)
        }
    }

    /// Symbol-View: `cloud.questionmark` existiert nicht in jedem SF-Symbols-Katalog →
    /// unknown wird als Wolke mit überlagertem „?“ gezeichnet (rendert garantiert).
    static func icon(_ state: SyncState) -> some View {
        ZStack {
            Image(systemName: symbol(state))
            if state == .unknown {
                Text(T("?")).font(.system(size: 8, weight: .bold))
            }
        }
    }

    static func color(_ state: SyncState) -> Color {
        switch state {
        case .synced: return .green
        case .notSynced: return .orange
        case .unknown: return .secondary
        }
    }

    static func help(_ state: SyncState) -> String {
        switch state {
        case .synced: return T("Synchronisiert mit paperless-ngx")
        case .notSynced: return T("Noch nicht synchronisiert — Push über „Sync“ in der Toolbar")
        case .unknown: return T("Sync-Stand unbekannt (paperless-ngx nicht konfiguriert oder nie gelaufen)")
        }
    }
}

struct DocumentCard: View {
    @EnvironmentObject var state: AppState
    let hit: SearchHit
    let selected: Bool
    /// Aktiv = wird gerade rechts in der Detailansicht angezeigt → stärkere Markierung
    var active: Bool = false
    /// Sidebar-Drag über der Liste → alle selektierten Karten zeigen den gestrichelten Rahmen
    var bulkHighlight: Bool = false
    @State private var dropTargeted = false

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
                    Label(T("OCR"), systemImage: "doc.text.magnifyingglass")
                        .font(.caption2).padding(4)
                        .background(.orange.opacity(0.9), in: Capsule())
                        .foregroundStyle(.white).padding(4)
                }
            }
            Text(doc.title ?? doc.filename).font(.caption).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                // farbiges Kategorie-Tag (jede Kategorie hat ihre eigene Farbe)
                if let cat = state.categories.first(where: { $0.id == doc.categoryId }) {
                    Text(cat.name)
                        .font(.caption2)
                        .foregroundStyle(Color(hex: cat.color)?.isLight == true ? .black : .white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color(hex: cat.color) ?? .accentColor))
                }
                let corr = state.nameOfCorrespondent(doc.correspondentId)
                if !corr.isEmpty { Text(corr) }
                if let d = doc.documentDate { Text(state.displayDate(d)) }
            }
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(8)
        .background(active
                    ? Color.accentColor.opacity(0.10)
                    : Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(active ? Color.accentColor : (selected ? Color.accentColor.opacity(0.7) : Color.clear),
                        lineWidth: active ? 3 : 2.5)
        }
        .overlay(alignment: .topTrailing) {
            // Sync-Wolke in der oberen rechten Ecke der Karte (im weißen Rand, nicht auf dem Dokument):
            // gefüllt grün = synced, Umriss orange = not synced, grau mit ? = unknown
            let syncState = state.effectiveSyncState(doc)
            SyncCloudBadge.icon(syncState)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SyncCloudBadge.color(syncState))
                .padding(3)
                .help(SyncCloudBadge.help(syncState))
        }
        .overlay {
            // aktives Element: Akzent-Häkchen oben links
            if active {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                    .font(.caption)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(4)
            }
        }
        // Kategorie/Tag aus der Sidebar auf diese Karte ziehen → Zuweisung (Mehrfachauswahl,
        // wenn die Karte selektiert ist, sonst nur diese Karte)
        .onDrop(of: [.plainText], isTargeted: $dropTargeted) { providers in
            guard let id = doc.id, let p = providers.first else { return false }
            p.loadObject(ofClass: NSString.self) { obj, _ in
                if let s = (obj as? NSString) as String? {
                    DispatchQueue.main.async { state.dropAssign(s, on: id) }
                }
            }
            return true
        }
        .overlay {
            if dropTargeted || (bulkHighlight && selected) {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
            }
        }
        .contentShape(Rectangle())
    }
}
