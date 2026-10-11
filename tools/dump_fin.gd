extends SceneTree

# Dump nodes in the viewpoint chunk whose world AABB intersects the
# pale-fin region seen from the across camera (under platform lip,
# outboard face side, mid-height).

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
	var origin: Vector3 = chunk.get("_origin")
	print("origin=", origin, " centre=", centre)
	# Fin zone: under the platform lip, outboard face side, below deck.
	var box := AABB(
		Vector3(-215.0, origin.y + 10.0, centre - 45.0),
		Vector3(75.0, 45.0, 90.0)
	)
	_walk(chunk, box, origin)
	print("--- all mm batches ---")
	_names(chunk)
	print("--- unnamed mm parents ---")
	_unnamed(chunk)
	quit()


func _unnamed(n: Node) -> void:
	if n is MultiMeshInstance3D and String(n.name).begins_with("@"):
		var mmi := n as MultiMeshInstance3D
		var path := ""
		var p := n.get_parent()
		while p != null and p != get_root():
			path = p.name + "/" + path
			p = p.get_parent()
		var scr := ""
		var pn := n.get_parent()
		if pn != null and pn.get_script() != null:
			scr = " pscript=%s" % pn.get_script().resource_path.get_file()
		var mat := mmi.material_override
		var alb := ""
		if mat is StandardMaterial3D:
			alb = " alb=%s" % (mat as StandardMaterial3D).albedo_color.to_html(false)
		var verts := mmi.multimesh.mesh.get_faces().size() if mmi.multimesh.mesh else 0
		print(
			"%s parent=%s n=%d meshverts=%d%s%s" % [
				mmi.name, path, mmi.multimesh.instance_count, verts, alb, scr
			]
			)
		var shown := 0
		for i in mmi.multimesh.instance_count:
			var xf: Transform3D = mmi.global_transform * mmi.multimesh.get_instance_transform(i)
			var sc := xf.basis.get_scale()
			print(
				"   #%d pos=%s scale=%s" % [
					i, xf.origin.snapped(Vector3.ONE), sc.snapped(Vector3.ONE * 0.1)
				]
			)
			shown += 1
			if shown >= 8:
				break
	for c in n.get_children():
		_unnamed(c)


func _names(n: Node) -> void:
	if n is MultiMeshInstance3D:
		var mmi := n as MultiMeshInstance3D
		if mmi.multimesh and mmi.multimesh.mesh:
			var s: Vector3 = mmi.multimesh.mesh.get_aabb().size
			var c0 := ""
			if mmi.multimesh.use_colors and mmi.multimesh.instance_count > 0:
				c0 = " c0=%s" % mmi.multimesh.get_instance_color(0).to_html(false)
			print(
				"MM %s n=%d mesh_size=%s%s" % [mmi.name, mmi.multimesh.instance_count, s.snapped(Vector3.ONE * 0.1), c0]
			)
	elif n is MeshInstance3D and (n as MeshInstance3D).mesh:
		var mi := n as MeshInstance3D
		var s: Vector3 = mi.mesh.get_aabb().size
		print("MI %s mesh_size=%s" % [mi.name, s.snapped(Vector3.ONE * 0.1)])
	for c in n.get_children():
		_names(c)


func _walk(n: Node, box: AABB, origin: Vector3) -> void:
	if n is MeshInstance3D and n.mesh != null:
		var mi := n as MeshInstance3D
		var a: AABB = mi.global_transform * mi.mesh.get_aabb()
		if a.intersects(box):
			var m: Material = mi.material_override
			if m == null and mi.mesh.get_surface_count() > 0:
				m = mi.mesh.surface_get_material(0)
			var alb := ""
			if m is StandardMaterial3D:
				alb = " alb=%s" % (m as StandardMaterial3D).albedo_color.to_html(false)
			print(
				"M %s y=[%.0f..%.0f] x=[%.0f..%.0f] z=[%.0f..%.0f]%s" % [
					mi.name, a.position.y - origin.y, a.end.y - origin.y,
					a.position.x, a.end.x, a.position.z, a.end.z, alb
				]
			)
	elif n is MultiMeshInstance3D and n.multimesh != null:
		var mmi := n as MultiMeshInstance3D
		var mm: MultiMesh = mmi.multimesh
		var m: Material = mmi.material_override
		var alb := ""
		if m is StandardMaterial3D:
			alb = " alb=%s" % (m as StandardMaterial3D).albedo_color.to_html(false)
		var count := 0
		for i in mm.instance_count:
			var xf: Transform3D = mmi.global_transform * mm.get_instance_transform(i)
			var a: AABB = xf * mm.mesh.get_aabb()
			if a.intersects(box):
				count += 1
				var col := ""
				if mm.use_colors:
					col = " col=%s" % mm.get_instance_color(i).to_html(false)
				if a.size.y > 4.0 or count <= 30:
					print(
						"MM %s#%d pos=%s size=%s%s%s" % [
							mmi.name, i, xf.origin.snapped(Vector3.ONE),
							a.size.snapped(Vector3.ONE), alb, col
						]
					)
		if count > 0:
			print("MM %s total_hits=%d%s" % [mmi.name, count, alb])
	for c in n.get_children():
		_walk(c, box, origin)
