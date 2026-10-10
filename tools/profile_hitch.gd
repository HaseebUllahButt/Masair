extends SceneTree
## Like profile_streaming but enables road_chunk.hitch_trace and records a
## wall-clock timeline of every frame over 20 ms, so remaining CPU lumps point
## at a build stage, not just a percentile.
##
##   godot --headless --path . --script res://tools/profile_hitch.gd

const RoadChunkGD: GDScript = preload("res://scripts/road_chunk.gd")
const WARMUP_SECONDS := 3.0
const SAMPLE_SECONDS := 30.0


func _initialize() -> void:
	RoadChunkGD.set("hitch_trace", true)
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	var runner := Runner.new()
	runner.tree_ref = self
	root.add_child(runner)


class Runner:
	extends Node

	var tree_ref: SceneTree
	var elapsed := 0.0
	var frames: Array[float] = []
	var _last_usec := 0

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		var path := get_tree().root.get_node("RoadPath")
		path.call("set_world_seed", 72117)
		var streamer := get_tree().root.find_child("RoadStreamer", true, false)
		streamer.call("reset_world")
		var hud := get_tree().root.find_child("HUD", true, false)
		if hud and hud.has_method("_start_ride"):
			hud.call("_start_ride")
		var player := get_tree().root.find_child("Player", true, false)
		player.set("_invuln", WARMUP_SECONDS + SAMPLE_SECONDS + 5.0)
		Input.action_press("throttle")
		_last_usec = Time.get_ticks_usec()

	func _process(delta: float) -> void:
		var now := Time.get_ticks_usec()
		var wall := float(now - _last_usec) / 1000.0
		_last_usec = now
		elapsed += delta
		if elapsed >= WARMUP_SECONDS:
			frames.append(wall)
			if wall > 20.0:
				var streamer := get_tree().root.find_child("RoadStreamer", true, false)
				print(
					"  frame %.1f ms at t=%.1f (queues: ribbon=%d props=%d scenic=%d highway=%d unload=%d)"
					% [
						wall,
						elapsed,
						(streamer.get("_ribbon_queue") as Array).size(),
						(streamer.get("_props_queue") as Array).size(),
						(streamer.get("_scenic_queue") as Array).size(),
						(streamer.get("_highway_queue") as Array).size(),
						(streamer.get("_unload_queue") as Array).size(),
					]
				)
		if elapsed < WARMUP_SECONDS + SAMPLE_SECONDS:
			return
		Input.action_release("throttle")
		frames.sort()
		var total := 0.0
		var hitches := 0
		var slow_frames := 0
		for frame in frames:
			total += frame / 1000.0
			if frame > 33.0:
				hitches += 1
			if frame > 20.0:
				slow_frames += 1
		var p95 := frames[mini(floori(float(frames.size() - 1) * 0.95), frames.size() - 1)]
		var p99 := frames[mini(floori(float(frames.size() - 1) * 0.99), frames.size() - 1)]
		print(
			"hitch perf: %.1f fps avg, %.2f ms p95, %.2f ms p99, %.2f ms worst, %d frames over 33 ms, %d over 20 ms"
			% [
				float(frames.size()) / total,
				p95,
				p99,
				frames[-1],
				hitches,
				slow_frames,
			]
		)
		tree_ref.quit(0)
