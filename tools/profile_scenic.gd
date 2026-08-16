extends SceneTree
## Live scenic-route hitch benchmark. Requires a display.
##
##   godot --path . --script res://tools/profile_scenic.gd

const RIDE_SECONDS := 32.0
const PARK_SECONDS := 12.0


func _initialize() -> void:
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	var runner := Runner.new()
	runner.tree_ref = self
	root.add_child(runner)


class Runner:
	extends Node

	var tree_ref: SceneTree
	var elapsed := 0.0
	var parked := false
	var ride_frames: Array[float] = []
	var approach_frames: Array[float] = []
	var lake_frames: Array[float] = []
	var park_frames: Array[float] = []
	var settled_frames: Array[float] = []
	var player: Node
	var path: Node
	var streamer: Node
	var viewpoint := 0.0
	var side := 1.0
	var missing_road_frames := 0

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		path = get_tree().root.get_node("RoadPath")
		path.call("set_world_seed", 72117)
		streamer = get_tree().root.find_child("RoadStreamer", true, false)
		player = get_tree().root.find_child("Player", true, false)
		var hud := get_tree().root.find_child("HUD", true, false)
		if hud and hud.has_method("_start_ride"):
			hud.call("_start_ride")
		viewpoint = float(path.call("viewpoint_centre_for", 2800.0))
		side = float(path.call("viewpoint_side_for", viewpoint))
		# Start well inside the committed spur, before lake chunks enter the normal
		# riding ring, then ride through their incremental construction.
		player.track_z = viewpoint - 1320.0
		player.lateral = side * float(path.call("spur_offset", player.track_z))
		player.set("_committed_to_spur", true)
		player.speed = player.top_speed
		player.set("_invuln", RIDE_SECONDS + PARK_SECONDS + 10.0)
		player.call("_place")
		player.reset_physics_interpolation()
		streamer.call("reset_world")
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Input.action_press("throttle")

	func _process(delta: float) -> void:
		elapsed += delta
		if not parked:
			ride_frames.append(delta)
			var current_index := floori(float(player.track_z) / 40.0)
			var current_chunk: Node = (streamer.get("_chunks") as Dictionary).get(current_index)
			if current_chunk == null or current_chunk.get_node_or_null("RoadSurface") == null:
				missing_road_frames += 1
			if elapsed < 16.0:
				approach_frames.append(delta)
			else:
				lake_frames.append(delta)
			if elapsed < RIDE_SECONDS:
				return
			parked = true
			Input.action_release("throttle")
			player.track_z = viewpoint
			player.lateral = side * float(path.call("spur_offset", viewpoint))
			player.speed = 0.0
			player.lat_vel = 0.0
			player.call("_place")
			player.reset_physics_interpolation()
		else:
			park_frames.append(delta)
			if elapsed >= RIDE_SECONDS + 8.0:
				settled_frames.append(delta)
			if elapsed < RIDE_SECONDS + PARK_SECONDS:
				return
			_report("scenic ride", ride_frames)
			_report("scenic approach", approach_frames)
			_report("scenic lake ride", lake_frames)
			_report("scenic parked", park_frames)
			_report("scenic parked settled", settled_frames)
			_validate_scenery()
			print("scenic validation: %d ride frames missing RoadSurface" % missing_road_frames)
			tree_ref.quit(0)

	func _report(label: String, frames: Array[float]) -> void:
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
		for chunk in (streamer.get("_chunks") as Dictionary).values():
			if not is_instance_valid(chunk):
				continue
			if chunk.get_node_or_null("RoadSurface") != null:
				road_chunks += 1
			for child in chunk.get_children():
				if child is MultiMeshInstance3D:
					var mm := (child as MultiMeshInstance3D).multimesh
					if mm and mm.instance_count > 0:
						scenic_instances += mm.instance_count
		print("scenic validation: %d road chunks, %d multimesh instances" % [road_chunks, scenic_instances])
