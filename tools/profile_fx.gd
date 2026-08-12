extends SceneTree
## Dev tool: per-effect frame cost, measured in the running game.
##
##   godot --path . --script res://tools/profile_fx.gd
##
## Boots the real scene, then rides it once per configuration, toggling a single
## effect each time. Guessing which post-process is expensive on an integrated
## GPU is how a stylised game quietly ends up at 30 fps, so measure instead.

const WARMUP := 3.0
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

	var _env: Environment
	var _cases: Array = []
	var _case: int = -1
	var _t := 0.0
	var _frames := 0

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		# GPU milliseconds, not fps: a compositor that paces the swapchain pins fps
		# at the refresh rate and hides every cost being measured here.
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
		Input.action_press("throttle")
		var world_env := get_tree().root.find_child("WorldEnvironment", true, false) as WorldEnvironment
		_env = world_env.environment
		var hud := get_tree().root.find_child("HUD", true, false)
		if hud and hud.has_method("_start_ride"):
			hud.call("_start_ride")
		# Alternating A/B/A/B: a single ordered sweep confounds each effect's cost
		# with whatever scenery happens to be on screen at that point in the ride.
		_cases = [
			["SSR + glow", func() -> void: _env.ssr_enabled = true; _env.glow_enabled = true],
			["no SSR", func() -> void: _env.ssr_enabled = false; _env.glow_enabled = true],
			["no SSR or glow", func() -> void: _env.ssr_enabled = false; _env.glow_enabled = false],
			["SSR + glow", func() -> void: _env.ssr_enabled = true; _env.glow_enabled = true],
			["no SSR", func() -> void: _env.ssr_enabled = false; _env.glow_enabled = true],
			["no SSR or glow", func() -> void: _env.ssr_enabled = false; _env.glow_enabled = false],
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
			"%-28s %6.1f fps   %5.2f ms gpu"
			% [
				_cases[_case][0],
				float(_frames) / _t,
				RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid()),
			]
		)
		_advance()

	func _sky_off() -> void:
		_env.background_mode = Environment.BG_COLOR
		_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR

	func _sun() -> DirectionalLight3D:
		return get_tree().root.find_child("Sun", true, false) as DirectionalLight3D

	func _fill_light() -> DirectionalLight3D:
		return get_tree().root.find_child("Fill", true, false) as DirectionalLight3D

	func _advance() -> void:
		_case += 1
		_t = 0.0
		_frames = 0
		if _case >= _cases.size():
			tree_ref.quit(0)
			return
		(_cases[_case][1] as Callable).call()
