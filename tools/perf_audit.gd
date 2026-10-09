extends SceneTree
## One-shot perf ablation: park or ride, optionally hide render families or
## toggle environment features, then report fps/gpu/cpu and draw stats.
##
##   gamescope -W 1920 -H 1080 --backend headless -- \
##       godot --path . --audio-driver Dummy --disable-vsync \
##       --script res://tools/perf_audit.gd -- \
##       --park=viewpoint --seated --seed=2 --hide=ViewpointLake,HorizonMountains \
##       --env=glow_enabled=0 --sample=6 --warmup=18
##
## Unlike screenshot.gd's --hide (which hides at shutter time), this hides
## before measuring, so the gpu figure is the ablated steady state.

const RoadPathGD: GDScript = preload("res://scripts/road_path.gd")


func _initialize() -> void:
	var opts := _parse_args()
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	var audit := Audit.new()
	audit.opts = opts
	audit.tree_ref = self
	root.add_child(audit)


func _parse_args() -> Dictionary:
	var out := {}
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=", true, 1)
		if kv.size() == 2:
			out[kv[0]] = kv[1]
		elif kv.size() == 1 and kv[0] != "":
			out[kv[0]] = "1"
	return out


class Audit:
	extends Node

	var opts: Dictionary = {}
	var tree_ref: SceneTree

	var _t := 0.0
	var _warmup := 18.0
	var _sample := 6.0
	var _frames := 0
	var _worst := 0.0
	var _slow33 := 0
	var _slow100 := 0
	var _frame_times: Array[float] = []
	var _gpu_sum := 0.0
	var _cpu_sum := 0.0
	var _gpu_n := 0
	var _dc := 0
	var _prim := 0
	var _rid: RID

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		_rid = get_viewport().get_viewport_rid()
		RenderingServer.viewport_set_measure_render_time(_rid, true)
		_warmup = float(opts.get("warmup", 18.0))
		_sample = float(opts.get("sample", 6.0))
		var hud := get_tree().root.find_child("HUD", true, false)
		if hud and hud.has_method("_start_ride"):
			hud.call("_start_ride")
		var seed := int(opts.get("seed", 72117))
		var path := get_tree().root.get_node("RoadPath")
		path.call("set_world_seed", seed)
		var player := get_tree().root.find_child("Player", true, false)
		var streamer := get_tree().root.find_child("RoadStreamer", true, false)
		var park := String(opts.get("park", "ride"))
		match park:
			"viewpoint":
				var centre: float = path.call("viewpoint_centre_for", 2800.0)
				var side: float = path.call("viewpoint_side_for", centre)
				player.track_z = centre
				var apron: float = float(path.get("PLATFORM_HALF_WIDTH"))
				player.lateral = side * (float(path.call("spur_offset", centre)) + apron - 3.5)
				player.speed = 0.0
				player.lat_vel = 0.0
				player.set("_committed_to_spur", true)
				player.call("_place")
				if opts.has("seated"):
					player.set("seated", true)
					player.set("_seat_yaw", deg_to_rad(float(opts.get("yaw", 0.0))))
					player.set("_seat_pitch", deg_to_rad(float(opts.get("pitch", 0.0))))
			"road":
				player.track_z = float(opts.get("z", 1600.0))
				player.lateral = 0.0
				player.speed = 0.0
				player.lat_vel = 0.0
				player.call("_place")
			_:
				Input.action_press("throttle")
		if streamer and streamer.has_method("reset_world"):
			streamer.call("reset_world")
		# Environment toggles: --env=glow_enabled=0,fog_enabled=0,adjustment_enabled=0
		if opts.has("env"):
			var world_env := get_tree().root.find_child("WorldEnvironment", true, false) as WorldEnvironment
			var env := world_env.environment
			for pair in String(opts["env"]).split(","):
				var kv := pair.split("=", true, 1)
				if kv.size() == 2:
					env.set(kv[0], kv[1] == "1" or kv[1] == "true")
		# Hide render families before the sample window opens.
		if opts.has("hide"):
			for node_name in String(opts["hide"]).split(","):
				var n := 0
				for node in get_tree().root.find_children(node_name.strip_edges(), "Node3D", true, false):
					(node as Node3D).visible = false
					n += 1
				for node in get_tree().root.find_children(node_name.strip_edges(), "CanvasItem", true, false):
					(node as CanvasItem).visible = false
					n += 1
				print("hide %s: %d nodes" % [node_name, n])
		if opts.has("nomusic"):
			var music := get_tree().root.get_node_or_null("MusicPlayer")
			if music:
				music.set("music_folder", "")
				music.set("_want_playing", false)
		if opts.has("notraffic"):
			var traffic := get_tree().root.find_child("TrafficManager", true, false)
			if traffic:
				traffic.set("max_active", 0)
				traffic.call("reset_world")

	func _process(delta: float) -> void:
		_t += delta
		if _t < _warmup:
			return
		_frames += 1
		_frame_times.append(delta)
		_worst = maxf(_worst, delta)
		if delta > 0.033:
			_slow33 += 1
		if delta > 0.100:
			_slow100 += 1
		_gpu_sum += RenderingServer.viewport_get_measured_render_time_gpu(_rid)
		_cpu_sum += RenderingServer.viewport_get_measured_render_time_cpu(_rid)
		_gpu_n += 1
		_dc = maxi(_dc, int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)))
		_prim = maxi(_prim, int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)))
		if _t < _warmup + _sample:
			return
		_frame_times.sort()
		var p95 := _frame_times[mini(floori((_frame_times.size() - 1) * 0.95), _frame_times.size() - 1)] * 1000.0
		var p99 := _frame_times[mini(floori((_frame_times.size() - 1) * 0.99), _frame_times.size() - 1)] * 1000.0
		var tag := String(opts.get("tag", "audit"))
		print(
			"audit[%s]: %.1f fps, p95 %.1f ms, p99 %.1f ms, worst %.1f ms, >33ms %d, >100ms %d, gpu %.2f ms, cpu %.2f ms, draw_calls<=%d, prims<=%d"
			% [
				tag,
				float(_frames) / _sample,
				p95,
				p99,
				_worst * 1000.0,
				_slow33,
				_slow100,
				_gpu_sum / maxi(_gpu_n, 1),
				_cpu_sum / maxi(_gpu_n, 1),
				_dc,
				_prim,
			]
		)
		tree_ref.quit(0)
