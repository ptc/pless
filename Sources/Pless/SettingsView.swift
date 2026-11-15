import SwiftUI
import AppKit
import PlessCore

/// Einstellungen (Cmd+,): Vault-Pfad, Import-Ordner, Namensschema + Live-Vorschau, OCR-Sprachen, MCP-Snippet.
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Änderungen werden sofort gespeichert.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Schließen") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            Form {
            Section("Vault") {
                LabeledContent("Pfad") {
                    HStack {
                        TextField("Vault-Ordner", text: $settings.vaultPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Wählen…") { pickDirectory { settings.vaultPath = $0 } }
                    }
                }
                Text("Vault-Pfad und Import-Ordner werden beim nächsten Start wirksam.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Import-Ordner") {
                Toggle("Eigenen Import-Ordner verwenden (Default: <Vault>/inbox)",
                       isOn: $settings.customInboxEnabled)
                LabeledContent("Pfad") {
                    HStack {
                        TextField("Import-Ordner", text: $settings.customInboxPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Wählen…") { pickDirectory { settings.customInboxPath = $0 } }
                    }
                }
                .disabled(!settings.customInboxEnabled)
            }
            Section("Dateinamen") {
                LabeledContent("Schema") {
                    TextField("Template", text: $settings.namingTemplate)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                LabeledContent("Vorschau") {
                    Text(preview).font(.system(.body, design: .monospaced))
                }
                Text("Platzhalter: {date} {correspondent} {category} {title} {tags}")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("OCR (on-device, Vision)") {
                Toggle("Deutsch (de-DE)", isOn: langBinding("de-DE"))
                Toggle("Englisch (en-US)", isOn: langBinding("en-US"))
            }
            Section("MCP — KI-Anbindung (z. B. Claude Desktop)") {
                Text(settings.mcpConfigSnippet(binaryPath: "<Pfad-zum-Binary>/Pless"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Button("Config kopieren") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(settings.mcpConfigSnippet(binaryPath: "<Pfad-zum-Binary>/Pless"), forType: .string)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        }
    }

    private var preview: String {
        NamingEngine.render(template: settings.namingTemplate, context: NamingContext(
            date: "2026-02-14", correspondent: "Allianz", category: "Rechnungen",
            title: "KFZ-Versicherung 2026", tags: ["wichtig"]))
    }

    private func langBinding(_ lang: String) -> Binding<Bool> {
        Binding(get: { settings.ocrLanguages.contains(lang) },
                set: { if $0 { settings.ocrLanguages.insert(lang) } else { settings.ocrLanguages.remove(lang) } })
    }

    private func pickDirectory(_ completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { completion(url.path) }
    }
}
