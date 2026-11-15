import Foundation

// Einstiegspunkt.
// Ohne Argumente: GUI-App (ab Phase 6).
// `pless mcp --vault <pfad>`: MCP-Server über stdio (ab Phase 10).
let arguments = CommandLine.arguments
if arguments.count > 1, arguments[1] == "mcp" {
    FileHandle.standardOutput.write(Data("pless mcp: noch nicht implementiert\n".utf8))
} else {
    FileHandle.standardOutput.write(Data("pless gui: noch nicht implementiert\n".utf8))
}
