#!/usr/bin/env bash
## Export Masair for Windows and build MasairSetup-*.exe (Inno Setup via Wine).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/windows"
PAYLOAD="$BUILD/payload"
OUT_ZIP="$BUILD/Masair-windows-x86_64.zip"
CACHE="$ROOT/packaging/windows/.cache"
GODOT_WIN_ZIP_URL="https://github.com/godotengine/godot/releases/download/4.7.1-stable/Godot_v4.7.1-stable_win64.exe.zip"
GODOT_WIN_TEMPLATE="$CACHE/Godot_v4.7.1-stable_win64.exe"
INNO_DIR="${HOME}/.local/share/masair-tools/inno"
INNO_URL="https://github.com/jrsoftware/issrc/releases/download/is-6_7_3/innosetup-6.7.3.exe"
VERSION="1.1.0"
PRESET_CFG="$ROOT/export_presets.cfg"

log() { printf '==> %s\n' "$*"; }

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "missing required command: $1" >&2
		exit 1
	}
}

ensure_ico() {
	local ico="$ROOT/packaging/windows/masair.ico"
	[[ -f "$ico" ]] && return
	need_cmd rsvg-convert
	need_cmd magick
	log "generating packaging/windows/masair.ico"
	local tmp
	tmp="$(mktemp -d)"
	for s in 16 32 48 64 128 256; do
		rsvg-convert -w "$s" -h "$s" "$ROOT/icon.svg" -o "$tmp/$s.png"
	done
	magick "$tmp/16.png" "$tmp/32.png" "$tmp/48.png" "$tmp/64.png" "$tmp/128.png" "$tmp/256.png" "$ico"
	rm -rf "$tmp"
}

ensure_windows_template() {
	mkdir -p "$CACHE"
	if [[ -f "$GODOT_WIN_TEMPLATE" ]]; then
		log "windows export template ready"
		return
	fi
	need_cmd curl
	need_cmd unzip
	log "downloading Godot 4.7.1 Windows editor (used as export template)"
	local zip="$CACHE/godot-win64.zip"
	curl -L --fail --retry 3 --retry-all-errors --progress-bar "$GODOT_WIN_ZIP_URL" -o "$zip"
	unzip -qo "$zip" -d "$CACHE/extracted"
	local found
	found="$(find "$CACHE/extracted" -iname 'Godot*.exe' ! -iname '*console*' | head -n1)"
	[[ -n "$found" ]] || {
		echo "Godot Windows exe not found in zip" >&2
		exit 1
	}
	cp -a "$found" "$GODOT_WIN_TEMPLATE"
	rm -rf "$CACHE/extracted" "$zip"
	log "template at $GODOT_WIN_TEMPLATE"
}

point_preset_at_template() {
	## Godot wants an absolute filesystem path for custom export templates.
	python3 - "$PRESET_CFG" "$GODOT_WIN_TEMPLATE" <<'PY'
import pathlib, sys
cfg = pathlib.Path(sys.argv[1])
template = pathlib.Path(sys.argv[2]).resolve().as_posix()
text = cfg.read_text()
out = []
for line in text.splitlines():
	if line.startswith("custom_template/release="):
		out.append(f'custom_template/release="{template}"')
	elif line.startswith("custom_template/debug="):
		out.append(f'custom_template/debug="{template}"')
	else:
		out.append(line)
cfg.write_text("\n".join(out) + "\n")
print(f"preset template -> {template}")
PY
}

ensure_inno() {
	local iscc=""
	if [[ -f "$INNO_DIR/ISCC.exe" ]]; then
		echo "$INNO_DIR/ISCC.exe"
		return
	fi
	local found
	found="$(find "$HOME/.wine/drive_c/Program Files (x86)/Inno Setup 6" "$HOME/.wine/drive_c/Program Files/Inno Setup 6" "$INNO_DIR" -iname 'ISCC.exe' 2>/dev/null | head -n1 || true)"
	if [[ -n "$found" ]]; then
		echo "$found"
		return
	fi
	need_cmd curl
	need_cmd wine
	log "downloading Inno Setup"
	mkdir -p "$INNO_DIR"
	local setup="$INNO_DIR/innosetup-installer.exe"
	curl -L --fail --retry 3 --retry-all-errors --progress-bar "$INNO_URL" -o "$setup"
	log "installing Inno Setup under Wine (silent)"
	wine "$setup" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- || true
	found="$(find "$HOME/.wine/drive_c/Program Files (x86)/Inno Setup 6" "$HOME/.wine/drive_c/Program Files/Inno Setup 6" -iname 'ISCC.exe' 2>/dev/null | head -n1 || true)"
	[[ -n "$found" ]] || {
		echo "ISCC.exe not found after Inno Setup install" >&2
		exit 1
	}
	echo "$found"
}

export_game() {
	need_cmd godot
	log "exporting Windows Desktop release"
	rm -rf "$PAYLOAD"
	mkdir -p "$PAYLOAD" "$BUILD"
	godot --headless --path "$ROOT" --export-release "Windows Desktop" "$PAYLOAD/Masair.exe"
	[[ -f "$PAYLOAD/Masair.exe" ]] || {
		echo "export failed — Masair.exe missing" >&2
		exit 1
	}
	cp -a "$PAYLOAD/Masair.exe" "$BUILD/Masair.exe"
	if [[ -f "$PAYLOAD/Masair.pck" ]]; then
		cp -a "$PAYLOAD/Masair.pck" "$BUILD/Masair.pck"
	fi
	# Copy any side-by-side DLLs Godot may emit
	find "$PAYLOAD" -maxdepth 1 -type f ! -name 'Masair.exe' -exec cp -a {} "$BUILD"/ \;
	log "export ok ($(du -h "$PAYLOAD/Masair.exe" | awk '{print $1}'))"
}

make_zip() {
	need_cmd zip
	log "writing $OUT_ZIP"
	rm -f "$OUT_ZIP"
	(
		cd "$PAYLOAD"
		zip -qr "$OUT_ZIP" .
	)
}

make_installer() {
	local iscc
	iscc="$(ensure_inno)"
	need_cmd wine
	log "compiling Inno Setup installer with $iscc"
	# ISCC resolves Source paths relative to the .iss file location
	wine "$iscc" "$(winepath -w "$ROOT/packaging/windows/masair.iss")"
	local setup="$BUILD/MasairSetup-${VERSION}.exe"
	[[ -f "$setup" ]] || {
		echo "installer missing at $setup" >&2
		ls -la "$BUILD" >&2 || true
		exit 1
	}
	log "installer ready: $setup ($(du -h "$setup" | awk '{print $1}'))"
}

main() {
	ensure_ico
	ensure_windows_template
	point_preset_at_template
	export_game
	make_zip
	make_installer
	log "done"
	ls -lh "$BUILD/Masair.exe" "$OUT_ZIP" "$BUILD/MasairSetup-${VERSION}.exe"
}

main "$@"
