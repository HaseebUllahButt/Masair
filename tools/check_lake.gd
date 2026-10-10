extends SceneTree
## Sanity probe: does the lake water sheet still emit its quads?

const RoadChunkGD: GDScript = preload("res://scripts/road_chunk.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var path: Node = root.get_node_or_null("RoadPath")
	if path != null:
		path.call("set_world_seed", 1)
	for index in [67, 68, 69, 70, 71, 72]:
		var chunk: Node3D = RoadChunkGD.new() as Node3D
		root.add_child(chunk)
		chunk.call("_configure", index, 4)
		chunk.call("_build_ribbon")
		chunk.call("_build_lake_water")
		var water: MeshInstance3D = chunk.get_node_or_null("ViewpointLake") as MeshInstance3D
		if water == null or water.mesh == null:
			print("idx %d: NO ViewpointLake" % index)
		else:
			var verts: PackedVector3Array = water.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			var aabb: AABB = water.mesh.get_aabb()
			print(
				"idx %d: ViewpointLake verts=%d quads=%d aabb_y=[%.1f..%.1f]"
				% [index, verts.size(), verts.size() / 4, aabb.position.y, aabb.end.y]
			)
		chunk.free()
	quit(0)
