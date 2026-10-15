extends SceneTree
## Every traffic mesh the worker prebuilds must match a main-thread build
## vertex for vertex — the prebuild is a scheduling change, not a model one.

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var car_gd: GDScript = load("res://scripts/traffic_car.gd")
	car_gd.call("prebuild_meshes")
	var deadline := Time.get_ticks_msec() + 20000
	while (car_gd.get("_prebuilt") as Dictionary).size() < 7 * 17 and Time.get_ticks_msec() < deadline:
		await process_frame
	var bad := 0
	var checked := 0
	for kind: int in 7:
		for colour: int in 16:
			bad += _diff(car_gd.call("_mesh_for", kind, colour), car_gd.call("_build_body_mesh", kind, colour))
			checked += 1
		bad += _diff(car_gd.call("_brake_mesh", kind), car_gd.call("_build_brake_mesh", kind))
		bad += _diff(car_gd.call("_blinker_mesh", kind, -1.0), car_gd.call("_build_blinker_mesh", kind, -1.0))
		bad += _diff(car_gd.call("_blinker_mesh", kind, 1.0), car_gd.call("_build_blinker_mesh", kind, 1.0))
		checked += 3
	var sample: ArrayMesh = car_gd.call("_mesh_for", 3, 5)
	print("car prebuild: %d meshes checked, %d differ, prebuilt=%d, sample verts=%d" % [checked, bad, (car_gd.get("_prebuilt") as Dictionary).size(), (sample.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()])
	quit(1 if bad > 0 else 0)


func _diff(a: ArrayMesh, b: ArrayMesh) -> int:
	if a.get_surface_count() != b.get_surface_count():
		return 1
	for i in a.get_surface_count():
		if var_to_bytes(a.surface_get_arrays(i)) != var_to_bytes(b.surface_get_arrays(i)):
			return 1
		if a.surface_get_material(i) != b.surface_get_material(i):
			return 1
	return 0
