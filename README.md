# Masair

Fast low-poly first-person motorcycle riding game (Godot 4.7).

## Run

```bash
godot --path /home/haseeb/dev/me/hehe/Masair
```

Or open the folder in the Godot editor and press F5.

## Controls

| Key | Action |
|-----|--------|
| W / ↑ | Throttle |
| S / ↓ | Brake |
| A / D or ← / → | Steer |
| Q / E | Look around — a glance while riding, most of a turn when stopped |
| F | Get off and sit on the bench at a viewpoint (A/D and W/S to look around) |
| Space | Wheelie |
| H | Horn |
| T | Cycle dusk / day / night |
| R | Restart |
| Esc / P | Pause / resume |
| M | Return to the ride menu while paused |

## Features

- Lean-based handling: steering sets a lean target, the lean produces lateral
  acceleration, and lateral velocity carries and has to be caught
- First-person camera with speed FOV, independent 144° head-look, corner glance
  and lean roll
- Endless streaming road, one generated ribbon mesh per 40 m chunk
- Seven traffic kinds with gradual lane changes, indicators, brake lights and
  delayed horn responses
- Three distance-unlocked motorcycles with live menu switching and persistent
  engine, brake and handling tuning
- Persistent credits earned from distance and close calls
- Five tree species planted in stands
- Café-rider start menu with day, dusk and night choices
- Easy, medium and hard traffic presets with score multipliers
- Rain bands with overcast sky, wet tarmac and reduced visibility
- Four route environments: countryside, forest, coast, and mountain
- Road-only riding: the tarmac is the playable boundary
- Terrain-aware scenery placement with a clear road margin
- Kenney CC0 rocks and city buildings in streamed scenery
- Scenic overlooks as real detours: a signed junction, a double-canopy forest
  road that climbs far from the highway to a headland above a lake, and a second
  junction back onto the carriageway
- Somewhere to be when you get there: marked bays, a railed terrace, benches you
  can sit on and look around from, a viewer, and three ranges over the water
- Tunnels and mountain switchback markers
- Distant wind farms and lattice radio masts with blinking beacons
- Two layers of distant ridge silhouettes fading into haze
- Distance, best distance (saved), near-miss combo, restart

## Sky and lighting

**Colours are authored as sRGB hex and decoded as sRGB.** Every colour in the
game is a hex string in a palette that ends up as a vertex colour, and Godot
takes vertex colour as linear light — so `3b3b3d` tarmac was arriving as 0.231
linear, the value of a mid grey rather than of asphalt. The whole world rendered
about a gamma too bright and too desaturated, which is why nothing in a frame was
ever dark and the greens went mint. `LowPoly._srgb()` sets
`vertex_color_is_srgb`; the two ShaderMaterials that read `COLOR` themselves
(`road`, `foliage`) do the same decode by hand. Anything authored above 1.0 is
light rather than albedo and stays out of it — that is the whole of the GLOW
channel.

The moods are balanced against that. `tools/histogram.gd` prints the luminance
distribution of a captured frame, which is the only honest way to tell a graded
image from a washed-out one; a sunlit exterior wants a 5th percentile under about
0.18 and a median near 0.4.

Each mood is one row of `MOODS` in `scripts/main.gd`, covering sky gradient, sun,
cloud weather, fog, exposure and grading. Switching a mood writes shader uniforms
and `Environment` properties; it never rebuilds the streamed world.

The start menu chooses a fixed day, golden-dusk or midnight mood for each run.
`T` cycles the same three authored looks during play; there is no ride-time
clock or route-distance-driven lighting.

The sky is `shaders/sky.gdshader`, drawn analytically:

- Three-stop gradient: horizon, mid band, zenith, with `band_low` / `band_high`
  setting where each takes over
- One celestial body per mood: sun, or moon with limb darkening and maria, from
  the same uniforms (`moon_face` selects)
- Two authored cloud layers with self-shadowing from a single resample toward the
  light, giving a lit top, a darker underside and bright rims near the sun
- A third low deck (`bank_*` uniforms) projected into the skyline with a 0.030
  divisor against the main deck's 0.14, and mixed toward `horizon_color` by
  `bank_haze`
- Night stars in two size layers, cool horizon airglow and a silver/violet Milky
  Way with a dark dust lane

Sun, moon and stars are drawn at infinity from the view direction, so they hold
position when the rider turns.

Fog colours distance only. No mood sets `fog_height_density` above zero, and dusk
keeps `fog_sun_scatter` at 0.14.

Real-time directional shadows are off (`sun.shadow_enabled = false`). Form comes
from the directional light and authored low-poly face shading. Each traffic car
has one shared, range-culled analytic contact patch, giving it a smooth grounded
shadow without shadow maps or the old dotted tarmac pattern.

No SSAO, no volumetric fog, no screen-space effects. Bloom is the only
post-process, weighted onto glow levels 2–5 with levels 6–7 at zero.

## Weather

`rain_at()` in `scripts/main.gd` reads two sizes of value noise seeded from
`RoadPath.world_seed` and maps them through `RAIN_ONSET` (0.58) to `RAIN_FULL`
(0.80). Cells are `rain_band_m` (2600) long, so a squall covers a few kilometres
of route. Restart keeps the current streamed route and returns instantly.

`_overcast()` takes the resolved hour and layers rain over it, so rain at dusk
and rain at midnight are different. It raises cloud cover, opacity, scale and the
cloud bank, drains colour toward a cool grey with `_dull()`, removes the sun
disc and stars, multiplies fog density by up to 3.8×, and drops light energy by
up to 58%.

- `shaders/road.gdshader` takes a `wet` uniform: albedo down by up to 55%,
  roughness from `base_roughness` to 0.30, and `SPECULAR` up to 0.45. The effect
  is stronger inside the wheel tracks than across the rest of the lane.
- Rain is one `GPUParticles3D` on the player with `local_coords = false`, 560
  quads aligned to velocity via `particle_flag_align_y`. `_rake_rain()` adds the
  bike's speed into the particle velocity each frame, capped at 2.2× the 17 m/s
  fall speed.
- The headlight follows the selected mood rather than the weather.

Rain costs roughly 1 ms GPU per frame at full intensity.

## Sound

Synthesised at boot in `scripts/audio.gd`; there are no audio assets. Three
voices are wired up:

- `engine()` — looped twin, pitched at runtime through six fake gear ranges, on
  the bike (`scripts/motorcycle.gd`)
- `horn()` — two detuned reeds with harmonics and a pitch droop on release
- `impact()` — crash, played by `scripts/ride_audio.gd` off `GameManager.crashed`

`audio.gd` also generates `wind()`, `tyre()`, `rain()`, `drone()` and `whoosh()`.
These are not currently used. The looped generators build a buffer of
`length + tail` samples and crossfade the overrun back over the start
(`_seamless()`), so a noise loop has no discontinuity at the loop point.

## The bike

`scripts/motorcycle_visual.gd` shows the rider one thing: the headlight. The
full cockpit — teardrop tank, clip-ons, lever perches, twin clocks with live
needles, mirrors, front fender — is still built and still correct behind
`SHOW_FULL_COCKPIT`, but it filled the bottom third of the frame and put every
degree of lean on screen twice, once as the world rolling and once as a metre of
bars swinging the other way. The headlight keeps what the cockpit was for, which
is a foreground for the speed to run past.

It is modelled for the one angle it is seen from — above and behind, cropped by
the bottom of the frame — so its shell is pale rather than black (a matt black
bucket at that size tonemaps to a hole in the road) and it carries a chrome ring
at each end plus a stub of fork so it does not float. `VISUAL_LEAN` on
`scripts/motorcycle.gd` damps how much of the lean it takes; the frame still
leans the full amount, only the drawn bike is held back. Nothing casts a shadow.

Handling constants are exported on `scripts/motorcycle.gd`: 200 km/h top speed,
32° maximum lean, ~0.17 s to reach full lean, 15 m/s lateral speed cap, and
`corner_load = 0.5` for the share of a corner's centrifugal load the rider holds.

## Trees

`_tree()` in `scripts/road_chunk.gd` grows one of five species — broadleaf,
conifer, birch, palm, bare — from four shared instance meshes: a tapered trunk
used for every woody part, a lumpy broadleaf crown, a five-skirt spruce and a
single palm frond. A chunk of woodland is four MultiMesh draw calls and about 11k
triangles.

- One road-footprint test per tree, taken at the trunk; canopies may overhang the
  tarmac
- A whole canopy is one instance, so the foliage shader's sway hinges at the base
  of the crown
- Trees are placed in stands sharing one species, tint and size range

## Traffic

Sedan, hatch, coupé, pickup, van, truck and bus. `KIND_WEIGHTS` and `KIND_SPEEDS`
in `scripts/traffic_manager.gd` set the mix and a cruise band per kind; up to
`max_active` (13) cars are live at once.

Each kind reads its lamp positions from one row of `LAMPS`, which also builds the
two overlays:

- Brake lights are driven by the target speed rather than the achieved speed, so
  they light when the car begins demanding less speed
- Indicators blink on the side the car is drifting toward for the whole lane
  change, gated by `SIGNAL_EPSILON`

Both are hidden child `MeshInstance3D` nodes; the body mesh is shared per (kind,
colour) and cannot carry per-car lamp state.

## Surfaces

`scripts/low_poly.gd` emits geometry into material channels — solid, glow, metal,
paint, mirror, foliage — and produces one surface per channel used.

- Metal and mirror are fully metallic and reflect the sky
- Paint carries a clearcoat
- Foliage (`shaders/foliage.gdshader`) sways, phased by instance world origin and
  hinged at the instance base. Rocks and hill humps share the ball mesh and stay
  in the non-swaying bucket
- Tarmac (`shaders/road.gdshader`) works in road space: `UV.x` is lateral metres,
  `UV.y` is metres travelled. It carries a value-noise grain and two darker wheel
  tracks per lane

## Overlooks

An overlook is a detour, not a lay-by. Every 4600 m of route a spur road leaves
the carriageway at a signed junction as an extra lane on its outside edge, runs
alongside as a deceleration lane, then peels through over two kilometres of
double-canopy woodland and climbs thirty metres to a parking platform on a
headland above a lake before returning to the carriageway.
Taking it costs the rider time, which is the point.

It is a slip road, so it is surveyed like one. The number that decides whether
any of this can be ridden is how fast the tarmac moves sideways under the rider
— lateral metres per metre travelled — because that times speed is the sideways
speed the bike has to produce, and the bike can only make 15 m/s of it. The spur
is held to an eighth of a metre per metre, a 7.5° divergence, which costs about
5 m/s at 150 km/h. `spur_gap()` is where that lives and `test_maps.gd` checks it.
A short, wide swing (0.6 lateral m per m) is a wall, not a corner: the road
leaves and the rider is dragged along its edge losing speed.

The parking at the top is an 18 m x 130 m lay-by. It was 30 m x 170 m, which
from the saddle read as an airport apron dropped on a hillside and was the single
biggest reason the overlook did not look like a place anyone would stop.
`PLATFORM_HALF_WIDTH` and `PLATFORM_HALF_LENGTH` are the two numbers; everything
that sits on the platform — bays, kerb lines, benches, planting, boulders — is
expressed against them rather than in absolute metres, so narrowing it moves the
markings instead of painting them off the edge.

Anything positioned by a fixed lateral offset has to ask `_junction_occupies()`
whether the overlook is there. The spur sweeps from the road edge out to 56 m
over 440 m of route, so a prop parked at a constant lateral gets crossed by it
somewhere: telegraph poles are planted at 15.5 m and stood in the middle of the
slip road, because `_power_line()` writes straight into a mesh and never went
through the clearance test scattered props get. The wire now ends at the last
pole clear of the junction, the same way it already ended at a theme boundary.

All of its shape lives in `scripts/road_path.gd` as pure functions of `(z,
lateral)`, exactly like the hills and curves — `spur_offset`, `spur_half_width`,
`spur_lift`, `spur_deck_blend` and the headland/lake shaping in `terrain_drop`.
That is what lets twenty streamed chunks agree on it to the millimetre. The
chunk builds the surfacing, the furniture and the planting on top.

Two details are load-bearing and easy to undo by accident:

- `road_bounds_at(z, lateral)` answers for the surface the rider is *on*. The
  world is no longer one strip: at a junction the carriageway and the spur are
  separate surfaces that meet edge to edge at the mouth, and answering for the
  containing interval is what lets the bike steer off, ride the spur, and be
  held on it by the same edge forces that hold it on the road.
- The spur meets the carriageway edge to edge and never laps over it. Anchoring
  its centreline on the road edge instead put half its width on top of the
  outside running lane: the exit opened in the middle of the traffic, and the
  two ribbons met in a 90 m patch of mismatched tarmac.
- Anything that runs *along* the spur — the barrier, the platform kerbs — is
  ribbon geometry sampled from its own line, never boxes stepped along `z`.
  Seventy metres off the centreline two metres of route is nearly three metres
  of terrace, so a fence built by spacing boxes in `z` comes out as a line of
  staples with daylight between them, each one turned to face the wrong road.
- The platform edge is a kerb and an open post-and-rail, never a wall. Anything
  solid at waist height two metres in front of a seated rider blocks everything
  more than five degrees below the horizon — which is the entire lake.

## Self-check

```bash
godot --headless --path . --script res://tests/test_road.gd
```

Six suites: `test_road` (road frame maths, mesh winding, route, road-only
boundary), `test_visuals` (materials and chunk structure), `test_handling_traffic`,
`test_restart` (instant in-place restart plus lighting, menu and weather
contracts), `test_progression`, and `test_maps`.

## Looking at it

`tools/shots.sh` rides the game and writes PNG frames with no window, focus steal
or audio:

```bash
tools/shots.sh /tmp/shots dusk --shots=3 --gap=6      # also: day, night
tools/shots.sh /tmp/shots night --shots=2 --look=left --bench=1
tools/shots.sh /tmp/viewpoint day --viewpoint --seated --dry   # parked at an overlook
tools/shots.sh /tmp/detour day --detour --seed=72117           # rides the spur
tools/shots.sh /tmp/quiet day --notraffic                      # empty the road
tools/shots.sh /tmp/over day --overview=spur --dry             # dev camera: spur, platform,
                                                               # terrace, across
```

`tools/histogram.gd` reports what is actually in a frame — luminance
percentiles, mean channel mix, and a row of named sample points — so a lighting
change can be judged by numbers rather than by an eye that has adapted to
whatever is already on screen:

```bash
godot --headless --path . --script res://tools/histogram.gd -- /tmp/shots/day_02.png
```

`tools/lineup.gd` photographs every traffic vehicle in a row — front, rear and
three-quarter — with the brake and indicator overlays forced on:

```bash
gamescope -W 1600 -H 700 --backend headless -- \
    godot --path . --audio-driver Dummy --script res://tools/lineup.gd -- --out=/tmp/lineup
```

`tools/profile_fx.gd` measures the frame cost of each post-process in the running
game, one effect at a time.
