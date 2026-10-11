extends SceneTree
## Drive-along traffic probe: boots the real game, rides a lane-hold autopilot
## through live traffic, and reports what the stream did — following gaps,
## braking, lane changes, oncoming passes, overlaps and pop events.
##
##   godot --headless --path . --script res://tools/probe_traffic.gd -- --seed=72117 --secs=90
##   --difficulty=1 --speed=110 --lane=0 --startz=900

var _runner: Node


func _initialize() -> void:
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	var runner := Runner.new()
	runner.tree_ref = self
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=", true, 1)
		if kv.size() == 2:
			match kv[0]:
				"seed": runner.seed = int(kv[1])
				"secs": runner.run_secs = float(kv[1])
				"difficulty": runner.difficulty = int(kv[1])
				"speed": runner.speed_kmh = float(kv[1])
				"lane": runner.hold_lane = float(kv[1])
				"startz": runner.start_z = float(kv[1])
	root.add_child(runner)


class Runner:
	extends Node

	var tree_ref: SceneTree
	var seed := 72117
	var run_secs := 90.0
	var difficulty := 1
	var speed_kmh := 110.0
	var hold_lane := 0.0
	var start_z := -1.0

	var _player: Node3D
	var _path: Node
	var _traffic: Node
	var _t := 0.0
	var _next_sample := 0.0
	var _samples := 0
	var _last_dz: Dictionary = {}
	var _min_gap := INF
	var _min_oncoming_gap := INF
	var _brake_car_seconds := 0.0
	var _indicating := 0
	var _lane_changes := 0
	var _oncoming_passes := 0
	var _min_pass_lateral := INF
	var _overlap_seconds := 0.0
	var _close_spawns := 0
	var _visible_despawns := 0
	var _fwd_peak := 0
	var _onc_peak := 0
	var _speed_min := INF
	var _speed_max := 0.0
	var _braking_now := false

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		_path = get_tree().root.get_node("RoadPath")
		_path.call("set_world_seed", seed)
		var streamer := get_tree().root.find_child("RoadStreamer", true, false)
		if streamer and streamer.has_method("reset_world"):
			streamer.call("reset_world")
		var hud := get_tree().root.find_child("HUD", true, false)
		if hud and hud.has_method("_start_ride"):
			hud.call("_start_ride")
		_traffic = get_tree().root.find_child("TrafficManager", true, false)
		if _traffic and difficulty >= 0:
			_traffic.call("set_difficulty", difficulty)
		_player = get_tree().root.find_child("Player", true, false)
		_player.set("_invuln", 1e9)
		if start_z >= 0.0:
			_player.track_z = start_z
			_player.call("_place")
			if streamer and streamer.has_method("reset_world"):
				streamer.call("reset_world")
			if _traffic:
				_traffic.call("reset_world")
		Input.action_press("throttle")

	func _process(delta: float) -> void:
		_t += delta
		_autopilot()
		_next_sample -= delta
		if _next_sample <= 0.0:
			_next_sample = 0.5
			_sample(0.5)
		if _t >= run_secs:
			_report()
			tree_ref.quit(0)

	func _autopilot() -> void:
		## Hold a painted lane the way the detour autopilot holds the spur: same
		## inputs a player gives, nothing teleported.
		if _player == null:
			return
		var error: float = hold_lane - float(_player.lateral)
		if speed_kmh > 0.0:
			if float(_player.speed) * 3.6 > speed_kmh:
				Input.action_release("throttle")
			else:
				Input.action_press("throttle")
		Input.action_release("steer_left")
		Input.action_release("steer_right")
		if absf(error) > 0.25 and absf(float(_player.lat_vel)) < absf(error) * 1.2:
			Input.action_press("steer_left" if error > 0.0 else "steer_right")

	func _sample(step: float) -> void:
		_samples += 1
		var pz: float = _player.track_z
		var fwd := 0
		var onc := 0
		var braking := 0
		var indicating := 0
		var lane_changing := 0
		var cars: Array = []
		var seen_now: Dictionary = {}
		for other in get_tree().get_nodes_in_group("traffic"):
			var v := other as Node3D
			if v == null or not ("track_z" in v):
				continue
			cars.append(v)
			var dir := 1
			if "direction" in v:
				dir = int(v.direction)
			var dz: float = float(v.track_z) - pz
			seen_now[v] = dz
			if dir < 0:
				onc += 1
				# A crossing sign change on an oncoming car is a pass.
				if _last_dz.has(v) and float(_last_dz[v]) > 0.0 and dz <= 0.0:
					_oncoming_passes += 1
					_min_pass_lateral = minf(_min_pass_lateral, absf(float(v.lateral) - float(_player.lateral)))
			else:
				fwd += 1
			if v.get("_brake_lamps") != null and (v.get("_brake_lamps") as MeshInstance3D).visible:
				braking += 1
			var blinkers = v.get("_blinkers")
			if blinkers != null:
				for b in blinkers:
					if (b as MeshInstance3D).visible:
						indicating += 1
						break
			if "direction" in v and bool(v.get("_lane_change_active")):
				lane_changing += 1
			_speed_min = minf(_speed_min, float(v.speed))
			_speed_max = maxf(_speed_max, float(v.speed))
		_brake_car_seconds += braking * step
		_indicating = maxi(_indicating, indicating)
		_lane_changes = maxi(_lane_changes, lane_changing)
		_fwd_peak = maxi(_fwd_peak, fwd)
		_onc_peak = maxi(_onc_peak, onc)

		# Tightest same-direction following gap anywhere on the road.
		var by_lane := {}
		var overlapped := false
		for a in cars:
			var dir_a := 1 if not ("direction" in a) else int(a.direction)
			var key := "%d:%d" % [dir_a, int(a.lane)]
			if not by_lane.has(key):
				by_lane[key] = []
			by_lane[key].append(a)
			for b in cars:
				if b == a:
					continue
				var dir_b := 1 if not ("direction" in b) else int(b.direction)
				if dir_a != dir_b:
					continue
				var dz: float = absf(float(b.track_z) - float(a.track_z))
				var dl: float = absf(float(b.lateral) - float(a.lateral))
				var hl: float = float(a.get_half_length()) + float(b.get_half_length())
				var hw: float = float(a.get_half_width()) + float(b.get_half_width())
				if dz < hl * 0.85 and dl < hw * 0.85:
					overlapped = true
		if overlapped:
			_overlap_seconds += step
		for key in by_lane:
			var row: Array = by_lane[key]
			row.sort_custom(func(a, b): return float(a.track_z) < float(b.track_z))
			var dir_key: int = int(String(key).split(":")[0])
			for i in row.size() - 1:
				var a: Node3D = row[i]
				var b: Node3D = row[i + 1]
				var gap: float = absf(float(b.track_z) - float(a.track_z)) \
					- float(a.get_half_length()) - float(b.get_half_length())
				if dir_key < 0:
					_min_oncoming_gap = minf(_min_oncoming_gap, gap)
				else:
					_min_gap = minf(_min_gap, gap)

		# Pop accounting: a car appearing inside 260 m of the rider is a spawn
		# that can be seen arriving; one vanishing inside 320 m is a despawn pop.
		for v in seen_now:
			if not _last_dz.has(v) and absf(float(seen_now[v])) < 260.0:
				_close_spawns += 1
		for v in _last_dz:
			if not seen_now.has(v):
				# Only a vanish AHEAD of the rider can be seen; cars dropped 45 m
				# behind (the despawn line) are already out of the rider's view.
				if is_instance_valid(v) or not (float(_last_dz[v]) > 0.0 and float(_last_dz[v]) < 320.0):
					continue
				_visible_despawns += 1
		_last_dz = seen_now
		if _samples % 20 == 0:
			print(
				"t=%.0f z=%.0f v=%.0fkm/h | fwd=%d onc=%d braking=%d indicating=%d | minGap=%.1f"
				% [_t, pz, float(_player.speed) * 3.6, fwd, onc, braking, indicating, _min_gap]
			)

	func _report() -> void:
		Input.action_release("throttle")
		print("traffic probe, seed %d, %.0f s ridden to z=%.0f" % [seed, _t, float(_player.track_z)])
		print("  forward peak %d cars, oncoming peak %d" % [_fwd_peak, _onc_peak])
		print("  oncoming passes: %d, closest lateral %.2f m" % [_oncoming_passes, _min_pass_lateral])
		print("  tightest forward gap: %.1f m, oncoming queue gap: %.1f m" % [_min_gap, _min_oncoming_gap])
		print("  cruise speeds seen: %.1f-%.1f m/s (%.0f-%.0f km/h)" % [_speed_min, _speed_max, _speed_min * 3.6, _speed_max * 3.6])
		print("  brake-seconds lit: %.0f, simultaneous lane changes peak: %d, indicators peak: %d" % [_brake_car_seconds, _lane_changes, _indicating])
		print("  overlaps: %.1f s, close spawns (<260 m): %d, in-view despawns (<320 m): %d" % [_overlap_seconds, _close_spawns, _visible_despawns])
