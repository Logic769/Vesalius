# Vesalius: Code Anatomy for VS Code

See the anatomy of your codebase without leaving the editor: what a file depends on, what depends on it, how risky a change is, where a symbol is really used, and how healthy the repository is overall. Answers come from a local Vesalius index, so they are fast, and the extension itself sends nothing off your machine.

This extension is a thin client over the `vesalius` command line tool. Every view, lens and command runs `vesalius <command> --json` against the index for your workspace folder.

## Features

**Activity bar views.** A Vesalius container with three views, each with a refresh button:

- **Health**: the repository score (0 to 100) and grade, the eight category scores with the deductions behind them, and the findings grouped by severity. Click a finding to open it.
- **Current File**: follows the active editor. Shows the change risk, the files that use this file (Used by), the files it uses (Depends on), its symbols, its findings and related files.
- **Hotspots**: the files where size, complexity, coupling, churn and findings concentrate, with the reasons for each.

**Blast Radius.** `Vesalius: Show Change Impact` opens a panel for the current file, or for the declaration under the cursor: risk level and score, the factors that drive it, direct and transitive dependents, call sites with snippets, related tests and affected areas. Every path is clickable, and the panel takes all of its colors from your theme.

**Problems panel.** Code health findings appear as diagnostics with source `Vesalius`. Critical and high findings are warnings, medium findings are information, low and info findings are hints. Each one carries the recommendation and links to the other files involved (for example, both sides of a dependency cycle).

**CodeLens.** `N references · risk <level>` above top-level types and functions. Click it to peek every reference from the graph.

**Graph navigation.** `Find References (Graph)` and `Find Callers` resolve the symbol under the cursor through the index and show the results in the native references peek.

**Ask the codebase.** Ask a question in plain words ("where are invoice totals calculated?") and get ranked files with the reason each one matched. Enter opens the best lines; the pulse button on a result shows its blast radius.

**Status bar.** `Health 84` with a category breakdown in the tooltip. The icon spins while the index updates.

**Always current.** The index updates incrementally in the background when the window opens, 1.5 seconds after you save, and when you create, rename or delete files in VS Code. Views, lenses and diagnostics refresh afterwards.

**MCP server for agents.** On VS Code 1.101 and later the extension registers a `Vesalius` MCP server for each workspace folder, so agent mode can query the same index. `Vesalius: Copy MCP Config` produces ready-to-paste configuration for Claude Code, Codex, Claude Desktop, Cursor and other MCP clients.

## Requirements

- macOS, with the Vesalius app or the `vesalius` command line tool.
- VS Code 1.95 or later (1.101 or later for the built-in MCP server registration).

## Install

1. Build the `.vsix` (see [Build from source](#build-from-source)) and install it: run `Extensions: Install from VSIX...` in VS Code, or

   ```sh
   code --install-extension vesalius-1.0.0.vsix
   ```

2. Make the `vesalius` command available. Any one of these works:
   - Install it with Homebrew: `brew install haplollc/tap/vesalius`.
   - Run `Vesalius: Install Vesalius CLI`. When the Vesalius app is in `/Applications`, this links `~/.local/bin/vesalius` to the command line tool inside the app. No administrator password is needed.
   - In the Vesalius app, open Settings, then Agents, then choose Install for My User.
   - Build it from source and point the `vesalius.cliPath` setting at the binary (see Build from source).

3. Open a folder. The first index is built in the background; the status bar shows its progress.

### How the extension finds the CLI

The first match wins:

1. The `vesalius.cliPath` setting (a path that does not exist is reported, not skipped).
2. The `VESALIUS_CLI_PATH` environment variable.
3. `vesalius` on your `PATH`.
4. `~/.local/bin/vesalius`, `/usr/local/bin/vesalius`, `/opt/homebrew/bin/vesalius`.
5. The command line tool inside `/Applications/Vesalius.app` or `~/Applications/Vesalius.app`.
6. A development build in the workspace: `VesaliusKit/.build/release/vesalius`, then `VesaliusKit/.build/debug/vesalius`.

`Vesalius: Show Output` shows which one is in use and every command the extension runs.

## Commands

| Command | What it does |
| --- | --- |
| Vesalius: Ask the Codebase... | Ask a question in plain words; results open at the most relevant lines. |
| Vesalius: Show Change Impact | Blast radius of the current file, or of the declaration under the cursor. Also in the editor, tab and explorer context menus. |
| Vesalius: Find References (Graph) | Every resolved reference to the symbol under the cursor, in the references peek. |
| Vesalius: Find Callers | Call sites of the function or method under the cursor, in the references peek. |
| Vesalius: Show File Context | Shows a file in the Current File view (also in the explorer context menu). |
| Vesalius: Update Index | Incremental update of every workspace folder, with progress. |
| Vesalius: Rebuild Index | Rebuilds the index from scratch. |
| Vesalius: Show Repository Health | Focuses the Health view and reloads it. |
| Vesalius: Open in Vesalius App | Opens the workspace (and the current file) in the Vesalius app. |
| Vesalius: Copy MCP Config | Copies MCP server configuration as JSON, a Claude Code command, Codex TOML or `.vscode/mcp.json`. |
| Vesalius: Install Vesalius CLI | Links `~/.local/bin/vesalius` to the app's command line tool. |
| Vesalius: Show Output | Opens the Vesalius log. |

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| `vesalius.cliPath` | empty | Path to the `vesalius` command. Empty means find it automatically (see above). |
| `vesalius.diagnostics.enabled` | `true` | Show findings in the Problems panel. |
| `vesalius.diagnostics.minimumSeverity` | `medium` | Lowest severity shown in the Problems panel: `info`, `low`, `medium`, `high` or `critical`. |
| `vesalius.codeLens.enabled` | `true` | Show reference counts and change risk above top-level types and functions. |
| `vesalius.indexOnSave` | `true` | Update the index after files are saved, created, renamed or deleted. |
| `vesalius.queryTimeoutSeconds` | `60` | Time limit for one query. |
| `vesalius.indexTimeoutSeconds` | `900` | Time limit for one index update. |

## MCP server

On VS Code 1.101 and later the extension registers an MCP server definition named `Vesalius` (`vesalius mcp --repo <folder>`) for each workspace folder; with several folders each one is labeled with its folder name. It appears in `MCP: List Servers`, and agent mode can start it when it needs a Vesalius tool. VS Code may ask you to trust the server the first time it starts. The server offers five read-only tools: `usages` (who calls, uses or depends on a symbol or file, and what a change touches), `feature_map` (where a feature is implemented), `architecture`, `dependency_cycles` and `outline`.

On older versions of VS Code, or for other clients, run `Vesalius: Copy MCP Config` and pick a format:

- **JSON** for Claude Desktop, Cursor, Windsurf and most clients (`mcpServers`).
- **Claude Code**: a `claude mcp add vesalius -- ...` command to run in a terminal.
- **Codex**: a `[mcp_servers.vesalius]` table for `~/.codex/config.toml`.
- **VS Code**: a `servers` entry for `.vscode/mcp.json`.

## Privacy

Vesalius reads your repository and writes its index to `~/Library/Application Support/Vesalius/Indexes` (or to `$VESALIUS_HOME/Indexes` when that variable is set). It never modifies your files and never sends source code anywhere; the extension only runs the local `vesalius` command. When VS Code's agent mode or another MCP client calls the Vesalius server, the answers it reads go to that agent's model, as anything else the agent reads does.

## Troubleshooting

**"The Vesalius command line tool was not found."** Run `Vesalius: Install Vesalius CLI`, or set `vesalius.cliPath` to the full path of the binary. Check `Vesalius: Show Output` to see where the extension looked.

**A file says it is not in the index.** It is excluded by `.gitignore` or `.vesaliusignore`, it is generated or vendored code, or its language is not supported. Unsupported files still open normally; they simply have no Vesalius data.

**Results look out of date.** Run `Vesalius: Update Index`. If you edit files outside VS Code, the next save, refresh or update picks the changes up. `Vesalius: Rebuild Index` starts over if something looks wrong.

**No CodeLens.** Check that both `vesalius.codeLens.enabled` and the editor setting `editor.codeLens` are on.

**Queries or indexing time out on a very large repository.** Raise `vesalius.queryTimeoutSeconds` or `vesalius.indexTimeoutSeconds`.

**The status bar shows a warning.** The last index update failed. Hover for the error, or open `Vesalius: Show Output` for the full log.

**Open in Vesalius App does nothing.** The app must be installed; the extension opens it through its `vesalius://open` link and falls back to `open -a Vesalius`.

## Build from source

```sh
cd vscode-extension
npm ci
npm run compile     # TypeScript to out/
npm run package     # writes vesalius-1.0.0.vsix
```

The command line tool comes from the Swift package in `VesaliusKit`:

```sh
swift build -c release --product vesalius --package-path VesaliusKit
```

### Tests

The tests are end to end: they download VS Code, open real workspaces, and drive the extension against the real `vesalius` command. Nothing is mocked.

```sh
VESALIUS_CLI_PATH=../VesaliusKit/.build/debug/vesalius npm test
```

The run has up to three parts:

1. A generated TypeScript and Python repository with a known shape (an import cycle, a large file, a call chain). It covers activation, indexing, Problems, CodeLens, references and callers, the views, Ask, Blast Radius, the status bar, index on save and the MCP configuration (including a real MCP handshake).
2. A workspace with no CLI installed, which then recovers through the `vesalius.cliPath` setting. It is skipped when a `vesalius` binary is already installed in one of the well-known locations.
3. An existing repository of your choice, read only, when `VESALIUS_TEST_REPO` is set. The runner checks that `git status` is identical before and after.

```sh
VESALIUS_TEST_REPO=~/code/my-app VESALIUS_CLI_PATH=../VesaliusKit/.build/debug/vesalius npm test
```

Indexes go to `VESALIUS_HOME` when it is set, otherwise to a temporary folder, never to Application Support. Temporary fixtures and VS Code profiles are deleted when the run ends.

Other switches:

- `VSCODE_TEST_VERSION=1.95.0` runs on a specific VS Code release instead of the latest stable (1.95 is the oldest supported).
- `VESALIUS_TEST_EXTENSION_PATH=<folder>` tests another copy of the extension, such as the contents of an installed `.vsix`.
- `VESALIUS_TEST_SCREENSHOTS=<folder>` saves screenshots of the test window (macOS).

## License

MIT
