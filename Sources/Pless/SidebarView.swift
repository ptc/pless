import SwiftUI
import AppKit
import PlessCore

/// Sidebar: Bibliothek, Kategorien (Baum mit Farbpunkten), Tags, Korrespondenten —
/// inkl. Verwaltung per "+" und Kontextmenü (anlegen/umbenennen/Farbe/verschachteln/löschen).
struct SidebarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        List(selection: Binding(
            get: { state.sidebarSelection },
            set: { state.sidebarSelection = $0 ?? .all })) {
            Section("Bibliothek") {
                Label("Alle Dokumente", systemImage: "tray.full")
                    .badge(state.hits.count)
                    .tag(SidebarSelection.all)
                Label("OCR ausstehend", systemImage: "doc.text.magnifyingglass").tag(SidebarSelection.pendingOCR)
                Label("Posteingang", systemImage: "tray.arrow.down")
                    .badge(state.inboxCount)
                    .tag(SidebarSelection.all)
                    .contextMenu {
                        Button("Jetzt scannen") { state.scanInbox() }
                        Button("Im Finder öffnen") { openInFinder(state.vault?.inboxURL) }
                    }
                    .onTapGesture { state.scanInbox() }
            }
            Section(header: sectionHeader("Kategorien") {
                if let name = Prompts.askText(title: "Neue Kategorie", message: "Name") {
                    state.addCategory(name: name)
                }
            }) {
                OutlineGroup(categoryTree(state.categories), children: \.children) { node in
                    categoryRow(node)
                }
            }
            Section(header: sectionHeader("Tags") {
                if let name = Prompts.askText(title: "Neuer Tag", message: "Name") {
                    state.addTag(name: name)
                }
            }) {
                ForEach(state.tags, id: \.id) { tag in
                    tagRow(tag)
                }
            }
            Section(header: sectionHeader("Korrespondenten") {
                if let name = Prompts.askText(title: "Neuer Korrespondent", message: "Name") {
                    state.addCorrespondent(name: name)
                }
            }) {
                ForEach(state.correspondents, id: \.id) { c in
                    correspondentRow(c)
                }
            }
            Section("Vault") {
                HStack(spacing: 4) {
                    Text(state.vaultPath.path)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button { openInFinder(state.vaultPath) } label: {
                        Image(systemName: "arrow.up.right.square").font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help("Vault im Finder öffnen")
                }
                HStack(spacing: 4) {
                    Text("Posteingang: \(state.vault?.inboxURL.path ?? "—")")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button { openInFinder(state.vault?.inboxURL) } label: {
                        Image(systemName: "tray.and.arrow.down").font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help("Posteingang (Import-Ordner) im Finder öffnen")
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: state.sidebarSelection) { _ in state.refresh() }
    }

    // MARK: - Zeilen

    /// Öffnet einen Ordner im Finder (Posteingang/Import-Ordner bzw. Vault).
    private func openInFinder(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    /// Dokumentanzahl inkl. aller Unterkategorien (für das Badge).
    private func countFor(_ node: CatNode) -> Int {
        let own = node.id.flatMap { state.categoryCounts[$0] } ?? 0
        return own + (node.children ?? []).reduce(0) { $0 + countFor($1) }
    }

    @ViewBuilder
    private func categoryRow(_ node: CatNode) -> some View {
        let base = Label {
            Text(node.name)
        } icon: {
            Circle().fill(Color(hex: node.color) ?? .accentColor).frame(width: 8, height: 8)
        }
        .tag(SidebarSelection.category(node.name))
        .onTapGesture {
            // Klick filtert die Übersicht auf diese Kategorie (und markiert sie in der Liste);
            // erneuter Klick auf die aktive Kategorie → wieder alle Dokumente
            if case .category(let active) = state.sidebarSelection, active == node.name {
                state.sidebarSelection = .all
            } else {
                state.sidebarSelection = .category(node.name)
            }
            state.refresh()
        }
        .onDrag {
            guard let id = node.id else { return NSItemProvider() }
            // Drag-Payload fürs Zuweisen auf Dokumente im Gitter
            return NSItemProvider(object: "pless/category/\(id)" as NSString)
        }
        let count = countFor(node)
        let row = base.contextMenu {
            Button("Umbenennen…") {
                guard let id = node.id,
                      let n = Prompts.askText(title: "Kategorie umbenennen", message: "Neuer Name", defaultValue: node.name) else { return }
                state.updateCategory(id: id, name: n, parentId: node.parentId, color: node.color)
            }
            Menu("Farbe wählen") {
                Button("Keine Farbe") {
                    if let id = node.id { state.updateCategory(id: id, name: node.name, parentId: node.parentId, color: nil) }
                }
                ForEach(ColorPalette.presets, id: \.self) { hex in
                    Button {
                        if let id = node.id { state.updateCategory(id: id, name: node.name, parentId: node.parentId, color: hex) }
                    } label: {
                        Label(hex, systemImage: "circle.fill").foregroundStyle(Color(hex: hex) ?? .primary)
                    }
                }
            }
            Menu("Überordnen unter…") {
                Button("— ohne Elternkategorie —") {
                    if let id = node.id { state.updateCategory(id: id, name: node.name, parentId: nil, color: node.color) }
                }
                let forbidden = descendants(of: node.id, in: state.categories).union([node.id].compactMap { $0 })
                ForEach(state.categories.filter { c in
                    guard let id = c.id else { return false }
                    return !forbidden.contains(id)
                }, id: \.id) { c in
                    Button(c.name) {
                        if let id = node.id { state.updateCategory(id: id, name: node.name, parentId: c.id, color: node.color) }
                    }
                }
            }
            Divider()
            Button("Löschen", role: .destructive) {
                if Prompts.confirm(title: "Kategorie „\(node.name)“ löschen?",
                                   message: "Dokumente mit dieser Kategorie verlieren die Zuordnung.") {
                    if let id = node.id { state.deleteCategory(id: id) }
                }
            }
        }
        if count > 0 {
            row.badge(count)
        } else {
            row
        }
    }

    private func tagRow(_ tag: Tag) -> some View {
        Label {
            Text(tag.name)
        } icon: {
            Circle().fill(Color(hex: tag.color) ?? .accentColor).frame(width: 8, height: 8)
        }
        .tag(SidebarSelection.tag(tag.name))
        .onDrag {
            // Drag-Payload fürs Zuweisen auf Dokumente im Gitter
            NSItemProvider(object: "pless/tag/\(tag.name)" as NSString)
        }
        .contextMenu {
            Button("Umbenennen…") {
                if let n = Prompts.askText(title: "Tag umbenennen", message: "Neuer Name", defaultValue: tag.name) {
                    if let id = tag.id { state.updateTag(id: id, name: n, color: tag.color) }
                }
            }
            Menu("Farbe wählen") {
                Button("Keine Farbe") { if let id = tag.id { state.updateTag(id: id, name: tag.name, color: nil) } }
                ForEach(ColorPalette.presets, id: \.self) { hex in
                    Button {
                        if let id = tag.id { state.updateTag(id: id, name: tag.name, color: hex) }
                    } label: {
                        Label(hex, systemImage: "circle.fill").foregroundStyle(Color(hex: hex) ?? .primary)
                    }
                }
            }
            Divider()
            Button("Löschen", role: .destructive) {
                if Prompts.confirm(title: "Tag „\(tag.name)“ löschen?",
                                   message: "Der Tag wird von allen Dokumenten entfernt.") {
                    if let id = tag.id { state.deleteTag(id: id) }
                }
            }
        }
    }

    private func correspondentRow(_ c: Correspondent) -> some View {
        Label(c.name, systemImage: "person")
            .tag(SidebarSelection.correspondent(c.name))
            .contextMenu {
                Button("Umbenennen…") {
                    if let n = Prompts.askText(title: "Korrespondent umbenennen", message: "Neuer Name", defaultValue: c.name) {
                        if let id = c.id { state.renameCorrespondent(id: id, newName: n) }
                    }
                }
                Divider()
                Button("Löschen", role: .destructive) {
                    if Prompts.confirm(title: "Korrespondent „\(c.name)“ löschen?",
                                       message: "Dokumente verlieren die Korrespondenten-Angabe.") {
                        if let id = c.id { state.deleteCorrespondent(id: id) }
                    }
                }
            }
    }

    // MARK: - Helfer

    private func sectionHeader(_ title: String, add: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button { add() } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("Neu anlegen")
        }
    }

    /// Baum-Modell für OutlineGroup.
    struct CatNode: Identifiable {
        let id: Int64?
        let name: String
        let parentId: Int64?
        let color: String?
        var children: [CatNode]?
    }

    private func categoryTree(_ cats: [PlessCore.Category]) -> [CatNode] {
        func kids(_ p: Int64?) -> [CatNode] {
            cats.filter { $0.parentId == p }
                .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
                // Kinder == nil → Blatt (kein Aufklapp-Pfeil); nur echte Unterkategorien zeigen ein „>“
                .map { c in
                    let children = kids(c.id)
                    return CatNode(id: c.id, name: c.name, parentId: c.parentId, color: c.color,
                                   children: children.isEmpty ? nil : children)
                }
        }
        return kids(nil)
    }

    private func descendants(of id: Int64?, in cats: [PlessCore.Category]) -> Set<Int64> {
        var out = Set<Int64>()
        var queue = cats.filter { $0.parentId == id }.compactMap { $0.id }
        while let cur = queue.popLast() {
            out.insert(cur)
            queue.append(contentsOf: cats.filter { $0.parentId == cur }.compactMap { $0.id })
        }
        return out
    }
}
