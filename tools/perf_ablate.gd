extends SceneTree
## Same-process A/B ablation of render families, parked or riding.
##
##   gamescope -W 1920 -H 1080 --backend headless -- \
##       godot --path . --audio-driver Dummy --disable-vsync \
##       --script res://tools/perf_ablate.gd -- --park=viewpoint --seated --seed=2
##
## One boot, then per family: OFF for `sample` seconds, ON for `sample` seconds,
## OFF again. gpu ms per window is printed; the family's cost is the median
## difference between adjacent windows — machine load confounds a single run,
## not an interleaved A/B/A inside one process.

const RoadPathGD: GDScript = preload("res://scripts/road_path.gd")


func _initialize() -> void:
	var opts := {}
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
		elif kv.size() == 1 and kv[0] != "":
			opts[kv[0]] = "1"
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	var r := Runner.new()
	r.opts = opts
	r.tree_ref = self
	root.add_child(r)


class Runner:
	extends Node

	var opts: Dictionary = {}
	var tree_ref: SceneTree

	var _t := 0.0
	var _warmup := 18.0
	var _sample := 3.5
	var _phase := -1
	var _frames := 0
	var _gpu_sum := 0.0
	var _cpu_sum := 0.0
	var _rid: RID
	var _env: Environment
	var _player: Node
	var _path: Node
	var _sky: Sky
	## Named groups of nodes, found once at setup and toggled per phase.
	var _groups := {}
	var _phases: Array = []
	var _applied: Dictionary = {}

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		_rid = get_viewport().get_viewport_rid()
		RenderingServer.viewport_set_measure_render_time(_rid, true)
		_warmup = float(opts.get("warmup", 18.0))
		_sample = float(opts.get("sample", 3.5))
		var hud := get_tree().root.find_child("HUD", true, false)
		if hud and hud.has_method("_start_ride"):
			hud.call("_start_ride")
		_path = get_tree().root.get_node("RoadPath")
		_path.call("set_world_seed", int(opts.get("seed", 2)))
		_player = get_tree().root.find_child("Player", true, false)
		var streamer := get_tree().root.find_child("RoadStreamer", true, false)
		var park := String(opts.get("park", "ride"))
		match park:
			"viewpoint":
				var centre: float = _path.call("viewpoint_centre_for", 2800.0)
				var side: float = _path.call("viewpoint_side_for", centre)
				_player.track_z = centre
				var apron: float = float(_path.get("PLATFORM_HALF_WIDTH"))
				_player.lateral = side * (float(_path.call("spur_offset", centre)) + apron - 3.5)
				_player.speed = 0.0
				_player.lat_vel = 0.0
				_player.set("_committed_to_spur", true)
				_player.call("_place")
				if opts.has("seated"):
					_player.set("seated", true)
					_player.set("_seat_yaw", deg_to_rad(float(opts.get("yaw", 0.0))))
			"road":
				_player.track_z = float(opts.get("z", 1600.0))
				_player.lateral = 0.0
				_player.speed = 0.0
				_player.lat_vel = 0.0
				_player.call("_place")
			_:
				Input.action_press("throttle")
		if streamer and streamer.has_method("reset_world"):
			streamer.call("reset_world")
		var world_env := get_tree().root.find_child("WorldEnvironment", true, false) as WorldEnvironment
		_env = world_env.environment
		_sky = _env.sky
		_collect_groups()
		_build_phases()

	func _collect_groups() -> void:
		## Family -> node names (any match hidden together).
		var want := {
			"lake": ["ViewpointLake"],
			"range": ["ViewpointRange"],
			"farground": ["ViewpointFarGround"],
			"cliffs+headland": ["ViewpointCliffs", "ViewpointHeadland"],
			"horizonring": ["HorizonMountains"],
			"foliage": ["Foliage", "Crowns", "Conifers", "Trunks", "Grass"],
			"props": ["Cubes", "Rocks", "FaceLedges", "Lamps"],
			"lookoutlife": ["LookoutLife"],
			"ridelife": ["RideLife"],
			"grade": ["GradeRect"],
			"traffic": ["TrafficManager"],
			"bikevisual": ["Visual"],
			"pollen": ["Pollen"],
		}
		for family in want:
			var nodes: Array[Node] = []
			for node_name in want[family]:
				for node in get_tree().root.find_children(node_name, "Node", true, false):
					nodes.append(node)
			_groups[family] = nodes

	func _build_phases() -> void:
		# baseline marker first so the first off-window has an adjacent on-window
		_phases = [
			["on", {}],
			["lake", {"lake": false}],
			["on", {}],
			["range", {"range": false}],
			["on", {}],
			["farground", {"farground": false}],
			["on", {}],
			["cliffs+headland", {"cliffs+headland": false}],
			["on", {}],
			["horizonring", {"horizonring": false}],
			["on", {}],
			["foliage", {"foliage": false}],
			["on", {}],
			["props", {"props": false}],
			["on", {}],
			["lookoutlife", {"lookoutlife": false}],
			["on", {}],
			["glow", {"env:glow_enabled": false}],
			["on", {}],
			["fog", {"env:fog_enabled": false}],
			["on", {}],
			["adjust", {"env:adjustment_enabled": false}],
			["on", {}],
			["grade", {"grade": false}],
			["on", {}],
			["post", {"env:glow_enabled": false, "env:adjustment_enabled": false, "env:fog_enabled": false, "grade": false}],
			["on", {}],
			["nosky", {"sky": false}],
			["on", {}],
			["pollen", {"pollen": false}],
			["on", {}],
		]

	func _apply(spec: Dictionary) -> void:
		for key in _applied:
			if not spec.has(key):
				_set_flag(key, true)
				_applied.erase(key)
		for key in spec:
			if _applied.get(key) != spec[key]:
				_set_flag(key, spec[key])
				_applied[key] = spec[key]

	func _set_flag(key: String, on: Variant) -> void:
		if key == "sky":
			if on:
				_env.background_mode = Environment.BG_SKY
			else:
				_env.background_mode = Environment.BG_COLOR
			return
		if key.begins_with("env:"):
			_env.set(key.trim_prefix("env:"), on)
			return
		for node in _groups.get(key, []):
			if is_instance_valid(node):
				if node is Node3D:
					(node as Node3D).visible = on
				elif node is CanvasItem:
					(node as CanvasItem).visible = on

	func _process(delta: float) -> void:
		if _phase < 0:
			_t += delta
			if _t < _warmup:
				return
			_phase = 0
			_apply(_phases[0][1])
			_t = 0.0
			return
		_t += delta
		_frames += 1
		_gpu_sum += RenderingServer.viewport_get_measured_render_time_gpu(_rid)
		_cpu_sum += RenderingServer.viewport_get_measured_render_time_cpu(_rid)
		if _t < _sample:
			return
		var label: String = "warmup"
		if _phase >= 0:
			label = "all-on" if _phases[_phase][0] == "on" else String(_phases[_phase][0])
		print(
			"ablate %-16s %6.1f fps   %5.2f ms gpu   %5.2f ms cpu"
			% [
				label,
				float(_frames) / _t,
				_gpu_sum / maxi(_frames, 1),
				_cpu_sum / maxi(_frames, 1),
			]
		)
		_t = 0.0
		_frames = 0
		_gpu_sum = 0.0
		_cpu_sum = 0.0
		_phase += 1
		if _phase >= _phases.size():
			tree_ref.quit(0)
			return
		_apply(_phases[_phase][1])
