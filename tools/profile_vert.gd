extends SceneTree
## Per-call microbenchmark for the scenic ribbon's inner functions.
##   godot --headless --path . --script res://tools/profile_vert.gd

const RoadChunkGD: GDScript = preload("res://scripts/road_chunk.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var chunk: Node3D = RoadChunkGD.new() as Node3D
	root.add_child(chunk)
	chunk.call("_configure", 67, 4)
	var bands: Array = chunk.call("_view_bands")
	print("bands: %d" % bands.size())
	var z0 := 67.0 * 40.0

	_time("p cold", 2000,
		func(i: int) -> void:
			chunk.call("_p", z0 + float(i % 11) * 4.0, 62.0 + float(i % 37) * 7.0, 0.0)
	)
	_time("p warm", 2000,
		func(i: int) -> void:
			chunk.call("_p", z0 + float(i % 11) * 4.0, 62.0 + float(i % 37) * 7.0, 0.0)
	)
	_time("ground_normal", 2000,
		func(i: int) -> void:
			chunk.call("_ground_normal", z0 + float(i % 11) * 4.0, 62.0 + float(i % 37) * 7.0, 0.0)
	)
	_time("ground_color", 2000,
		func(i: int) -> void:
			chunk.call("_ground_color", 62.0 + float(i % 37) * 7.0, z0 + float(i % 11) * 4.0)
	)
	_time("face_chord_point", 2000,
		func(i: int) -> void:
			chunk.call("_face_chord_point", z0 + float(i % 11) * 4.0, 66.0 + float(i % 29) * 3.0)
	)
	_time("face_profile", 200,
		func(i: int) -> void:
			chunk.call("_face_profile", z0 + float(i) * 0.37)
	)
	_time("foliage_road_push far", 2000,
		func(i: int) -> void:
			chunk.call(
				"_foliage_road_push",
				Vector3(100.0 + float(i % 7), 0.0, z0 + float(i % 37)), 0.5, -2.0, true
			)
	)
	_time("foliage_road_push near", 2000,
		func(i: int) -> void:
			chunk.call(
				"_foliage_road_push",
				Vector3(-9.0, 0.0, z0 + float(i % 37)), 2.0, -2.0, true
			)
	)
	_time("terrain_surface_at", 2000,
		func(i: int) -> void:
			chunk.call("_terrain_surface_at", z0 + float(i % 37), 20.0 + float(i % 53))
	)
	_time("footprint_is_clear", 2000,
		func(i: int) -> void:
			chunk.call("_footprint_is_clear", z0 + float(i % 37), 25.0 + float(i % 31), 1.0, 1.0)
	)
	_time("xform_road_push", 2000,
		func(i: int) -> void:
			chunk.call(
				"_xform_road_push",
				Transform3D(
					Basis.IDENTITY,
					Vector3(float(i % 40) - 20.0, 0.0, float(i % 37))
				),
				RoadChunkGD.unit_sphere(),
				true
			)
	)
	quit(0)


func _time(label: String, n: int, fn: Callable) -> void:
	var started := Time.get_ticks_usec()
	for i in n:
		fn.call(i)
	var us := float(Time.get_ticks_usec() - started)
	print("%-22s %8.1f us/call  (%.1f ms / %d)" % [label, us / float(n), us / 1000.0, n])
