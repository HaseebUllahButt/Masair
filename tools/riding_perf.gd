extends SceneTree
## A real-render, traffic-on four kilometre ride, without PNG encoding in the
## sample. Lane holding uses rider inputs; invulnerability prevents one random
## overtake ending a benchmark. Run at 1280x720 inside the GPU heavy slot.

func _initialize() -> void:
	var opts: Dictionary = {}
	for arg in OS.get_cmdline_user_args():
		var kv: PackedStringArray = arg.trim_prefix("--").split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	var runner := Ride.new()
	runner.opts = opts
	root.add_child(runner)


class Ride:
	extends Node
	var opts: Dictionary
	var launched: bool = false
	var prepared: bool = false
	var settled_frames: int = 0
	var player: Node3D
	var streamer: Node
	var frames: Array[float] = []
	var elapsed: float = 0.0
	var sample_start: float = -1.0
	var last_usec: int = 0
	var gpu: float = 0.0
	var cpu: float = 0.0
	var process_ms: float = 0.0
	var physics_ms: float = 0.0
	var draws: float = 0.0
	var primitives: float = 0.0
	var rid: RID
	var hitch_jobs: Dictionary = {}
	var missing_surface_frames: int = 0
	var late_props_frames: int = 0

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = int(opts.get("fps-cap", 0))
		rid = get_viewport().get_viewport_rid()
		RenderingServer.viewport_set_measure_render_time(rid, true)
		while is_instance_valid(get_tree().root.find_child("ScenicWarmup", true, false)):
			await get_tree().process_frame
		var hud: Node = get_tree().root.find_child("HUD", true, false)
		hud.call("_start_ride")
		var main: Node = get_tree().root.find_child("Main", true, false)
		main.call("begin_ride", 2 if opts.get("mode", "day") == "night" else (0 if opts.get("mode", "day") == "dusk" else 1), 1)
		var path: Node = get_tree().root.get_node("RoadPath")
		path.call("set_world_seed", int(opts.get("seed", 2)))
		player = get_tree().root.find_child("Player", true, false)
		var catalog: GDScript = load("res://scripts/bike_catalog.gd")
		player.call("apply_bike_profile", 0, catalog.call("stats", 0, catalog.call("empty_tuning")), 0)
		player.track_z = float(opts.get("z", 0))
		player.lateral = -2.0
		player.speed = 0.0
		player.lat_vel = 0.0
		player.call("_place")
		streamer = get_tree().root.find_child("RoadStreamer", true, false)
		streamer.call("reset_world")
		get_tree().root.find_child("TrafficManager", true, false).call("reset_world")
		var ablate: String = opts.get("ablate", "")
		if ablate == "shadows":
			(get_tree().root.find_child("Sun", true, false) as DirectionalLight3D).shadow_enabled = false
		elif ablate == "field":
			var shader: Shader = Shader.new()
			shader.code = "shader_type spatial; void fragment() { ALBEDO = OUTPUT_IS_SRGB ? COLOR.rgb : mix(COLOR.rgb / 12.92, pow((COLOR.rgb + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), COLOR.rgb)); ROUGHNESS = 1.0; SPECULAR = 0.0; }"
			var poly: GDScript = load("res://scripts/low_poly.gd")
			poly.field_material().shader = shader
		Input.action_release("throttle")
		last_usec = Time.get_ticks_usec()
		launched = true

	func _process(delta: float) -> void:
		if not launched:
			return
		var now: int = Time.get_ticks_usec()
		var wall: float = float(now - last_usec) / 1000000.0
		last_usec = now
		if not prepared:
			player.track_z = float(opts.get("z", 0))
			player.speed = 0.0
			player.call("_place")
			settled_frames = settled_frames + 1 if int(streamer.get("_idle_current")) >= 0 else 0
			if settled_frames < 8:
				return
			prepared = true
			Input.action_press("throttle")
		elapsed += delta
		player.set("_invuln", 2.0)
		var error: float = -2.0 - float(player.lateral)
		Input.action_release("steer_left")
		Input.action_release("steer_right")
		if absf(error) > 0.25 and absf(float(player.lat_vel)) < absf(error) * 1.2:
			Input.action_press("steer_left" if error > 0.0 else "steer_right")
		if elapsed < float(opts.get("warmup", 8)):
			return
		if sample_start < 0.0:
			sample_start = player.track_z
			print("ride start: seed=%s mode=%s z=%.0f" % [opts.get("seed", 2), opts.get("mode", "day"), sample_start])
			return
		var chunks: Dictionary = streamer.get("_chunks")
		var current: int = floori(float(player.track_z) / 40.0)
		var road: Node = chunks.get(current)
		if road == null or road.get_node_or_null("RoadSurface") == null:
			missing_surface_frames += 1
		var ahead: Node = chunks.get(current + 2)
		if ahead == null or not bool(ahead.get_meta("props_done", false)):
			late_props_frames += 1
		frames.append(wall)
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(rid)
		cpu += RenderingServer.viewport_get_measured_render_time_cpu(rid)
		process_ms += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		physics_ms += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		draws += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		primitives += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
		if wall > 0.033:
			var job: String = streamer.call("debug_state")
			hitch_jobs[job] = int(hitch_jobs.get(job, 0)) + 1
		if float(player.track_z) - sample_start < float(opts.get("distance", 4000)):
			return
		_report()
		get_tree().quit()

	func _report() -> void:
		frames.sort()
		var total: float = 0.0
		var slow: float = 0.0
		var hitches: int = 0
		var hitches20: int = 0
		var tail: int = maxi(1, ceili(frames.size() * 0.01))
		for i in frames.size():
			total += frames[i]
			if i >= frames.size() - tail:
				slow += frames[i]
			if frames[i] > 0.020:
				hitches20 += 1
			if frames[i] > 0.033:
				hitches += 1
		var n: float = float(frames.size())
		print("ride: ", JSON.stringify({
			"seed": int(opts.get("seed", 2)), "mode": opts.get("mode", "day"),
			"ablate": opts.get("ablate", "none"), "km": (float(player.track_z) - sample_start) / 1000.0,
			"seconds": total, "fps": n / total, "low1": tail / slow,
			"hitches20": hitches20, "p95_ms": frames[mini(frames.size() - 1, floori(n * 0.95))] * 1000.0,
			"p99_ms": frames[mini(frames.size() - 1, floori(n * 0.99))] * 1000.0,
			"worst_ms": frames[-1] * 1000.0, "hitches33": hitches, "speed_mps": player.speed, "cars": (get_tree().root.find_child("TrafficManager", true, false).get("_cars") as Array).size(),
			"gpu_ms": gpu / n, "render_cpu_ms": cpu / n,
			"process_ms": process_ms / n, "physics_ms": physics_ms / n,
			"draws": draws / n, "primitives": primitives / n,
			"missing_surface_frames": missing_surface_frames, "late_props_pct": late_props_frames / n * 100.0,
		}))
		print("hitch_jobs: ", JSON.stringify(hitch_jobs))
