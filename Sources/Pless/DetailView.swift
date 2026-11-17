import SwiftUI
import AppKit
import PDFKit
import PlessCore

/// Anzeigemodus der PDF-Vorschau.
enum PDFMode { case fit, height, full }  // fit = an Fenster, height = volle skalierte Höhe, full = 100 %

struct DetailView: View {
    @EnvironmentObject var state: AppState
    @State private var pdfMode: PDFMode = .height  // Default: ganze skalierte Höhe
    @State private var pdfZoom: CGFloat = 1.0      // nur in .full wirksam (1.0 = 100 %)
    @State private var showOCRText = false          // OCR-Text-Panel (markierbar) erst auf Klick
    @State private var ocrSelection = ""             // aktuell markierter Text im OCR-Panel

    var doc: PlessCore.Document? {
        state.selectedDoc
    }

    var body: some View {
        if let doc, let vault = state.vault {
            VStack(spacing: 0) {
                // Zoom-Leiste: Modus (Anpassen / Höhe / 100 %) + Stufen
                HStack(spacing: 8) {
                    Picker(T("Ansicht"), selection: $pdfMode) {
                        Text(T("Anpassen")).tag(PDFMode.fit)
                        Text(T("Höhe")).tag(PDFMode.height)
                        Text(T("100 %")).tag(PDFMode.full)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)
                    Button {
                        pdfMode = .full
                        pdfZoom = max(0.25, pdfZoom / 1.25)
                    } label: { Image(systemName: "minus.magnifyingglass") }
                    Text(TF("%d %%", Int(pdfZoom * 100))).font(.caption).frame(width: 44)
                    Button {
                        pdfMode = .full
                        pdfZoom = min(8, pdfZoom * 1.25)
                    } label: { Image(systemName: "plus.magnifyingglass") }
                    // OCR als kompaktes Icon-Dropdown (wie Sync in der Toolbar)
                    Menu {
                        Button { if let id = doc.id { state.startOCR(for: id) } } label: {
                            Label(doc.ocrDone ? T("OCR erneut ausführen") : T("OCR starten"),
                                  systemImage: "text.viewfinder")
                        }
                        .disabled(state.ocrRunning)
                        if doc.ocrText != nil {
                            Divider()
                            Button { showOCRText.toggle() } label: {
                                Label(showOCRText ? T("OCR-Text ausblenden") : T("OCR-Text anzeigen"),
                                      systemImage: "text.alignleft")
                            }
                        }
                    } label: {
                        if state.ocrRunning {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "doc.text.viewfinder")
                                .foregroundStyle(doc.ocrDone ? Color.secondary : Color.accentColor)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .help(doc.ocrDone
                          ? T("OCR für dieses Dokument erneut ausführen (z. B. nach Änderung der OCR-Einstellungen) — überschreibt den bisherigen OCR-Text; Metadaten bleiben erhalten. Menü: OCR-Text ein-/ausblenden")
                          : T("OCR für dieses Dokument starten (Status „OCR offen“) — Menü: OCR-Text ein-/ausblenden"))
                    Spacer()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                Divider()
                PDFViewRepresentable(url: vault.root.appendingPathComponent(doc.relativePath),
                                     mode: $pdfMode, zoom: $pdfZoom,
                                     onSelectionAsTitle: { state.setTitleFromText(doc.id, $0) },
                                     onSelectionAsCorrespondent: { state.setCorrespondentFromText(doc.id, $0) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // OCR-Text (bei gescannten PDFs liegt der Text nur in der DB, nicht im PDF selbst)
                // als markierbares, read-only Textfeld — Text kann ausgewählt und kopiert werden.
                if showOCRText, let text = doc.ocrText, !text.isEmpty {
                    Divider()
                    VStack(spacing: 2) {
                        HStack {
                            Text(T("OCR-Text")).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button { showOCRText = false } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help(T("OCR-Text ausblenden"))
                        }
                        .padding(.horizontal, 8)
                        SelectableTextView(text: text, selectedText: $ocrSelection)
                            .padding(.horizontal, 8)
                            .frame(height: 110)
                            .contextMenu {
                                let sel = ocrSelection.trimmingCharacters(in: .whitespacesAndNewlines)
                                Button { state.setTitleFromText(doc.id, ocrSelection) } label: {
                                    Label(T("Als Titel übernehmen"), systemImage: "textformat")
                                }
                                .disabled(sel.isEmpty)
                                Button { state.setCorrespondentFromText(doc.id, ocrSelection) } label: {
                                    Label(T("Als Korrespondent übernehmen"), systemImage: "person")
                                }
                                .disabled(sel.isEmpty)
                            }
                    }
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .windowBackgroundColor))
                }
                Divider()
                if state.isEditing {
                    MetadataEditView(doc: doc)
                        .frame(height: 300)
                } else {
                    MetadataSummary(doc: doc)
                        .frame(height: 230)
                }
            }
        } else {
            ContentUnavailableView(T("Dokument wählen"), systemImage: "doc.text",
                                   description: Text(T("In der Übersicht ein PDF auswählen.")))
        }
    }
}

/// PDFView, das bei Modus „Höhe“ die Skalierung an die View-Höhe koppelt (auch bei Resize).
/// Bietet bei Rechtsklick auf eine Textselektion „Als Titel/Korrespondent übernehmen“ an.
final class ScaledPDFView: PDFView {
    var fitToHeight = false
    var onSelectionAsTitle: ((String) -> Void)?
    var onSelectionAsCorrespondent: ((String) -> Void)?

    override func layout() {
        super.layout()
        if fitToHeight, let page = currentPage ?? document?.page(at: 0) {
            let pageHeight = page.bounds(for: .mediaBox).height
            if pageHeight > 0, bounds.height > 0 {
                scaleFactor = bounds.height / pageHeight
            }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard let sel = currentSelection?.string,
              !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return menu }
        let m = menu ?? NSMenu()
        m.addItem(NSMenuItem.separator())
        let t = NSMenuItem(title: T("Als Titel übernehmen"), action: #selector(useSelectionAsTitle(_:)), keyEquivalent: "")
        t.target = self
        m.addItem(t)
        let c = NSMenuItem(title: T("Als Korrespondent übernehmen"), action: #selector(useSelectionAsCorrespondent(_:)), keyEquivalent: "")
        c.target = self
        m.addItem(c)
        return m
    }

    @objc private func useSelectionAsTitle(_ sender: NSMenuItem) {
        guard let s = currentSelection?.string else { return }
        onSelectionAsTitle?(s)
    }

    @objc private func useSelectionAsCorrespondent(_ sender: NSMenuItem) {
        guard let s = currentSelection?.string else { return }
        onSelectionAsCorrespondent?(s)
    }
}

struct PDFViewRepresentable: NSViewRepresentable {
    let url: URL
    @Binding var mode: PDFMode
    @Binding var zoom: CGFloat
    var onSelectionAsTitle: ((String) -> Void)?
    var onSelectionAsCorrespondent: ((String) -> Void)?

    func makeNSView(context: Context) -> PDFView {
        let v = ScaledPDFView()
        v.document = PDFDocument(url: url)
        v.autoScales = false
        v.fitToHeight = true
        v.onSelectionAsTitle = onSelectionAsTitle
        v.onSelectionAsCorrespondent = onSelectionAsCorrespondent
        return v
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
        }
        guard let v = nsView as? ScaledPDFView else { return }
        v.onSelectionAsTitle = onSelectionAsTitle
        v.onSelectionAsCorrespondent = onSelectionAsCorrespondent
        switch mode {
        case .fit:
            v.fitToHeight = false
            v.autoScales = true
            v.scaleFactor = 1.0
        case .height:
            v.autoScales = false
            v.fitToHeight = true
            if let page = v.currentPage ?? v.document?.page(at: 0) {
                let pageHeight = page.bounds(for: .mediaBox).height
                if pageHeight > 0, v.bounds.height > 0 {
                    v.scaleFactor = v.bounds.height / pageHeight
                }
            }
        case .full:
            v.fitToHeight = false
            v.autoScales = false
            v.scaleFactor = zoom
        }
    }
}

struct ThumbnailView: View {
    let doc: PlessCore.Document
    let vault: Vault
    var width: CGFloat? = 44
    var height: CGFloat = 56
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "doc.text").resizable().aspectRatio(contentMode: .fit)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: height)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task { load() }
    }

    private func load() {
        let thumb = vault.thumbnailsURL.appendingPathComponent("\(doc.uuid).png")
        if let data = try? Data(contentsOf: thumb), let img = NSImage(data: data) {
            image = img
            return
        }
        let pdfURL = vault.root.appendingPathComponent(doc.relativePath)
        Task.detached(priority: .utility) {
            if let png = Thumbnails.pngData(for: pdfURL, width: 120) {
                try? png.write(to: thumb)
                if let img = NSImage(data: png) {
                    await MainActor.run { image = img }
                }
            }
        }
    }
}

/// Read-only Metadaten-Anzeige: Header mit Sync-Pill, Meta als Chips, technische Details eingeklappt.
struct MetadataSummary: View {
    @EnvironmentObject var state: AppState
    let doc: PlessCore.Document

    var body: some View {
        let syncState = state.effectiveSyncState(doc)
        VStack(alignment: .leading, spacing: 10) {
            // Header: Titel + Dateiname; rechts der Sync-Status als Pill
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(doc.title ?? doc.filename)
                        .font(.title3).fontWeight(.semibold).lineLimit(2)
                    Text(doc.filename)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(TF("Im Vault: %@", doc.relativePath))
                }
                Spacer()
                syncPill(syncState)
            }
            // Metadaten als Chips statt technischem Label/Value-Grid
            FlowLayout(spacing: 6) {
                if let cat = state.categories.first(where: { $0.id == doc.categoryId }) {
                    Label(cat.name, systemImage: "folder.fill")
                        .font(.caption).fontWeight(.medium)
                        .foregroundStyle(Color(hex: cat.color)?.isLight == true ? .black : .white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color(hex: cat.color) ?? .accentColor))
                }
                let corr = state.nameOfCorrespondent(doc.correspondentId)
                if !corr.isEmpty { chip(corr, systemImage: "person") }
                if let d = doc.documentDate { chip(state.displayDate(d), systemImage: "calendar") }
                chip(TF("%d Seiten", doc.pageCount), systemImage: "doc.text")
                if doc.ocrDone {
                    chip(T("OCR fertig"), systemImage: "checkmark.circle.fill", color: .green)
                } else {
                    chip(T("OCR offen"), systemImage: "circle.dashed", color: .orange)
                }
            }
            // Technische Details (Pfad, paperless-ID, SHA) eingeklappt statt offener Grid-Zeilen
            DisclosureGroup(content: {
                VStack(alignment: .leading, spacing: 2) {
                    techRow(T("Datei"), doc.filename)
                    techRow(T("Im Vault"), doc.relativePath)
                    if let entry = doc.id.flatMap({ state.syncEntry(for: $0) }) {
                        techRow(T("paperless-ID"), "#\(entry.paperlessId) · \(state.displayDate(String(entry.syncedAt.prefix(10))))")
                    }
                    techRow("SHA-256", String(doc.sha256.prefix(16)) + "…")
                }
                .padding(.top, 2)
            }) {
                Label(T("Details"), systemImage: "info.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            // Korrespondent-Vorschlag aus dem Dokumenttext (bekannter Treffer oder Absender-Firma)
            if let suggestion = state.correspondentSuggestion(for: doc) {
                HStack(spacing: 6) {
                    Label(T("Korrespondent-Vorschlag:"), systemImage: "lightbulb")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(suggestion) {
                        if let id = doc.id { state.applyCorrespondentSuggestion(documentId: id, name: suggestion) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help(T("Diesen Korrespondenten anlegen und dem Dokument zuweisen"))
                }
            }
            let tags = state.tagsOf(doc)
            if !tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(tags, id: \.id) { chip($0.name, systemImage: "tag") }
                }
            }
            // Datums-Vorschläge aus dem Dokumenttext (auch ohne Edit-Modus sichtbar);
            // Klick übernimmt das Datum direkt im Edit-Modus
            if !dateSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label(T("Datum-Vorschläge:"), systemImage: "calendar.badge.plus")
                        .font(.caption).foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(dateSuggestions, id: \.self) { d in
                            Button(state.displayDate(d)) {
                                state.beginEditing()
                                state.draft?.date = d
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .tint(d == doc.documentDate ? .secondary : .accentColor)
                            .help(T("Dieses Datum übernehmen (öffnet den Edit-Modus)"))
                        }
                    }
                }
            }
            HStack {
                Button(T("Im Finder zeigen")) { reveal() }
                if state.syncConfigured(), let id = doc.id {
                    Menu {
                        Button { state.syncDocument(id) } label: {
                            Label(T("Jetzt synchronisieren"), systemImage: "cloud.arrow.up.fill")
                        }
                        Button { state.syncDocument(id, forceMetadata: true) } label: {
                            Label(T("Metadaten aktualisieren"), systemImage: "pencil.circle.fill")
                        }
                    } label: {
                        if state.syncRunning {
                            ProgressView().controlSize(.mini)
                        } else {
                            Label(T("Synchronisieren"), systemImage: "cloud.arrow.up.fill")
                        }
                    }
                    .disabled(state.syncRunning)
                    .help(T("Dieses Dokument zu paperless-ngx hochladen — „Metadaten aktualisieren“ pusht Kategorie/Korrespondent/Tags per PATCH, auch ohne Änderung"))
                }
                Spacer()
                Button { state.beginEditing() } label: {
                    Label(T("Bearbeiten"), systemImage: "pencil")
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.selection == nil)
                .help(T("Metadaten bearbeiten (unten in den Details)"))
            }
        }
        .padding()
    }

    /// Alle Datums-Vorkommen im Dokumenttext (ISO), für die Vorschlags-Chips.
    private var dateSuggestions: [String] {
        guard let text = doc.ocrText, !text.isEmpty else { return [] }
        let all = Heuristics.extractDates(from: text)
        // nur anzeigen, wenn es mehr als das bereits gesetzte Datum gibt
        if all.count > 1 || (all.count == 1 && all[0] != doc.documentDate) { return all }
        return []
    }

    /// Meta-Chip ( rund, dezente Füllung).
    private func chip(_ text: String, systemImage: String, color: Color = .primary) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.14)))
    }

    /// Sync-Status als Pill oben rechts im Header (Wolke + Klartext; Details im Tooltip).
    private func syncPill(_ syncState: SyncState) -> some View {
        let entry = doc.id.flatMap { state.syncEntry(for: $0) }
        let text: String
        switch syncState {
        case .synced: text = T("Synchronisiert")
        case .notSynced: text = T("Nicht synchronisiert")
        case .unknown: text = T("Sync unbekannt")
        }
        let detail: String
        switch syncState {
        case .synced:
            detail = entry.map { "paperless-#\($0.paperlessId) · \(state.displayDate(String($0.syncedAt.prefix(10))))" }
                ?? T("mit paperless-ngx abgeglichen")
        case .notSynced: detail = T("Push über „Sync“ in der Toolbar offen")
        case .unknown: detail = T("paperless-ngx nicht konfiguriert oder nie gelaufen")
        }
        return HStack(spacing: 4) {
            SyncCloudBadge.icon(syncState)
            Text(text)
        }
        .font(.caption).fontWeight(.medium)
        .foregroundStyle(SyncCloudBadge.color(syncState))
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(SyncCloudBadge.color(syncState).opacity(0.15)))
        .help(TF("%@ — %@", text, detail))
    }

    /// Eine Zeile im eingeklappten „Details“-Bereich (technisch, klein, kopierbar).
    private func techRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).frame(width: 90, alignment: .leading)
            Text(value).lineLimit(1).textSelection(.enabled)
        }
        .font(.caption2).foregroundStyle(.secondary)
    }

    private func reveal() {
        guard let vault = state.vault else { return }
        let path = vault.root.appendingPathComponent(doc.relativePath).path
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: vault.root.path)
    }
}

/// Einfaches Flow-Layout: Chips zeilenweise umbrechen (macOS 14: Layout-Protokoll verfügbar).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(proposal)
            if x > 0, x + s.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
        }
        return CGSize(width: maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(proposal)
            if x > bounds.minX, x + s.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            sv.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
        }
    }
}

/// Read-only, selektierbares Textfeld (NSTextView in ScrollView) — meldet die aktuelle
/// Selektion über ein Binding, damit das Kontextmenü „Als Titel/Korrespondent übernehmen“
/// auf den markierten Text zugreifen kann.
struct SelectableTextView: NSViewRepresentable {
    let text: String
    @Binding var selectedText: String

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.font = NSFont.systemFont(ofSize: 11)
        tv.textColor = NSColor.labelColor
        tv.delegate = context.coordinator
        tv.string = text
        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, tv.string != text else { return }
        let sel = tv.selectedRange()
        tv.string = text
        if sel.location < text.utf16.count {
            tv.setSelectedRange(NSRange(location: sel.location, length: min(sel.length, text.utf16.count - sel.location)))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SelectableTextView
        init(_ parent: SelectableTextView) { self.parent = parent }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let r = tv.selectedRange()
            guard r.length > 0, let s = tv.string as NSString? else { parent.selectedText = ""; return }
            parent.selectedText = s.substring(with: r)
        }
    }
}
