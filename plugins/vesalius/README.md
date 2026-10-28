# Vesalius plugin for Claude Code

This plugin registers the Vesalius MCP server with Claude Code. Vesalius is
an on-device code graph: it reads a repository once, on your Mac, and
answers questions about how the code connects, with file and line evidence.
Every tool is read-only. Indexing never uploads your code.

## Requirements

A Mac with Apple silicon on macOS 15 or later, and the `vesalius` command
installed before you enable the plugin:

```bash
brew install haplollc/tap/vesalius
```

The plugin does not bundle the binary. If Claude Code cannot find
`vesalius`, give the full path, `/opt/homebrew/bin/vesalius`, in your own
MCP configuration instead of using this plugin.

## Install

```bash
claude plugin marketplace add haplollc/Vesalius
claude plugin install vesalius@haplo
```

Then start Claude Code in a project and ask the way you normally would.
The plugin is an alternative to running `vesalius setup`, which registers
the same server by hand.

## What Claude Code gets

The server runs `vesalius mcp` over stdio and serves the repository Claude
Code is working in. The tools are:

| Tool | Ask it |
| --- | --- |
| `usages` | Who calls X? What uses this file? What breaks if I rename X? |
| `feature_map` | Where are purchases handled? How is data persisted? |
| `outline` | What is in this file, type, or function? |
| `architecture` | How is this project put together? |
| `dependency_cycles` | Do we have circular imports? |

`usages` and `feature_map` load up front. The other three load on demand.
Set the plugin's `profile` option to `lean` to load every tool on demand,
or to `full` to add a sixth tool, `repo_report`, for health, diagnostics,
hotspots, and unused code.

## Validate locally

The `claude` CLI is the authoritative check. From the repository root:

```bash
claude plugin validate ./plugins/vesalius
```

To load the plugin from this folder without a marketplace:

```bash
claude --plugin-dir ./plugins/vesalius
```

## Links

Repository: https://github.com/haplollc/Vesalius
