# Handoff — scenic overlooks rework

**Branch:** `scenic-overlooks` · **Commit:** `e4b1648` (parent `45ddb9e` on `main`)
**Tree state:** clean, nothing uncommitted. This file is untracked; delete it when done.

---

## 1. What the task was

The four scenic overlooks (the F-key bench viewpoints) rendered badly — all four
arrived as the same flat orange card. Scope agreed with the user:

- Blast radius: **global fixes allowed** (shared materials, MOODS table, fog).
- Art direction: **warm and stylised — Art of Rally / Firewatch.** Bold hue
  separation: teal water against ochre land against violet distance.
- Scope: **overlooks plus a riding pass** — fix the overlooks, then polish the
  coast/mountain/country riding biomes so they read as distinctly as forest.

Standing constraints from VISION.md that must not be regressed: first-person
endless country roads; no city, no buildings beside the road; café racers only;
no story or missions. Do not reintroduce towers, trees in water, village blobs,
campanile, hamlet, chapel, jetty or boats.

---

## 2. What was done

### Root causes found

**Terrain used wrapped diffuse.** `DIFFUSE_LAMBERT_WRAP` remaps N·L from
`[-1,1]` into `[0,1]`, so a slope facing directly away from the sun still
collected half the key. Under a strongly coloured low key (dusk sun is `ff9e62`
at 1.42) that paints every face in the landscape one hue whichever way it
points, and no reasonable set of albedos survives it. Now plain
`DIFFUSE_LAMBERT`, with the dusk fill and ambient rebalanced around the light
that donation used to hide. This single change is what unlocked all form in the
landscape — it is the most important edit in the commit.

**The overlook deleted its own aerial perspective.** `_protect_scenic_visibility()`
was written on the theory that a view you rode a 3 km detour to reach should be
visible, and what it removed was the one cue carrying distance: each ridge
stepping paler and bluer toward the sky. Now density is clamped *low* and
`fog_aerial` *high*, so ridges take the sky's own hue and the ladder reads as
kilometres at any time of day.

**Scenic lighting never applied in dry weather.** A genuine latent bug:
`_apply_lighting()` only ran when `rain` changed, and dry pins rain to exactly
`0.0`. Fixed by tracking `_applied_scenic` and re-applying when the flag flips.

**`_height_above_water()` disagreed with reality.** It reconstructed height from
the centreline less a profile drop instead of sampling `_terrain_surface_at` —
the surface things are actually placed on. The two disagree precisely where the
headland face falls away, which is the only place any caller asks. Every
shore-dressing guard in the overlook was therefore passing on rock the sampled
terrain put metres under the lake. Fixed at the one function rather than in the
callers. **If you add shore dressing, use this function; do not reconstruct.**

### Composition

- **Ranges** are the upper envelope of overlapping tents, not a sum of gaussians.
  Summed gaussians stack past the layer top and clamp flat where they overlap,
  and fall to the floor term where they do not — a mesa with paper shark fins
  cut out of it, which is what was on screen. Each layer now plants its two
  shoulders explicitly (`RANGE_LAYERS[*].left/right`) so the col is legible on
  every seed. **`tests/test_visuals.gd` asserts those keys exist and that
  `left.x > mid.x * 1.35` — do not remove them.**
- **Fine relief** is scaled by `crest * (1 - crest)`, not by `crest`. Scaling by
  crest put the largest displacement exactly on the summits and sharpened
  ordinary tops into needles.
- **Framing stands** are placed by angle off the seated eye (`FRAME_CLUMP`).
  They used to sit at the bench's own lateral — ninety degrees off axis, outside
  the lens — so every overlook was an unframed panorama. Note the camera FOV is
  *vertical* (Godot `KEEP_HEIGHT`); on 16:9 the horizontal FOV is far wider, and
  sizing angles against the vertical number is a mistake I made once already.
- **Scree** falls in graded fans (big blocks at the foot, fines at the head);
  boulders cluster; the water carries its sun path in `shaders/water.gdshader`'s
  `light()` where it can sit on the line between eye and sun. Painting it into
  vertex colour cannot work — that line moves with the head and time of day.
- **Sea stacks** were four per 40 m chunk at boulder scale — eighty pebbles in a
  bay. Now roughly one per three chunks, at 24–48 m, stretched vertically
  (`0.52 × 1.55 × 0.52`) because the Kenney rocks are wide and low and lie on
  the water like skipping stones when scaled uniformly.
- **Imported boulders** kept their asset material — a bright moss cap over an
  orange body — and read as painted confetti floating on a dusk sea. Now
  retinted per biome via `_vista_rock_material()`.

### Palettes

Each overlook gets its own rock/haze family: ochre country, green forest, grey
mountain, blue coast.

Riding biomes got the same treatment. Coast and mountain were each **seven tones
inside twenty degrees of one desaturated hue**, so the light had no separation to
work with and the whole biome read as a single wash. Now built on an opposition:

| biome | ground | ground_alt |
|---|---|---|
| coast | `c9ae74` sand | `7c9483` marram scrub |
| mountain | `4a5940` moss | `6a5e4e` bare scree |
| country | `b39a4a` standing corn | `5c6b34` grazed pasture |

### Performance

`_face_mix`, `_terrace_mix` and `_deck_mix` run **once per ribbon vertex on every
chunk in the world**, and each issued overlook path queries
(`viewpoint_near_shore`, `platform_blend`, `spur_deck_blend`) before deciding it
had nothing to do. `_face_mix` was worst: the outer half of every ordinary verge
clears the headland-crest threshold, so it went on to ask for a near-shore
distance that only means anything at an overlook. `_resolve_viewpoint()` already
computes `_on_lake` / `_on_spur` for exactly this reason — its own comment says
so — and the three helpers were bypassing it. Now guarded.

Measured effect: steady-state build of ten chunks went from **309 ms → 295 ms**,
i.e. now *below* baseline.

### Tooling

- The catalog held `look_left` through the coast road shot, putting the camera
  side-on across the carriageway — a featureless slab of tarmac with the lane
  dashes running across it and the sea reduced to a sliver. Dropped.
- Road-shot warmup 5 s → 11 s, lookoff 12 s → 18 s. A shot that races the
  streamer photographs a half-built valley, which is indistinguishable from a
  lighting regression until you re-run it.

---

## 3. Verification

All six suites green on `e4b1648`:

```
test_visuals  test_road  test_restart  test_handling_traffic  test_progression  test_maps
   0 fail       0 fail      0 fail            0 fail               0 fail         0 fail
```

Gallery captured and reviewed frame by frame (8 frames, `tools/shots.sh <dir> dusk --catalog`).
The real game was launched and confirmed rendering correctly.

---

## 4. What is left

### 4.1 Restart hitch — intermittent spike (the main open item)

`test_restart` asserts `restart()` completes in **< 48 ms**. It passes most runs
but spikes to **60–77 ms on roughly 1 in 6–8 runs**. Baseline never spikes.

**Diagnosed, not fixed.** A cold-path profile of the post-restart chunk shows:

```
_build_theme_scenery    48.58 ms cold   vs   ~5 ms warm
```

That is first-use lazy initialisation. Three sources, all behind static flags:

1. `RoadChunk._ensure_rocks()` — loads two Kenney GLBs on first use.
2. Ten `RoadChunk.unit_*()` mesh factories, cached in `static var _unit_*`.
3. Eight `LowPoly` shared materials, cached in `static var _solid/_road/...`.
   **Two are ShaderMaterials, whose first use compiles a shader.**

`restart()` hands the world a new seed, so the first chunk built afterwards is
routinely the first user of a mesh or material nothing had needed yet. That is
why it fires on some seeds and not others, and why it reads as noise. Baseline
has the same lazy loading; it simply touches less of it.

**The fix is to warm these once at load. ⚠️ My attempt broke the game.**

I added the warm to `RoadStreamer._ready()`. Result: **no road and no scenery
built at all** — the game booted to a bare terrain hump under the sky. Critically:

- **No script error was printed.**
- **All six test suites still passed.**
- The catalog capture path still worked, because it goes through
  `_park_on_road()` → `reset_world()` rather than normal startup.

Only launching the actual game revealed it. It is fully reverted and was never
committed. Whatever you do here, **launch the game to verify, not just the tests.**
Try a warm step during scene load rather than inside `RoadStreamer._ready()`.

### 4.2 Measurement traps — read before you profile

This cost me a lot of time; do not repeat it.

- **Timing on this machine swings enormously with load.** A single A/B is
  worthless. My first bisect "proved" `road_chunk.gd` was the culprit; re-running
  it interleaved showed the reverted file failing identically. **Always
  interleave current and baseline within the same loop.**
- **Use a `git worktree` at the parent commit for the baseline, never `git stash`.**
  I twice had a `git stash` + long-running command hit the 2-minute tool timeout,
  which killed the command before `git stash pop` ran and left the entire working
  tree stashed. Recoverable, but alarming.
- **`min` over passes hides one-time costs.** The whole spike is invisible to a
  best-of-N harness. Profile the *first* pass to see it.
- **A "faster" result can mean "broken".** The background A/B that measured the
  warm code reported 7/8 passing — because the streamer was building nothing at
  all. That number is void.

### 4.3 Cosmetic leftovers

- One small residual needle spire survives in the country overlook ridge. Much
  reduced, not gone.
- The forest overlook is deliberately a dark silhouette against the fiery col.
  I judged this correct for the art direction; the user may want it overruled.
- `_build_furniture` is ~6% above baseline. Not chased — steady-state total is
  already below baseline, so this is not costing anything net.

---

## 5. Useful commands

```bash
# gallery: 8 frames, road + lookoff for all four biomes
tools/shots.sh /path/to/out dusk --catalog

# all suites
for t in test_visuals test_road test_restart test_handling_traffic test_progression test_maps; do
  godot --headless --path . --script res://tests/$t.gd
done

# per-phase chunk profiler
godot --headless --path . --script res://tools/profile_chunk.gd
```

**Gotcha:** `tests/test_visuals.gd` has no `await` and no error handling — a
runtime error inside `_run()` aborts it, `quit()` never fires, and the SceneTree
idles forever. It looks exactly like a hang. Pipe stderr to a file rather than
through `tail`, which buffers and hides the error line.
