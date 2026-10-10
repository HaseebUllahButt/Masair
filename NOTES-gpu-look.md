# GPU look pass — notes

Laptop run on real GPU (Iris-class), branch `wip-gpu-look` on `night-integ @321eeb7`.
All frames captured with `tools/shots.sh` (1280x720, real render, not headless software).
Shot paths below are under `/home/haseeb/dev/me/hehe/misc/.masair-wt/shots/gpu-look/`.

---

## 1. Low-sun road glare — fixed

**What it was:** where the road is wet (seed 2, ~776–1069 m), the whole right
half of the tarmac lit up as one long cream smear. It read as a smudge on the
road, not as water catching the sun.

**Cause:** rain dropped the roughness of the *entire lane* to 0.30, so the low
sun and the warm sky mirrored across half the road at once.

**Fix (`shaders/road.gdshader`):** standing water now only lives in the wheel
ruts (roughness 0.15, specular 0.50) — the two thin polished strips per lane.
The rest of the lane keeps a thin rough film (0.40, 0.20) so it stays a sheen,
not a mirror. The emissive sky-sheen's wet boost was cut 1.6x → 0.5x so the
broad wash stops doubling the real reflection. Dry road is byte-identical to
before.

**What you see now:** two thin bright glare lines running down the lanes
toward the sun; the rest of the road stays neutral charcoal. Dusk shows a
tighter sunset column; night shows a faint sheen only.

- Before: `shots/gpu-look/base-s2-z900-wet/day_00.png`, `base-s2-detour/day_02.png`, `day_03.png`
- After: `shots/gpu-look/fix1-s2-z900-wet/day_00.png`, `qa-detour-s2/day_02.png`, `day_03.png`
- Moods: `fix1-s2-z900-day|dusk|night` (day_00 / dusk_00 / night_00)
- Measured (300x180 crop over the old wash): mean **(168,127,83) → (76,62,47)**;
  left lane unchanged (~25).

## 2. Near-black shaded pines — fixed

**What it was:** on the side-road climb (seed 1 detour ~1954 m), the shade side
of the conifers read almost black.

**Cause:** with real sun shadows on, a crown's unlit side gets almost no light
— scene ambient is deliberately low (0.28 day) so the flat surfaces keep their
modelling, and the grade clips anything under a few percent to black.

**Fix (`shaders/foliage.gdshader` + `scripts/main.gd`):** foliage gets its own
sky fill — `ambient_color × ambient × 4.6`, pushed per mood. It is emitted
through the leaf's own colour, so shade lifts as deep green, dusk goes violet,
night goes navy — no green glow after dark. The darkest leaves (conifer tiers)
get up to 2.5x the share so they clear the floor without washing mid crowns.
Scoped to the foliage material only: the road and hills keep their crush, and
the light/shade contrast is untouched.

- Before: `shots/gpu-look/base-s1-detour/day_06.png`
- After: `shots/gpu-look/fix4-s1-detour/day_06.png`
- Measured in the pine wall (300x260 crop): shade-side pixels with visible
  green went from a mean of ~G25 to **G32** (12% ≈ G31); pixels still under
  the floor dropped **45342 → 20244**, and what remains is mostly the shaded
  hillside (terrain — deliberately not touched) and crown undersides at the
  frame edge where the vignette takes ~17%.
- Night re-checked at final strength (`qa2-night-road-s1/night_00.png`):
  trees stay silhouettes, no glow.

## 3. GPU QA checkset

Frames in `shots/gpu-look/qa-*`:

| shot | verdict |
|---|---|
| day road s1 (`qa-day-road-s1`) | lush forest, charcoal road, deep-blue ranges |
| day road s2 (`qa-day-road-s2`) | rolling country, hedges, hay bales — fine |
| look-left / look-right s2 | glance views clean; horizon and bodies stay put (bike crashed into a lorry mid-capture — expected, not a defect) |
| detour s1 (`fix4-s1-detour`) | shaded pines fixed, verge lush, road charcoal |
| detour s2 (`qa-detour-s2`) | wet glare now thin streaks (frames 02–03) |
| seated s1 (`qa-seated-s1`) | terrace, rail, lake below — clean |
| seated s2 (`qa-seated-s2`) | lake vista, balloons, birds — clean |
| dusk road s1 (`qa2-dusk-road-s1`) | sunset sky, warm sheen ahead, silhouettes keep green hint |
| night road s1 (`qa2-night-road-s1`) | moon, stars, reflector posts, dark charcoal road |

Frame-to-frame diff on parked pairs: ~3% day, ~1.6% night — just dither grain
and tree sway, no popping. ~57 fps average on this GPU at 720p; worst frame
72.6 ms once during the s2 detour (a stream hitch, noted below).

## Left to the other helpers (not touched, by design)

- **Blue/violet distant ranges** in nearly every frame — owner wants slate/
  granite; that is the horizon shader / range_material job.
- **Tan/khaki patches** on the far shore and mid-ground fields at the seated
  overlooks — shore/lake water and field palettes are theirs.
- **The dark wall face under the terrace** at the seated overlooks — lookout
  face work.
- **Streaming hitch**: one ~72 ms frame during the s2 detour ride (worst was
  30–50 ms elsewhere). Streaming hitches are another helper's area.
- **Rain streak / dusk sky** — untouched per split.

## Small observations (in scope, judged OK as-is)

- Wet tarmac under a closed sky reads very dark (real wet asphalt does);
  now carries thin glare lines rather than a wash.
- Sky gradients are clean — the dither pass is doing its job, no banding seen.
- Bloom is controlled: sun disc and halo read strong but not blown.

## Tests

All 11 suites pass on this laptop:

```
test_clearance test_handling_traffic test_lookout_arrival test_maps
test_mobile_ui test_multiplayer test_progression test_race_grid test_restart
test_road test_visuals   —  0 failures each
```

(The `Unrecognized UID` / autoload warnings on stderr are pre-existing —
they appear on a clean `--editor --quit` import with no changes.)
