extends SceneTree
## One-shot CPU cost report for procedural road generation stages.
##
##   godot --headless --path . --script res://tools/profile_chunk.gd

const RoadChunkGD: GDScript = preload("res://scripts/road_chunk.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for theme in range(4):
		var chunk: Node3D = RoadChunkGD.new() as Node3D
		root.add_child(chunk)
		_measure(chunk, "configure", "_configure", [24 + theme, theme])
		_measure(chunk, "ribbon", "_build_ribbon")
		_measure(chunk, "furniture", "_build_furniture")
		_measure(chunk, "theme scenery", "_build_theme_scenery")
		_measure(chunk, "distant scenery", "_build_distant_scenery")
		_measure(chunk, "set piece", "_build_set_piece")
		_measure(chunk, "multimesh commit", "_commit_props")
		chunk.free()
	quit(0)


func _measure(target: Object, label: String, method: String, args: Array = []) -> void:
	var started := Time.get_ticks_usec()
	target.callv(method, args)
	print("theme %d  %-18s %7.2f ms" % [int(target.get("theme")), label, float(Time.get_ticks_usec() - started) / 1000.0])
