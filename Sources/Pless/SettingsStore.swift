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
    static let dateFormat = "dateFormat"
    static let ocrQuality = "ocrQuality"               // "accurate" | "fast"
    static let ocrLanguageCorrection = "ocrLanguageCorrection"
    static let ocrResolutionDPI = "ocrResolutionDPI"
    static let paperlessURL = "paperlessURL"
    // paperlessToken liegt NICHT in UserDefaults, sondern in der Keychain (KeychainStore)
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
    /// Anzeigeformat für Datumsfelder (DB bleibt ISO yyyy-MM-dd); Default deutsch.
    @Published var dateFormat: String {
        didSet { save() }
    }
    /// OCR-Genauigkeit: "accurate" (Default, besser bei kleiner Schrift) oder "fast".
    @Published var ocrQuality: String {
        didSet { save() }
    }
    /// OCR-Sprachkorrektur (Vision usesLanguageCorrection).
    @Published var ocrLanguageCorrection: Bool {
        didSet { save() }
    }
    /// OCR-Render-Auflösung in dpi (200/300/400) — höhere Werte = feinere Erkennung, langsamer.
    @Published var ocrResolutionDPI: Int {
        didSet { save() }
    }
    /// paperless-ngx Basis-URL (leer = Sync deaktiviert, kein Netzwerk-Zugriff).
    @Published var paperlessURL: String {
        didSet { save() }
    }
    /// paperless-ngx API-Token — wird in der Keychain gespeichert, nicht in UserDefaults.
    @Published var paperlessToken: String {
        didSet {
            if paperlessToken.isEmpty {
                KeychainStore.deleteToken()
            } else {
                KeychainStore.saveToken(paperlessToken)
            }
        }
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
        self.dateFormat = defaults.string(forKey: SettingsKey.dateFormat) ?? "dd.MM.yyyy"
        self.ocrQuality = defaults.string(forKey: SettingsKey.ocrQuality) ?? "accurate"
        self.ocrLanguageCorrection = defaults.object(forKey: SettingsKey.ocrLanguageCorrection) as? Bool ?? true
        self.ocrResolutionDPI = defaults.object(forKey: SettingsKey.ocrResolutionDPI) as? Int ?? 300
        self.paperlessURL = defaults.string(forKey: SettingsKey.paperlessURL) ?? ""
        self.paperlessToken = KeychainStore.loadToken() ?? ""
    }

    func save() {
        defaults.set(vaultPath, forKey: SettingsKey.vaultPath)
        defaults.set(namingTemplate, forKey: SettingsKey.namingTemplate)
        defaults.set(Array(ocrLanguages).sorted(), forKey: SettingsKey.ocrLanguages)
        defaults.set(customInboxEnabled, forKey: SettingsKey.customInboxEnabled)
        defaults.set(customInboxPath, forKey: SettingsKey.customInboxPath)
        defaults.set(dateFormat, forKey: SettingsKey.dateFormat)
        defaults.set(ocrQuality, forKey: SettingsKey.ocrQuality)
        defaults.set(ocrLanguageCorrection, forKey: SettingsKey.ocrLanguageCorrection)
        defaults.set(ocrResolutionDPI, forKey: SettingsKey.ocrResolutionDPI)
        defaults.set(paperlessURL, forKey: SettingsKey.paperlessURL)
    }

    /// OCR-Qualität als Enum (unbekannter Wert → .accurate).
    var ocrQualityEnum: OCRQuality { OCRQuality(rawValue: ocrQuality) ?? .accurate }

    /// Sync-Konfiguration — nil, solange URL oder Token fehlt (dann: kein Netzwerk-Call möglich).
    func paperlessConfig() -> PaperlessConfig? {
        let trimmed = paperlessURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paperlessToken.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return PaperlessConfig(baseURL: url, token: paperlessToken)
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
