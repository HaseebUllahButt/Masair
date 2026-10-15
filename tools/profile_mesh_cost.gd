extends SceneTree
## Count the real shared prop meshes, including indexed draw vertices. Run the
## same probe in the frozen baseline and candidate; triangle hashes prove that
## indexing changes the upload, not the visible faces of the existing kit.

func _initialize() -> void:
	var chunk: GDScript = load("res://scripts/road_chunk.gd")
	for method: String in ["unit_cube", "unit_sphere", "unit_trunk", "unit_crown", "unit_conifer"]:
		var mesh: ArrayMesh = chunk.call(method)
		var arrays: Array = mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices := PackedInt32Array()
		if arrays[Mesh.ARRAY_INDEX] != null:
			indices = arrays[Mesh.ARRAY_INDEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var colours: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		var faces: Array = []
		var count: int = indices.size() if not indices.is_empty() else vertices.size()
		for i in count:
			var j: int = indices[i] if not indices.is_empty() else i
			faces.append([vertices[j], normals[j], colours[j]])
		var hash: HashingContext = HashingContext.new()
		hash.start(HashingContext.HASH_SHA256)
		hash.update(var_to_bytes(faces))
		print("mesh: %s vertices=%d triangles=%d faces=%s" % [method, vertices.size(), count / 3, hash.finish().hex_encode()])
	quit()
