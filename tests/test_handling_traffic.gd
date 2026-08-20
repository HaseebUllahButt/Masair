extends SceneTree
## Focused regression checks for the rideable road boundary and traffic brains.
##
##   godot --headless --path . --script res://tests/test_handling_traffic.gd

const RoadPathGD := preload("res://scripts/road_path.gd")
const MotorcycleGD := preload("res://scripts/motorcycle.gd")
const TrafficCarGD := preload("res://scripts/traffic_car.gd")
const TrafficManagerGD := preload("res://scripts/traffic_manager.gd")

var failures: int = 0
var _ran := false


func check(ok: bool, what: String) -> void:
	if not ok:
		failures += 1
		print("FAIL: ", what)


func _process(_delta: float) -> bool:
	if _ran:
		quit(1 if failures > 0 else 0)
		return true
	_ran = true
	var path: Node = root.get_node_or_null("RoadPath")
	if path == null:
		path = RoadPathGD.new()
		path.name = "RoadPath"
		root.add_child(path)
	path.call("set_world_seed", 72117)

	# A bike can lean and recover at speed, but its full footprint stays inside
	# the authored road. Build the minimal cockpit tree so this remains headless.
	var bike := MotorcycleGD.new()
	var visual := Node3D.new()
	visual.name = "Visual"
	bike.add_child(visual)
	var pivot := Node3D.new()
	pivot.name = "CameraPivot"
	bike.add_child(pivot)
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	pivot.add_child(camera)
	root.add_child(bike)
	bike.set_physics_process(false)
	# Garage save applies a profile in `_ready`; this file tests the handling
	# model of the stock 200 km/h machine, not whichever bike is unlocked.
	bike.top_speed = 55.5556
	bike.engine_accel = 12.0
	bike.brake_accel = 16.0
	bike.engine_brake = 3.2
	bike.roll_drag = 0.03
	check(is_equal_approx(float(bike.top_speed), 55.5556), "bike keeps the 200 km/h top speed")
	check(float(bike.max_lateral) < float(path.HALF_WIDTH), "bike boundary is inside the road edges")
	bike.lateral = 50.0
	bike.call("_place")
	check(absf(float(bike.lateral)) <= float(bike.max_lateral) + 0.001, "edge recovery clamps an invalid lateral position")
	check(path.is_on_road(bike.track_z, bike.lateral, bike.half_width + bike.road_edge_margin), "clamped bike footprint remains on tarmac")

	# Sideways speed is a heading angle, not a free parameter. Under a flat cap a
	# bike at walking pace could cross a lane faster than it was travelling
	# forward, which is the skating feel — and it is worst pulling away from a
	# standstill, which is exactly what leaving an overlook platform is.
	bike.speed = 4.0
	check(float(bike.call("lateral_speed_limit")) < 4.0, "a slow bike cannot travel sideways faster than it rides")
	bike.speed = bike.top_speed
	check(
		is_equal_approx(float(bike.call("lateral_speed_limit")), float(bike.max_lat_speed)),
		"at speed the flat cap is what holds the bike, not the heading"
	)
	check(float(bike.high_speed_lean_rate) < 1.0, "a bike at speed is harder to tip than one at town pace")

	# Once selected, the lead-off is the bike's moving coordinate frame. Without
	# carrying this centreline motion forward, a neutral input leaves the bike at
	# its old main-road lateral while the scenic road moves out from under it.
	var centre: float = float(path.viewpoint_centre_for(0.0))
	var entry: float = centre - float(path.SPUR_HALF_SPAN)
	var spur_z_a := entry + 240.0
	var spur_z_b := spur_z_a + 12.0
	var spur_a: Vector2 = path.spur_interval(spur_z_a)
	var spur_b: Vector2 = path.spur_interval(spur_z_b)
	var local_offset := 1.35
	bike.set("_committed_to_spur", true)
	bike.lateral = (spur_a.x + spur_a.y) * 0.5 + local_offset
	var carried_velocity: float = float(bike.call("_follow_committed_surface", spur_z_a, spur_z_b, 0.25))
	var carried_offset: float = bike.lateral - (spur_b.x + spur_b.y) * 0.5
	check(
		is_equal_approx(carried_offset, local_offset),
		"neutral steering preserves position across the moving lead-off (%.3f vs %.3f)" % [carried_offset, local_offset]
	)
	check(absf(carried_velocity) > 0.01, "lead-off frame motion contributes to the bike heading")
	bike.set("_committed_to_spur", false)

	# Standing up off the bench has to give the camera back to the rig. The blend
	# used to filter the camera's *own* transform toward the bench every frame,
	# and the rig only ever wrote its position — so its rotation had nothing to
	# return to, and the ride carried on pointing out over the water.
	bike.speed = 0.0
	bike.call("_update_view", 0.016)
	var upright: Transform3D = camera.transform
	bike.seated = true
	for _i in 90:
		bike.call("_update_view", 0.016)
	check(not camera.transform.is_equal_approx(upright), "sitting down takes the camera off the bike")
	bike.seated = false
	for _i in 150:
		bike.call("_update_view", 0.016)
	check(camera.transform.basis.is_equal_approx(upright.basis), "standing up gives the camera back to the rig")
	check(is_equal_approx(camera.fov, float(bike.get("_ride_fov"))), "standing up gives the lens back too")

	# A faster car must see a slower same-lane lead before changing lanes, and a
	# lane with no nearby vehicle must be available for a safe pass.
	var lead: Node3D = TrafficCarGD.new() as Node3D
	var follower: Node3D = TrafficCarGD.new() as Node3D
	root.add_child(follower)
	root.add_child(lead)
	follower.call("setup", 0, 1, 100.0, 30.0, 0)
	lead.call("setup", 1, 1, 112.0, 10.0, 1)
	follower.set_physics_process(false)
	lead.set_physics_process(false)
	var vehicle_mesh := follower.get_node("VehicleMesh") as MeshInstance3D
	check(
		vehicle_mesh.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		"traffic never enters the artifact-prone directional shadow pass"
	)
	check(vehicle_mesh.visibility_range_end <= 380.0, "distant traffic leaves the far fog without a draw")
	var contact_shadow := follower.get_node_or_null("ContactShadow") as MeshInstance3D
	check(contact_shadow != null, "traffic has a smooth lightweight contact shadow")
	check(
		contact_shadow != null and contact_shadow.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		"contact patch never re-enters the real-time shadow pass"
	)
	check(follower.get_node_or_null("Voice") == null, "traffic does not create continuous engine drones")
	check(follower.call("_nearest_lead") == lead, "traffic follows the nearest same-lane lead")
	check(not follower.call("can_change_to_lane", 1), "traffic rejects an occupied target lane")
	check(follower.call("can_change_to_lane", 0), "traffic accepts a clear adjacent lane")
	var before_speed: float = follower.speed
	follower.call("_physics_process", 0.1)
	check(float(follower.speed) < before_speed, "traffic brakes into a safe following gap")

	# A horn reaches the nearest aligned driver after a human reaction delay. The
	# car signals first, checks the lane again, then eases across instead of
	# receiving an instantaneous sideways velocity.
	bike.track_z = 0.0
	bike.lateral = float(path.lane_x(1))
	var near_horn_car: Node3D = TrafficCarGD.new() as Node3D
	var far_horn_car: Node3D = TrafficCarGD.new() as Node3D
	root.add_child(near_horn_car)
	root.add_child(far_horn_car)
	near_horn_car.call("setup", 0, 1, 38.0, 24.0, 3)
	far_horn_car.call("setup", 0, 1, 58.0, 24.0, 4)
	near_horn_car.set_physics_process(false)
	far_horn_car.set_physics_process(false)
	bike.call("_sound_horn")
	check(float(near_horn_car.get("_horn_reaction_timer")) >= 0.0, "nearest aligned driver receives the horn")
	check(float(far_horn_car.get("_horn_reaction_timer")) < 0.0, "horn does not scatter a whole line of traffic")

	var horn_car: Node3D = TrafficCarGD.new() as Node3D
	root.add_child(horn_car)
	horn_car.call("setup", 0, 1, 200.0, 24.0, 2)
	horn_car.set_physics_process(false)
	var horn_start: float = horn_car.lateral
	check(bool(horn_car.call("hear_horn", 150.0, horn_start)), "an aligned car ahead hears the horn")
	check(not bool(horn_car.call("hear_horn", 150.0, horn_start)), "horn response has a cooldown")
	horn_car.call("_update_horn_response", 1.0)
	check(int(horn_car.get("_pending_lane")) >= 0, "driver chooses a safe adjacent lane after reacting")
	check(is_equal_approx(float(horn_car.lateral), horn_start), "driver does not move during reaction or signal lead-in")
	horn_car.call("_update_lane_plan", 1.0)
	check(bool(horn_car.get("_lane_change_active")), "lane change starts after indicating")
	horn_car.call("_advance_lane_change", 0.1)
	check(absf(float(horn_car.lateral) - horn_start) < 0.1, "lane change eases in without a sideways jump")
	for _i in 40:
		horn_car.call("_advance_lane_change", 0.1)
	check(not bool(horn_car.get("_lane_change_active")), "lane change completes in a bounded time")
	check(is_equal_approx(float(horn_car.lateral), float(horn_car.get("_target_lateral"))), "car settles exactly on its new lane")

	# Traffic weather is a function of (world_seed, z): long bands, not a sprinkle.
	var traffic: Node = TrafficManagerGD.new()
	traffic.name = "TrafficManager"
	root.add_child(traffic)
	traffic.call("bind_player", bike)
	path.call("set_world_seed", 72117)
	traffic.call("reset_world")
	var mood_a: int = int(traffic.call("mood_at", 4200.0))
	var mood_a_again: int = int(traffic.call("mood_at", 4200.0))
	check(mood_a == mood_a_again, "same seed and z always resolve the same traffic mood")
	path.call("set_world_seed", 72117)
	check(int(traffic.call("mood_at", 4200.0)) == mood_a, "resetting the same world seed keeps the mood")
	var seq_a: Array[int] = []
	var seq_b: Array[int] = []
	for i in 24:
		seq_a.append(int(traffic.call("mood_at", float(i) * 1100.0)))
	path.call("set_world_seed", 88421)
	traffic.call("reset_world")
	for i in 24:
		seq_b.append(int(traffic.call("mood_at", float(i) * 1100.0)))
	check(seq_a != seq_b, "different world seeds can produce different traffic weather")
	path.call("set_world_seed", 72117)
	traffic.call("reset_world")
	var seen: Dictionary = {}
	var sample_step := 80.0
	var scan_end := 36000.0
	var z := 0.0
	var run_mood: int = int(traffic.call("mood_at", 0.0))
	var run_start := 0.0
	var longest_run := 0.0
	var shortest_complete := INF
	while z <= scan_end:
		var m: int = int(traffic.call("mood_at", z))
		seen[m] = true
		if m != run_mood:
			var run_len := z - run_start
			longest_run = maxf(longest_run, run_len)
			if run_start > 0.0 or z > sample_step:
				shortest_complete = minf(shortest_complete, run_len)
			run_mood = m
			run_start = z
		z += sample_step
	longest_run = maxf(longest_run, scan_end - run_start)
	check(seen.size() >= 3, "a long stretch of road contains at least three traffic moods")
	check(longest_run >= 800.0, "a mood band lasts hundreds of metres (longest %.0f m)" % longest_run)
	check(
		shortest_complete >= 700.0,
		"moods do not flicker every corner (shortest complete band %.0f m)" % shortest_complete
	)
	var mood_clear: int = TrafficManagerGD.Mood.CLEAR
	var mood_flow: int = TrafficManagerGD.Mood.FLOW
	var mood_crawl: int = TrafficManagerGD.Mood.CRAWL
	var mood_wall: int = TrafficManagerGD.Mood.WALL
	check(
		float(traffic.call("mood_interval_mul", mood_clear))
		> float(traffic.call("mood_interval_mul", mood_flow)),
		"CLEAR waits longer between spawns than FLOW"
	)
	check(
		float(traffic.call("mood_min_gap_mul", mood_clear))
		> float(traffic.call("mood_min_gap_mul", mood_wall)),
		"CLEAR leaves longer gaps than WALL"
	)
	check(
		int(traffic.call("mood_active_cap", mood_clear))
		< int(traffic.call("mood_active_cap", mood_wall)),
		"CLEAR holds fewer cars than WALL at the same difficulty"
	)
	var crawl_weights: Array = traffic.call("kind_weights_for", mood_crawl)
	var flow_weights: Array = traffic.call("kind_weights_for", mood_flow)
	var clear_weights: Array = traffic.call("kind_weights_for", mood_clear)
	var crawl_heavy := float(crawl_weights[4]) + float(crawl_weights[5]) + float(crawl_weights[6])
	var flow_heavy := float(flow_weights[4]) + float(flow_weights[5]) + float(flow_weights[6])
	var clear_light := float(clear_weights[0]) + float(clear_weights[1]) + float(clear_weights[2])
	check(crawl_heavy > 0.5, "CRAWL prefers vans, trucks and buses (heavy weight %.2f)" % crawl_heavy)
	check(crawl_heavy > flow_heavy, "CRAWL is heavier than the default FLOW mix")
	check(clear_light > 0.75, "CLEAR is mostly light cars (light weight %.2f)" % clear_light)
	check(
		float(traffic.call("mood_speed_mul", mood_crawl))
		< float(traffic.call("mood_speed_mul", mood_flow)),
		"CRAWL traffic cruises slower than FLOW"
	)
	var first_roll: int = int(traffic.get("_rng").randi())
	traffic.call("reset_world")
	var second_roll: int = int(traffic.get("_rng").randi())
	check(first_roll == second_roll, "reset_world re-seeds the traffic RNG from world_seed")

	var parked := TrafficCarGD.new() as Node3D
	traffic.add_child(parked)
	parked.call("setup", 0, 1, 150.0, 24.0, 0)
	(traffic.get("_cars") as Array).append(parked)
	var viewpoint_z: float = float(path.call("viewpoint_centre_for", 800.0))
	var viewpoint_side: float = float(path.call("viewpoint_side_for", viewpoint_z))
	bike.track_z = viewpoint_z
	bike.lateral = viewpoint_side * float(path.call("spur_offset", viewpoint_z))
	traffic.call("_process", 0.016)
	check((traffic.get("_cars") as Array).is_empty(), "traffic despawns while the rider is on the scenic spur")
	check(bool(traffic.get("_scenic_quiet")), "traffic stays quiet on the scenic spur")
	bike.lateral = 0.0
	traffic.call("_process", 0.016)
	check(not bool(traffic.get("_scenic_quiet")), "traffic resumes on the main road")

	# Cruise holds speed without the throttle down, and the brake cancels it.
	bike.speed = 22.0
	bike.set("alive", true)
	bike.set("seated", false)
	bike.set("_road_pitch", 0.0)
	Input.action_press("cruise")
	bike.call("_drive", 0.016)
	Input.action_release("cruise")
	check(bool(bike.get("cruise_on")), "C engages cruise at the current speed")
	check(is_equal_approx(float(bike.get("_cruise_speed")), 22.0), "cruise locks the speed it was set at")
	var held := float(bike.speed)
	for _i in 24:
		bike.call("_drive", 0.016)
	check(absf(bike.speed - held) < 0.8, "cruise holds speed without the throttle held")
	Input.action_press("brake")
	bike.call("_drive", 0.016)
	Input.action_release("brake")
	check(not bool(bike.get("cruise_on")), "brake cancels cruise")
	bike.speed = 4.0
	Input.action_press("cruise")
	bike.call("_drive", 0.016)
	Input.action_release("cruise")
	check(not bool(bike.get("cruise_on")), "cruise does not engage at walking pace")

	print("handling/traffic self-check: %d failures" % failures)
	quit(1 if failures > 0 else 0)
	return true
