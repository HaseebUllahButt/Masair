extends SceneTree
const RoadChunkGD: GDScript = preload("res://scripts/road_chunk.gd")
const RoadPathGD: GDScript = preload("res://scripts/road_path.gd")
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	var path: Node = RoadPathGD.new()
	path.name = "RoadPath"
	get_root().add_child(path)
	path.call("set_world_seed", 1)
	for index in [67, 68, 69]:
		var chunk: Node3D = RoadChunkGD.new()
		chunk.name = "C%d" % index
		get_root().add_child(chunk)
		chunk.call("setup", index, int(path.call("theme_for_chunk", index)))
		var cubes: int = chunk.get("_cubes").size() if chunk.get("_cubes") != null else -1
		print("chunk ", index, " on_spur=", chunk.get("_on_spur"), " cubes=", cubes)
		chunk.queue_free()
	print("gate z = ", 2800.0 - 23.0 - 44.0 - 3.0)
	quit()
