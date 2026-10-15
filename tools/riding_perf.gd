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
		else:
			opts[kv[0]] = "1"
	if opts.has("hitch"):
		load("res://scripts/road_chunk.gd").set("hitch_trace", true)
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
	var late_chunks: Dictionary = {}
	## Per-frame phase clocks (--hitch): where a slow frame actually went.
	## process_frame resumes the parked build coroutines before any node
	## processes, so "resume" is the sliced streaming work; the streamer and
	## traffic get bracketed by marker nodes; "rest" is render + swap.
	var t_frame: int = 0
	var t_resume_end: int = 0
	var t_phys_start: int = 0
	var phys_usec: int = 0
	var phases: Dictionary = {}
	var phase_hitch: Dictionary = {}
	## Distance ahead (m) at which each chunk's dressing became complete.
	var dressed_at: Dictionary = {}
	var dressed_close: int = 0

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = int(opts.get("fps-cap", 0))
		rid = get_viewport().get_viewport_rid()
		RenderingServer.viewport_set_measure_render_time(rid, true)
		get_tree().process_frame.connect(_on_frame_start)
		get_tree().physics_frame.connect(_on_physics_start)
		while is_instance_valid(get_tree().root.find_child("ScenicWarmup", true, false)) and DisplayServer.get_name() != "headless":
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
		if opts.has("hitch"):
			_bracket(streamer, "stream", 100)
			_bracket(get_tree().root.find_child("TrafficManager", true, false), "traffic", 200)
			var first := Marker.new()
			first.ride = self
			first.label = "resume"
			first.process_priority = -1000000
			first.process_physics_priority = -1000000
			add_sibling(first)
			var last := Marker.new()
			last.ride = self
			last.label = "process_end"
			last.process_priority = 1000000
			last.process_physics_priority = 1000000
			add_sibling(last)
		streamer.call("reset_world")
		get_tree().root.find_child("TrafficManager", true, false).call("reset_world")
		if opts.has("nohead"):
			# Diagnostic: does the bike's spot light alone ask for new programs?
			var head := player.find_child("Headlight", true, false) as Light3D
			if head:
				head.visible = false
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
			if opts.has("hitch"):
				var compiled := _new_programs()
				print("compiled before ride: %d" % compiled)
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
			late_chunks[current + 2] = true
		frames.append(wall)
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(rid)
		cpu += RenderingServer.viewport_get_measured_render_time_cpu(rid)
		process_ms += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		physics_ms += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		draws += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		primitives += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
		_note_dressing(chunks, current)
		if opts.has("hitch"):
			for key: String in phases:
				if not key.begins_with("_"):
					phase_hitch[key] = float(phase_hitch.get(key, 0.0)) + float(phases[key]) / 1000.0
		if wall > 0.033:
			var job: String = streamer.call("debug_state")
			hitch_jobs[job] = int(hitch_jobs.get(job, 0)) + 1
			if opts.has("hitch"):
				print("hitch: z=%.1f wall=%.2f render=%.2f gpu=%.2f %s" % [player.track_z, wall * 1000.0, RenderingServer.viewport_get_measured_render_time_cpu(rid), RenderingServer.viewport_get_measured_render_time_gpu(rid), job])
		if float(player.track_z) - sample_start < float(opts.get("distance", 4000)):
			return
		_report()
		get_tree().quit()

	var cur_phases: Dictionary = {}

	func _on_frame_start() -> void:
		## Frame start to frame start: this frame's resumes, process and render,
		## plus the physics steps that open the next one. A slow interval prints
		## its own split, so a hitch line names where its milliseconds went.
		var now := Time.get_ticks_usec()
		if t_frame > 0:
			cur_phases["rest"] = now - int(cur_phases.get("_process_end", now))
			cur_phases["physics"] = phys_usec
			var done := {}
			for key: String in cur_phases:
				if not key.begins_with("_"):
					done[key] = cur_phases[key]
			phases = done
			var span := now - t_frame
			if sample_start >= 0.0 and span > 33000 and opts.has("hitch"):
				var compiled := _new_programs()
				print("split: z=%.1f span=%.2f %s compiled=%d %s" % [player.track_z, float(span) / 1000.0, _phase_text(phases), compiled, streamer.call("debug_state")])
				if compiled > 0 and opts.has("trace"):
					_print_new_looks()
			elif span > 20000 and opts.has("hitch"):
				var fresh := _new_programs()
				if fresh > 0:
					print("compile: z=%.1f span=%.2f compiled=%d" % [float(player.track_z) if player else -1.0, float(span) / 1000.0, fresh])
					if opts.has("trace"):
						_print_new_looks()
			if opts.has("trace") and player != null and Engine.get_process_frames() % 10 == 0:
				_scan_looks(false)
		cur_phases = {}
		phys_usec = 0
		t_frame = now

	## The renderer's program cache rewrites a shader's cache file each time it
	## compiles a new variant of it, so a changed mtime is a compile that frame.
	var cache_seen: Dictionary = {}

	func _new_programs() -> int:
		var fresh := 0
		var root_dir := "user://shader_cache/SceneShaderGLES3"
		for sub: String in DirAccess.get_directories_at(root_dir):
			for file: String in DirAccess.get_files_at(root_dir + "/" + sub):
				var path := root_dir + "/" + sub + "/" + file
				var stamp := FileAccess.get_modified_time(path)
				if int(cache_seen.get(path, -1)) != stamp:
					if cache_primed:
						fresh += 1
					cache_seen[path] = stamp
		cache_primed = true
		return fresh

	var cache_primed := false

	## --trace: what kinds of drawable came near the camera since the last scan,
	## so a compile line can name the newcomer that asked for the program.
	var looks_seen: Dictionary = {}
	var looks_new: Array = []

	func _look_key(node: GeometryInstance3D) -> String:
		var mat: Material = node.material_override
		var mesh: Mesh = null
		if node is MeshInstance3D:
			mesh = (node as MeshInstance3D).mesh
			if mat == null and mesh != null and mesh.get_surface_count() > 0:
				var parts := PackedStringArray()
				for i in mesh.get_surface_count():
					var m: Material = (node as MeshInstance3D).get_active_material(i)
					parts.append(_mat_name(m))
				return "%s MI[%s] shadow=%d" % [node.name.rstrip("0123456789"), ",".join(parts), node.cast_shadow]
		var kind := "MM" if node is MultiMeshInstance3D else node.get_class()
		return "%s %s[%s] shadow=%d" % [node.name.rstrip("0123456789"), kind, _mat_name(mat), node.cast_shadow]

	func _mat_name(m: Material) -> String:
		if m == null:
			return "none"
		if m is ShaderMaterial:
			var sh: Shader = (m as ShaderMaterial).shader
			return "SM:" + (sh.resource_path.get_file() if sh and sh.resource_path != "" else str(sh.get_instance_id() if sh else 0))
		if m is BaseMaterial3D:
			var b := m as BaseMaterial3D
			return "STD:%d/%d/%d/%d" % [b.shading_mode, b.transparency, int(b.vertex_color_use_as_albedo), b.cull_mode]
		return m.get_class()

	func _scan_looks(report: bool) -> void:
		var cam := get_viewport().get_camera_3d()
		if cam == null:
			return
		var eye := cam.global_position
		var lights := 0
		for node: Node in get_tree().root.find_children("*", "GeometryInstance3D", true, false):
			var geo := node as GeometryInstance3D
			if not geo.is_visible_in_tree():
				continue
			var reach := geo.visibility_range_end if geo.visibility_range_end > 0.0 else 3000.0
			var aabb := geo.get_aabb()
			var centre := geo.global_transform * aabb.get_center()
			if centre.distance_to(eye) - aabb.size.length() * 0.5 > minf(reach, 3000.0):
				continue
			var key := _look_key(geo)
			if not looks_seen.has(key):
				looks_seen[key] = true
				if looks_primed:
					looks_new.append([Engine.get_process_frames(), key])
		for node: Node in get_tree().root.find_children("*", "Light3D", true, false):
			var light := node as Light3D
			if light is DirectionalLight3D or not light.is_visible_in_tree():
				continue
			var key := "light %s %s energy=%.1f" % [light.get_class(), light.name.rstrip("0123456789"), light.light_energy]
			if light.global_position.distance_to(eye) < 80.0 and not looks_seen.has(key):
				looks_seen[key] = true
				if looks_primed:
					looks_new.append([Engine.get_process_frames(), key])
		looks_primed = true

	var looks_primed := false

	func _print_new_looks() -> void:
		_scan_looks(true)
		var names := PackedStringArray()
		for entry: Array in looks_new:
			if Engine.get_process_frames() - int(entry[0]) <= 40:
				names.append(str(entry[1]))
		print("  newcomers: ", " | ".join(names))
		looks_new.clear()

	func _on_physics_start() -> void:
		t_phys_start = Time.get_ticks_usec()

	func mark(label: String, physics: bool) -> void:
		var now := Time.get_ticks_usec()
		if physics:
			if label == "process_end":
				phys_usec += now - t_phys_start
			return
		match label:
			"resume":
				cur_phases["resume"] = now - t_frame
				t_resume_end = now
			"process_end":
				cur_phases["_process_end"] = now
				cur_phases["process"] = now - t_resume_end - int(cur_phases.get("stream", 0)) - int(cur_phases.get("traffic", 0))
			_:
				if label.ends_with(">"):
					cur_phases["_" + label] = now
				else:
					var key := label.trim_suffix("<")
					cur_phases[key] = now - int(cur_phases.get("_" + key + ">", now))
					if key == "traffic" and int(cur_phases[key]) > 5000 and sample_start >= 0.0:
						var tm := get_tree().root.find_child("TrafficManager", true, false)
						print("traffic: z=%.1f ms=%.1f cars=%d" % [player.track_z, float(cur_phases[key]) / 1000.0, (tm.get("_cars") as Array).size()])

	func _phase_text(p: Dictionary) -> String:
		var out := PackedStringArray()
		for key: String in ["physics", "resume", "stream", "traffic", "process", "rest"]:
			out.append("%s=%.1f" % [key, float(p.get(key, 0)) / 1000.0])
		return " ".join(out)

	func _bracket(target: Node, label: String, priority: int) -> void:
		if target == null:
			return
		target.process_priority = priority
		var before := Marker.new()
		before.ride = self
		before.label = label + ">"
		before.process_priority = priority - 1
		add_sibling(before)
		var after := Marker.new()
		after.ride = self
		after.label = label + "<"
		after.process_priority = priority + 1
		add_sibling(after)

	func _note_dressing(chunks: Dictionary, current: int) -> void:
		## A chunk "lands late" when its dressing finishes closer than the
		## distance its trees are drawn from: the rider watched it appear.
		## Chunks already dressed when sampling starts are not arrivals.
		var first := dressed_at.is_empty()
		for index: int in range(current, current + 16):
			if dressed_at.has(index):
				continue
			var chunk: Node = chunks.get(index)
			if chunk == null or not bool(chunk.get_meta("props_done", false)):
				continue
			if first:
				dressed_at[index] = INF
				continue
			var ahead: float = float(index) * 40.0 - float(player.track_z)
			dressed_at[index] = ahead
			if ahead < 160.0:
				dressed_close += 1
				if opts.has("hitch"):
					print("late: chunk=%d dressed %.0f m ahead" % [index, ahead])

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
			"frames": frames.size(), "late_chunks": late_chunks.size(), "late_props_frames": late_props_frames,
			"dressed_under160": dressed_close, "dressed_min_m": _min_dressed(),
			"missing_surface_frames": missing_surface_frames, "late_props_pct": late_props_frames / n * 100.0,
		}))
		print("hitch_jobs: ", JSON.stringify(hitch_jobs))
		if opts.has("hitch"):
			var avg := {}
			for key: String in phase_hitch:
				avg[key] = float(phase_hitch[key]) / n
			print("phases_avg_ms: ", JSON.stringify(avg))

	func _min_dressed() -> float:
		var best := INF
		for index: int in dressed_at:
			best = minf(best, float(dressed_at[index]))
		return best if best < INF else -1.0


class Marker:
	extends Node
	var ride: Node
	var label: String

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS

	func _process(_delta: float) -> void:
		ride.call("mark", label, false)

	func _physics_process(_delta: float) -> void:
		ride.call("mark", label, true)
