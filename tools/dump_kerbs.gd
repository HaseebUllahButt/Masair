extends SceneTree

const RoadChunkGD: GDScript = preload("res://scripts/road_chunk.gd")
const RoadPathGD: GDScript = preload("res://scripts/road_path.gd")


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
	var chunk: Node3D = RoadChunkGD.new()
	get_root().add_child(chunk)
	chunk.call("setup", index, theme)
	for want in ["PlatformKerbs", "ViewpointPath", "SpurDetails"]:
		var n := chunk.find_child(want, false, false)
		if n == null or not (n is MeshInstance3D):
			print(want, " missing")
			continue
		var mesh: ArrayMesh = (n as MeshInstance3D).mesh
		for surf in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(surf)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
			print("%s surf%d verts=%d colors=%d" % [want, surf, verts.size(), cols.size()])
			# Bucket vertices by local y; report color range per band.
			var bands := {}
			for i in verts.size():
				var y := snappedf(verts[i].y, 4.0)
				if not bands.has(y):
					bands[y] = {"min": Color(1, 1, 1), "max": Color(0, 0, 0), "n": 0}
				var c := cols[i] if i < cols.size() else Color(-1, -1, -1)
				var e: Dictionary = bands[y]
				var mn: Color = e["min"]
				var mx: Color = e["max"]
				e["min"] = Color(minf(mn.r, c.r), minf(mn.g, c.g), minf(mn.b, c.b))
				e["max"] = Color(maxf(mx.r, c.r), maxf(mx.g, c.g), maxf(mx.b, c.b))
				e["n"] += 1
			var keys := bands.keys()
			keys.sort()
			for k in keys:
				var e: Dictionary = bands[k]
				print(
					"  y=%.0f n=%d colmin=%s colmax=%s" % [
						k, e["n"], e["min"].to_html(false), e["max"].to_html(false)
					]
				)
	quit()
