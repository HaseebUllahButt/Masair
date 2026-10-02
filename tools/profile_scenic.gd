extends SceneTree
## Live scenic-route hitch benchmark. Requires a display.
##
##   godot --path . --script res://tools/profile_scenic.gd -- [--seed=N]
##
## Frame cost here is wall clock from Time.get_ticks_usec(), not the `delta`
## that _process is handed: Godot clamps that to
## physics/common/max_physics_steps_per_frame steps at 60 Hz, so no frame can
## report more than 133.3 ms through it however long it really took. The first
## two frames of this scene cost seconds each to compile shaders, and measured
## through `delta` they came out as two ~140 ms hitches on the approach ride —
## the wrong number, in the wrong place. Every p95 and p99 below was built from
## that clamped value, so they were understated as well.
##
## The first WARMUP_FRAMES frames are therefore reported as boot cost and kept
## out of the ride stats. They are not streaming: build time on them measures
## 0.00 ms with empty queues, and they land 10 m into a 1320 m approach, long
## before the lookoff chunks at z=2800. profile_startup.gd measures cold boot in
## more detail; this tool's job is only to stop mistaking it for a hitch.
##
## `elapsed` still advances on `delta`. It is the simulation clock, and the
## phases of the ride are distances along the road: on a wall clock the bike
## would finish the 1320 m approach inside the boot frames and the phases would
## stop meaning what they are named after.
##
## Cold and warm are not the same number and must not be averaged together.
## `scenic boot cost` is what a player waits through at launch; the ride,
## approach, lake and parked lines are what the road costs per frame once the
## driver has the programs.

const RIDE_SECONDS := 32.0
## Bound the parked wait independently of the clamped simulation clock.
const PARK_TIMEOUT_SECONDS := 45.0
const SETTLED_SECONDS := 4.0
## Frames at the head of the run that are cold boot rather than gameplay: the
## first two draw a freshly built scene, and letting them into the ride stats
## would put shader compilation back into the per-frame number. Same value and
## same reason as profile_startup.gd's WARMUP_FRAMES.
const WARMUP_FRAMES := 2
## Wall-clock cost that counts as a hitch, well clear of the ~15 ms p99 a warm
## scenic frame runs at, so only a real stall spends a line of output.
const HITCH_MS := 80.0


func _initialize() -> void:
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	var runner := Runner.new()
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--seed="):
			runner.world_seed = int(argument.trim_prefix("--seed="))
	runner.tree_ref = self
	root.add_child(runner)


class Runner:
	extends Node

	var world_seed: int = 72117
	var tree_ref: SceneTree
	var elapsed := 0.0
	var parked := false
	var frame_index: int = 0
	var last_frame_usec: int = 0
	var wall_elapsed := 0.0
	## True while the current frame belongs in the ride statistics. The cold
	## frames are recorded as boot cost instead, so a shader compile cannot be
	## reported as a hitch on the road.
	var measuring := false
	var boot_frames: Array[float] = []
	var ride_frames: Array[float] = []
	var approach_frames: Array[float] = []
	var lake_frames: Array[float] = []
	var park_frames: Array[float] = []
	var settled_frames: Array[float] = []
	var parked_wall_seconds: float = 0.0
	var stable_wall_seconds: float = 0.0
	var ready_last_frame: bool = false
	var scenery_valid: bool = false
	var player: Node
	var path: Node
	var streamer: Node
	var viewpoint := 0.0
	var side := 1.0
	var missing_road_frames := 0

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		path = get_tree().root.get_node("RoadPath")
		streamer = get_tree().root.find_child("RoadStreamer", true, false)
		player = get_tree().root.find_child("Player", true, false)
		var hud := get_tree().root.find_child("HUD", true, false)
		if hud and hud.has_method("_start_ride"):
			hud.call("_start_ride")
		# Starting the ride randomizes the world; pin the benchmark afterward.
		path.call("set_world_seed", world_seed)
		viewpoint = float(path.call("viewpoint_centre_for", 2800.0))
		side = float(path.call("viewpoint_side_for", viewpoint))
		# Start well inside the committed spur, before lake chunks enter the normal
		# riding ring, then ride through their incremental construction.
		player.track_z = viewpoint - 1320.0
		player.lateral = side * float(path.call("spur_offset", player.track_z))
		player.set("_committed_to_spur", true)
		player.speed = player.top_speed
		player.set("_invuln", RIDE_SECONDS + PARK_TIMEOUT_SECONDS + 10.0)
		player.call("_place")
		player.reset_physics_interpolation()
		streamer.call("reset_world")
		# Frame 0 is the cold frame, so the clock starts at the end of setup:
		# everything from here to the first _process is what that frame costs.
		last_frame_usec = Time.get_ticks_usec()
		print("scenic setup: seed_requested=%d seed_actual=%d biome=%d seated=%s" % [world_seed, int(path.get("world_seed")), int(path.call("theme_at", viewpoint)), str(player.get("seated"))])
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Input.action_press("throttle")

	func _process(delta: float) -> void:
		# Wall clock for what a frame cost, `delta` for how far the simulation
		# got. Only the first is a measurement: the second is capped at 133.3 ms
		# and would report every cold frame as a 133 ms hitch. Seconds, the unit
		# the report and the phase clock already speak.
		var now := Time.get_ticks_usec()
		var frame_seconds := float(now - last_frame_usec) / 1000000.0
		last_frame_usec = now
		var frame_ms := frame_seconds * 1000.0
		wall_elapsed += frame_seconds
		elapsed += delta
		measuring = frame_index >= WARMUP_FRAMES
		if measuring:
			# t is wall clock too, so it lines up with the ms beside it. Cold
			# frames are not here: they are a launch wait, and a hitch line
			# that quotes one teaches the wrong lesson about the road.
			if frame_ms > HITCH_MS:
				print("scenic hitch: t=%.2f z=%.1f %.1f ms ribbon=%s scenic=%s props=%s" % [wall_elapsed, float(player.track_z), frame_ms, str(streamer.get("_build_in_flight")), str(streamer.get("_scenic_in_flight")), str(streamer.get("_props_in_flight"))])
		else:
			boot_frames.append(frame_seconds)
		frame_index += 1
		if not parked:
			# Follow the access road through real steering input. Holding the initial
			# lateral drove off the spur instead of profiling its climb.
			var span: Vector2 = path.call("spur_interval", player.track_z)
			var target: float = (span.x + span.y) * 0.5
			var steer_error: float = target - float(player.lateral)
			Input.action_release("steer_left")
			Input.action_release("steer_right")
			if absf(steer_error) > 0.4 and absf(float(player.lat_vel)) < absf(steer_error) * 1.2:
				Input.action_press("steer_left" if steer_error > 0.0 else "steer_right")
			_sample(ride_frames, frame_seconds)
			if measuring and not _active_road_visible():
				missing_road_frames += 1
			if elapsed < 16.0:
				_sample(approach_frames, frame_seconds)
			else:
				_sample(lake_frames, frame_seconds)
			if elapsed < RIDE_SECONDS:
				return
			parked = true
			Input.action_release("throttle")
			Input.action_release("steer_left")
			Input.action_release("steer_right")
			player.track_z = viewpoint
			var apron: float = float(path.get("PLATFORM_HALF_WIDTH"))
			player.lateral = side * (float(path.call("spur_offset", viewpoint)) + apron - 3.5)
			player.speed = 0.0
			player.lat_vel = 0.0
			player.set("_committed_to_spur", true)
			player.call("_place")
			player.set("seated", true)
			player.set("_seat_yaw", 0.0)
			player.set("_seat_pitch", 0.0)
			player.reset_physics_interpolation()
			print("scenic parked view: seed_actual=%d biome=%d seated=%s z=%.1f lateral=%.1f" % [int(path.get("world_seed")), int(path.call("theme_at", viewpoint)), str(player.get("seated")), float(player.track_z), float(player.lateral)])
		else:
			parked_wall_seconds += frame_seconds
			_sample(park_frames, frame_seconds)
			var ready: bool = _lookout_ready()
			if ready and ready_last_frame:
				# Both ends of this drawn frame were idle. A frame that finishes a
				# build belongs to loading, even if its queues are empty now.
				stable_wall_seconds += frame_seconds
				_sample(settled_frames, frame_seconds)
			else:
				stable_wall_seconds = 0.0
				settled_frames.clear()
			ready_last_frame = ready
			var settled: bool = stable_wall_seconds >= SETTLED_SECONDS
			var timed_out: bool = parked_wall_seconds >= PARK_TIMEOUT_SECONDS
			if not settled and not timed_out:
				return
			_report_boot()
			_report("scenic ride", ride_frames)
			_report("scenic approach", approach_frames)
			_report("scenic lake ride", lake_frames)
			_report("scenic parked", park_frames)
			if settled:
				_report("scenic parked settled", settled_frames)
			else:
				print("scenic parked settled: INCOMPLETE; no four-second idle window before timeout")
			_validate_scenery()
			print("scenic validation: %d measured ride frames missing the active road surface" % missing_road_frames)
			var complete: bool = settled and ready and scenery_valid and missing_road_frames == 0
			print("scenic readiness: %s seed_requested=%d seed_actual=%d biome=%d seated=%s seat_blend=%.3f idle=%s active_road=%s stable_wall_s=%.2f parked_wall_s=%.2f settled_samples=%d timeout=%s" % ["COMPLETE" if complete else "INCOMPLETE", world_seed, int(path.get("world_seed")), int(path.call("theme_at", viewpoint)), str(player.get("seated")), float(player.get("_seat_blend")), str(_streamer_idle()), str(_active_road_visible()), stable_wall_seconds, parked_wall_seconds, settled_frames.size(), str(timed_out)])
			tree_ref.quit(0 if complete else 2)

	func _active_road_visible() -> bool:
		var current_index: int = floori(float(player.track_z) / 40.0)
		var chunk: Node = (streamer.get("_chunks") as Dictionary).get(current_index)
		if not is_instance_valid(chunk):
			return false
		var riding_spur: bool = bool(path.call("on_spur", player.track_z, player.lateral))
		var surface_name: String = "SpurSurface" if riding_spur else "RoadSurface"
		var surface: Node3D = chunk.get_node_or_null(surface_name) as Node3D
		return is_instance_valid(surface) and surface.is_visible_in_tree()

	func _streamer_idle() -> bool:
		for flag: String in ["_build_in_flight", "_props_in_flight", "_scenic_in_flight", "_highway_in_flight"]:
			if bool(streamer.get(flag)):
				return false
		for queue: String in ["_ribbon_queue", "_props_queue", "_scenic_queue", "_highway_queue", "_unload_queue"]:
			if not (streamer.get(queue) as Array).is_empty():
				return false
		return true

	func _lookout_ready() -> bool:
		return _streamer_idle() and _active_road_visible() and bool(player.get("seated")) and float(player.get("_seat_blend")) >= 0.999 and int(path.get("world_seed")) == world_seed

	func _sample(frames: Array[float], frame_seconds: float) -> void:
		## Feed one wall-clock frame cost into a stats array, unless this is a
		## cold frame — those are boot cost, and `boot_frames` already has them.
		if measuring:
			frames.append(frame_seconds)

	func _report_boot() -> void:
		## Boot on its own line, never inside a ride percentile: these frames are
		## shader compilation and the driver uploading programs, a launch wait
		## rather than something the road did. One line per cold frame with the
		## wall clock when that frame's _process ran, because the cold draw lands
		## in the gap after the frame that asked for it — so the cost is in the
		## numbers and not on the frame that caused it.
		if boot_frames.is_empty():
			return
		var total := 0.0
		for frame in boot_frames:
			total += frame
		boot_frames.sort()
		print(
			"scenic boot cost: %d cold frames, %.0f ms total, %.0f ms worst, excluded from the ride stats"
			% [boot_frames.size(), total * 1000.0, boot_frames[-1] * 1000.0]
		)
		var at := 0.0
		for index in boot_frames.size():
			at += boot_frames[index]
			print("scenic boot cost:   frame %d drawn by %.0f ms" % [index, at * 1000.0])

	func _report(label: String, frames: Array[float]) -> void:
		## Percentiles over wall-clock frame costs in seconds, sorted in place.
		## `frames` is empty only if a run was cut short, and then there is
		## nothing to say.
		if frames.is_empty():
			return
		frames.sort()
		var total := 0.0
		var over_20 := 0
		var over_33 := 0
		for frame in frames:
			total += frame
			over_20 += int(frame > 0.020)
			over_33 += int(frame > 0.033)
		var p95 := mini(floori(float(frames.size() - 1) * 0.95), frames.size() - 1)
		var p99 := mini(floori(float(frames.size() - 1) * 0.99), frames.size() - 1)
		print(
			"%s: %.1f fps, %.2f ms p95, %.2f ms p99, %.2f ms worst, %d over 20 ms, %d over 33 ms"
			% [
				label,
				float(frames.size()) / total,
				frames[p95] * 1000.0,
				frames[p99] * 1000.0,
				frames[-1] * 1000.0,
				over_20,
				over_33,
			]
		)

	func _validate_scenery() -> void:
		var road_chunks := 0
		var scenic_instances := 0
		var buckets := {}
		for chunk in (streamer.get("_chunks") as Dictionary).values():
			if not is_instance_valid(chunk):
				continue
			if chunk.get_node_or_null("RoadSurface") != null or chunk.get_node_or_null("SpurSurface") != null:
				road_chunks += 1
			for child in chunk.get_children():
				if child is MultiMeshInstance3D:
					var mm := (child as MultiMeshInstance3D).multimesh
					if mm and mm.instance_count > 0:
						scenic_instances += mm.instance_count
						buckets[child.name] = int(buckets.get(child.name, 0)) + mm.instance_count
		scenery_valid = road_chunks > 0 and scenic_instances > 0
		print("scenic validation: %d road chunks, %d multimesh instances, geometry_present=%s" % [road_chunks, scenic_instances, str(scenery_valid)])
		var names: Array = buckets.keys()
		names.sort_custom(func(a: Variant, b: Variant) -> bool: return int(buckets[a]) > int(buckets[b]))
		for bucket in names:
			print("scenic instances: %-16s %d" % [str(bucket), int(buckets[bucket])])
		print(
			"scenic streamer: ribbon=%s props=%s scenic=%s highway=%s queues_ribbon_props_scenic_highway_unload=%d/%d/%d/%d/%d"
			% [
				str(streamer.get("_build_in_flight")),
				str(streamer.get("_props_in_flight")),
				str(streamer.get("_scenic_in_flight")),
				str(streamer.get("_highway_in_flight")),
				(streamer.get("_ribbon_queue") as Array).size(),
				(streamer.get("_props_queue") as Array).size(),
				(streamer.get("_scenic_queue") as Array).size(),
				(streamer.get("_highway_queue") as Array).size(),
				(streamer.get("_unload_queue") as Array).size(),
			]
		)
