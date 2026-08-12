#!/usr/bin/env bash
## Export Masair for Windows and build MasairSetup-*.exe (Inno Setup via Wine).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/windows"
PAYLOAD="$BUILD/payload"
OUT_ZIP="$BUILD/Masair-windows-x86_64.zip"
TEMPLATES_DIR="${HOME}/.local/share/godot/export_templates/4.7.1.stable"
TEMPLATES_URL="https://github.com/godotengine/godot/releases/download/4.7.1-stable/Godot_v4.7.1-stable_export_templates.tpz"
INNO_DIR="${HOME}/.local/share/masair-tools/inno"
INNO_URL="https://jrsoftware.org/download.php/is.exe"
VERSION="1.1.0"

log() { printf '==> %s\n' "$*"; }

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "missing required command: $1" >&2
		exit 1
	}
}

ensure_templates() {
	if [[ -f "$TEMPLATES_DIR/windows_release_x86_64.exe" ]]; then
		log "export templates already installed"
		return
	fi
	need_cmd curl
	need_cmd unzip
	log "downloading Godot 4.7.1 export templates"
	local tmp
	tmp="$(mktemp -d)"
	curl -L --fail --progress-bar "$TEMPLATES_URL" -o "$tmp/templates.tpz"
	mkdir -p "$TEMPLATES_DIR"
	unzip -qo "$tmp/templates.tpz" -d "$tmp/extracted"
	# tpz layout: templates/*
	if [[ -d "$tmp/extracted/templates" ]]; then
		cp -a "$tmp/extracted/templates/." "$TEMPLATES_DIR/"
	else
		cp -a "$tmp/extracted/." "$TEMPLATES_DIR/"
	fi
	rm -rf "$tmp"
	[[ -f "$TEMPLATES_DIR/windows_release_x86_64.exe" ]] || {
		echo "templates install failed — windows_release_x86_64.exe missing" >&2
		exit 1
	}
	log "templates installed to $TEMPLATES_DIR"
}

ensure_ico() {
	local ico="$ROOT/packaging/windows/masair.ico"
	if [[ -f "$ico" ]]; then
		return
	fi
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

ensure_inno() {
	local iscc="$INNO_DIR/ISCC.exe"
	if [[ -f "$iscc" ]]; then
		echo "$iscc"
		return
	fi
	need_cmd curl
	need_cmd wine
	need_cmd 7z
	log "downloading Inno Setup (silent install under Wine)"
	mkdir -p "$INNO_DIR"
	local setup="$INNO_DIR/innosetup-installer.exe"
	curl -L --fail --progress-bar "$INNO_URL" -o "$setup"
	# Portable extract: the official installer can be unpacked; fall back to wine install.
	if 7z x -y "-o$INNO_DIR/extracted" "$setup" >/dev/null && [[ -f "$INNO_DIR/extracted/ISCC.exe" ]]; then
		cp -a "$INNO_DIR/extracted/." "$INNO_DIR/"
	else
		wine "$setup" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR="$(winepath -w "$INNO_DIR")" || true
	fi
	# Common Wine install locations
	if [[ ! -f "$iscc" ]]; then
		local found
		found="$(find "$HOME/.wine/drive_c" "$INNO_DIR" -iname 'ISCC.exe' 2>/dev/null | head -n1 || true)"
		if [[ -n "$found" ]]; then
			mkdir -p "$INNO_DIR"
			cp -a "$(dirname "$found")/." "$INNO_DIR/" 2>/dev/null || true
			# keep absolute path if copy incomplete
			if [[ -f "$found" && ! -f "$iscc" ]]; then
				echo "$found"
				return
			fi
		fi
	fi
	[[ -f "$iscc" ]] || {
		echo "could not install Inno Setup / ISCC.exe" >&2
		exit 1
	}
	echo "$iscc"
}

export_game() {
	need_cmd godot
	log "exporting Windows Desktop release"
	rm -rf "$PAYLOAD"
	mkdir -p "$PAYLOAD" "$BUILD"
	# Godot writes to export_path; export into payload dir
	godot --headless --path "$ROOT" --export-release "Windows Desktop" "$PAYLOAD/Masair.exe"
	[[ -f "$PAYLOAD/Masair.exe" ]] || {
		echo "export failed — Masair.exe missing" >&2
		exit 1
	}
	# Keep a copy at the preset path too for convenience
	cp -a "$PAYLOAD/Masair.exe" "$BUILD/Masair.exe"
	if [[ -f "$PAYLOAD/Masair.pck" ]]; then
		cp -a "$PAYLOAD/Masair.pck" "$BUILD/Masair.pck"
	fi
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
	wine "$iscc" "$(winepath -w "$ROOT/packaging/windows/masair.iss")"
	local setup="$BUILD/MasairSetup-${VERSION}.exe"
	[[ -f "$setup" ]] || {
		echo "installer missing at $setup" >&2
		exit 1
	}
	log "installer ready: $setup ($(du -h "$setup" | awk '{print $1}'))"
}

main() {
	ensure_ico
	ensure_templates
	export_game
	make_zip
	make_installer
	log "done"
	ls -lh "$BUILD/Masair.exe" "$OUT_ZIP" "$BUILD/MasairSetup-${VERSION}.exe"
}

main "$@"
