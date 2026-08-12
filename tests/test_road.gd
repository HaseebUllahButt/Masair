extends SceneTree
## Headless self-check for the road frame maths.
##
##   godot --headless --path . --script res://tests/test_road.gd
##
## The regression that matters: the road ribbon and the vehicles riding it must
## agree on where the surface is. They used to disagree by up to a metre on hills
## because `Basis.from_euler(pitch, yaw, 0)` tilts +Z the opposite way to
## `forward_dir()`, which parked traffic inside the tarmac.

const RoadPathGD := preload("res://scripts/road_path.gd")
const LowPolyGD := preload("res://scripts/low_poly.gd")

var failures: int = 0


func check(ok: bool, what: String) -> void:
	if not ok:
		failures += 1
		print("FAIL: ", what)


func _initialize() -> void:
	var p: Node = RoadPathGD.new()
	var same_seed: Node = RoadPathGD.new()
	var other_seed: Node = RoadPathGD.new()
	p.call("set_world_seed", 123456)
	same_seed.call("set_world_seed", 123456)
	other_seed.call("set_world_seed", 654321)
	for z in [0.0, 120.0, 740.0, 1600.0]:
		check(
			p.center_at(z).is_equal_approx(same_seed.center_at(z)),
			"same world seed reproduces road at z=%.1f" % z
		)
	check(
		p.center_at(740.0).distance_to(other_seed.center_at(740.0)) > 1.0,
		"different world seeds produce different roads"
	)

	# Café Racer-like grades: hills may be visible and long, but the rider should
	# never meet a sudden ramp or angular crest. Check both grade and rate of change.
	var max_pitch := 0.0
	var max_pitch_change := 0.0
	var previous_pitch: float = p.pitch_at(0.0)
	for i in 2000:
		var sample_z := float(i) * 2.0
		var sample_pitch: float = p.pitch_at(sample_z)
		max_pitch = maxf(max_pitch, absf(sample_pitch))
		max_pitch_change = maxf(max_pitch_change, absf(sample_pitch - previous_pitch))
		previous_pitch = sample_pitch
	check(max_pitch < deg_to_rad(2.5), "road grade stays gentle (max %.2f deg)" % rad_to_deg(max_pitch))
	check(
		max_pitch_change < deg_to_rad(0.08),
		"hill pitch changes gradually (max %.3f deg per 2 m)" % rad_to_deg(max_pitch_change)
	)

	for i in 400:
		var z := float(i) * 7.3
		var f: Basis = p.frame_at(z)

		check(absf(f.determinant() - 1.0) < 1e-3, "frame is a rotation at z=%.1f" % z)
		check(absf(f.x.dot(f.y)) < 1e-4 and absf(f.y.dot(f.z)) < 1e-4, "frame is orthogonal at z=%.1f" % z)
		check(f.z.dot(p.forward_dir(z)) > 0.999, "frame Z is the travel tangent at z=%.1f" % z)
		var combined: Transform3D = p.transform_at(z, 3.25)
		check(combined.origin.distance_to(p.point_at(z, 3.25)) < 1e-4, "combined transform position agrees at z=%.1f" % z)
		check(combined.basis.is_equal_approx(f), "combined transform frame agrees at z=%.1f" % z)

		# The playable world continues far beyond the tarmac. Its transform must sit
		# exactly on the rendered terrain and remain a clean rotation on rolling land.
		for lat in [-72.0, 72.0]:
			var offroad: Transform3D = p.ride_transform_at(z, lat)
			check(
				offroad.origin.distance_to(p.ride_surface_at(z, lat)) < 1e-4,
				"off-road transform meets terrain at z=%.1f lat=%.1f" % [z, lat]
			)
			check(absf(offroad.basis.determinant() - 1.0) < 1e-3, "off-road frame is a rotation")

		# The sign trap: climbing means the tangent points up.
		var slope: float = p.height_at(z + 0.5) - p.height_at(z - 0.5)
		check(signf(f.z.y) == signf(slope) or absf(slope) < 1e-4, "frame Z climbs with the hill at z=%.1f" % z)

		# Ribbon chord vs. true surface: a car sitting on point_at() must not sink
		# into the tarmac between two cross-sections.
		var step: float = 40.0 / 24.0
		for lat in [-7.0, 0.0, 7.0]:
			var a: Vector3 = p.point_at(z, lat)
			var b: Vector3 = p.point_at(z + step, lat)
			var mid: Vector3 = p.point_at(z + step * 0.5, lat)
			check(absf(((a + b) * 0.5 - mid).y) < 0.03, "ribbon matches surface at z=%.1f lat=%.1f" % [z, lat])

		# Lanes stay on the road.
		for lane in p.LANE_COUNT:
			check(absf(p.lane_x(lane)) < p.HALF_WIDTH - 1.0, "lane %d fits the road" % lane)

	# advance() must measure real metres, not Z-axis metres.
	var z0 := 1234.0
	var walked := 0.0
	var zc := z0
	for _i in 500:
		var nz: float = p.advance(zc, 0.2)
		walked += p.point_at(nz).distance_to(p.point_at(zc))
		zc = nz
	check(absf(walked - 100.0) < 2.0, "advance() covers real distance (got %.2f m)" % walked)

	# Every convex primitive is built around its own origin, so an outward normal
	# means vertex·normal > 0. This is what catches a flipped winding, which shows
	# up in game as a prop you can see straight through.
	var b := LowPolyGD.new()
	b.add_box(Transform3D.IDENTITY, Vector3(2, 2, 2), Color.WHITE)
	var arrays: Array = b.commit().surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	check(verts.size() == 36, "cube has 12 triangles (got %d verts)" % verts.size())
	for i in verts.size():
		check(verts[i].dot(norms[i]) > 0.0, "cube face %d points outward" % i)

	for shape in ["rounded_box", "cone", "cylinder"]:
		var lp = LowPolyGD.new()
		match shape:
			"rounded_box":
				lp.add_rounded_box(Transform3D.IDENTITY, Vector3(2, 1.4, 3), 0.3, Color.WHITE)
			"cone":
				lp.add_cone(Transform3D(Basis.IDENTITY, Vector3(0, -0.25, 0)), 1.0, 1.0, 10, Color.WHITE)
			_:
				lp.add_cylinder(Transform3D.IDENTITY, 0.6, 1.5, 12, Color.WHITE)
		var a2: Array = lp.commit().surface_get_arrays(0)
		var v2: PackedVector3Array = a2[Mesh.ARRAY_VERTEX]
		var n2: PackedVector3Array = a2[Mesh.ARRAY_NORMAL]
		check(v2.size() > 0, "%s produced geometry" % shape)
		var inward := 0
		for i in v2.size():
			if v2[i].dot(n2[i]) <= 1e-5:
				inward += 1
		check(inward == 0, "%s has %d inward-facing vertices" % [shape, inward])

	var loft = LowPolyGD.new()
	loft.add_loft(
		PackedVector3Array([Vector3(0, 0, -1), Vector3(0, 0, 0), Vector3(0, 0, 1)]),
		PackedVector2Array([Vector2(0.4, 0.3), Vector2(0.6, 0.4), Vector2(0.3, 0.25)]),
		10,
		Color.WHITE
	)
	var loft_mesh: ArrayMesh = loft.commit()
	check(loft_mesh.get_surface_count() > 0, "loft produced a surface")
	var loft_verts: PackedVector3Array = loft_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	check(loft_verts.size() > 40, "loft has enough vertices to be a tank, not a box (%d)" % loft_verts.size())

	# The rider's eye and the frame must roll the same way about the same point,
	# or the bike slides across the screen when you lean. Mirrors the two lines
	# in motorcycle.gd: visual is Rz(-lean), the eye is _pivot_base rotated to match.
	var lean := deg_to_rad(30.0)
	var frame_up: Vector3 = Basis.from_euler(Vector3(0, 0, -lean)) * Vector3.UP
	var eye: Vector3 = Vector3(0, 1.44, 0).rotated(Vector3.BACK, -lean)
	check(eye.distance_to(frame_up * 1.44) < 1e-5, "eye rides with the frame when leaning")

	print("road self-check: %d failures" % failures)
	quit(1 if failures > 0 else 0)
