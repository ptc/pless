import SwiftUI
import AppKit
import PlessCore

/// Einstellungen (Cmd+,) als Tab-Fenster mit Sidebar: Allgemein, OCR, paperless-ngx, MCP.
/// Alle Änderungen werden sofort gespeichert (SettingsStore persistiert in UserDefaults/Keychain).
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var testingConnection = false
    @State private var connectionResult: String?

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                generalTab
                    .tabItem { Label("Allgemein", systemImage: "gear") }
                ocrTab
                    .tabItem { Label("OCR", systemImage: "doc.text.viewfinder") }
                paperlessTab
                    .tabItem { Label("paperless-ngx", systemImage: "cloud") }
                mcpTab
                    .tabItem { Label("MCP · KI", systemImage: "sparkles") }
            }
            Divider()
            HStack {
                Text("Änderungen werden sofort gespeichert.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Schließen") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Tabs

    private var generalTab: some View {
        Form {
            Section("Vault") {
                LabeledContent("Pfad") {
                    HStack(spacing: 6) {
                        TextField("Vault-Ordner", text: $settings.vaultPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Wählen…") { pickDirectory { settings.vaultPath = $0 } }
                    }
                }
                Text("Vault-Pfad und Import-Ordner werden beim nächsten Start wirksam.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Import-Ordner") {
                Toggle("Eigenen Import-Ordner verwenden", isOn: $settings.customInboxEnabled)
                LabeledContent("Pfad") {
                    HStack(spacing: 6) {
                        TextField("Import-Ordner", text: $settings.customInboxPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Wählen…") { pickDirectory { settings.customInboxPath = $0 } }
                    }
                }
                .disabled(!settings.customInboxEnabled)
                Text("Default: <Vault>/inbox — PDFs hier hineinlegen, sie werden automatisch importiert.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Dateinamen") {
                LabeledContent("Schema") {
                    TextField("Template", text: $settings.namingTemplate)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                LabeledContent("Vorschau") {
                    Text(preview)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text("Platzhalter: {date} {correspondent} {category} {title} {tags}")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Anzeige") {
                LabeledContent("Datumsformat") {
                    Picker("Datumsformat", selection: $settings.dateFormat) {
                        Text("Deutsch (dd.MM.yyyy)").tag("dd.MM.yyyy")
                        Text("ISO (yyyy-MM-dd)").tag("yyyy-MM-dd")
                        Text("US (MM/dd/yyyy)").tag("MM/dd/yyyy")
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                Text("Betrifft Anzeige in Liste, Details und Bearbeitungsmodus — gespeichert wird immer ISO (yyyy-MM-dd).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var ocrTab: some View {
        Form {
            Section("Sprachen") {
                Toggle("Deutsch (de-DE)", isOn: langBinding("de-DE"))
                Toggle("Englisch (en-US)", isOn: langBinding("en-US"))
                Text("Die Texterkennung läuft per Vision vollständig lokal auf dem Mac — keine Daten gehen an externe Dienste.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var paperlessTab: some View {
        Form {
            Section("Verbindung (opt-in)") {
                LabeledContent("URL") {
                    TextField("https://paperless.example.local", text: $settings.paperlessURL)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("API-Token") {
                    SecureField("Token", text: $settings.paperlessToken)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Das Token liegt sicher in der macOS-Keychain, nicht in der pless.db. Ohne URL + Token wird kein Netzwerk-Zugriff ausgeführt.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button { testConnection() } label: {
                        if testingConnection {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Verbindung testen", systemImage: "bolt.fill")
                        }
                    }
                    .disabled(testingConnection || settings.paperlessConfig() == nil)
                    if let r = connectionResult {
                        Label(r, systemImage: r.hasPrefix("OK") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(r.hasPrefix("OK") ? .green : .red)
                    }
                    Spacer()
                }
            }
            Section("Sync & Import") {
                Button { state.pullFromPaperless() } label: {
                    Label("Kategorien & Korrespondenten aus paperless importieren", systemImage: "tray.and.arrow.down")
                }
                .disabled(testingConnection || state.syncRunning || settings.paperlessConfig() == nil)
                .help("Pull aus paperless-ngx: Document Types → Kategorien, Correspondents → Korrespondenten (bestehende Namen bleiben erhalten)")
                Text("Push (Einweg): Kategorie → Document Type, Tags → Tags, Korrespondent → Correspondent (jeweils find-or-create in paperless). Der Dateiname bleibt als original_filename erhalten; bereits gesyncte Dokumente werden per SHA-256 übersprungen, reine Metadaten-Änderungen per PATCH nachgesendet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var mcpTab: some View {
        Form {
            Section("MCP-Server (stdio) — z. B. für Claude Desktop") {
                Text(settings.mcpConfigSnippet(binaryPath: "<Pfad-zum-Binary>/Pless"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                Button { copyMCPConfig() } label: {
                    Label("Config kopieren", systemImage: "doc.on.doc")
                }
                Text("Server starten: Pless mcp --vault <Pfad> — JSON-RPC 2.0 über stdio, eine Nachricht pro Zeile.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Helfer

    private var preview: String {
        NamingEngine.render(template: settings.namingTemplate, context: NamingContext(
            date: "2026-02-14", correspondent: "Allianz", category: "Rechnungen",
            title: "KFZ-Versicherung 2026", tags: ["wichtig"]))
    }

    private func langBinding(_ lang: String) -> Binding<Bool> {
        Binding(get: { settings.ocrLanguages.contains(lang) },
                set: { if $0 { settings.ocrLanguages.insert(lang) } else { settings.ocrLanguages.remove(lang) } })
    }

    private func copyMCPConfig() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(settings.mcpConfigSnippet(binaryPath: "<Pfad-zum-Binary>/Pless"), forType: .string)
    }

    /// `GET /api/` mit Token — prüft URL + Token gegen die paperless-Instanz.
    private func testConnection() {
        guard let cfg = settings.paperlessConfig() else {
            connectionResult = "URL fehlt oder ist ungültig (http/https + Host nötig)"
            return
        }
        testingConnection = true
        connectionResult = nil
        Task {
            let client = PaperlessClient(config: cfg, transport: URLSessionTransport())
            do {
                _ = try await client.ping()
                connectionResult = "OK — verbunden"
            } catch {
                connectionResult = "Fehler: \(error.localizedDescription)"
            }
            testingConnection = false
        }
    }

    private func pickDirectory(_ completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { completion(url.path) }
    }
}
