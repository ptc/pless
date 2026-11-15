import SwiftUI
import AppKit

@main
struct PlessApp: App {
    @StateObject private var state: AppState

    init() {
        let args = CommandLine.arguments
        if args.count > 1 && args[1] == "mcp" {
            // MCP-Server über stdio — kommt in Phase 10.
            FileHandle.standardOutput.write(Data("pless mcp: noch nicht implementiert (Phase 10)\n".utf8))
            exit(0)
        }
        _state = StateObject(wrappedValue: AppState(vaultPath: Self.vaultPath(from: args)))
    }

    static func vaultPath(from args: [String]) -> URL {
        if let i = args.firstIndex(of: "--vault"), i + 1 < args.count {
            return URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Pless", isDirectory: true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(state)
        }
        .commands {
            CommandMenu("Ablage") {
                Button("Importieren…") { importPanel() }
                    .keyboardShortcut("I", modifiers: .command)
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
