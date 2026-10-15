extends SceneTree
## Dev tool: rebuilds the overlook kit meshes that are made in code rather than
## modelled — currently the promenade lantern — and writes them back into
## their scenes, keeping each scene's nodes, materials and UID.
##
##   godot --headless --path . --audio-driver Dummy --script res://tools/build_kit.gd

const LowPolyGD: GDScript = preload("res://scripts/low_poly.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_rebuild("res://scenes/lookout_bollard.tscn", "Mesh", _lantern())
	quit()


func _lantern() -> ArrayMesh:
	## A cast-iron promenade lantern at bollard height: a stepped foot, an
	## eight-sided shaft with a collar, four corner bars round the glass and a
	## pyramid cap with a knob. The old one was a black box with a lit band —
	## from the bench it read as a bin. The glass itself is the scene's "Light"
	## child, so it keeps its own warm emissive material.
	var iron := Color("23272a")
	var iron_hi := Color("343a3e")
	var b = LowPolyGD.new()
	b.add_rounded_box(Transform3D(Basis.IDENTITY, Vector3(0, 0.035, 0)), Vector3(0.28, 0.07, 0.28), 0.015, iron)
	b.add_rounded_box(Transform3D(Basis.IDENTITY, Vector3(0, 0.1, 0)), Vector3(0.19, 0.06, 0.19), 0.012, iron_hi)
	b.add_cylinder(Transform3D(Basis.IDENTITY, Vector3(0, 0.39, 0)), 0.052, 0.52, 8, iron)
	b.add_rounded_box(Transform3D(Basis.IDENTITY, Vector3(0, 0.665, 0)), Vector3(0.16, 0.035, 0.16), 0.01, iron_hi)
	for x in [-0.075, 0.075]:
		for z in [-0.075, 0.075]:
			b.add_box(Transform3D(Basis.IDENTITY, Vector3(x, 0.79, z)), Vector3(0.022, 0.23, 0.022), iron)
	b.add_rounded_box(Transform3D(Basis.IDENTITY, Vector3(0, 0.915, 0)), Vector3(0.2, 0.025, 0.2), 0.008, iron_hi)
	b.add_cone(Transform3D(Basis(Vector3.UP, PI * 0.25), Vector3(0, 0.927, 0)), 0.15, 0.11, 4, iron)
	b.add_cylinder(Transform3D(Basis.IDENTITY, Vector3(0, 1.05, 0)), 0.018, 0.04, 6, iron_hi)
	return b.commit()


func _rebuild(scene_path: String, node_name: String, mesh: ArrayMesh) -> void:
	var packed: PackedScene = load(scene_path)
	var root: Node = packed.instantiate()
	var target := root.get_node(node_name) as MeshInstance3D
	# Surface materials stay empty: the scene's own override material (vertex
	# colour, sRGB) is what draws it, as before.
	for i in mesh.get_surface_count():
		mesh.surface_set_material(i, null)
	target.mesh = mesh
	var out := PackedScene.new()
	out.pack(root)
	var err := ResourceSaver.save(out, scene_path)
	print("rebuilt ", scene_path, " err=", err, " verts=", mesh.surface_get_array_len(0))
	root.free()
