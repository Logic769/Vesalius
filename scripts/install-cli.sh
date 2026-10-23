#!/usr/bin/env bash
# Builds the `vesalius` command-line tool (release) and installs it.
# Usage: scripts/install-cli.sh [install-directory]   (default: ~/.local/bin)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${1:-$HOME/.local/bin}"

echo "Building vesalius (release)…"
swift build -c release --product vesalius --package-path "$ROOT/VesaliusKit"

mkdir -p "$PREFIX"
install -m 0755 "$ROOT/VesaliusKit/.build/release/vesalius" "$PREFIX/vesalius"
echo "Installed $PREFIX/vesalius ($("$PREFIX/vesalius" --version))"

case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *) echo "Note: $PREFIX is not on your PATH. Add this to your shell profile:"
     echo "  export PATH=\"$PREFIX:\$PATH\"" ;;
esac
