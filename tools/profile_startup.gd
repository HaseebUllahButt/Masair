extends SceneTree
## Repeatable first-frame and steady-state cost for the real scene.
##
##   godot --path . --script res://tools/profile_startup.gd -- [--runs=N] [--frames=N]
##
## A single run is not a measurement. Two runs of this scene on an idle machine
## differed by 2x end to end, because the first two frames carry shader
## compilation and everything after them is warm. So this runs the scene N times
## in one process and reports the first run's cold frames separately from the
## warm ones, then a median with the spread that came from.
##
## Cold and warm are not the same number and must not be averaged together:
## `cold_first` is what a player waits through at launch, and the warm median is
## what the mountains cost per frame once the driver has the programs.
##
## Ablation flags hide one render family at a time, so the same N-run report can
## be attributed to a family rather than guessed at:
##
##   --no-horizon   the painted mountain ring
##   --no-road      the streamed road chunks
##   --no-bike      the player and its visual
##   --no-hud       the overlay
##   --no-world     the WorldEnvironment
##
## Compare two trees by running both with the same flags and the same --runs.
## Sub-second differences between two cold runs are noise; only the warm median
## over enough runs to show its spread is worth arguing about.

const MainScene := preload("res://scenes/main.tscn")

const DEFAULT_RUNS := 7
const DEFAULT_FRAMES := 14
## Frames at the head of a run we ignore: the first draws a freshly built
## scene, and letting it into the warm median would put scene construction
## back into the per-frame number.
const WARMUP_FRAMES := 2
## Fixed so every run walks the same road. Autoloads outlive the scene, so
## without this run 2 inherits run 1's streamed distance and builds a different
## world — which is exactly the drift that made a single run look like a
## 2x difference.
const WORLD_SEED := 72117

var _runs: int = DEFAULT_RUNS
var _frames: int = DEFAULT_FRAMES
var _hide: Dictionary = {}


func _initialize() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	RenderingServer.viewport_set_measure_render_time(get_root().get_viewport_rid(), true)

	var args := OS.get_cmdline_user_args()
	_runs = maxi(_int_arg(args, "--runs", DEFAULT_RUNS), 2)
	_frames = maxi(_int_arg(args, "--frames", DEFAULT_FRAMES), WARMUP_FRAMES + 4)
	_hide = {
		"horizon": "--no-horizon" in args,
		"road": "--no-road" in args,
		"bike": "--no-bike" in args,
		"hud": "--no-hud" in args,
		"world": "--no-world" in args,
	}
	var off: Array[String] = []
	for key in _hide:
		if _hide[key]:
			off.append(key)
	print(
		"startup: %d runs x %d frames, hidden: %s" % [_runs, _frames, ", ".join(off) if off.size() > 0 else "none"]
	)

	var runner := Runner.new()
	runner.tree_ref = self
	runner.runs = _runs
	runner.frames = _frames
	root.add_child(runner)


func reset_world() -> void:
	## Put the autoloads back to kilometre zero so every run measures the same
	## world. `RoadPath` and `GameManager` are autoloads: freeing the scene does
	## not touch them, so a second run would otherwise start wherever the first
	## one stopped streaming and the medians would be comparing two roads.
	var path := root.get_node_or_null("RoadPath")
	if path != null and path.has_method("set_world_seed"):
		path.call("set_world_seed", WORLD_SEED)
	var manager := root.get_node_or_null("GameManager")
	if manager != null and manager.has_method("restart"):
		manager.call("restart")


func apply_hide(scene: Node) -> void:
	## Diagnostic only. The flags stay off, so a report and a screenshot of the
	## same tree are the same picture.
	for key in _hide:
		if not _hide[key]:
			continue
		match key:
			"horizon":
				_hide_node(scene, "HorizonMountains")
			"road":
				_hide_node(scene, "RoadStreamer")
			"bike":
				var player := scene.get_node_or_null("Player")
				if player != null:
					_hide_node(player, "Visual")
			"hud":
				_hide_node(scene, "HUD")
			"world":
				var env := scene.get_node_or_null("WorldEnvironment") as WorldEnvironment
				if env != null:
					env.environment = null


func _hide_node(parent: Node, path: String) -> void:
	var node := parent.get_node_or_null(path)
	if node is Node3D or node is CanvasItem:
		(node as Node3D if node is Node3D else node as CanvasItem).visible = false


func _int_arg(args: PackedStringArray, name: String, fallback: int) -> int:
	for arg in args:
		if arg.begins_with(name + "="):
			return int(arg.split("=", true, 1)[1])
	return fallback


func report(records: Array[Dictionary]) -> void:
	## `records` is one entry per run: the cold first two frames and the warm
	## median that follows them.
	var cold: Array[float] = []
	var warm: Array[float] = []
	var gpu: Array[float] = []
	var instantiate: Array[float] = []
	for r in records:
		cold.append(r["cold_first"])
		warm.append(r["warm_median"])
		gpu.append(r["gpu_median"])
		instantiate.append(r["instantiate_ms"])

	## The cold number is only meaningful from the first run: by the second the
	## driver has every program and the scene no longer pays to compile.
	var cold_first: float = cold[0]
	cold.sort()
	warm.sort()
	gpu.sort()
	instantiate.sort()

	var label := "full"
	var off: Array[String] = []
	for key in _hide:
		if _hide[key]:
			off.append(str(key))
	if off.size() > 0:
		label = "-" + "+".join(off)

	print(
		(
			"startup[%s]: instantiate %.2f ms (median), cold first frame %.2f ms, warm frame %.2f ms"
			% [label, _median(instantiate), cold_first, _median(warm)]
		)
	)
	print(
		(
			"startup[%s]: warm frame spread %.2f..%.2f ms across %d warm runs, warm gpu %.2f ms"
			% [label, warm[0], warm[-1], warm.size(), _median(gpu)]
		)
	)
	# One line per run, so a median that hides a bimodal distribution cannot
	# quietly pass as a result.
	for i in records.size():
		var r: Dictionary = records[i]
		print(
			"startup[%s]:   run %d cold %.2f ms, warm %.2f ms, gpu %.2f ms, instantiate %.2f ms"
			% [label, i + 1, r["cold_first"], r["warm_median"], r["gpu_median"], r["instantiate_ms"]]
		)


func _median(sorted_values: Array[float]) -> float:
	if sorted_values.is_empty():
		return 0.0
	var mid := sorted_values.size() / 2
	if sorted_values.size() % 2 == 1:
		return sorted_values[mid]
	return (sorted_values[mid - 1] + sorted_values[mid]) * 0.5


class Runner:
	extends Node

	enum Phase { BUILD, FRAMES, SETTLE, DONE }

	var tree_ref: SceneTree
	var runs: int = 7
	var frames: int = 14

	var _phase: Phase = Phase.BUILD
	var _index: int = 0
	var _frame: int = 0
	var _scene: Node = null
	var _t0: int = 0
	var _instantiate_ms: float = 0.0
	var _cold_first: float = 0.0
	var _frame_costs: Array[float] = []
	var _gpu_costs: Array[float] = []
	var _records: Array[Dictionary] = []

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS

	func _process(_delta: float) -> void:
		match _phase:
			Phase.BUILD:
				_build()
			Phase.FRAMES:
				_frames_tick()
			Phase.SETTLE:
				_tear_down()
			Phase.DONE:
				pass

	func _build() -> void:
		tree_ref.call("reset_world")
		_t0 = Time.get_ticks_usec()
		_scene = MainScene.instantiate()
		var after_instantiate := Time.get_ticks_usec()
		root_owner().add_child(_scene)
		tree_ref.call("apply_hide", _scene)
		_instantiate_ms = float(after_instantiate - _t0) / 1000.0
		_frame = 0
		_frame_costs.clear()
		_gpu_costs.clear()
		_phase = Phase.FRAMES

	func _frames_tick() -> void:
		# The first processed frame after add_child is the one that compiles and
		# uploads, so it is sampled before anything else can land in the warm set.
		if _frame == 0:
			_cold_first = Time.get_ticks_usec() - _t0
		_frame += 1
		if _frame > WARMUP_FRAMES:
			var rid := get_viewport().get_viewport_rid()
			_frame_costs.append(
				RenderingServer.viewport_get_measured_render_time_cpu(rid) + RenderingServer.viewport_get_measured_render_time_gpu(rid)
			)
			_gpu_costs.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
		if _frame >= frames:
			_records.append(
				{
					"cold_first": float(_cold_first) / 1000.0,
					"warm_median": tree_ref.call("_median", _sorted(_frame_costs)) as float,
					"gpu_median": tree_ref.call("_median", _sorted(_gpu_costs)) as float,
					"instantiate_ms": _instantiate_ms,
				}
			)
			_phase = Phase.SETTLE

	func _tear_down() -> void:
		# Freeing and waiting a frame keeps one run's leaked render resources out
		# of the next run's numbers, which is the whole reason this repeats at all.
		if _scene != null and is_instance_valid(_scene):
			_scene.queue_free()
		_scene = null
		_index += 1
		if _index >= runs:
			_phase = Phase.DONE
			tree_ref.call("report", _records)
			tree_ref.quit(0)
			return
		_phase = Phase.BUILD

	func _sorted(values: Array[float]) -> Array[float]:
		var copy: Array[float] = values.duplicate()
		copy.sort()
		return copy

	func root_owner() -> Node:
		return get_tree().root
