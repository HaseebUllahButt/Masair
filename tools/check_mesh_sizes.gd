extends SceneTree
## Largest meshes on the lake-owning chunk — candidate one-frame GPU uploads.

const RoadChunkGD: GDScript = preload("res://scripts/road_chunk.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var path: Node = root.get_node_or_null("RoadPath")
	if path != null:
		path.call("set_world_seed", 1)
	var chunk: Node3D = RoadChunkGD.new() as Node3D
	root.add_child(chunk)
	chunk.call("setup", 70, 4)
	var sizes: Array = []
	var stack: Array[Node] = [chunk]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var m: Mesh = (n as MeshInstance3D).mesh
			var verts := 0
			for s in m.get_surface_count():
				verts += (m.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			sizes.append([verts, str(n.name)])
	sizes.sort()
	sizes.reverse()
	var total := 0
	for entry in sizes:
		total += int(entry[0])
		print("%8d verts  %s" % [entry[0], entry[1]])
	print("TOTAL %d verts across %d meshes" % [total, sizes.size()])
	quit(0)
