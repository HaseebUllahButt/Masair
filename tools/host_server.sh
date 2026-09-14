#!/usr/bin/env bash
# Host a Splendor race night: serves the web build and the race lobby.
#
#   tools/host_server.sh [WEBROOT] [HTTP_PORT] [extra mp_server args...]
#
# WEBROOT defaults to build/web (run `godot --headless --path . --export-release
# "Web" build/web/index.html` first — needs export templates installed).
# The websocket port is always HTTP_PORT + 1; the game page derives it from
# the address bar, so friends never type it. Forward both ports, then give
# friends http://<your-ip>:<port>. Extra args go to mp_server.gd, e.g.
#   tools/host_server.sh build/web 8000 --dist=10000
set -euo pipefail
cd "$(dirname "$0")/.."
web="${1:-build/web}"
http="${2:-8000}"
set -- "${@:3}"
exec godot --headless --path . --script res://tools/mp_server.gd -- \
    --http="$http" --ws="$((http + 1))" --webroot="$web" "$@"
