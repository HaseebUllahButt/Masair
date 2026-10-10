extends SceneTree
## Time the far-shore grove instantiate lump + scene loads on the lake chunk.

const RoadChunkGD: GDScript = preload("res://scripts/road_chunk.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var path: Node = root.get_node_or_null("RoadPath")
	if path != null:
		path.call("set_world_seed", 1)
	var chunk: Node3D = RoadChunkGD.new() as Node3D
	root.add_child(chunk)
	chunk.call("_configure", 70, 4)
	chunk.call("_build_ribbon")
	var t := Time.get_ticks_usec()
	var packed: PackedScene = load("res://scenes/lookout_grove.tscn")
	print("load lookout_grove.tscn = %.1f ms" % (float(Time.get_ticks_usec() - t) / 1000.0))
	t = Time.get_ticks_usec()
	chunk.call("_build_far_shore_groves")
	print("_build_far_shore_groves = %.1f ms" % (float(Time.get_ticks_usec() - t) / 1000.0))
	for scene_path in [
		"res://scenes/lookout_bench.tscn",
		"res://scenes/lookout_board.tscn",
		"res://scenes/lookout_deck.tscn",
		"res://scenes/lookout_rail.tscn",
		"res://scenes/lookout_tree.tscn",
		"res://scenes/lookout_bollard.tscn",
		"res://scenes/lookout_bays.tscn",
		"res://scenes/lookout_stop.tscn"
	]:
		t = Time.get_ticks_usec()
		var p: PackedScene = load(scene_path)
		var load_ms := float(Time.get_ticks_usec() - t) / 1000.0
		t = Time.get_ticks_usec()
		var inst: Node = p.instantiate() if p != null else null
		var inst_ms := float(Time.get_ticks_usec() - t) / 1000.0
		if inst != null:
			inst.free()
		print("%s: load=%.1f ms instantiate=%.1f ms" % [scene_path.get_file(), load_ms, inst_ms])
	chunk.free()
	quit(0)
