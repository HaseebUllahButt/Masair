extends SceneTree

# Dump every triangle inside the picket world-box for the meshes that could
# own the hanging boards — position, span and vertex color per triangle.

const RoadChunkGD: GDScript = preload("res://scripts/road_chunk.gd")
const RoadPathGD: GDScript = preload("res://scripts/road_path.gd")
const BOX := AABB(Vector3(-192, 22, 2774), Vector3(20, 30, 24))


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var path: Node = get_root().get_node_or_null("RoadPath")
	if path == null:
		path = RoadPathGD.new()
		path.name = "RoadPath"
		get_root().add_child(path)
	path.call("set_world_seed", 1)
	var centre: float = path.call("viewpoint_centre_for", 800.0)
	var index := int(path.call("viewpoint_index_for", centre))
	var theme := int(path.call("theme_for_chunk", index))
	print("centre=%s index=%d theme=%d" % [centre, index, theme])
	var chunk: Node3D = RoadChunkGD.new()
	get_root().add_child(chunk)
	chunk.call("setup", index, theme)
	for want in ["PlatformKerbs", "ViewpointBastion", "ViewpointHeadland", "ViewpointPath", "SpurDetails"]:
		_scan(chunk, want)
	quit()


func _scan(chunk: Node, want: String) -> void:
	var n := chunk.find_child(want, false, false) as MeshInstance3D
	if n == null:
		print(want, " missing")
		return
	var xf := n.global_transform
	var mesh := n.mesh
	print("== %s surfs=%d" % [want, mesh.get_surface_count()])
	for surf in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surf)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		var idx_arr: PackedInt32Array = (
			arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		)
		var tris: Array = []
		if idx_arr.size() > 0:
			for i in range(0, idx_arr.size() - 2, 3):
				tris.append([idx_arr[i], idx_arr[i + 1], idx_arr[i + 2]])
		else:
			for i in range(0, verts.size() - 2, 3):
				tris.append([i, i + 1, i + 2])
		var hit := 0
		for t in tris:
			var w0: Vector3 = xf * verts[t[0]]
			var w1: Vector3 = xf * verts[t[1]]
			var w2: Vector3 = xf * verts[t[2]]
			var c0 := (w0 + w1 + w2) / 3.0
			if BOX.has_point(c0):
				hit += 1
				var col := cols[t[0]].to_html(false) if t[0] < cols.size() else "none"
				var sy := maxf(w0.y, maxf(w1.y, w2.y)) - minf(w0.y, minf(w1.y, w2.y))
				var sz := maxf(w0.z, maxf(w1.z, w2.z)) - minf(w0.z, minf(w1.z, w2.z))
				var sx := maxf(w0.x, maxf(w1.x, w2.x)) - minf(w0.x, minf(w1.x, w2.x))
				print(
					"   s%d tri c=(%.1f,%.1f,%.1f) span=(%.1f,%.1f,%.1f) col=%s a=(%.1f,%.1f,%.1f) b=(%.1f,%.1f,%.1f)"
					% [surf, c0.x, c0.y, c0.z, sx, sy, sz, col, w0.x, w0.y, w0.z, w1.x, w1.y, w1.z]
				)
		print("   s%d hits=%d/%d" % [surf, hit, tris.size()])
