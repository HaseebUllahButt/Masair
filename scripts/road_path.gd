extends Node
## The road: single source of truth for shape, orientation, banking and terrain.
##
## Conventions everything else depends on:
##
##  * Travel runs along +Z. `z` is a *path parameter*, not world Z — a lateral
##    offset shifts world Z slightly on curves. Keep your own `z` and advance it
##    with `advance()`; never read it back out of `global_position.z`.
##  * `frame_at(z)` is an orthonormal Basis: X = right of travel, Y = road surface
##    normal (banked), Z = travel tangent. Use it instead of hand-rolling
##    `Basis.from_euler(pitch, yaw, 0)` — that form tilts +Z the *wrong way* for
##    positive pitch and is what used to bury traffic inside hills.
##  * `point_at(z, lateral)` is a point ON the road surface. Vehicles sit at
##    exactly that height with no fudge offset.

## The tarmac is the complete playable surface. Scenic viewpoints widen it into
## a short authored pull-off; the surrounding generated terrain remains blocked.
const HALF_WIDTH := 8.0
const RIDEABLE_HALF_WIDTH := HALF_WIDTH
const ROAD_EDGE_EPSILON := 0.001
const LANE_COUNT := 3
const MAX_BANK := deg_to_rad(9.0)
const BANK_PER_CURVATURE := 26.0
const DZ := 0.6  # finite-difference step for tangents

var world_seed: int = 1
var _height_phase_a: float = 0.0
var _height_phase_b: float = 0.0
var _curve_phase_a: float = 0.0
var _curve_phase_b: float = 0.0
var _terrain_phase: float = 0.0
var _shape_scale: float = 1.0
func _ready() -> void:
	randomize_world()
## RoadChunk.Env.COUNTRY. The ride has one coherent English-countryside identity;
## world seeds vary the road and planting, never the biome.
const ENGLISH_COUNTRYSIDE_THEME := 4


func theme_for_chunk(_index: int) -> int:
	return ENGLISH_COUNTRYSIDE_THEME


func randomize_world() -> void:
	set_world_seed(hash(Vector2i(int(Time.get_ticks_usec()), int(Time.get_unix_time_from_system()))))


func set_world_seed(value: int) -> void:
	world_seed = value
	_water_y_cache.clear()
	var rng := RandomNumberGenerator.new()
	rng.seed = value
	_height_phase_a = rng.randf_range(0.0, TAU)
	_height_phase_b = rng.randf_range(0.0, TAU)
	_curve_phase_a = rng.randf_range(0.0, TAU)
	_curve_phase_b = rng.randf_range(0.0, TAU)
	_terrain_phase = rng.randf_range(0.0, TAU)
	_shape_scale = rng.randf_range(0.82, 1.12)


func lane_x(lane: int) -> float:
	var lane_w := HALF_WIDTH * 2.0 / float(LANE_COUNT)
	return (float(lane) - float(LANE_COUNT - 1) * 0.5) * lane_w


# ------------------------------------------------------------ scenic overlooks
#
# An overlook is a real detour, not a wide bit of shoulder: a spur road leaves
# the carriageway as a lane on its outside edge, swings away and climbs a
# headland over half a kilometre, opens out into a parking platform above a
# lake, and rejoins the carriageway well over a kilometre after it left. Riding it is a choice
# that costs the rider time, which is the whole point.
#
# It is a loop rather than a dead end because the bike only travels forward:
# an out-and-back would need a reverse gear the game does not have, and every
# real belvedere road is built as a loop for the same practical reason.
#
# All of it lives here as pure functions of (z, lateral), like the hills and
# curves, so that a chunk built at any time agrees with its neighbours to the
# millimetre — the spur crosses fourteen chunks and the lake basin twenty.
#
#   lateral:  0       8           41 .. 71    78         106 ..... 340
#             carriageway  gore    PLATFORM   crest  face  lake      far shore
#   height:   0        0    rising    +13      +11  falling  -14      rising
#
const CHUNK_LENGTH := 40.0
## One overlook every 1400 m. They are set pieces: frequent enough to meet a few
## on a long run, rare enough that taking one is an event. The period has to
## cover the whole detour twice over with plain carriageway left between two of
## them, which is what sets it — a slip road long enough to be ridden is most of
## a kilometre on its own.
const VIEWPOINT_PERIOD := 4600.0
const VIEWPOINT_FIRST := 2800.0

## The spur road.
##
## The number that decides whether this is rideable is not how far out the
## platform sits, it is how fast the tarmac moves sideways under the rider:
## lateral metres per metre travelled. The first version swung 80 m out over a
## 200 m ramp, which peaks at 0.6 — a bike at 150 km/h would have to travel
## sideways at 25 m/s to stay on it, and the cap is 15. The road simply left,
## and the rider was dragged along its edge losing speed. Held to an eighth of
## a metre per metre it is a 7.5° divergence: one lean, held, the way a real
## exit is taken.
const SPUR_HALF_SPAN := 1160.0  # a 2.32 km forest road, junction to junction
const SPUR_RAMP := 1160.0  # long enough to move far away without an impossible lean
## Fraction of the ramp ridden straight, alongside the carriageway, before the
## spur peels away at all. This is the deceleration lane: time to notice the
## sign, come off the throttle and move across before the gore opens.
const SPUR_HOLD := 0.08
## Fraction of the swing spent easing into and out of the lean. The rest is
## ridden at one constant angle.
const SPUR_EASE := 0.14
const SPUR_OUT := 156.0  # far enough that the main road disappears behind woodland
const SPUR_LIFT := 30.0  # a real climb before the lake-and-range reveal
const SPUR_HALF_WIDTH := 4.6
const SPUR_MOUTH := 34.0  # junction taper, where the spur is still part of the road
const SPUR_SHOULDER := 2.2  # surfaced shoulder beyond the rideable edge
## The parking platform at the top. The rideable apron is what the bike can
## reach; the terrace beyond it is made ground the bike cannot enter, which is
## where the wall, the benches and the viewer stand. Without that separation
## every bench on the platform is something to ride through.
## A real viewpoint lay-by is one bike-length of parking wide. At 15 this was
## thirty metres of open tarmac by a hundred and seventy long, which from the
## saddle read as an airport apron dropped on a hillside — the single biggest
## reason the overlook did not look like a place anyone would stop.
const PLATFORM_HALF_WIDTH := 9.0
## Narrow on purpose. A flat terrace hides everything steeper than
## atan(eye height / its width): make it broad and the rider standing at the
## parking edge sees the far shore and none of the water below them.
const PLATFORM_TERRACE := 4.5
const PLATFORM_HALF_LENGTH := 23.0
## The parking opens outward, on the view side, off a near edge that stays
## straight — so the flare is all on one edge and wants to be long enough that
## it reads as a road opening into a car park rather than as the road suddenly
## trebling in width.
const PLATFORM_TAPER := 44.0

## The landscape the platform exists to look at.
const HEADLAND_RISE := 25.0  # natural ground under the platform, above road level
const HEADLAND_INNER := 48.0  # where the hillside starts to climb
## Where the headland tips over into the drop. It sits just past the outer lip
## of the terrace, so the ground the rider is parked on ends where the view
## starts. Left further out than the platform reaches, the overlook looks over a
## field that slopes gently to a pond.
const HEADLAND_CREST := 176.0
## Lake surface below the carriageway. With the platform thirteen metres above
## the road, this is the other half of how far down the water is — and how far
## down it is, over how short a run, is the whole difference between a belvedere
## and a picnic table beside a pond.
const WATER_DROP := 34.0
## The near shore is close in on purpose: 27 m of fall over 28 m of ground is a
## bluff you are standing on top of. Put the water 60 m further out and the same
## drop becomes a lawn running down to a lake, which is what this was.
const LAKE_NEAR := 252.0
const LAKE_FAR := 760.0
const LAKE_BED := 9.0
const LAKE_SPAN := 520.0  # half length of the water along the route
const FAR_BANK := 95.0
const FAR_BANK_RISE := 38.0
const VIEWPOINT_OUTER := 1040.0

var _water_y_cache: Dictionary = {}


func viewpoint_centre_for(z: float) -> float:
	## Route distance of the overlook nearest z. Everything else keys off this.
	## Never earlier than the first one: a run starts at z = 0 and an overlook
	## rounded to a negative centre would hang its spur off the start line.
	return maxf(VIEWPOINT_FIRST + VIEWPOINT_PERIOD * roundf((z - VIEWPOINT_FIRST) / VIEWPOINT_PERIOD), VIEWPOINT_FIRST)


func viewpoint_side_for(centre_z: float) -> float:
	return 1.0 if posmod(hash(Vector2i(int(round(centre_z)), world_seed)), 2) == 0 else -1.0


func viewpoint_index_for(centre_z: float) -> int:
	## Chunk that owns the platform furniture. The overlook spans a dozen chunks;
	## only one may build the benches or they appear a dozen times.
	return floori(centre_z / CHUNK_LENGTH)


func is_viewpoint_chunk(index: int) -> bool:
	var centre := viewpoint_centre_for((float(index) + 0.5) * CHUNK_LENGTH)
	return viewpoint_index_for(centre) == index


func viewpoint_side(index: int) -> float:
	return viewpoint_side_for(viewpoint_centre_for((float(index) + 0.5) * CHUNK_LENGTH))


static func _taper(u: float) -> float:
	## Trapezoid: eased in at both ends, one constant gradient through the middle.
	##
	## A smoothstep is smooth, but its steepest point is 1.5x its average, and on
	## a road the steepest point is the entire story — it is the one the rider has
	## to be able to follow. This holds a single angle for four fifths of the
	## swing instead of spiking through the middle of it, which is both what a
	## surveyed slip road does and what a bike can be ridden along.
	if u <= 0.0:
		return 0.0
	if u >= 1.0:
		return 1.0
	var area := 1.0 - SPUR_EASE  # the trapezoidal gradient integrates to this
	if u < SPUR_EASE:
		return u * u / (2.0 * SPUR_EASE) / area
	if u > 1.0 - SPUR_EASE:
		return (area - (1.0 - u) * (1.0 - u) / (2.0 * SPUR_EASE)) / area
	return (SPUR_EASE * 0.5 + u - SPUR_EASE) / area


func spur_divergence(z: float) -> float:
	## How far the spur has pulled away from the carriageway, 0 alongside it and
	## 1 at the platform.
	##
	## It holds at 0 for the first eighty metres on purpose. That stretch is a
	## deceleration lane: the spur is a lane on the edge of the carriageway, so
	## the rider has a second and a half at speed — much longer if they brake,
	## which the sign is asking them to do — to decide and move across. Peeling
	## away immediately left a forty-metre window to cross a gore, which no player
	## is going to hit.
	var distance := absf(z - viewpoint_centre_for(z))
	if distance >= SPUR_HALF_SPAN:
		return 0.0
	var t := clampf((SPUR_HALF_SPAN - distance) / SPUR_RAMP, 0.0, 1.0)
	return _taper(clampf((t - SPUR_HOLD) / (1.0 - SPUR_HOLD), 0.0, 1.0))


func spur_gap(z: float) -> float:
	## Width of the gore: open ground between the carriageway's edge and the
	## spur's near edge. This is the spur's plan geometry, not its centreline —
	## see spur_offset().
	return (SPUR_OUT - HALF_WIDTH - PLATFORM_HALF_WIDTH) * spur_divergence(z)


func spur_offset(z: float) -> float:
	## Unsigned lateral of the spur centreline, written from its *near* edge.
	##
	## The spur begins as an extra lane bolted to the edge of the carriageway and
	## walks outward from there, so its near edge is HALF_WIDTH + the gore and its
	## centreline follows from that. Anchoring the centreline at the carriageway
	## edge instead — which is what this did — laid half the spur's width on top
	## of the outside running lane for the whole length of the junction: the exit
	## opened in the middle of the traffic, and the two road surfaces overlapped
	## in a patch of mismatched tarmac 90 m long.
	return HALF_WIDTH + spur_gap(z) + spur_half_width(z)


func spur_half_width(z: float) -> float:
	## Zero at the very ends (so the junction opens as a gore rather than a step),
	## a lane and a half along the ramps, and the full apron at the top.
	var distance := absf(z - viewpoint_centre_for(z))
	if distance >= SPUR_HALF_SPAN:
		return 0.0
	var mouth := smoothstep(SPUR_HALF_SPAN, SPUR_HALF_SPAN - SPUR_MOUTH, distance)
	return SPUR_HALF_WIDTH * mouth + (PLATFORM_HALF_WIDTH - SPUR_HALF_WIDTH) * platform_blend(z)


func platform_blend(z: float) -> float:
	## 1 across the parking platform, easing out along the ramps either side.
	var distance := absf(z - viewpoint_centre_for(z))
	return 1.0 - smoothstep(PLATFORM_HALF_LENGTH, PLATFORM_HALF_LENGTH + PLATFORM_TAPER, distance)


func spur_interval(z: float) -> Vector2:
	## Signed rideable span of the spur at z, or a zero-length span in the open.
	var half := spur_half_width(z)
	if half <= 0.001:
		return Vector2.ZERO
	var centre := viewpoint_centre_for(z)
	var offset := viewpoint_side_for(centre) * spur_offset(z)
	return Vector2(offset - half, offset + half)


func on_spur(z: float, lateral: float) -> bool:
	## True once the rider has committed to the detour — past the gore, out on
	## the spur proper rather than on the carriageway.
	var spur := spur_interval(z)
	if spur == Vector2.ZERO:
		return false
	return lateral >= spur.x and lateral <= spur.y and (lateral < -HALF_WIDTH or lateral > HALF_WIDTH)


func at_platform(z: float, lateral: float) -> bool:
	## Standing on the parking platform itself, where the view is.
	var centre := viewpoint_centre_for(z)
	if absf(z - centre) > PLATFORM_HALF_LENGTH + PLATFORM_TAPER:
		return false
	return absf(absf(lateral) - spur_offset(z)) <= PLATFORM_HALF_WIDTH


## Where the benches stand, relative to the overlook centre and the platform
## centreline. The chunk builds them here and the rider sits down here; two
## copies of these numbers would put the camera through the back of a bench.
const PLATFORM_BENCH_Z := [-10.0, 6.0]
## Where the bench stands across the terrace, which is a framing decision more
## than a furniture one. Ground falling away at sixty degrees hides itself from
## anyone set back from the edge of it, so the closer the bench is to the rail
## the more of the drop a seated rider sees. The barrier is only a low open rail
## here, so the eye can sit close to the lip and reveal the lake all the way down
## the frame without putting the bench through the fence. Two metres of setback
## filled the bottom sixth of the old view with a bright horizontal terrace slab.
const PLATFORM_BENCH_OUT := PLATFORM_HALF_WIDTH + 5.55
const SEAT_EYE := 1.24
## How far below the horizon a seated rider is looking. Dead level, the frame is
## two thirds sky; much past this and it is two thirds the terrace they are
## sitting on, because a bench set back from a cliff edge cannot see the cliff.
## This is the angle that fills the frame with water and the far side.
const SEAT_TILT := deg_to_rad(4.0)


func viewpoint_seat(z: float) -> Transform3D:
	## Eye transform for a rider sitting on the nearest bench, facing the view.
	var centre := viewpoint_centre_for(z)
	var best: float = centre + float(PLATFORM_BENCH_Z[0])
	for offset in PLATFORM_BENCH_Z:
		if absf(centre + float(offset) - z) < absf(best - z):
			best = centre + float(offset)
	var side := viewpoint_side_for(centre)
	var lateral := side * (spur_offset(best) + PLATFORM_BENCH_OUT)
	var flat := frame_flat_at(best)
	var eye := point_at(best, lateral) + flat.y * SEAT_EYE - flat.x * side * 0.15
	# Looking out over the water: away from the road, along the seat's own axis,
	# and tilted down.
	#
	# Dead level, the frame is two thirds sky and the drop the platform exists for
	# is entirely below the bottom edge of it — the rider has to be told to look
	# down before the view contains anything but distant hills. Nobody sits down
	# at a belvedere and stares at the horizon. W/S still moves from here.
	var aim: Vector3 = (flat.x * side - flat.y * tan(SEAT_TILT)).normalized()
	return Transform3D(Basis.looking_at(aim, flat.y), eye)


func _spur_full_lift(z: float, lateral: float) -> float:
	## Height of the spur road above the carriageway plane, before the embankment
	## taper. The carriageway itself is never lifted: without that gate the
	## platform, which is wide enough to reach back over the road, would pick the
	## road up with it.
	# Climbs with the divergence, not before it: an exit lane still running
	# alongside the carriageway cannot be thirteen metres above it.
	var shape := spur_divergence(z)
	if shape <= 0.0:
		return 0.0
	if lateral * viewpoint_side_for(viewpoint_centre_for(z)) <= 0.0:
		return 0.0
	# The climb happens across the gore — between the carriageway's edge and the
	# spur's — so the spur itself is lifted evenly and stays flat across its
	# width. Ramped over a fixed few metres instead, the gate cut across the
	# spur's own surface and gave it a crossfall that grew as it climbed.
	var inner := HALF_WIDTH + spur_gap(z)
	return SPUR_LIFT * shape * smoothstep(HALF_WIDTH, maxf(inner, HALF_WIDTH + 1.0), absf(lateral))


func spur_deck_blend(z: float, lateral: float) -> float:
	## Made ground: 1 on the spur and its shoulder, falling to 0 at the foot of
	## the embankment. The lift below shares this exact curve, which is what
	## makes the sides of the spur a clean slope from road surface down to
	## natural ground — blend the two on different curves and the ground rears up
	## in a lip around the road instead.
	if spur_half_width(z) <= 0.001:
		return 0.0
	# Never inside the carriageway. A junction is where two roads meet, not where
	# one is painted over the other: made ground that reached back across the
	# carriageway's own edge line replaced its curb and verge with gravel for the
	# whole length of the mouth, which is the grey patch the approach used to be
	# covered in.
	var inside := smoothstep(HALF_WIDTH - 0.05, HALF_WIDTH + 0.35, absf(lateral))
	if inside <= 0.0:
		return 0.0
	var full := _spur_full_lift(z, lateral)
	var out := absf(lateral) - spur_offset(z)
	var edge := spur_half_width(z) + SPUR_SHOULDER
	# The terrace is on the view side only: made ground the rider walks out on.
	var outward := out > 0.0
	if outward:
		edge += PLATFORM_TERRACE * platform_blend(z)
	out = absf(out)
	if out <= edge:
		return inside
	# The embankment is as long as the fill under it is deep — and the fill is
	# the road surface above the *natural* ground, not above the carriageway.
	# Sized off the full lift instead, the platform grows a thirty-metre skirt of
	# made ground that buries the drop it exists to look over.
	var fill: float = maxf(full - headland_rise(z, absf(lateral)), 0.0)
	var skirt := 5.0 + fill * 1.5
	if outward:
		# On the drop side of the platform the made ground simply stops. An
		# embankment is for blending fill into a hillside that carries on, and past
		# the terrace lip there is no hillside to blend into — leaving it here hung
		# an eight-metre shelf of flat ground over the edge, which from the bench
		# is a grey slab across the bottom third of the view with the drop behind
		# it. Along the ramp there *is* a hillside, so it keeps its embankment.
		skirt = lerpf(skirt, 0.9, platform_blend(z))
	return inside * (1.0 - smoothstep(edge, edge + skirt, out))


func headland_rise(z: float, out: float) -> float:
	## Natural ground above the carriageway plane on the view side: the hillside
	## the spur climbs and the headland the platform sits on.
	var along := 1.0 - smoothstep(PLATFORM_HALF_LENGTH + 80.0, SPUR_HALF_SPAN + 60.0, absf(z - viewpoint_centre_for(z)))
	return HEADLAND_RISE * (0.35 + 0.65 * along) * smoothstep(HEADLAND_INNER, HEADLAND_CREST, out)


func spur_lift(z: float, lateral: float) -> float:
	var full := _spur_full_lift(z, lateral)
	if full <= 0.0:
		return 0.0
	return full * spur_deck_blend(z, lateral)


func viewpoint_water_y(centre_z: float) -> float:
	## One level for the whole lake, taken under the *lowest* point the road
	## reaches along it. The carriageway climbs and falls several metres over the
	## length of the water; levelling on the middle would flood one end of it.
	var key := int(round(centre_z))
	if _water_y_cache.has(key):
		return _water_y_cache[key]
	var lowest := INF
	for i in 13:
		lowest = minf(lowest, height_at(centre_z + LAKE_SPAN * (float(i) / 6.0 - 1.0)))
	var level: float = lowest - WATER_DROP
	_water_y_cache[key] = level
	return level


func viewpoint_near_shore(z: float) -> float:
	## Wobbling shorelines. A basin cut with constant radii reads as a swimming
	## pool the moment you can see both ends of it.
	##
	## Two wavelengths, not one: the long one moves the whole bank in and out over
	## half a kilometre, and the short one puts a point and a bay every couple of
	## hundred metres. A single sine is a shore that curves, which from a fixed
	## viewpoint is indistinguishable from a straight one.
	return LAKE_NEAR + 11.0 * sin(z * 0.0125 + _terrain_phase) + 7.0 * sin(z * 0.0268 + _terrain_phase * 1.9)


func viewpoint_far_shore(z: float, centre_z: float) -> float:
	# Lens-shaped in plan, so the water closes to a point instead of ending in a
	# straight edge drawn across the valley.
	var u := clampf(absf(z - centre_z) / LAKE_SPAN, 0.0, 1.0)
	var lens := sqrt(maxf(1.0 - u * u, 0.0))
	var near := viewpoint_near_shore(z)
	return near + (LAKE_FAR - LAKE_NEAR) * (0.25 + 0.75 * lens) + 26.0 * sin(z * 0.0085 + _terrain_phase * 1.7)


func viewpoint_reserves(z: float, lateral: float) -> bool:
	## Ground the overlook owns, which the scattered scenery pass has to keep out
	## of: the spur corridor, the platform and everything past the headland. The
	## hillside between the carriageway and the spur is deliberately *not*
	## reserved — trees on it are what the climb is ridden through.
	var centre := viewpoint_centre_for(z)
	var distance := absf(z - centre)
	# Far enough out to cover the spur as well as the basin. Bounded by the lake
	# alone, the outermost stretch of the ramp was open to the scatter pass and
	# grew boulders in the middle of its own carriageway.
	if distance > maxf(LAKE_SPAN + 60.0, SPUR_HALF_SPAN):
		return false
	if lateral * viewpoint_side_for(centre) <= 0.0:
		return false
	var out := absf(lateral)
	if out > HEADLAND_CREST - 6.0:
		return true  # the drop, the water, the far shore
	if distance > SPUR_HALF_SPAN:
		return false
	# Clear of the spur road, its shoulders and its embankment.
	return absf(out - spur_offset(z)) <= spur_half_width(z) + SPUR_SHOULDER + 7.0


func _viewpoint_terrain_drop(z: float, lateral: float, base: float) -> float:
	## Carve the headland and the basin, then flatten whatever the spur road
	## runs over. Called for every terrain vertex in the world, so it gives up on
	## route distance before touching anything expensive.
	var centre := viewpoint_centre_for(z)
	var distance := absf(z - centre)
	# The spur reaches further along the route than the basin does, and the ground
	# it is built on has to be flattened for all of it — cut this off at the lake
	# and the last stretch of ramp floats over unmade hillside.
	if distance > maxf(LAKE_SPAN + 70.0, SPUR_HALF_SPAN):
		return base
	var drop := base
	if lateral * viewpoint_side_for(centre) > 0.0:
		var out := absf(lateral)
		if out > HEADLAND_INNER:
			var mask := (
				(1.0 - smoothstep(LAKE_SPAN * 0.72, LAKE_SPAN + 65.0, distance))
				* smoothstep(HEADLAND_INNER, HEADLAND_INNER + 14.0, out)
				* (1.0 - smoothstep(VIEWPOINT_OUTER, VIEWPOINT_OUTER + 90.0, out))
			)
			if mask > 0.0:
				drop = lerpf(drop, _viewpoint_land_drop(z, out, centre), mask)
	# The lift is already in the road plane every one of these drops is measured
	# from, so made ground is simply zero drop.
	var deck := spur_deck_blend(z, lateral)
	if deck > 0.0:
		drop = lerpf(drop, 0.0, deck)
	return drop


func _viewpoint_land_drop(z: float, out: float, centre_z: float) -> float:
	## Absolute-height shaping written as a drop below the carriageway plane, so
	## the lake bed stays under one level water surface however the road rolls.
	## Negative is above the road: the headland is high ground.
	var water := height_at(z) - viewpoint_water_y(centre_z)
	var near := viewpoint_near_shore(z)
	var far := viewpoint_far_shore(z, centre_z)
	# The headland is a hill, not a plateau: it falls away along the route as
	# well as across it, so the platform sits on a nose of land.
	var crest := -headland_rise(z, HEADLAND_CREST)
	if out <= HEADLAND_CREST:
		return -headland_rise(z, out)
	if out <= near:
		# The face: from the crest down past the waterline. It goes over the edge
		# steeply and eases into the shore, rather than the other way round —
		# what tells a rider standing at the rail that they are high up is ground
		# that disappears from under them in the first few metres. Easing out of
		# the crest instead put a shoulder of gentle grass between the platform
		# and anything worth looking at.
		var t := clampf((out - HEADLAND_CREST) / maxf(near - HEADLAND_CREST, 1.0), 0.0, 1.0)
		# Eased, but not so much that the foot of it flattens out: run the last
		# third of a drop into the water at a shallow angle and what the rider is
		# looking down at is twenty metres of beach, which is the one thing a
		# clifftop view must not have at the bottom of it.
		var fall := 1.0 - pow(1.0 - t, 1.5)
		# A ledge two thirds of the way down: one break in the face reads as rock
		# rather than as a ramp, and it catches light differently from the slope
		# above and below it.
		fall -= 0.09 * sin(PI * clampf((t - 0.35) / 0.5, 0.0, 1.0))
		# The face carries on under the surface rather than stopping at it, so the
		# waterline lands on the steep part of the slope instead of on the shelf
		# at the end of it.
		return lerpf(crest, water + 4.5, fall)
	if out <= far:
		var s := (out - near) / maxf(far - near, 1.0)
		return water + 1.6 + LAKE_BED * sin(PI * s)
	var r := clampf((out - far) / FAR_BANK, 0.0, 1.0)
	return water + 1.6 - (FAR_BANK_RISE + 1.6) * smoothstep(0.0, 1.0, r)


func road_bounds_at(
	z: float, lateral: float = 0.0, connection_margin: float = 0.0, prefer_spur: bool = false
) -> Vector2:
	## Signed lateral limits of the rideable surface *containing* `lateral`.
	##
	## The world is no longer one strip: at an overlook the carriageway and the
	## spur are two separate surfaces that meet at a junction. Answering for the
	## surface the rider is actually on is what lets them steer off onto the
	## detour, ride it, and be held on it — with the same clamp, the same edge
	## forces and the same code in the bike as an ordinary road edge.
	var carriageway := Vector2(-HALF_WIDTH, HALF_WIDTH)
	var spur := spur_interval(z)
	if spur == Vector2.ZERO:
		return carriageway
	# Overlapping at the junction: one wide mouth, so crossing over is a steer
	# rather than a jump. Keep it connected until the gap clears the whole vehicle
	# envelope too. Splitting the bounds the instant a hairline gore appeared made
	# the safe edge jump by roughly a bike width while the rider was crossing it,
	# which felt like a collision on otherwise flat tarmac.
	var join := maxf(connection_margin, 0.0) * 2.0
	if spur.x <= carriageway.y + join and spur.y >= carriageway.x - join:
		return Vector2(minf(carriageway.x, spur.x), maxf(carriageway.y, spur.y))
	# Once a rider has crossed the mouth, their chosen ribbon must survive the
	# widening gore. Selecting only by the previous frame's lateral position can
	# otherwise switch them back to the nearer carriageway as the spur moves out
	# from underneath them.
	if prefer_spur:
		return spur
	if lateral >= spur.x and lateral <= spur.y:
		return spur
	if lateral >= carriageway.x and lateral <= carriageway.y:
		return carriageway
	# In the gore between the two: whichever is nearer keeps the rider.
	var to_spur := minf(absf(lateral - spur.x), absf(lateral - spur.y))
	var to_road := minf(absf(lateral - carriageway.x), absf(lateral - carriageway.y))
	return spur if to_spur < to_road else carriageway


func clamp_road_lateral(
	lateral: float, edge_margin: float = 0.0, z: float = 0.0, prefer_spur: bool = false
) -> float:
	var margin := clampf(edge_margin, 0.0, HALF_WIDTH)
	var bounds := road_bounds_at(z, lateral, margin, prefer_spur)
	return clampf(lateral, bounds.x + margin, bounds.y - margin)


func is_on_road(z: float, lateral: float, edge_margin: float = 0.0) -> bool:
	var bounds := road_bounds_at(z, lateral)
	var margin := clampf(edge_margin, 0.0, HALF_WIDTH)
	return lateral >= bounds.x + margin - ROAD_EDGE_EPSILON and lateral <= bounds.y - margin + ROAD_EDGE_EPSILON


func road_point_at(z: float, lateral: float = 0.0, edge_margin: float = 0.0) -> Vector3:
	## Safe surface query for riders and traffic. It always projects to defined
	## road, unlike the legacy terrain helpers used to place scenery.
	return point_at(z, clamp_road_lateral(lateral, edge_margin, z))


func road_transform_at(
	z: float, lateral: float = 0.0, edge_margin: float = 0.0, prefer_spur: bool = false
) -> Transform3D:
	return transform_at(z, clamp_road_lateral(lateral, edge_margin, z, prefer_spur))


## How twisty / hilly this stretch is (0..1), on a much longer wavelength than
## the curves themselves — that is what gives long straights and tight sections
## instead of one uniform noodle.
func twistiness_at(z: float) -> float:
	return clampf(0.22 + 0.48 * (0.5 + 0.5 * sin(z * 0.00085 + _curve_phase_b)), 0.0, 1.0)


func hilliness_at(z: float) -> float:
	return 0.2 + 0.5 * (0.5 + 0.5 * sin(z * 0.00065 + _height_phase_b))


func height_at(z: float) -> float:
	var h := hilliness_at(z)
	# Two long wavelengths only. Layering short waves onto hills is mathematically
	# smooth but creates repeated sharp-looking crests at riding speed. These broad
	# grades keep the horizon readable in the same way Café Racer's roads do.
	return _shape_scale * (
		sin(z * 0.0024 + _height_phase_a) * 7.5
		+ sin(z * 0.0065 + _height_phase_b) * 2.8 * h
	)


func center_x_at(z: float) -> float:
	var t := twistiness_at(z)
	return _shape_scale * (
		sin(z * 0.0038 + _curve_phase_a) * 24.0
		+ sin(z * 0.010 + _curve_phase_b) * 5.0 * t
	)


func pitch_at(z: float) -> float:
	return atan2(height_at(z + DZ) - height_at(z - DZ), DZ * 2.0)


func yaw_at(z: float) -> float:
	return atan2(center_x_at(z + DZ) - center_x_at(z - DZ), DZ * 2.0)


## Signed horizontal curvature (rad per metre). Positive = the road bends toward
## the frame's +X. Drives banking, the bike's cornering load and traffic lean.
func curvature_at(z: float) -> float:
	return (yaw_at(z + 2.0) - yaw_at(z - 2.0)) / 4.0


func bank_at(z: float) -> float:
	return clampf(-curvature_at(z) * BANK_PER_CURVATURE, -MAX_BANK, MAX_BANK)


func forward_dir(z: float) -> Vector3:
	var p := pitch_at(z)
	var y := yaw_at(z)
	return Vector3(sin(y) * cos(p), sin(p), cos(y) * cos(p)).normalized()


## Unbanked frame. Positions are built on this; banking is added back as a height
## offset that tapers out past the verge, so a 9° corner does not launch terrain
## 70 m out into the sky.
func frame_flat_at(z: float) -> Basis:
	var fwd := forward_dir(z)
	var right := Vector3(fwd.z, 0.0, -fwd.x).normalized()
	return Basis(right, fwd.cross(right), fwd)


func frame_at(z: float) -> Basis:
	var fwd := forward_dir(z)
	var right := Vector3(fwd.z, 0.0, -fwd.x).normalized()
	var flat := Basis(right, fwd.cross(right), fwd)
	return flat.rotated(fwd, bank_at(z))


func transform_at(z: float, lateral: float = 0.0) -> Transform3D:
	## Build orientation and position from one road sample. Calling frame_at() and
	## point_at() separately repeats all of the curve, hill and bank trigonometry;
	## moving traffic used to do that several times per physics tick.
	var fwd := forward_dir(z)
	var right := Vector3(fwd.z, 0.0, -fwd.x).normalized()
	var up := fwd.cross(right)
	var flat := Basis(right, up, fwd)
	var bank := bank_at(z)
	var taper := 1.0 - smoothstep(HALF_WIDTH, HALF_WIDTH + 6.0, absf(lateral))
	var lift := spur_lift(z, lateral)
	var origin := center_at(z) + right * lateral + up * (lateral * tan(bank) * taper + lift)
	var basis := flat.rotated(fwd, bank)
	if lift != 0.0:
		# The spur climbs; a bike sitting level on a 6% ramp looks like it is
		# hovering up the hill.
		basis = basis.rotated(basis.x, -spur_grade(z, lateral))
	return Transform3D(basis, origin)


func spur_grade(z: float, lateral: float) -> float:
	## Along-route slope the spur adds on top of the carriageway's own pitch.
	return atan2(spur_lift(z + DZ, lateral) - spur_lift(z - DZ, lateral), DZ * 2.0)


func surface_pitch_at(z: float, lateral: float) -> float:
	## Pitch of the surface actually under the rider, carriageway or spur. The
	## bike reads this for gravity and camera tilt.
	return pitch_at(z) + spur_grade(z, lateral)


func center_at(z: float) -> Vector3:
	return Vector3(center_x_at(z), height_at(z), z)


func bank_offset(z: float, lateral: float) -> float:
	var taper := 1.0 - smoothstep(HALF_WIDTH, HALF_WIDTH + 6.0, absf(lateral))
	return lateral * tan(bank_at(z)) * taper


func point_at(z: float, lateral: float = 0.0) -> Vector3:
	var f := frame_flat_at(z)
	return center_at(z) + f.x * lateral + f.y * (bank_offset(z, lateral) + spur_lift(z, lateral))


## Ground point beside the road, on the terrain rather than the tarmac.
func ground_at(z: float, lateral: float) -> Vector3:
	return point_at(z, lateral) - frame_flat_at(z).y * terrain_drop(lateral, z)


## Extra shaping used by the verge ribbon. Kept here as well as in the mesh
## profile so roadside scenery sits on the visible ground instead of floating
## at road height. Cancelled over the spur road, which carries its own surface
## and has no carriageway curb or verge camber across it.
func terrain_profile_drop(lateral: float, z: float = 0.0) -> float:
	var a := absf(lateral)
	if a <= HALF_WIDTH:
		return 0.0
	var deck := spur_deck_blend(z, lateral)
	if deck > 0.0:
		return _profile_drop_shape(a) * (1.0 - deck)
	return _profile_drop_shape(a)


func _profile_drop_shape(a: float) -> float:
	if a <= 8.7:
		return -0.16
	if a <= 11.5:
		return lerpf(0.14, 0.55, (a - 8.7) / 2.8)
	if a <= 14.0:
		return lerpf(0.55, 0.6, (a - 11.5) / 2.5)
	if a <= 20.5:
		return lerpf(0.6, 0.4, (a - 14.0) / 6.5)
	if a <= 29.0:
		return lerpf(0.4, 0.0, (a - 20.5) / 8.5)
	return 0.0


func ride_surface_at(z: float, lateral: float) -> Vector3:
	## Legacy terrain query for scenery and migration tests. Playable actors must
	## use road_point_at(), which projects lateral to the defined tarmac.
	if absf(lateral) <= HALF_WIDTH:
		return point_at(z, lateral)
	return ground_at(z, lateral) - frame_flat_at(z).y * terrain_profile_drop(lateral, z)


func ride_transform_at(z: float, lateral: float) -> Transform3D:
	## Legacy terrain transform for scenery and migration tests. Playable actors
	## must use road_transform_at() so no transform can place them off tarmac.
	if absf(lateral) <= HALF_WIDTH:
		return transform_at(z, lateral)
	var centre := ride_surface_at(z, lateral)
	var along := ride_surface_at(z + DZ, lateral) - ride_surface_at(z - DZ, lateral)
	var across := ride_surface_at(z, lateral + DZ) - ride_surface_at(z, lateral - DZ)
	var right := across.normalized()
	var forward := (along - right * along.dot(right)).normalized()
	var up := forward.cross(right).normalized()
	if up.dot(Vector3.UP) < 0.0:
		right = -right
		up = -up
	return Transform3D(Basis(right, up, forward), centre)


## Advance a path parameter by `metres` of *actual* travel. Stepping z directly
## by speed*delta under-reads on curves and hills, which made the speedo lie.
func advance(z: float, metres: float) -> float:
	return z + metres * maxf(forward_dir(z).z, 0.5)


## Ground height relative to the road surface (positive = below it), as a
## function of distance along the road's right vector. Flat out to the verge,
## then rolling country. A pure function of (lateral, z) so neighbouring chunks
## always meet seamlessly, and so props can sit on it without a raycast.
func terrain_drop(lateral: float, z: float) -> float:
	var a := absf(lateral)
	var blend := clampf((a - HALF_WIDTH - 3.0) / 18.0, 0.0, 1.0)
	var rolling := (
		sin(lateral * 0.0125 - z * 0.006 + _terrain_phase) * 4.0
		+ sin(lateral * 0.031 + z * 0.014 + _terrain_phase * 0.6) * 1.6
		+ sin(lateral * 0.072 + z * 0.035) * 0.45
	)
	return _viewpoint_terrain_drop(z, lateral, blend * (1.0 - rolling))
