#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

hotspot=0
args=()
for arg in "$@"; do
	if [[ "$arg" == "--hotspot" ]]; then
		hotspot=1
	else
		args+=("$arg")
	fi
done

if ! command -v godot >/dev/null 2>&1; then
	echo "!! godot not found — install Godot 4.7 and re-run" >&2
	exit 1
fi

mkdir -p build/web
if [[ ! -f build/web/index.html || ! -f build/web/index.pck ]]; then
	echo ">> no web build yet — exporting once…"
	if ! godot --headless --path . --export-release "Web" build/web/index.html; then
		echo "!! export failed. Install the matching Godot 4.7.2 export templates and re-run." >&2
		exit 1
	fi
fi

if [[ "$hotspot" == 1 ]]; then
	exec tools/splendor_multiplayer.sh "${args[@]}"
fi
exec tools/splendor_multiplayer.sh --no-hotspot "${args[@]}"
