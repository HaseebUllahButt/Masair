extends SceneTree
## One-shot CPU cost report for procedural road generation stages.
##
##   godot --headless --path . --script res://tools/profile_chunk.gd

const RoadChunkGD: GDScript = preload("res://scripts/road_chunk.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for theme in range(4):
		_run_chunk(24 + theme, theme, "highway")
	var overlook := int(floor(2800.0 / 40.0))
	_run_chunk(overlook - 40, 1, "scenic-approach")
	_run_chunk(overlook - 10, 1, "scenic-climb")
	_run_chunk(overlook, 4, "scenic-platform")
	_run_chunk(overlook - 3, 4, "scenic-lake")
	quit(0)


func _run_chunk(index: int, theme: int, tag: String) -> void:
	var chunk: Node3D = RoadChunkGD.new() as Node3D
	root.add_child(chunk)
	_measure(chunk, tag, "configure", "_configure", [index, theme])
	_measure(chunk, tag, "ribbon", "_build_ribbon")
	_measure(chunk, tag, "furniture", "_build_furniture")
	_measure(chunk, tag, "theme scenery", "_build_theme_scenery")
	_measure(chunk, tag, "distant scenery", "_build_distant_scenery")
	_measure(chunk, tag, "set piece", "_build_set_piece")
	_measure(chunk, tag, "vista", "_build_viewpoint_landscape")
	_measure(chunk, tag, "multimesh commit", "_commit_props")
	print(
		"%s idx %d theme %d  trunks=%d conifers=%d leaves=%d grass=%d cubes=%d"
		% [
			tag,
			index,
			theme,
			(chunk.get("_trunks") as Array).size(),
			(chunk.get("_conifers") as Array).size(),
			(chunk.get("_leaves") as Array).size(),
			(chunk.get("_grass") as Array).size(),
			(chunk.get("_cubes") as Array).size(),
		]
	)
	chunk.free()


func _measure(target: Object, tag: String, label: String, method: String, args: Array = []) -> void:
	var started := Time.get_ticks_usec()
	target.callv(method, args)
	print(
		"%-16s theme %d  %-18s %7.2f ms"
		% [tag, int(target.get("theme")), label, float(Time.get_ticks_usec() - started) / 1000.0]
	)
