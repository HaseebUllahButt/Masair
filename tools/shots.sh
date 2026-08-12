#!/usr/bin/env bash
# Capture Masair frames without a window, focus steal or audio.
#
#   tools/shots.sh OUTDIR [mode] [extra screenshot.gd args...]
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:?usage: shots.sh OUTDIR [mode] [args...]}"; shift
mode="${1:-dusk}"; [ $# -gt 0 ] && shift
gamescope -W 1280 -H 720 --backend headless -- \
    godot --path . --audio-driver Dummy --script res://tools/screenshot.gd -- \
    "--out=$out" "--mode=$mode" "$@" 2>&1 |
    grep -E "^shot |^perf:|^hitches:|^gpu:|SHADER ERROR|Shader compilation|SCRIPT ERROR" || true
