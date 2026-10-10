extends SceneTree
## Fine-grained CPU report for the scenic-overlook landscape stages.
##
##   godot --headless --path . --script res://tools/profile_vista.gd

const RoadChunkGD: GDScript = preload("res://scripts/road_chunk.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	# One lake-owning chunk per theme family: forest overlook (idx 67 sits in
	# the first lake span on seed-default worlds), platform chunk.
	for index in [67, 70]:
		var chunk: Node3D = RoadChunkGD.new() as Node3D
		root.add_child(chunk)
		_measure(chunk, "configure", "_configure", [index, 4])
		_measure(chunk, "ribbon", "_build_ribbon")
		_measure(chunk, "lake_water", "_build_lake_water")
		_measure(chunk, "far_ground", "_build_far_ground")
		_measure(chunk, "view_range", "_build_view_range")
		_measure(chunk, "far_shore", "_build_far_shore")
		_measure(chunk, "far_cliffs", "_build_far_cliffs")
		_measure(chunk, "headland_face", "_build_headland_face")
		_measure(chunk, "lake_edges", "_build_lake_edges")
		_measure(chunk, "view_frame", "_build_view_frame")
		_measure(chunk, "dress_vista", "_dress_vista")
		_measure(chunk, "vista_landmarks", "_build_vista_landmarks")
		_measure(chunk, "commit", "_commit_props")
		chunk.free()
	# Forest scenery on an ordinary chunk: the deep band + canopy masses.
	var forest: Node3D = RoadChunkGD.new() as Node3D
	root.add_child(forest)
	_measure(forest, "configure", "_configure", [25, 1])
	_measure(forest, "ribbon", "_build_ribbon")
	_measure(forest, "furniture", "_build_furniture")
	_measure(forest, "forest_scenery", "_scenery_forest")
	_measure(forest, "commit", "_commit_props")
	forest.free()
	quit(0)


func _measure(target: Object, label: String, method: String, args: Array = []) -> void:
	var started := Time.get_ticks_usec()
	target.callv(method, args)
	print(
		"idx %-3d  %-16s %8.2f ms"
		% [int(target.get("chunk_index")), label, float(Time.get_ticks_usec() - started) / 1000.0]
	)
