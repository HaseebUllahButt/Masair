extends SceneTree
## Repeatable live hitch benchmark for road streaming and traffic.
##
##   godot --path . --script res://tools/profile_streaming.gd

const WARMUP_SECONDS := 3.0
const SAMPLE_SECONDS := 20.0


func _initialize() -> void:
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

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		var hud := get_tree().root.find_child("HUD", true, false)
		if hud and hud.has_method("_start_ride"):
			hud.call("_start_ride")
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Input.action_press("throttle")

	func _process(delta: float) -> void:
		elapsed += delta
		if elapsed >= WARMUP_SECONDS:
			frames.append(delta)
		if elapsed < WARMUP_SECONDS + SAMPLE_SECONDS:
			return
		Input.action_release("throttle")
		frames.sort()
		var total := 0.0
		var hitches := 0
		for frame in frames:
			total += frame
			if frame > 0.033:
				hitches += 1
		var p99_index := mini(floori(float(frames.size() - 1) * 0.99), frames.size() - 1)
		print(
			"streaming perf: %.1f fps avg, %.1f ms p99, %.1f ms worst, %d frames over 33 ms"
			% [float(frames.size()) / total, frames[p99_index] * 1000.0, frames[-1] * 1000.0, hitches]
		)
		tree_ref.quit(0)
