import SwiftUI
import AppKit
import PlessCore

/// Sidebar: Bibliothek, Kategorien (Baum mit Farbpunkten), Tags, Korrespondenten —
/// inkl. Verwaltung per "+" und Kontextmenü (anlegen/umbenennen/Farbe/verschachteln/löschen).
struct SidebarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            inboxBar
            Divider()
            list
        }
    }

    /// Posteingang-Leiste oben in der Sidebar — bewusst außerhalb der selektierbaren
    /// Liste, damit sie keine Ansicht umschaltet: zeigt, wie viele PDFs im Import-Ordner
    /// warten, und scannt auf Knopfdruck (der Watcher macht das sonst automatisch).
    private var inboxBar: some View {
        HStack(spacing: 8) {
            Label(T("Posteingang"), systemImage: "tray.arrow.down")
                .help(T("Import-Ordner <Vault>/inbox — PDFs hier hineinlegen, sie werden automatisch importiert"))
            Spacer()
            Text(state.inboxCount == 0 ? T("leer") : TF("%d wartend", state.inboxCount))
                .font(.caption)
                .fontWeight(state.inboxCount == 0 ? .regular : .semibold)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(state.inboxCount == 0
                                           ? Color.secondary.opacity(0.18)
                                           : Color.orange.opacity(0.35)))
            Button { state.scanInbox() } label: {
                Label(T("Scannen"), systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(T("Posteingang jetzt scannen — importiert alle wartenden PDFs"))
            Button { openInFinder(state.vault?.inboxURL) } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help(T("Posteingang-Ordner im Finder öffnen"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thickMaterial)
        .contextMenu {
            Button(T("Jetzt scannen")) { state.scanInbox() }
            Button(T("Im Finder öffnen")) { openInFinder(state.vault?.inboxURL) }
        }
    }

    private var list: some View {
        List(selection: Binding(
            get: { state.sidebarSelection },
            set: { state.sidebarSelection = $0 ?? .all })) {
            Section(T("Bibliothek")) {
                Label(T("Alle Dokumente"), systemImage: "tray.full")
                    .badge(state.hits.count)
                    .tag(SidebarSelection.all)
                Label(T("OCR ausstehend"), systemImage: "doc.text.magnifyingglass").tag(SidebarSelection.pendingOCR)
            }
            Section(header: sectionHeader("Kategorien") {
                if let name = Prompts.askText(title: T("Neue Kategorie"), message: T("Name")) {
                    state.addCategory(name: name)
                }
            }) {
                OutlineGroup(categoryTree(state.categories), children: \.children) { node in
                    categoryRow(node)
                }
            }
            Section(header: sectionHeader("Tags") {
                if let name = Prompts.askText(title: T("Neuer Tag"), message: T("Name")) {
                    state.addTag(name: name)
                }
            }) {
                ForEach(state.tags, id: \.id) { tag in
                    tagRow(tag)
                }
            }
            Section(header: sectionHeader("Korrespondenten") {
                if let name = Prompts.askText(title: T("Neuer Korrespondent"), message: T("Name")) {
                    state.addCorrespondent(name: name)
                }
            }) {
                ForEach(state.correspondents, id: \.id) { c in
                    correspondentRow(c)
                }
            }
            Section(T("Vault")) {
                HStack(spacing: 4) {
                    Text(state.vaultPath.path)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button { openInFinder(state.vaultPath) } label: {
                        Image(systemName: "arrow.up.right.square").font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help(T("Vault im Finder öffnen"))
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: state.sidebarSelection) { state.refresh() }
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

    private func categoryRow(_ node: CatNode) -> some View {
        // Zähler als trailing Text IN der Zeile (nicht .badge — das stört die native
        // Auswahl-Markierung der List bei OutlineGroup-Zeilen)
        let count = countFor(node)
        return HStack(spacing: 6) {
            Label {
                Text(node.name)
            } icon: {
                Circle().fill(Color(hex: node.color) ?? .accentColor).frame(width: 8, height: 8)
            }
            Spacer()
            if count > 0 {
                Text(TF("%d", count)).font(.caption2).foregroundStyle(.secondary)
            }
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
        .contextMenu {
            Button(T("Umbenennen…")) {
                guard let id = node.id,
                      let n = Prompts.askText(title: T("Kategorie umbenennen"), message: T("Neuer Name"), defaultValue: node.name) else { return }
                state.updateCategory(id: id, name: n, parentId: node.parentId, color: node.color)
            }
            Menu(T("Farbe wählen")) {
                Button(T("Keine Farbe")) {
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
            Menu(T("Überordnen unter…")) {
                Button(T("— ohne Elternkategorie —")) {
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
            Button(T("Löschen"), role: .destructive) {
                if Prompts.confirm(title: TF("Kategorie „%@“ löschen?", node.name),
                                   message: T("Dokumente mit dieser Kategorie verlieren die Zuordnung.")) {
                    if let id = node.id { state.deleteCategory(id: id) }
                }
            }
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
            Button(T("Umbenennen…")) {
                if let n = Prompts.askText(title: T("Tag umbenennen"), message: T("Neuer Name"), defaultValue: tag.name) {
                    if let id = tag.id { state.updateTag(id: id, name: n, color: tag.color) }
                }
            }
            Menu(T("Farbe wählen")) {
                Button(T("Keine Farbe")) { if let id = tag.id { state.updateTag(id: id, name: tag.name, color: nil) } }
                ForEach(ColorPalette.presets, id: \.self) { hex in
                    Button {
                        if let id = tag.id { state.updateTag(id: id, name: tag.name, color: hex) }
                    } label: {
                        Label(hex, systemImage: "circle.fill").foregroundStyle(Color(hex: hex) ?? .primary)
                    }
                }
            }
            Divider()
            Button(T("Löschen"), role: .destructive) {
                if Prompts.confirm(title: TF("Tag „%@“ löschen?", tag.name),
                                   message: T("Der Tag wird von allen Dokumenten entfernt.")) {
                    if let id = tag.id { state.deleteTag(id: id) }
                }
            }
        }
    }

    private func correspondentRow(_ c: Correspondent) -> some View {
        // Zähler als trailing Text in der Zeile (nicht .badge — störte die native Auswahl-Markierung)
        let count = c.id.flatMap { state.correspondentCounts[$0] } ?? 0
        return HStack(spacing: 6) {
            Label(c.name, systemImage: "person")
            Spacer()
            if count > 0 {
                Text(TF("%d", count)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .tag(SidebarSelection.correspondent(c.name))
        .onTapGesture {
            // Klick filtert auf diesen Korrespondenten; erneuter Klick auf den aktiven → alle
            if case .correspondent(let active) = state.sidebarSelection, active == c.name {
                state.sidebarSelection = .all
            } else {
                state.sidebarSelection = .correspondent(c.name)
            }
            state.refresh()
        }
        .onTapGesture(count: 2) {
            // Doppelklick → Korrespondent bearbeiten (umbenennen)
            if let id = c.id,
               let n = Prompts.askText(title: T("Korrespondent umbenennen"), message: T("Neuer Name"), defaultValue: c.name) {
                state.renameCorrespondent(id: id, newName: n)
            }
        }
        .onDrag {
            guard let id = c.id else { return NSItemProvider() }
            // Drag-Payload fürs Zuweisen auf Dokumente im Gitter
            return NSItemProvider(object: "pless/correspondent/\(id)" as NSString)
        }
        .contextMenu {
                Button(T("Umbenennen…")) {
                    if let n = Prompts.askText(title: T("Korrespondent umbenennen"), message: T("Neuer Name"), defaultValue: c.name) {
                        if let id = c.id { state.renameCorrespondent(id: id, newName: n) }
                    }
                }
                Divider()
                Button(T("Löschen"), role: .destructive) {
                    if Prompts.confirm(title: TF("Korrespondent „%@“ löschen?", c.name),
                                       message: T("Dokumente verlieren die Korrespondenten-Angabe.")) {
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
                .help(T("Neu anlegen"))
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
