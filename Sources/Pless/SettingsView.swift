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
                // .id(language) am Root erzwingt Re-Render aller T()-Strings bei Sprachwechsel
                generalTab
                    .tabItem { Label(T("Allgemein"), systemImage: "gear") }
                ocrTab
                    .tabItem { Label(T("OCR"), systemImage: "doc.text.viewfinder") }
                paperlessTab
                    .tabItem { Label(T("paperless-ngx"), systemImage: "cloud") }
                mcpTab
                    .tabItem { Label(T("MCP · KI"), systemImage: "sparkles") }
            }
            Divider()
            HStack {
                Text(T("Änderungen werden sofort gespeichert."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(T("Schließen")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .id(state.language)   // Sprachwechsel → komplettes Re-Render aller T()-Strings
    }

    // MARK: - Tabs

    private var generalTab: some View {
        Form {
            Section(T("Sprache")) {
                Picker(T("Sprache"), selection: Binding(get: { state.language }, set: { state.setLanguage($0) })) {
                    Text(T("Deutsch")).tag("de")
                    Text(T("English")).tag("en")
                }
                .labelsHidden()
                .frame(width: 160)
                Text(T("Gilt ab sofort für die gesamte App-Oberfläche."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(T("Vault")) {
                LabeledContent(T("Pfad")) {
                    HStack(spacing: 6) {
                        TextField(T("Vault-Ordner"), text: $settings.vaultPath)
                            .textFieldStyle(.roundedBorder)
                        Button(T("Wählen…")) { pickDirectory { settings.vaultPath = $0 } }
                    }
                }
                Text(T("Vault-Pfad und Import-Ordner werden beim nächsten Start wirksam."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(T("Import-Ordner")) {
                Toggle(T("Eigenen Import-Ordner verwenden"), isOn: $settings.customInboxEnabled)
                LabeledContent(T("Pfad")) {
                    HStack(spacing: 6) {
                        TextField(T("Import-Ordner"), text: $settings.customInboxPath)
                            .textFieldStyle(.roundedBorder)
                        Button(T("Wählen…")) { pickDirectory { settings.customInboxPath = $0 } }
                    }
                }
                .disabled(!settings.customInboxEnabled)
                Text(T("Default: <Vault>/inbox — PDFs hier hineinlegen, sie werden automatisch importiert."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(T("Dateinamen")) {
                LabeledContent(T("Schema")) {
                    TextField(T("Template"), text: $settings.namingTemplate)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                LabeledContent(T("Vorschau")) {
                    Text(preview)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(T("Platzhalter: {date} {correspondent} {category} {title} {tags}"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(T("Anzeige")) {
                LabeledContent(T("Datumsformat")) {
                    Picker(T("Datumsformat"), selection: $settings.dateFormat) {
                        Text(T("Deutsch (dd.MM.yyyy)")).tag("dd.MM.yyyy")
                        Text(T("ISO (yyyy-MM-dd)")).tag("yyyy-MM-dd")
                        Text(T("US (MM/dd/yyyy)")).tag("MM/dd/yyyy")
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                Text(T("Betrifft Anzeige in Liste, Details und Bearbeitungsmodus — gespeichert wird immer ISO (yyyy-MM-dd)."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var ocrTab: some View {
        Form {
            Section(T("Sprachen")) {
                Toggle(T("Deutsch (de-DE)"), isOn: langBinding("de-DE"))
                Toggle(T("Englisch (en-US)"), isOn: langBinding("en-US"))
                Text(T("Die Texterkennung läuft per Vision vollständig lokal auf dem Mac — keine Daten gehen an externe Dienste."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(T("Qualität")) {
                LabeledContent(T("Genauigkeit")) {
                    Picker(T("Genauigkeit"), selection: $settings.ocrQuality) {
                        Text(T("Genau (accurate) — empfohlen")).tag("accurate")
                        Text(T("Schnell (fast)")).tag("fast")
                    }
                    .labelsHidden()
                    .frame(width: 230)
                }
                LabeledContent(T("Auflösung")) {
                    Picker(T("Auflösung"), selection: $settings.ocrResolutionDPI) {
                        Text(T("200 dpi — schnell")).tag(200)
                        Text(T("300 dpi — Standard")).tag(300)
                        Text(T("400 dpi — feine Schrift")).tag(400)
                    }
                    .labelsHidden()
                    .frame(width: 230)
                }
                Toggle(T("Sprachkorrektur (Language Correction)"), isOn: $settings.ocrLanguageCorrection)
                Text(T("„Genau“ + höhere dpi erkennen kleine Schrift deutlich besser, kosten aber Rechenzeit. Gilt ab dem nächsten Start der App."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var paperlessTab: some View {
        Form {
            Section(T("Verbindung (opt-in)")) {
                LabeledContent(T("URL")) {
                    TextField(T("https://paperless.example.local"), text: $settings.paperlessURL)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent(T("API-Token")) {
                    SecureField(T("Token"), text: $settings.paperlessToken)
                        .textFieldStyle(.roundedBorder)
                }
                Text(T("Das Token liegt sicher in der macOS-Keychain, nicht in der pless.db. Ohne URL + Token wird kein Netzwerk-Zugriff ausgeführt."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button { testConnection() } label: {
                        if testingConnection {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(T("Verbindung testen"), systemImage: "bolt.fill")
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
            Section(T("Sync & Import")) {
                Button { state.pullFromPaperless() } label: {
                    Label(T("Kategorien & Korrespondenten aus paperless importieren"), systemImage: "tray.and.arrow.down")
                }
                .disabled(testingConnection || state.syncRunning || settings.paperlessConfig() == nil)
                .help(T("Pull aus paperless-ngx: Document Types → Kategorien, Correspondents → Korrespondenten (bestehende Namen bleiben erhalten)"))
                Text(T("Push (Einweg): Kategorie → Document Type, Tags → Tags, Korrespondent → Correspondent (jeweils find-or-create in paperless). Der Dateiname bleibt als original_filename erhalten; bereits gesyncte Dokumente werden per SHA-256 übersprungen, reine Metadaten-Änderungen per PATCH nachgesendet."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var mcpTab: some View {
        Form {
            Section(T("MCP-Server (stdio) — z. B. für Claude Desktop")) {
                Text(settings.mcpConfigSnippet(binaryPath: "<Pfad-zum-Binary>/Pless"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                Button { copyMCPConfig() } label: {
                    Label(T("Config kopieren"), systemImage: "doc.on.doc")
                }
                Text(T("Server starten: Pless mcp --vault <Pfad> — JSON-RPC 2.0 über stdio, eine Nachricht pro Zeile."))
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
            title: T("KFZ-Versicherung 2026"), tags: ["wichtig"]))
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
                connectionResult = TF("Fehler: %@", error.localizedDescription)
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
