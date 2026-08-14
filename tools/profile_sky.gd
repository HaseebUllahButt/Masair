extends SceneTree
## Measure how much the realtime sky radiance actually costs on this GPU.
##
##   godot --path . --script res://tools/profile_sky.gd
##
## Boots the real scene and rides it once per sky configuration, alternating
## A/B/A/B so scenery streaming does not confound the measurement.

const WARMUP := 4.0
const SAMPLE := 4.0


func _initialize() -> void:
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	var runner := Runner.new()
	runner.tree_ref = self
	root.add_child(runner)


class Runner:
	extends Node

	var tree_ref: SceneTree

	var _sky: Sky
	var _cases: Array = []
	var _case: int = -1
	var _t := 0.0
	var _frames := 0

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
		Input.action_press("throttle")
		var hud := get_tree().root.find_child("HUD", true, false)
		if hud and hud.has_method("_start_ride"):
			hud.call("_start_ride")
		var world_env := get_tree().root.find_child("WorldEnvironment", true, false) as WorldEnvironment
		_sky = world_env.environment.sky
		_cases = [
			["realtime", Sky.PROCESS_MODE_REALTIME],
			["incremental", Sky.PROCESS_MODE_INCREMENTAL],
			["realtime", Sky.PROCESS_MODE_REALTIME],
			["incremental", Sky.PROCESS_MODE_INCREMENTAL],
		]

	func _process(delta: float) -> void:
		_t += delta
		if _case < 0:
			if _t < WARMUP:
				return
			_advance()
			return
		_frames += 1
		if _t < SAMPLE:
			return
		print(
			"%-12s %6.1f fps   %5.2f ms gpu"
			% [
				_cases[_case][0],
				float(_frames) / _t,
				RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid()),
			]
		)
		_advance()

	func _advance() -> void:
		_case += 1
		_t = 0.0
		_frames = 0
		if _case >= _cases.size():
			tree_ref.quit(0)
			return
		_sky.process_mode = _cases[_case][1]
