extends SceneTree
## Real-GPU seat transitions and interleaved ablations at the same viewpoint.
## Wall time includes drawing; cold startup and chunk construction stay outside
## the sample. Run under gamescope at 1280x720 through the shared heavy slot.

var _opts: Dictionary = {}
var _player: Node
var _life: Node3D
var _rid: RID
var _seed: int = 2
var _mode: String = "day"


func _initialize() -> void:
	for arg: String in OS.get_cmdline_user_args():
		var kv: PackedStringArray = arg.trim_prefix("--").split("=", true, 1)
		_opts[kv[0]] = kv[1] if kv.size() == 2 else "1"
	if _opts.has("hitch"):
		load("res://scripts/road_chunk.gd").set("hitch_trace", true)
	_seed = int(_opts.get("seed", 2))
	_mode = String(_opts.get("mode", "day"))
	_run.call_deferred()


func _run() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	await process_frame
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	_rid = root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_rid, true)
	var warm: Node = root.find_child("ScenicWarmup", true, false)
	while is_instance_valid(warm):
		await process_frame
	while is_instance_valid(root.find_child("WorldWarmup", true, false)):
		await process_frame
	var hud: Node = root.find_child("HUD", true, false)
	hud.call("_start_ride")
	main.call("preview_mood", {"day": 1, "dusk": 0, "night": 2}[_mode])
	var path: Node = root.get_node("RoadPath")
	path.call("set_world_seed", _seed)
	if _opts.has("theme"):
		var order: Array[int] = [int(_opts["theme"])]
		path.set("_biome_order", order)
	_player = root.find_child("Player", true, false)
	var centre: float = path.call("viewpoint_centre_for", 2800.0)
	var side: float = path.call("viewpoint_side_for", centre)
	_player.set("track_z", centre)
	_player.set("lateral", side * (float(path.call("spur_offset", centre)) + float(path.get("PLATFORM_HALF_WIDTH")) - 3.5))
	_player.set("speed", 0.0)
	_player.set("lat_vel", 0.0)
	_player.set("_committed_to_spur", true)
	_player.set("_invuln", 600.0)
	_player.call("_place")
	_player.reset_physics_interpolation()
	if _opts.has("pixel"):
		_player.set_physics_process(false)
	var traffic: Node = root.find_child("TrafficManager", true, false)
	traffic.set("max_active", 0)
	var streamer: Node = root.find_child("RoadStreamer", true, false)
	streamer.call("reset_world")
	var deadline: int = Time.get_ticks_msec() + 90000
	while int(streamer.get("_idle_current")) < 0 and Time.get_ticks_msec() < deadline:
		await process_frame
	print("seatbench setup seed=%d actual=%d theme=%d idle=%s" % [_seed, int(path.get("world_seed")), int(path.call("theme_at", centre)), str(int(streamer.get("_idle_current")) >= 0)])
	await create_timer(3.0).timeout
	_life = root.find_child("LookoutLife", true, false)
	if _opts.has("nolife"):
		_life.set_process(false)
	if _opts.has("pixel"):
		await _pixel_gallery(main, centre)
		quit()
		return
	if _opts.has("steady"):
		_player.call("_toggle_seat")
		await create_timer(8.0).timeout
		await _sample("steady", 1, 10.0)
		quit()
		return
	await _sample("arrived", 180)
	for lap: int in 2:
		_player.call("_toggle_seat")
		await _sample("sit%d" % lap, 60)
		await _sample("settling%d" % lap, 1, 6.0)
		await _sample("seated%d" % lap, 240, 6.0 if _mode == "night" else 0.0)
		if lap == 0 and _opts.has("out"):
			await _gallery()
		if lap == 0 and _opts.has("ablate"):
			await _ablations(main)
		_player.call("_toggle_seat")
		await _sample("stand%d" % lap, 60)
		await create_timer(1.0).timeout
	quit()


func _sample(label: String, count: int, seconds: float = 0.0) -> void:
	var samples: Array[float] = []
	var gpu: float = 0.0
	var cpu: float = 0.0
	var draws: float = 0.0
	var prims: float = 0.0
	var slow: int = 0
	var began: int = Time.get_ticks_usec()
	var i: int = 0
	while i < count or float(Time.get_ticks_usec() - began) / 1000000.0 < seconds:
		var start: int = Time.get_ticks_usec()
		await process_frame
		var ms: float = float(Time.get_ticks_usec() - start) / 1000.0
		samples.append(ms)
		if ms > 33.0 and _opts.has("hitch"):
			print("hitch: seated %s wall=%.2f process=%.2f physics=%.2f render=%.2f gpu=%.2f" % [label, ms, Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0, RenderingServer.viewport_get_measured_render_time_cpu(_rid), RenderingServer.viewport_get_measured_render_time_gpu(_rid)])
		if ms > 20.0:
			slow += 1
			if label.begins_with("sit"):
				print("transition frame=%d wall=%.2f script=%.2f draw_cpu=%.2f gpu=%.2f" % [i, ms, Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, RenderingServer.viewport_get_measured_render_time_cpu(_rid), RenderingServer.viewport_get_measured_render_time_gpu(_rid)])
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(_rid)
		cpu += RenderingServer.viewport_get_measured_render_time_cpu(_rid)
		draws += RenderingServer.viewport_get_render_info(_rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)
		prims += RenderingServer.viewport_get_render_info(_rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME)
		i += 1
	count = samples.size()
	samples.sort()
	var total: float = 0.0
	var tail_total: float = 0.0
	var hitches: int = 0
	var tail: int = maxi(1, ceili(count * 0.01))
	for j: int in count:
		total += samples[j]
		if j >= count - tail:
			tail_total += samples[j]
		if samples[j] > 33.0:
			hitches += 1
	print("seat: ", JSON.stringify({"seed": _seed, "mode": _mode, "label": label,
		"frames": count, "seconds": total / 1000.0, "fps": count * 1000.0 / total,
		"low1": tail * 1000.0 / tail_total, "hitches33": hitches,
		"worst_ms": samples[-1], "gpu_ms": gpu / count, "render_cpu_ms": cpu / count,
		"draws": draws / count, "primitives": prims / count}))
	print("seatbench seed=%d mood=%s %-18s median=%.2f p95=%.2f worst=%.2f over20=%d gpu=%.2f cpu=%.2f draws=%.0f prims=%.0f" % [_seed, _mode, label, samples[count / 2], samples[int(count * 0.95)], samples[-1], slow, gpu / count, cpu / count, draws / count, prims / count])


func _ablations(main: Node) -> void:
	var families: Dictionary = {
		"life": ["LookoutLife"], "mist": [], "lake": ["ViewpointLake"],
		"range": ["ViewpointRange"], "far-ground": ["ViewpointFarGround"],
		"foliage": ["Foliage", "Crowns", "Conifers", "Trunks", "Grass"],
		"shadows": [], "life-cpu": [],
	}
	for family: String in families:
		var nodes: Array[Node3D] = []
		for pattern: String in families[family]:
			for n: Node in root.find_children(pattern, "Node3D", true, false):
				nodes.append(n as Node3D)
		if family == "mist":
			for n: Node in _life.find_children("*", "MeshInstance3D", true, false):
				var mat: Material = (n as MeshInstance3D).material_override
				if mat is ShaderMaterial and (mat as ShaderMaterial).shader.resource_path.ends_with("life_mist.gdshader"):
					nodes.append(n as Node3D)
		for n: Node3D in nodes:
			n.visible = false
		if family == "shadows":
			for n: Node in root.find_children("*", "DirectionalLight3D", true, false):
				(n as DirectionalLight3D).shadow_enabled = false
		if family == "life-cpu":
			_life.set_process(false)
		await create_timer(0.3).timeout
		await _sample(family + "-off", 180)
		for n: Node3D in nodes:
			n.visible = true
		if family == "shadows":
			var sun: DirectionalLight3D = main.get_node("Sun")
			sun.shadow_enabled = true
		if family == "life-cpu":
			_life.set_process(true)
		await create_timer(0.3).timeout
		await _sample(family + "-on", 180)


func _gallery() -> void:
	var out_dir: String = String(_opts["out"])
	DirAccess.make_dir_recursive_absolute(out_dir)
	for i: int in (8 if _opts.has("sweep") else 1):
		_player.set("_seat_yaw", wrapf(float(i) * PI / 4.0, -PI, PI))
		if _opts.has("pixel"):
			_player.call("_update_view", 1.0)
			_player.reset_physics_interpolation()
		await process_frame
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var image: Image = root.get_texture().get_image()
		if _opts.has("pixel"):
			print("pixel seed=%d mood=%s yaw=%d draws=%d prims=%d" % [_seed, _mode, i * 45, RenderingServer.viewport_get_render_info(_rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME), RenderingServer.viewport_get_render_info(_rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME)])
		image.save_png("%s/seed%d-%s-y%03d.png" % [out_dir, _seed, _mode, i * 45])
	_player.set("_seat_yaw", 0.0)


func _pixel_gallery(main: Node, centre: float) -> void:
	## A comparison fixture freezes time in both archived shader sets. Rebuild
	## life from its authored seed before staging the exact same signature.
	root.find_child("HUD", true, false).call("hide")
	_player.call("_toggle_seat")
	_player.call("_update_view", 1.0)
	await create_timer(2.0).timeout
	var streamer: Node = root.find_child("RoadStreamer", true, false)
	while int(streamer.get("_idle_current")) < 0:
		await process_frame
	streamer.set_process(false)
	if _opts.has("fixed-world"):
		## Concurrent highway/scenic dressing consumes one RNG in a different
		## order when a driver stalls. Compare the authored kit in a fixed build
		## order, so an unrelated tree shuffle cannot hide a material difference.
		var chunks: Dictionary = streamer.get("_chunks")
		var indices: Array = chunks.keys()
		indices.sort()
		var chunk_script: GDScript = load("res://scripts/road_chunk.gd")
		for index: int in indices:
			(chunks[index] as Node).free()
			var chunk: Node3D = chunk_script.new()
			streamer.add_child(chunk)
			chunks[index] = chunk
			chunk.call("setup", index, streamer.call("theme_for_chunk", index))
			streamer.call("_apply_corridor_to", chunk)
	_life.set_process(false)
	_life.call("_clear")
	await process_frame
	await _life.call("_build", centre, Vector2i(int(round(centre)), _seed))
	_life.call("stage_capture")
	main.set_process(false)
	main.set("rain", 0.0)
	main.call("_apply_lighting")
	var grade: ShaderMaterial = main.get("_grade_mat")
	grade.set_shader_parameter("seed", 0.0)
	for n: Node in root.find_children("*", "Node3D", true, false):
		(n as Node3D).physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	var sky: ShaderMaterial = main.get("_sky_mat")
	sky.set_shader_parameter("sky_phase", float(_seed % 1000) * 0.17)
	for n: Node in root.find_children("*", "GPUParticles3D", true, false):
		(n as GPUParticles3D).emitting = false
		(n as GPUParticles3D).visible = false
	await create_timer(4.0).timeout
	await _gallery()
