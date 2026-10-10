extends SceneTree
## Dressing-lag probe: rides the spur at a fixed speed and reports, for every
## station, whether the chunks the rider is looking at have their liner planted
## (`stub_done`) and filled (`scenic_done`). A rider-facing chunk without its
## stub is a bare stretch on screen.
##
##   godot --headless --path . --script res://tools/probe_ride.gd -- --seed=1 --speed=11.5
##
## --speed is m/s (the screenshot detour rides ~11.5). --startz, --endz bound the
## sampled stretch; default covers junction to platform.

const STATION_EVERY := 100.0

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
				"speed": runner.speed = float(kv[1])
				"startz": runner.start_z = float(kv[1])
				"endz": runner.end_z = float(kv[1])
	root.add_child(runner)


class Runner:
	extends Node

	var tree_ref: SceneTree
	var seed := 1
	var speed := 11.5
	var start_z := 1250.0
	var end_z := 2950.0
	var _path: Node
	var _streamer: Node
	var _player: Node3D
	var _next_station := 0.0
	var _t := 0.0
	var _worst_gap := -99

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		_path = get_tree().root.get_node("RoadPath")
		_path.call("set_world_seed", seed)
		_streamer = get_tree().root.find_child("RoadStreamer", true, false)
		_streamer.call("reset_world")
		var hud := get_tree().root.find_child("HUD", true, false)
		if hud and hud.has_method("_start_ride"):
			hud.call("_start_ride")
		_player = get_tree().root.find_child("Player", true, false)
		_player.set("_invuln", 1e6)
		_player.set("speed", speed)
		_next_station = start_z

	func _process(delta: float) -> void:
		_t += delta
		if _t < 6.0:
			# Opening chunks build synchronously around the spawn; skip ahead
			# once so the ride itself is what gets measured.
			if _t > 5.8:
				_player.set("track_z", start_z)
			return
		var z: float = float(_player.get("track_z")) + speed * delta
		var span: Vector2 = _path.call("spur_interval", z)
		if span != Vector2.ZERO:
			_player.set("lateral", (span.x + span.y) * 0.5)
		_player.set("track_z", z)
		_player.set("speed", speed)
		if z >= end_z:
			print("PROBE DONE worst_liner_gap=%d chunks" % _worst_gap)
			tree_ref.quit(0)
			return
		if z < _next_station:
			return
		_next_station += STATION_EVERY
		var current := int(floor(z / 40.0))
		var report := []
		for i in range(current, current + 8):
			var chunk: Node = _streamer.get("_chunks").get(i)
			if chunk == null:
				report.append("%d:absent" % i)
				continue
			var ribbon := bool(chunk.get_meta("ribbon_ready", false)) or chunk.get_node_or_null("RoadSurface") != null
			var stub := bool(chunk.get_meta("stub_done", false))
			var scenic := bool(chunk.get_meta("scenic_done", false))
			var props := bool(chunk.get_meta("props_done", false))
			var trunks := (chunk.get("_trunks") as Array).size() + (chunk.get("_conifers") as Array).size()
			report.append("%d:%s%s%s%s t=%d" % [
				i,
				"R" if ribbon else "-",
				"S" if stub else "-",
				"P" if props else "-",
				"C" if scenic else "-",
				trunks,
			])
		# Distance from the rider to the nearest ahead chunk missing its liner.
		var ahead_bare := -1
		for i in range(current, current + 8):
			var chunk: Node = _streamer.get("_chunks").get(i)
			if chunk == null or not bool(chunk.get_meta("stub_done", false)):
				ahead_bare = i - current
				break
		_worst_gap = maxi(_worst_gap, ahead_bare)
		print("z=%.0f lat=%.0f | %s | first_bare_ahead=%d" % [z, float(_player.get("lateral")), " ".join(report), ahead_bare])
