import Foundation
import PlessCore

/// App-Einstellungen (UserDefaults). Wirksam: Vault-Pfad/Import-Ordner beim nächsten Start,
/// Namensschema und OCR-Sprachen sofort (werden beim Anlegen der Services ausgelesen).
enum SettingsKey {
    static let vaultPath = "vaultPath"
    static let namingTemplate = "namingTemplate"
    static let ocrLanguages = "ocrLanguages"
    static let customInboxEnabled = "customInboxEnabled"
    static let customInboxPath = "customInboxPath"
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var vaultPath: String {
        didSet { save() }
    }
    @Published var namingTemplate: String {
        didSet { save() }
    }
    @Published var ocrLanguages: Set<String> {
        didSet { save() }
    }
    @Published var customInboxEnabled: Bool {
        didSet { save() }
    }
    @Published var customInboxPath: String {
        didSet { save() }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.vaultPath = defaults.string(forKey: SettingsKey.vaultPath) ?? "\(home)/Documents/Pless"
        self.namingTemplate = defaults.string(forKey: SettingsKey.namingTemplate) ?? NamingEngine.defaultTemplate
        self.ocrLanguages = Set(defaults.stringArray(forKey: SettingsKey.ocrLanguages) ?? ["de-DE", "en-US"])
        self.customInboxEnabled = defaults.bool(forKey: SettingsKey.customInboxEnabled)
        self.customInboxPath = defaults.string(forKey: SettingsKey.customInboxPath) ?? ""
    }

    func save() {
        defaults.set(vaultPath, forKey: SettingsKey.vaultPath)
        defaults.set(namingTemplate, forKey: SettingsKey.namingTemplate)
        defaults.set(Array(ocrLanguages).sorted(), forKey: SettingsKey.ocrLanguages)
        defaults.set(customInboxEnabled, forKey: SettingsKey.customInboxEnabled)
        defaults.set(customInboxPath, forKey: SettingsKey.customInboxPath)
    }

    /// Import-Ordner: eigener Pfad (falls aktiviert) oder Default `<vault>/inbox`.
    func inboxOverride() -> URL? {
        guard customInboxEnabled, !customInboxPath.isEmpty else { return nil }
        return URL(fileURLWithPath: (customInboxPath as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// MCP-Config-Snippet für Claude Desktop & Co.
    func mcpConfigSnippet(binaryPath: String) -> String {
        """
        {
          "mcpServers": {
            "pless": {
              "command": "\(binaryPath)",
              "args": ["mcp", "--vault", "\(vaultPath)"]
            }
          }
        }
        """
    }
}
