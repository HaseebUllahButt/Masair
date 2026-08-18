extends SceneTree
## Regression for the one Free Ride route and its road-only boundary.
##
##   godot --headless --path . --script res://tests/test_maps.gd

const RoadPathGD := preload("res://scripts/road_path.gd")
const RoadChunkGD := preload("res://scripts/road_chunk.gd")

var failures: int = 0


func check(ok: bool, what: String) -> void:
	if not ok:
		failures += 1
		print("FAIL: ", what)


func _initialize() -> void:
	var path: Node = RoadPathGD.new()
	path.call("set_world_seed", 72117)

	# Free Ride is intentionally the only route. These API checks prevent a map
	# selector or stale persisted profile from silently returning.
	check(not path.has_method("map_profile_ids"), "no alternate map profiles are registered")
	check(not path.has_method("set_map_profile"), "map switching is removed from the route")
	check(not path.has_method("scenic_detours"), "detour overlay data is removed")
	check(not path.has_method("scenic_detour_at"), "detour overlay lookup is removed")
	check(int(path.get("RIDEABLE_HALF_WIDTH")) == int(path.get("HALF_WIDTH")), "rideable width is exactly the road width")
	var pool: Array = path.get("THEME_POOL")
	check(pool.size() == 4, "the route has four rural biomes")
	check(not pool.has(RoadChunkGD.Env.CITY), "city is never in the biome pool")
	for env in [RoadChunkGD.Env.FOREST, RoadChunkGD.Env.COAST, RoadChunkGD.Env.MOUNTAIN, RoadChunkGD.Env.COUNTRY]:
		check(pool.has(env), "biome pool includes environment %d" % env)
	var biome_length: float = float(path.get("BIOME_LENGTH"))
	check(biome_length >= 10000.0 and biome_length <= 14000.0, "each biome lasts about 10–14 km")
	check(
		float(path.get("VIEWPOINT_PERIOD")) > 2.0 * float(path.get("SPUR_HALF_SPAN")),
		"detours leave a stretch of main road between them"
	)
	check(
		float(path.get("VIEWPOINT_PERIOD")) >= 4000.0 and float(path.get("VIEWPOINT_PERIOD")) <= 4500.0,
		"overlooks come around every four kilometres"
	)

	# Route distances with no spur anywhere near them, so the plain carriageway
	# rules apply. The first reward road now begins at 1440 m.
	for z in [0.0, 240.0, 900.0, 1100.0, 3200.0]:
		var bounds: Vector2 = path.call("road_bounds_at", z)
		check(bounds.x == -8.0 and bounds.y == 8.0, "free ride road bounds stay authored at z=%.1f" % z)
		check(path.call("is_on_road", z, -8.0), "left edge remains on road")
		check(path.call("is_on_road", z, 8.0), "right edge remains on road")
		check(not path.call("is_on_road", z, -8.1), "left terrain is not rideable")
		check(not path.call("is_on_road", z, 8.1), "right terrain is not rideable")
		check(is_equal_approx(float(path.call("clamp_road_lateral", 100.0)), 8.0), "positive lateral clamps to tarmac")
		check(is_equal_approx(float(path.call("clamp_road_lateral", -100.0)), -8.0), "negative lateral clamps to tarmac")

	# ---------------------------------------------------------------- overlooks
	# An overlook is a detour, not a wide shoulder: a spur road leaves the
	# carriageway, climbs, opens into a platform and rejoins. These checks are
	# the contract the bike relies on to be able to ride it.
	var centre: float = float(path.call("viewpoint_centre_for", 800.0))
	var side: float = float(path.call("viewpoint_side_for", centre))
	var half_span: float = float(path.get("SPUR_HALF_SPAN"))
	var entry: float = centre - half_span
	check(side != 0.0, "the overlook has an authored side")
	check(
		float(path.call("viewpoint_centre_for", 0.0)) == float(path.get("VIEWPOINT_FIRST")),
		"the route never rounds back to an overlook behind the start line"
	)
	check(float(path.get("VIEWPOINT_FIRST")) >= 2000.0, "the first scenic reward is earned well into the ride")
	check(float(path.get("SPUR_HALF_SPAN")) >= 1400.0, "the scenic lead-off is a substantial side-road journey")

	var platform: Vector2 = path.call("spur_interval", centre)
	# A motorcycle turns inside about four metres, so this is a guard against an
	# apron nobody can use rather than a measure of how big it should look. The
	# threshold used to be 24 m only because the apron was 30 m wide, which is an
	# airport stand, not a viewpoint.
	check(platform.y - platform.x > 15.0, "the parking apron is wide enough to pull up and turn on")
	# The terrace outside it is made ground the bike cannot reach, which is what
	# keeps the benches and the wall out of the rideable surface.
	var terrace_lateral: float = side * (float(path.call("spur_offset", centre)) + float(path.get("PLATFORM_HALF_WIDTH")) + 6.0)
	check(not path.call("is_on_road", centre, terrace_lateral), "the terrace is walked on, not ridden on")
	check(float(path.call("spur_deck_blend", centre, terrace_lateral)) > 0.99, "the terrace is still made ground")
	check(
		absf(float(path.call("ground_at", centre, terrace_lateral).y) - float(path.call("point_at", centre, terrace_lateral).y)) < 0.05,
		"the terrace is level with the platform it extends"
	)
	check(minf(absf(platform.x), absf(platform.y)) > 85.0, "the platform is far away from the carriageway")
	check(path.call("spur_interval", entry - 1.0) == Vector2.ZERO, "there is no spur before the junction")
	check(path.call("spur_interval", centre + half_span + 1.0) == Vector2.ZERO, "the spur has rejoined by the far junction")

	# The junction has to be a merge. If the two surfaces never overlap the rider
	# can never cross between them, and the detour is unreachable.
	var merged := false
	var mouth_z := entry
	while mouth_z < entry + 80.0:
		var wide: Vector2 = path.call("road_bounds_at", mouth_z, side * 8.0)
		if wide.y - wide.x > 17.0:
			merged = true
		mouth_z += 1.0
	check(merged, "the spur and the carriageway share one mouth at the junction")

	# The visual ribbons can separate as soon as a gore appears, but the driving
	# boundary must remain one mouth until a complete motorcycle can clear the
	# split. Otherwise its margin changes sides mid-crossing and snaps it sideways.
	var bike_margin := 1.28
	var envelope_joined := false
	var join_z := entry
	while join_z < entry + 280.0:
		var join_span: Vector2 = path.call("spur_interval", join_z)
		if join_span != Vector2.ZERO:
			var near_edge: float = minf(absf(join_span.x), absf(join_span.y))
			var gap: float = near_edge - float(path.get("HALF_WIDTH"))
			if gap > 0.05 and gap < bike_margin * 2.0:
				var crossing_lateral: float = side * (float(path.get("HALF_WIDTH")) + gap * 0.5)
				var joined_bounds: Vector2 = path.call("road_bounds_at", join_z, crossing_lateral, bike_margin)
				envelope_joined = joined_bounds.x < -7.9 and joined_bounds.y > 7.9 and joined_bounds.y - joined_bounds.x > 16.0
				break
		join_z += 0.25
	check(envelope_joined, "the viewpoint mouth stays connected until the whole bike clears the gore")

	# A committed rider must stay on the lead-off after the fork separates. Their
	# previous lateral coordinate can briefly remain closer to the main road than
	# to the moving spur; nearest-surface selection used to pull them back across
	# the gore here.
	var separated_z := entry
	var separated_span := Vector2.ZERO
	while separated_z < centre and separated_span == Vector2.ZERO:
		var candidate: Vector2 = path.call("spur_interval", separated_z)
		if candidate != Vector2.ZERO:
			var near_edge: float = minf(absf(candidate.x), absf(candidate.y))
			if near_edge > float(path.get("HALF_WIDTH")) + bike_margin * 2.0:
				separated_span = candidate
				break
		separated_z += 0.25
	check(separated_span != Vector2.ZERO, "the lead-off develops a separated ribbon")
	if separated_span != Vector2.ZERO:
		var main_side_edge: float = side * (float(path.get("HALF_WIDTH")) + 0.05)
		var retained: Vector2 = path.call(
			"road_bounds_at", separated_z, main_side_edge, bike_margin, true
		)
		check(
			retained == separated_span,
			"a committed rider stays assigned to the lead-off instead of the nearer main road"
		)
		var projected: float = float(path.call(
			"clamp_road_lateral", main_side_edge, bike_margin, separated_z, true
		))
		check(
			projected >= separated_span.x + bike_margin - 0.001
			and projected <= separated_span.y - bike_margin + 0.001,
			"lead-off confinement projects toward the chosen spur"
		)

	# Sweep the whole spur: the edges must move continuously, the bike must be
	# held on the surface it is on, and the climb must stay a rideable grade.
	var worst_edge_step := 0.0
	var worst_grade := 0.0
	var highest := 0.0
	var previous := Vector2.ZERO
	var swept := 0
	var sweep_z := entry
	while sweep_z <= centre + half_span:
		var span: Vector2 = path.call("spur_interval", sweep_z)
		if span != Vector2.ZERO:
			if previous != Vector2.ZERO:
				worst_edge_step = maxf(worst_edge_step, absf(span.x - previous.x))
				worst_edge_step = maxf(worst_edge_step, absf(span.y - previous.y))
			previous = span
			var middle: float = (span.x + span.y) * 0.5
			var bounds: Vector2 = path.call("road_bounds_at", sweep_z, middle)
			check(middle >= bounds.x and middle <= bounds.y, "the spur centreline is rideable at z=%.0f" % sweep_z)
			check(
				is_equal_approx(float(path.call("clamp_road_lateral", middle, 0.0, sweep_z)), middle),
				"a rider on the spur is not dragged off it at z=%.0f" % sweep_z
			)
			var lift: float = float(path.call("spur_lift", sweep_z, middle))
			highest = maxf(highest, lift)
			worst_grade = maxf(worst_grade, absf(float(path.call("spur_grade", sweep_z, middle))))
			swept += 1
		sweep_z += 0.5
	check(swept > 800, "the spur is a real distance of riding (%d samples)" % swept)

	# The number that decides whether the detour can be ridden at all: how fast
	# the road moves sideways under the rider. Lateral metres per metre travelled,
	# times speed, is the sideways speed the bike has to produce to stay on it,
	# and the bike's cap is 15 m/s. The first version peaked at 0.6, so above
	# 90 km/h the road simply left and the rider was dragged along its edge.
	var worst_drift := 0.0
	var drift_z := entry
	while drift_z <= centre + half_span:
		worst_drift = maxf(
			worst_drift, absf(float(path.call("spur_gap", drift_z + 1.0)) - float(path.call("spur_gap", drift_z)))
		)
		drift_z += 1.0
	check(
		worst_drift < 0.16,
		"the spur diverges at a rideable angle (%.3f lateral m per m, %.1f deg)" % [worst_drift, rad_to_deg(atan(worst_drift))]
	)
	check(
		worst_drift * 42.0 < 9.0,
		"following the spur at 150 km/h costs %.1f m/s of the bike's 15 m/s of sideways speed" % (worst_drift * 42.0)
	)

	# The spur is a lane on the outside of the carriageway, never a surface laid
	# across it. Overlapped, the two ribbons meet in a patch of mismatched tarmac
	# and the exit opens in the middle of the running traffic.
	var worst_intrusion := 0.0
	var deepest_deck := 0.0
	var overlap_z := entry
	while overlap_z <= centre + half_span:
		var span: Vector2 = path.call("spur_interval", overlap_z)
		if span != Vector2.ZERO:
			worst_intrusion = maxf(worst_intrusion, 8.0 - minf(absf(span.x), absf(span.y)))
		for lane_x in [-6.0, -2.0, 2.0, 6.0]:
			deepest_deck = maxf(deepest_deck, float(path.call("spur_deck_blend", overlap_z, lane_x)))
		overlap_z += 2.0
	check(worst_intrusion <= 0.001, "the spur never laps over the carriageway (worst %.2f m)" % worst_intrusion)
	check(deepest_deck <= 0.0, "the spur's made ground never reaches into a running lane")
	# Continuity, not gentleness — the far edge is allowed to flare, because that
	# is the parking opening out on the view side. How gently the *near* edge
	# moves is what decides whether the road can be followed, and that is the
	# divergence check below.
	check(worst_edge_step < 0.35, "the spur edge never steps: worst half-metre change was %.3f m" % worst_edge_step)
	check(is_equal_approx(highest, float(path.get("SPUR_LIFT"))), "the spur climbs its full height")
	check(worst_grade < deg_to_rad(9.0), "the climb stays a rideable grade (max %.1f deg)" % rad_to_deg(worst_grade))
	check(float(path.call("spur_lift", entry + 2.0, side * 9.0)) < 0.5, "the spur starts level with the carriageway")

	# The detour is never a shortcut. What it actually costs is time rather than
	# distance: a surveyed slip road is close to the length of the carriageway it
	# leaves, and the price of taking it is a single-lane road, a climb, and a car
	# park at the top of it. Buying the extra metres back by swinging the spur
	# further out is what made it unrideable in the first place.
	var detour := 0.0
	var previous_point: Vector3 = path.call("point_at", entry, side * 8.0)
	var walk_z := entry
	while walk_z <= centre + half_span:
		var span: Vector2 = path.call("spur_interval", walk_z)
		var lat: float = side * 8.0 if span == Vector2.ZERO else (span.x + span.y) * 0.5
		var here: Vector3 = path.call("point_at", walk_z, lat)
		detour += here.distance_to(previous_point)
		previous_point = here
		walk_z += 2.0
	check(detour >= half_span * 2.0, "riding the spur is never shorter than the road it leaves (%.0f m)" % detour)

	# A rider who stays on the carriageway is unaffected by any of it.
	for lane_lateral in [-7.0, 0.0, 7.0]:
		var bounds: Vector2 = path.call("road_bounds_at", centre, lane_lateral)
		check(bounds.x >= -8.0 and bounds.y <= 8.0, "the carriageway keeps its own bounds beside the platform")

	# Ground: level under the platform, falling away past it, water below that.
	var platform_mid: float = side * float(path.get("SPUR_OUT"))
	var surface_y: float = float(path.call("point_at", centre, platform_mid).y)
	var ground_y: float = float(path.call("ground_at", centre, platform_mid).y)
	check(absf(surface_y - ground_y) < 0.05, "the platform ground is level with the platform surface")
	check(
		surface_y - float(path.call("point_at", centre, 0.0).y) > 10.0,
		"the platform stands well above the carriageway"
	)
	var water_y: float = float(path.call("viewpoint_water_y", centre))
	check(surface_y - water_y > 18.0, "there is a real drop from the platform to the water")

	var flooded := 0
	var wet := 0
	var probe_z: float = centre - float(path.get("LAKE_SPAN")) * 0.6
	while probe_z <= centre + float(path.get("LAKE_SPAN")) * 0.6:
		if float(path.call("point_at", probe_z, 0.0).y) <= water_y:
			flooded += 1
		if float(path.call("ground_at", probe_z, side * (float(path.call("viewpoint_near_shore", centre)) + 80.0)).y) < water_y:
			wet += 1
		probe_z += 5.0
	check(flooded == 0, "the water level never rises over the carriageway")
	check(wet > 60, "the middle of the lake is actually below the water level")
	var far_out: float = float(path.call("viewpoint_far_shore", centre, centre))
	check(
		float(path.call("ground_at", centre, side * (far_out + float(path.get("FAR_BANK")))).y) > water_y,
		"the far bank climbs back out of the water"
	)

	# Sitting down: the seat is on the platform, at head height, facing the view.
	check(path.call("at_platform", centre, platform_mid), "the platform is where the rider can stop")
	check(not path.call("at_platform", centre, 0.0), "the carriageway is not the platform")
	check(not path.call("at_platform", entry, platform_mid), "the ramp is not the platform")
	var seat: Transform3D = path.call("viewpoint_seat", centre)
	check(seat.origin.y - surface_y > 0.9 and seat.origin.y - surface_y < 2.0, "the seated eye is at head height above the platform")
	var out_dir: Vector3 = (path.call("frame_flat_at", centre) as Basis).x * side
	check(-seat.basis.z.dot(out_dir) > 0.9, "sitting down faces the view, not the road")
	check((-seat.basis.z).y < -0.04, "sitting down still dips toward the lake")
	check((-seat.basis.z).y > -0.16, "sitting down looks out at the far shore, not down at the water")

	# Ground the overlook owns, which the random scenery pass has to keep out of.
	check(path.call("viewpoint_reserves", centre, platform_mid), "the platform is reserved from scattered scenery")
	check(path.call("viewpoint_reserves", centre, side * 240.0), "the lake bed is reserved from scattered scenery")
	check(not path.call("viewpoint_reserves", centre, -platform_mid), "the far side of the road is still planted")
	check(not path.call("viewpoint_reserves", centre, side * 30.0), "the hillside the spur climbs is still planted")
	check(
		not path.call("viewpoint_reserves", centre + half_span + 140.0, side * 240.0),
		"the reservation ends with the overlook"
	)

	var chunks_per_biome := int(biome_length / float(path.get("CHUNK_LENGTH")))
	var start_theme := int(path.call("theme_for_chunk", 0))
	check(start_theme != RoadChunkGD.Env.CITY, "the run never starts in the city")
	for chunk in chunks_per_biome:
		check(
			int(path.call("theme_for_chunk", chunk)) == start_theme,
			"neighbouring chunks inside a region share a theme (chunk %d)" % chunk
		)
	check(
		int(path.call("theme_for_chunk", chunks_per_biome)) != start_theme,
		"the next region is a different biome"
	)
	var seen := {}
	for chunk in chunks_per_biome * 4:
		var theme := int(path.call("theme_for_chunk", chunk))
		seen[theme] = true
		check(theme != RoadChunkGD.Env.CITY, "city never appears on the route")
	check(seen.size() == 4, "all four rural biomes appear over a full permutation")

	var order_a: Array = path.call("biome_order")
	path.call("set_world_seed", 72117)
	var order_b: Array = path.call("biome_order")
	check(order_a == order_b, "a seed rebuilds the same biome permutation")
	path.call("set_world_seed", 4096)
	var order_c: Array = path.call("biome_order")
	check(order_a != order_c, "a different seed shuffles the biomes")
	path.call("set_world_seed", 72117)

	var viewpoints := 0
	var rural := [RoadChunkGD.Env.FOREST, RoadChunkGD.Env.COAST, RoadChunkGD.Env.MOUNTAIN, RoadChunkGD.Env.COUNTRY]
	for scan_chunk in range(chunks_per_biome * 4):
		var scan_theme := int(path.call("theme_for_chunk", scan_chunk))
		if RoadChunkGD.is_viewpoint_chunk(scan_chunk, scan_theme):
			viewpoints += 1
			check(scan_theme in rural, "viewpoint stays in a rural biome")
			var vp_centre: float = float(path.call("viewpoint_centre_for", (float(scan_chunk) + 0.5) * 40.0))
			var entry_theme := int(path.call("theme_for_chunk", int(floor((vp_centre - half_span) / 40.0))))
			var exit_theme := int(path.call("theme_for_chunk", int(floor((vp_centre + half_span) / 40.0))))
			check(
				entry_theme == scan_theme and exit_theme == scan_theme,
				"a detour's spur stays inside the centre's biome"
			)
	check(viewpoints >= 3, "the endless route regularly schedules scenic overlooks")

	print("map self-check: %d failures" % failures)
	quit(1 if failures > 0 else 0)
