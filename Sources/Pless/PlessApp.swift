import SwiftUI
import AppKit
import PlessCore

@main
struct PlessApp: App {
    @StateObject private var state: AppState

    init() {
        let args = CommandLine.arguments
        if args.count > 1 && args[1] == "mcp" {
            // MCP-Server über stdio (JSON-RPC 2.0, eine Nachricht pro Zeile).
            do {
                let v = try Vault(root: Self.vaultPath(from: args))
                let db = try Database(url: v.databaseURL)
                exit(MCPServer(vault: v, db: db).runStdio())
            } catch {
                FileHandle.standardError.write(Data("pless mcp: \(error)\n".utf8))
                exit(1)
            }
        }
        let settings = SettingsStore()
        _state = StateObject(wrappedValue: AppState(vaultPath: Self.vaultPath(from: args, settings),
                                                   settings: settings))
    }

    static func vaultPath(from args: [String], _ settings: SettingsStore? = nil) -> URL {
        if let i = args.firstIndex(of: "--vault"), i + 1 < args.count {
            return URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
        }
        if let path = settings?.vaultPath, !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Pless", isDirectory: true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(state)
                .frame(minWidth: 960, minHeight: 600)
                .sheet(isPresented: Binding(
                    get: { state.showSettings },
                    set: { state.showSettings = $0 })) {
                    SettingsView(settings: state.settings)
                        .frame(width: 560, height: 520)
                }
        }
        .commands {
            CommandMenu("Ablage") {
                Button("Importieren…") { importPanel() }
                    .keyboardShortcut("I", modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Einstellungen…") { state.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }

    private func importPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            state.importFiles(panel.urls)
        }
    }
}
