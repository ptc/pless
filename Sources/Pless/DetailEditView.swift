import SwiftUI
import PlessCore

/// Edit-Modus des Detailbereichs (Phase 7): Titel, Datum, Korrespondent, Kategorie, Tags, Notizen.
/// „Fertig“ (Toolbar) speichert über AppState.saveEditing und benennt die Datei ggf. um.
struct MetadataEditView: View {
    @EnvironmentObject var state: AppState
    let doc: PlessCore.Document
    @State private var newTag = ""

    /// Alle im Dokumenttext gefundenen Datums-Vorkommen (ISO + deutsch), als yyyy-MM-dd.
    private var dateSuggestions: [String] {
        guard let text = doc.ocrText, !text.isEmpty else { return [] }
        return Heuristics.extractDates(from: text)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(doc.title ?? doc.filename).font(.headline).lineLimit(1)

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Titel").foregroundStyle(.secondary)
                        TextField("Titel", text: bind(\.title, "")).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Datum").foregroundStyle(.secondary)
                        // Anzeige im eingestellten Format; Eingabe darf ISO oder Anzeigeformat sein
                        TextField(state.settings.dateFormat, text: Binding(
                            get: { state.displayDate(state.draft?.date) },
                            set: { state.draft?.date = DateDisplay.parse($0, pattern: state.settings.dateFormat) ?? $0 }))
                            .textFieldStyle(.roundedBorder).frame(width: 110)
                    }
                    // Datums-Vorschläge aus dem OCR-/Textschicht-Text: jedes Datum anwählbar (im Anzeigeformat)
                    if !dateSuggestions.isEmpty {
                        GridRow {
                            Text("Vorschläge").foregroundStyle(.secondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(dateSuggestions, id: \.self) { d in
                                        Button(state.displayDate(d)) { state.draft?.date = d }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                            .tint(state.draft?.date == d ? .accentColor : .secondary)
                                            .help("Datum übernehmen")
                                    }
                                }
                            }
                        }
                    }
                    GridRow {
                        Text("Korrespondent").foregroundStyle(.secondary)
                        Picker("Korrespondent", selection: Binding(
                            get: { state.draft?.correspondentId },
                            set: { state.draft?.correspondentId = $0 })) {
                            Text("Keiner").tag(nil as Int64?)
                            ForEach(state.correspondents, id: \.id) { Text($0.name).tag($0.id) }
                            Divider()
                            Button("Neu…") {
                                if let name = Prompts.askText(title: "Neuer Korrespondent", message: "Name") {
                                    state.run {
                                        if let id = try state.db?.findOrCreateCorrespondent(name: name) {
                                            state.draft?.correspondentId = id
                                        }
                                    }
                                }
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 260)
                    }
                    GridRow {
                        Text("Kategorie").foregroundStyle(.secondary)
                        Picker("Kategorie", selection: Binding(
                            get: { state.draft?.categoryId },
                            set: { state.draft?.categoryId = $0 })) {
                            Text("Keine").tag(nil as Int64?)
                            ForEach(state.categories, id: \.id) { Text($0.name).tag($0.id) }
                            Divider()
                            Button("Neu…") {
                                if let name = Prompts.askText(title: "Neue Kategorie", message: "Name") {
                                    state.run {
                                        if let id = try state.db?.findOrCreateCategory(name: name) {
                                            state.draft?.categoryId = id
                                        }
                                    }
                                }
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 260)
                    }
                }
                .font(.caption)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Tags").foregroundStyle(.secondary).font(.caption)
                    ForEach(Array((state.draft?.tagNames ?? []).enumerated()), id: \.offset) { i, name in
                        HStack {
                            Label(name, systemImage: "tag").font(.caption2)
                            Spacer()
                            Button { state.draft?.tagNames.remove(at: i) } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("Tag hinzufügen…", text: $newTag)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                        Button("Hinzufügen") {
                            let n = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !n.isEmpty, state.draft?.tagNames.contains(n) != true {
                                state.draft?.tagNames.append(n)
                            }
                            newTag = ""
                        }
                        .disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Notizen").foregroundStyle(.secondary).font(.caption)
                    TextEditor(text: bind(\.notes, ""))
                        .font(.caption)
                        .frame(height: 56)
                        .scrollContentBackground(.hidden)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding()
        }
    }

    private func bind<T>(_ keyPath: WritableKeyPath<MetadataDraft, T>, _ defaultValue: T) -> Binding<T> {
        Binding(get: { state.draft?[keyPath: keyPath] ?? defaultValue },
                set: { state.draft?[keyPath: keyPath] = $0 })
    }
}
