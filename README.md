# Masair

Fast low-poly first-person motorcycle riding game (Godot 4.7). Ride an endless
streaming road past traffic, forests, coastline and mountains — day, dusk or
night, with a café-rider start menu, distance-unlocked bikes and persistent
credits.

## Run

```bash
godot --path /home/haseeb/dev/me/hehe/Masair
```

Or open the folder in the Godot editor and press F5. The full project needs no
imports or external assets — fonts, audio and everything else are included or
synthesised at boot.

## Controls

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

## Self-check

```bash
godot --headless --path . --script res://tests/test_road.gd
```

Six headless suites validate the road maths, visuals, traffic, restart,
progression and maps.