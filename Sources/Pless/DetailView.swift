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
    @State private var showOCRText = true           // OCR-Text-Panel (markierbar) ein-/ausblenden

    var doc: PlessCore.Document? {
        state.selectedDoc
    }

    var body: some View {
        if let doc, let vault = state.vault {
            VStack(spacing: 0) {
                // Zoom-Leiste: Modus (Anpassen / Höhe / 100 %) + Stufen
                HStack(spacing: 8) {
                    Picker("Ansicht", selection: $pdfMode) {
                        Text("Anpassen").tag(PDFMode.fit)
                        Text("Höhe").tag(PDFMode.height)
                        Text("100 %").tag(PDFMode.full)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)
                    Button {
                        pdfMode = .full
                        pdfZoom = max(0.25, pdfZoom / 1.25)
                    } label: { Image(systemName: "minus.magnifyingglass") }
                    Text("\(Int(pdfZoom * 100)) %").font(.caption).frame(width: 44)
                    Button {
                        pdfMode = .full
                        pdfZoom = min(8, pdfZoom * 1.25)
                    } label: { Image(systemName: "plus.magnifyingglass") }
                    if !doc.ocrDone {
                        Button {
                            if let id = doc.id { state.startOCR(for: id) }
                        } label: { Label("OCR starten", systemImage: "text.viewfinder") }
                        .disabled(state.ocrRunning)
                        .help("OCR für dieses Dokument jetzt ausführen (Status „OCR offen“)")
                    }
                    if doc.ocrText != nil {
                        Button { showOCRText.toggle() } label: {
                            Label("OCR-Text", systemImage: "text.alignleft")
                                .foregroundStyle(showOCRText ? Color.accentColor : .secondary)
                        }
                        .help("OCR-Text ein-/ausblenden — der Text ist markierbar/kopierbar")
                    }
                    Spacer()
                    // Bearbeiten direkt in der Detail-Vorschau
                    if state.isEditing {
                        Button { state.saveEditing() } label: {
                            Label("Fertig", systemImage: "checkmark.circle.fill")
                        }
                        .help("Speichern (Datei wird ggf. umbenannt)")
                        Button { state.cancelEditing() } label: {
                            Label("Abbrechen", systemImage: "xmark.circle")
                        }
                        .help("Änderungen verwerfen")
                    } else {
                        Button { state.beginEditing() } label: {
                            Label("Bearbeiten", systemImage: "pencil")
                        }
                        .disabled(state.selection == nil)
                        .help("Metadaten bearbeiten")
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                Divider()
                PDFViewRepresentable(url: vault.root.appendingPathComponent(doc.relativePath),
                                     mode: $pdfMode, zoom: $pdfZoom)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // OCR-Text (bei gescannten PDFs liegt der Text nur in der DB, nicht im PDF selbst)
                // als markierbares, read-only Textfeld — Text kann ausgewählt und kopiert werden.
                if showOCRText, let text = doc.ocrText, !text.isEmpty {
                    Divider()
                    VStack(spacing: 2) {
                        HStack {
                            Text("OCR-Text").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button { showOCRText = false } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("OCR-Text ausblenden")
                        }
                        .padding(.horizontal, 8)
                        TextEditor(text: .constant(text))
                            .font(.caption)
                            .scrollContentBackground(.hidden)
                            .padding(.horizontal, 8)
                            .frame(height: 110)
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
                        .frame(height: 210)
                }
            }
        } else {
            ContentUnavailableView("Dokument wählen", systemImage: "doc.text",
                                   description: Text("In der Übersicht ein PDF auswählen."))
        }
    }
}

/// PDFView, das bei Modus „Höhe“ die Skalierung an die View-Höhe koppelt (auch bei Resize).
final class ScaledPDFView: PDFView {
    var fitToHeight = false

    override func layout() {
        super.layout()
        if fitToHeight, let page = currentPage ?? document?.page(at: 0) {
            let pageHeight = page.bounds(for: .mediaBox).height
            if pageHeight > 0, bounds.height > 0 {
                scaleFactor = bounds.height / pageHeight
            }
        }
    }
}

struct PDFViewRepresentable: NSViewRepresentable {
    let url: URL
    @Binding var mode: PDFMode
    @Binding var zoom: CGFloat

    func makeNSView(context: Context) -> PDFView {
        let v = ScaledPDFView()
        v.document = PDFDocument(url: url)
        v.autoScales = false
        v.fitToHeight = true
        return v
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
        }
        guard let v = nsView as? ScaledPDFView else { return }
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

/// Read-only Metadaten-Anzeige (Edit-Modus kommt in Phase 7).
struct MetadataSummary: View {
    @EnvironmentObject var state: AppState
    let doc: PlessCore.Document

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(doc.title ?? doc.filename).font(.headline).lineLimit(1)
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 4) {
                row("Datei", doc.filename)
                row("Im Vault", doc.relativePath)
                row("Datum", doc.documentDate ?? "—")
                row("Korrespondent", state.nameOfCorrespondent(doc.correspondentId).isEmpty ? "—" : state.nameOfCorrespondent(doc.correspondentId))
                row("Kategorie", state.nameOfCategory(doc.categoryId).isEmpty ? "—" : state.nameOfCategory(doc.categoryId))
                row("Seiten", "\(doc.pageCount)")
                row("OCR", doc.ocrDone ? "fertig" : "ausstehend")
            }
            .font(.caption)
            let tags = state.tagsOf(doc)
            if !tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(tags, id: \.id) {
                        Label($0.name, systemImage: "tag").font(.caption2)
                    }
                }
            }
            HStack {
                Button("Im Finder zeigen") { reveal() }
                Spacer()
            }
        }
        .padding()
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func reveal() {
        guard let vault = state.vault else { return }
        let path = vault.root.appendingPathComponent(doc.relativePath).path
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: vault.root.path)
    }
}
