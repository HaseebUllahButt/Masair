extends SceneTree
## Regression: the overlook's furniture is standing before its basin finishes.
##
##   godot --headless --path . --script res://tests/test_lookout_arrival.gd
##
## The platform used to be the last step of the owner chunk's ~500-frame scenic
## pass, so a quick arrival parked on a bare terrace while the benches were still
## queued behind the range and the far shore. This streams each biome's first
## overlook the way the streamer does — highway first, then the late scenic pass
## — and counts frames until the bench, map, lamps and deck are in the tree.

const RoadChunkGD: GDScript = preload("res://scripts/road_chunk.gd")
## Frames from the start of the scenic pass to standing furniture. The old order
## needed about 497; the platform now follows the lake sheet.
const MAX_FURNITURE_FRAMES := 60
const MAX_PASS_FRAMES := 3000
const SEED := 5

var failures: int = 0
var frames: int = 0
var path: Node
var centres: Array[float] = []
var current: int = -1
var chunk: Node3D
var started: int = 0
var furnished_at: int = -1


func check(ok: bool, what: String) -> void:
	if not ok:
		failures += 1
		print("FAIL: ", what)


func _visible(pattern: String) -> int:
	var n := 0
	for node in chunk.find_children(pattern, "", true, false):
		if (node as Node3D).is_visible_in_tree():
			n += 1
	return n


func _furnished() -> bool:
	return (
		_visible("LookoutBench_*") == 2
		and _visible("LookoutMap") == 1
		and _visible("LookoutLight_*") >= 1
		and _visible("LookoutDeck") == 1
	)


func _start_next() -> void:
	current += 1
	if current >= centres.size():
		print("lookout arrival self-check: %d failures" % failures)
		quit(1 if failures > 0 else 0)
		return
	var index: int = int(path.call("viewpoint_index_for", centres[current]))
	chunk = RoadChunkGD.new()
	chunk.name = "ArrivalOwner%d" % current
	root.add_child(chunk)
	# Highway first, exactly as streaming builds it; the scenic pass comes late.
	chunk.call("setup", index, int(path.call("theme_for_chunk", index)), false, true)
	check(bool(chunk.get("_owns_platform")), "chunk %d owns its overlook" % index)
	check(_visible("LookoutBench_*") == 0, "the platform is not built with the highway")
	started = frames
	furnished_at = -1
	chunk.call("ensure_scenic_dress")


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 1:
		path = root.get_node("RoadPath")
		path.call("set_world_seed", SEED)
		# One overlook per biome.
		var themes := {}
		var z := float(path.get("VIEWPOINT_FIRST"))
		while themes.size() < 4 and z < 120000.0:
			var c: float = float(path.call("viewpoint_centre_for", z))
			var theme: int = int(path.call("theme_for_chunk", int(path.call("viewpoint_index_for", c))))
			if not themes.has(theme):
				themes[theme] = c
				centres.append(c)
			z += 700.0
		check(centres.size() == 4, "found an overlook in each of the four biomes")
		_start_next()
		return false
	if chunk == null:
		return false
	var elapsed := frames - started
	var done := bool(chunk.get_meta("scenic_done", false))
	if furnished_at < 0 and _furnished():
		furnished_at = elapsed
		check(not done, "overlook %d: furniture stands before the basin finishes" % current)
		check(
			elapsed <= MAX_FURNITURE_FRAMES,
			"overlook %d: furniture in %d frames (limit %d, was ~497)" % [current, elapsed, MAX_FURNITURE_FRAMES]
		)
	if done or elapsed > MAX_PASS_FRAMES:
		check(done, "overlook %d: the scenic pass completes" % current)
		check(furnished_at >= 0, "overlook %d: furniture is built at all" % current)
		# One of each after the full pass: no second deck, rail or bench set.
		check(chunk.find_children("LookoutDeck", "", true, false).size() == 1, "overlook %d: one deck run" % current)
		check(chunk.find_children("LookoutRail", "", true, false).size() == 1, "overlook %d: one rail run" % current)
		check(chunk.find_children("LookoutBench_*", "", true, false).size() == 2, "overlook %d: two benches" % current)
		check(_furnished(), "overlook %d: furniture still standing after the pass" % current)
		print("overlook %d (%.0f): furniture at frame %d, pass done at frame %d" % [current, centres[current], furnished_at, elapsed])
		chunk.free()
		chunk = null
		_start_next()
	return false
