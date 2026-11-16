import SwiftUI
import AppKit
import PlessCore

/// Nimmt Dateien entgegen, die auf das App-/Dock-Icon gezogen werden („Öffnen mit“ / Dock-Drop).
final class PlessAppDelegate: NSObject, NSApplicationDelegate {
    var onOpenFiles: (([URL]) -> Void)?
    func application(_ application: NSApplication, open urls: [URL]) {
        onOpenFiles?(urls)
    }
}

@main
struct PlessApp: App {
    @StateObject private var state: AppState
    @NSApplicationDelegateAdaptor(PlessAppDelegate.self) private var appDelegate

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
        let st = AppState(vaultPath: Self.vaultPath(from: args, settings), settings: settings)
        _state = StateObject(wrappedValue: st)
        _appDelegate = NSApplicationDelegateAdaptor(PlessAppDelegate.self)
        appDelegate.onOpenFiles = { urls in
            st.importFiles(urls.filter { $0.pathExtension.lowercased() == "pdf" })
        }
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
                        .environmentObject(state)   // SettingsView liest state (paperless-Pull) — ohne Injection crasht das Sheet
                        .frame(width: 680, height: 540)
                }
        }
        .commands {
            CommandMenu("Ablage") {
                Button("Importieren…") { importPanel() }
                    .keyboardShortcut("I", modifiers: .command)
                Button("Posteingang jetzt scannen") { state.scanInbox() }
                Divider()
                Button("Zu paperless-ngx synchronisieren") { state.syncAll() }
                    .disabled(!state.syncConfigured())
            }
            CommandMenu("Auswahl") {
                Button("Alle auswählen") { state.selectAll() }
                    .keyboardShortcut("a", modifiers: .command)
                Button("Auswahl aufheben") { state.clearSelection() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
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
