import AppKit
import QueryEngine
import RepositoryIndex
import SwiftUI
import VesaliusCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            RepositorySettings()
                .tabItem { Label("Repository", systemImage: "folder") }
            AgentSettings()
                .tabItem { Label("Agents", systemImage: "terminal") }
            PrivacySettings()
                .tabItem { Label("Privacy", systemImage: "lock") }
        }
        .frame(width: 620)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @State private var semantic = Preferences.semanticVectors
    @State private var history = Preferences.gitHistory
    @State private var watch = Preferences.watchForChanges
    @State private var editor = Preferences.preferredEditor ?? EditorLauncher.defaultEditor?.id ?? ""

    var body: some View {
        Form {
            Section("Indexing") {
                Toggle("Compute on-device semantic vectors", isOn: $semantic)
                    .onChange(of: semantic) { _, value in Preferences.semanticVectors = value }
                Text("Improves natural-language search using Apple's built-in language model. Runs locally.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3)
                Toggle("Read git history for change frequency", isOn: $history)
                    .onChange(of: history) { _, value in Preferences.gitHistory = value }
                Toggle("Update the index when files change", isOn: $watch)
                    .onChange(of: watch) { _, value in Preferences.watchForChanges = value }
            }
            Section("Editor") {
                let installed = Editor.installed
                if installed.isEmpty {
                    Text("No supported editor found. Files open with their default application.").foregroundStyle(Theme.Colors.text3)
                } else {
                    Picker("Open files in", selection: $editor) {
                        ForEach(installed) { editor in
                            Text(editor.name).tag(editor.id)
                        }
                    }
                    .onChange(of: editor) { _, value in Preferences.preferredEditor = value }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct RepositorySettings: View {
    @Environment(AppModel.self) private var model
    @State private var exclusions = ""
    @State private var confirmDelete = false

    var body: some View {
        Form {
            if let workspace = model.workspace {
                Section("Exclusions for \(workspace.name)") {
                    TextEditor(text: $exclusions)
                        .font(Theme.Font.mono)
                        .frame(height: 120)
                        .onAppear { exclusions = Preferences.exclusions(for: workspace.root.path).joined(separator: "\n") }
                    Text("One pattern per line, in .gitignore syntax, for example `Generated/` or `*.pb.swift`. Vesalius already respects .gitignore, a .vesaliusignore file, and skips build output, dependencies and vendored code.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3)
                    HStack {
                        Spacer()
                        Button("Save and Re-index") {
                            Preferences.setExclusions(exclusions.components(separatedBy: .newlines), for: workspace.root.path)
                            workspace.reindex(rebuild: true)
                        }
                    }
                }
                Section("Index") {
                    LabeledContent("Location") {
                        Text((workspace.engine.location.directory.path as NSString).abbreviatingWithTildeInPath)
                            .font(Theme.Font.monoSmall).textSelection(.enabled).lineLimit(2)
                    }
                    HStack {
                        Button("Reveal Index in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([workspace.engine.location.databaseURL])
                        }
                        Spacer()
                        Button("Rebuild Index") { workspace.reindex(rebuild: true) }
                        Button("Delete Index…", role: .destructive) { confirmDelete = true }
                    }
                    Text("Deleting the index never touches your repository. It is rebuilt the next time you open it.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3)
                }
                .confirmationDialog("Delete the index for \(workspace.name)?", isPresented: $confirmDelete) {
                    Button("Delete Index", role: .destructive) {
                        let location = workspace.engine.location
                        model.closeWorkspace()
                        // Waits for any CLI, MCP or watch process that is writing this index, so the database is never
                        // deleted mid-write.
                        Task { try? await IndexLock(location: location).withLock { try location.removeIndex() } }
                    }
                }
            } else {
                Text("Open a repository to edit its settings.").foregroundStyle(Theme.Colors.text3)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AgentSettings: View {
    @State private var installed = CommandLineInstaller.installedCommand()
    @State private var installMessage: String?
    @State private var connectMessages: [AgentKind: String] = [:]
    @State private var connecting: AgentKind?
    private let availability = AgentAvailability.shared

    private var mcpJSON: String {
        let mcp = CommandLineInstaller.mcpCommand()
        let args = mcp.arguments.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        {
          "mcpServers": {
            "vesalius": { "command": "\(mcp.command)", "args": [\(args)] }
          }
        }
        """
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("vesalius command") {
                    if let installed {
                        Label(installed, systemImage: "checkmark.circle").foregroundStyle(Theme.Colors.text2).font(Theme.Font.monoSmall)
                    } else {
                        Text("Not installed").foregroundStyle(Theme.Colors.text3)
                    }
                }
                HStack {
                    Button("Install for My User") {
                        do {
                            let link = try CommandLineInstaller.installForUser()
                            installed = CommandLineInstaller.installedCommand()
                            installMessage = CommandLineInstaller.isOnPath(link.deletingLastPathComponent())
                                ? "Installed \(link.path)."
                                : "Installed \(link.path). Add ~/.local/bin to your PATH to run `vesalius` by name."
                        } catch {
                            installMessage = error.localizedDescription
                        }
                    }
                    Button("Install System-Wide…") {
                        installMessage = CommandLineInstaller.installSystemWide() ?? "Installed \(CommandLineInstaller.systemPath)."
                        installed = CommandLineInstaller.installedCommand()
                    }
                }
                if let installMessage {
                    Text(installMessage).font(Theme.Font.caption).foregroundStyle(Theme.Colors.text2)
                }
                Text("The command is this app's own binary, so it always matches the app and shares its index.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3)
            } header: {
                Text("Command line")
            }

            Section {
                ForEach(AgentKind.allCases) { agent in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.displayName).font(Theme.Font.rowTitle)
                            Text(availability.paths[agent] ?? (availability.resolved ? "Not found on your shell PATH" : "Checking…"))
                                .font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3)
                        }
                        Spacer()
                        if connecting == agent {
                            ProgressView().controlSize(.small)
                        }
                        Button("Connect to Vesalius") { connect(agent) }
                            .disabled(!availability.isInstalled(agent) || connecting != nil)
                    }
                    if let message = connectMessages[agent] {
                        Text(message).font(Theme.Font.caption).foregroundStyle(Theme.Colors.text2)
                    }
                }
                Text("Registers the Vesalius MCP server for all your repositories. Agents then search the index instead of grepping the filesystem.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3)
            } header: {
                Text("Coding agents")
            }

            Section("Other MCP clients") {
                CopyableCode(text: mcpJSON)
            }
        }
        .formStyle(.grouped)
        .onAppear { availability.refresh() }
    }

    private func connect(_ agent: AgentKind) {
        connecting = agent
        let command = agent.connectCommand()
        Task.detached {
            let result = LoginShell.run(command, timeout: 30)
            await MainActor.run {
                connecting = nil
                connectMessages[agent] = result.status == 0
                    ? "Connected. \(agent.displayName) can now use the vesalius tools."
                    : "Could not connect: " + (result.error.isEmpty ? result.output : result.error).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
}

private struct PrivacySettings: View {
    var body: some View {
        Form {
            Section {
                Label("Indexing never leaves this Mac", systemImage: "lock")
                    .font(Theme.Font.rowTitle)
                Text("Scanning, parsing, the dependency graph, health analysis, search and semantic vectors all run locally. Vesalius makes no network requests and has no accounts or telemetry. Indexes are stored in ~/Library/Application Support/Vesalius and can be deleted at any time.")
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.Colors.text2)
                Text("Vesalius only reads your repository. Agent runs you start from the app are the exception: Claude Code or Codex sends what it reads to its own model, and Allow edits mode edits your working tree.")
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.Colors.text2)
            }
        }
        .formStyle(.grouped)
    }
}

struct CopyableCode: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top) {
            Text(text)
                .font(Theme.Font.mono)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
        .padding(Theme.Space.s)
        .background(Theme.Colors.inset, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
    }
}
