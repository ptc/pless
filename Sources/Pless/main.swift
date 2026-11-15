import Foundation
import PlessCore

// Entry point. Without arguments: launch the GUI app.
// With `mcp`: run as MCP server over stdio (for local AI assistants).
let arguments = CommandLine.arguments
if arguments.count > 1, arguments[1] == "mcp" {
    print(Probe.ok()) // placeholder until the MCP server lands
    FileHandle.standardOutput.write("pless mcp: not implemented yet\n".data(using: .utf8)!)
} else {
    print(Probe.ok())
    print("pless gui: not implemented yet")
}
