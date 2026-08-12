# Masair

Fast low-poly first-person motorcycle riding game (Godot 4.7). Ride an endless
streaming road past traffic, forests, coastline and mountains — day, dusk or
night, with a café-rider start menu, distance-unlocked bikes and persistent
credits.

## Play on Windows

1. Open the latest [GitHub Release](https://github.com/HaseebUllahButt/Masair/releases/latest).
2. Download **`MasairSetup-1.1.0.exe`** (or the newest `MasairSetup-*.exe`).
3. Run the installer. Choose an install folder (default is fine).
4. Optionally tick **Create a desktop icon**.
5. Finish, then launch **Masair** from the Start Menu or desktop.

No Godot install needed. The game is 64-bit Windows.

**Portable option:** download `Masair-windows-x86_64.zip`, unzip it, and run
`Masair.exe` next to `Masair.pck`. Keep those two files in the same folder.

### Music (optional)

On the café menu (top right), pick a music folder. Masair plays **MP3 / OGG /
WAV** natively. **FLAC / M4A** work if [ffmpeg](https://ffmpeg.org/download.html)
is on your PATH — tracks are decoded once to a lossless cache, then played.

### Controls

| Key | Action |
|-----|--------|
| W / ↑ | Throttle |
| S / ↓ | Brake |
| A / D or ← / → | Steer |
| Q / E | Look around |
| F | Get off and sit on the bench at a viewpoint |
| Space | Wheelie |
| H | Horn |
| T | Cycle dusk / day / night |
| R | Restart |
| Esc / P | Pause |
| M | Back to the ride menu while paused |

## Run from source (Linux / Godot)

```bash
godot --path .
```

Or open the folder in the Godot editor and press F5.

## Self-check

```bash
godot --headless --path . --script res://tests/test_road.gd
```

Six headless suites validate the road maths, visuals, traffic, restart,
progression and handling.

## Build the Windows installer (maintainers)

```bash
./tools/build_windows.sh
```

Writes under `build/windows/`:

- `MasairSetup-1.1.0.exe` — Inno Setup installer
- `Masair-windows-x86_64.zip` — portable zip
- `Masair.exe` + `Masair.pck` — raw export

Needs `godot`, `curl`, `unzip`, `zip`, `wine`. First run downloads the Godot
Windows editor binary (export template) and Inno Setup 6.

Upload the Setup exe (and optionally the zip) to a GitHub Release so Windows
players can download them — `build/` is not committed to the repo.
