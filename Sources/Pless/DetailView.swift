import SwiftUI
import AppKit
import PDFKit
import PlessCore

struct DetailView: View {
    @EnvironmentObject var state: AppState

    var doc: PlessCore.Document? {
        state.hits.first { $0.document.id == state.selection }?.document
    }

    var body: some View {
        if let doc, let vault = state.vault {
            VStack(spacing: 0) {
                PDFViewRepresentable(url: vault.root.appendingPathComponent(doc.relativePath))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                                   description: Text("Links in der Liste ein PDF auswählen."))
        }
    }
}

struct PDFViewRepresentable: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.document = PDFDocument(url: url)
        v.autoScales = true
        return v
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
        }
    }
}

struct ThumbnailView: View {
    let doc: PlessCore.Document
    let vault: Vault
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
        .frame(width: 44, height: 56)
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
