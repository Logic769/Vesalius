import Foundation
import SwiftUI
import VesaliusCommands

/// One binary, two personalities: started normally it is the macOS app; started through a `vesalius`
/// symlink (or with `--cli`) it is the command-line tool and MCP server, sharing the same engine.
@main
enum EntryPoint {
    static func main() {
        if let arguments = CommandLineMode.arguments(CommandLine.arguments) {
            Task.detached {
                await VesaliusCommand.runCommandLine(arguments)
            }
            dispatchMain()
        } else {
            VesaliusApp.main()
        }
    }
}

enum CommandLineMode {
    /// Arguments for the CLI, or nil when the binary should launch the app.
    nonisolated static func arguments(_ argv: [String]) -> [String]? {
        guard let first = argv.first else { return nil }
        if (first as NSString).lastPathComponent == "vesalius" { return Array(argv.dropFirst()) }
        if argv.count > 1, argv[1] == "--cli" { return Array(argv.dropFirst(2)) }
        return nil
    }
}
