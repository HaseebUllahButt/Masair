#!/usr/bin/env bash
# Install uv (if missing) and verify GodotIQ MCP can start.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v uvx >/dev/null 2>&1; then
  echo "Installing uv (provides uvx)..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

echo "Installing/updating godotiq..."
uvx godotiq --version

echo "Refreshing GodotIQ addon in this project..."
uvx godotiq install-addon "$ROOT"

echo
echo "Done. Next steps:"
echo "  1. Restart Cursor (or toggle the godotiq MCP server off/on)"
echo "  2. Open Masair in Godot 4.x and enable Project → Project Settings → Plugins → GodotIQ"
echo "  3. In Cursor, pick Grok 4.5 and ask: Ping GodotIQ"
