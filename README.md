# Splendor

Fast low-poly first-person motorcycle riding game (Godot 4.7). Ride an endless
streaming road past traffic, forests, coastline and mountains — day, dusk or
night, with a café-rider start menu, distance-unlocked bikes and persistent
credits.

## Play on Windows

1. Open the latest [GitHub Release](https://github.com/HaseebUllahButt/Masair/releases/latest).
2. Download **`SplendorSetup-1.1.0.exe`** (or the newest `SplendorSetup-*.exe`).
3. Run the installer. Choose an install folder (default is fine).
4. Optionally tick **Create a desktop icon**.
5. Finish, then launch **Splendor** from the Start Menu or desktop.

No Godot install needed. The game is 64-bit Windows.

**Portable option:** download `Splendor-windows-x86_64.zip`, unzip it, and run
`Splendor.exe` next to `Splendor.pck`. Keep those two files in the same folder.

### Music (optional)

On the café menu (top right), pick a music folder. Splendor plays **MP3 / OGG /
WAV** natively. **FLAC / M4A** work if [ffmpeg](https://ffmpeg.org/download.html)
is on your PATH — tracks decode in the background to a CD-quality cache, then
crossfade so a switch never stalls the ride. Playback resumes where you left
off, including after quitting the game.

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

## Play in a browser (no install)

The web build runs anywhere a browser has WebGL2 — no Godot and no strong GPU
needed (the project renders with the Compatibility renderer).

1. Install the Godot 4.7.2 export templates once (Godot editor → Editor →
   Manage Export Templates, or drop `Godot_v4.7.2-stable_export_templates.tpz`
   into `~/.local/share/godot/export_templates/`).
2. `godot --headless --path . --export-release "Web" build/web/index.html`
3. `build/web/` is a static site — host it anywhere, or let SplendorServer
   serve it (below). Serve over plain `http://` so in-game `ws://` works.

## Race friends

One friend hosts; everyone else plays in a browser.

**Host:**
1. Build the web export (above).
2. `./tools/host_server.sh` — serves the game on `:8000` and the race lobby
   on `:8001`.
3. Give friends an address they can reach. Easiest to hardest:
   - **Same network / Tailscale:** nothing to forward — use the LAN or
     tailnet IP.
   - **playit.gg tunnel:** `playit` tunnels TCP without touching the router —
     share the `xxx.playit.gg:port` it prints for the web port, and run a
     second tunnel for the ws port (or give friends the ws address the page
     already pre-fills for them).
   - **Router forward:** TCP `8000-8001` to the host machine.
4. Friends open `http://<host>:8000`. The page derives the websocket address
   from the URL bar — nobody types an address.

**Everyone:** the join box is already open on the web menu — name is
pre-filled, hit **JOIN**, then **READY**. The lobby leader hits **START RACE**;
every client loads the same road (shared world seed), waits on a 3-2-1, and
the first rider to 5 km wins. Riders are real traffic to each other: clip a
friend and you both go down; thread past them and it pays near-miss credits.
Crashing restarts you at kilometre zero on the *same* road — you can lose a
race, not your lobby. Joining mid-race loads the same road and rides along
(marked DNF). Race length is set server-side:
`tools/host_server.sh build/web 8000 --dist=10000`.

Traffic is per-client in this version — close racing, not shared traffic.

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

- `SplendorSetup-1.1.0.exe` — Inno Setup installer
- `Splendor-windows-x86_64.zip` — portable zip
- `Splendor.exe` + `Splendor.pck` — raw export

Needs `godot`, `curl`, `unzip`, `zip`, `wine`. First run downloads the Godot
Windows editor binary (export template) and Inno Setup 6.

Upload the Setup exe (and optionally the zip) to a GitHub Release so Windows
players can download them — `build/` is not committed to the repo.
