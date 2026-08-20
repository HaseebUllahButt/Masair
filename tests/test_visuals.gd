extends SceneTree
## Headless regression for the road-first visual contract.
##
##   godot --headless --path . --script res://tests/test_visuals.gd
##
## This intentionally checks the inexpensive, deterministic seams rather than
## screenshot pixels: road/terrain get distinct materials and a chunk has one
## clean road surface plus defined edge details.

const RoadChunkGD: GDScript = preload("res://scripts/road_chunk.gd")
const RoadPathGD: GDScript = preload("res://scripts/road_path.gd")
const LowPolyGD: GDScript = preload("res://scripts/low_poly.gd")
const MotorcycleVisualGD: GDScript = preload("res://scripts/motorcycle_visual.gd")

var failures: int = 0


func check(ok: bool, what: String) -> void:
	if not ok:
		failures += 1
		print("FAIL: ", what)


func _first_overlook(path: Node, theme_id: int) -> float:
	var first: float = RoadPathGD.VIEWPOINT_FIRST
	var period: float = RoadPathGD.VIEWPOINT_PERIOD
	var half: float = RoadPathGD.SPUR_HALF_SPAN
	var biome: float = RoadPathGD.BIOME_LENGTH
	for k in 24:
		var centre: float = first + period * float(k)
		var start: float = floorf(centre / biome) * biome
		if centre - half < start or centre + half > start + biome:
			continue
		if int(path.call("theme_at", centre)) == theme_id:
			return centre
	return -1.0


func _count_trees_on_tarmac(chunk: Node3D, path: Node, index: int) -> int:
	## Project each planted trunk back onto the path and ask whether that
	## lateral is on the carriageway or the scenic spur.
	var origin: Vector3 = chunk.get("_origin")
	var planted: Array = []
	planted.append_array(chunk.get("_conifers") as Array)
	planted.append_array(chunk.get("_trunks") as Array)
	var z0: float = float(index) * RoadChunkGD.LENGTH
	var on_road := 0
	for xform in planted:
		var world: Vector3 = origin + xform.origin
		var best_z := z0
		var best_d := INF
		for i in 21:
			var z: float = z0 + float(i) * 2.0
			var centre: Vector3 = path.call("center_at", z)
			var d: float = Vector2(world.x - centre.x, world.z - centre.z).length()
			if d < best_d:
				best_d = d
				best_z = z
		var at: Vector3 = path.call("center_at", best_z)
		var right: Vector3 = (path.call("frame_flat_at", best_z) as Basis).x
		var lateral: float = (world - at).dot(right)
		if bool(chunk.call("_on_tarmac", best_z, lateral, 0.8)):
			on_road += 1
	return on_road


func _count_inland_verge_trees(chunk: Node3D, path: Node, index: int) -> int:
	## Trees on the main-road verge opposite the scenic turnoff. The climb used
	## to skip ordinary scenery for the whole spur window, so this side went bare.
	var origin: Vector3 = chunk.get("_origin")
	var planted: Array = []
	planted.append_array(chunk.get("_conifers") as Array)
	planted.append_array(chunk.get("_trunks") as Array)
	var z0: float = float(index) * RoadChunkGD.LENGTH
	var side: float = float(path.call("viewpoint_side_for", path.call("viewpoint_centre_for", z0)))
	var inland := 0
	for xform in planted:
		var world: Vector3 = origin + xform.origin
		var best_z := z0
		var best_d := INF
		for i in 21:
			var z: float = z0 + float(i) * 2.0
			var centre: Vector3 = path.call("center_at", z)
			var d: float = Vector2(world.x - centre.x, world.z - centre.z).length()
			if d < best_d:
				best_d = d
				best_z = z
		var at: Vector3 = path.call("center_at", best_z)
		var right: Vector3 = (path.call("frame_flat_at", best_z) as Basis).x
		var lateral: float = (world - at).dot(right)
		if lateral * side < 0.0 and absf(lateral) > RoadChunkGD.HALF_WIDTH + 1.5:
			inland += 1
	return inland


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var path: Node = get_root().get_node_or_null("RoadPath")
	var owns_path := false
	if path == null:
		path = RoadPathGD.new()
		path.name = "RoadPath"
		get_root().add_child(path)
		owns_path = true
	path.call("set_world_seed", 91827)

	var city: Dictionary = RoadChunkGD.palette(RoadChunkGD.Env.CITY)
	check(city.has("shoulder"), "city palette defines a shoulder colour")
	for env in [RoadChunkGD.Env.FOREST, RoadChunkGD.Env.COAST, RoadChunkGD.Env.MOUNTAIN, RoadChunkGD.Env.COUNTRY]:
		check(RoadChunkGD.palette(env)["road"] == city["road"], "tarmac colour stays continuous across environments")
	var overlook_chunk := int(floor(RoadPathGD.VIEWPOINT_FIRST / RoadChunkGD.LENGTH))
	check(RoadChunkGD.is_viewpoint_chunk(overlook_chunk, RoadChunkGD.Env.FOREST), "the first overlook has an owning chunk whatever the theme")
	check(not RoadChunkGD.is_viewpoint_chunk(overlook_chunk + 1, RoadChunkGD.Env.FOREST), "only one chunk owns an overlook")

	var road_material: ShaderMaterial = LowPolyGD.road_material()
	var terrain_material: StandardMaterial3D = LowPolyGD.terrain_material()
	check(road_material.shader != null, "tarmac is a procedural surface, not a flat colour")
	check(terrain_material.vertex_color_use_as_albedo, "terrain preserves vertex colour shading")
	# Metals must reflect: the sky is the only reflection source in the scene, so
	# a rough or non-metallic "chrome" would show nothing at all.
	var metal: StandardMaterial3D = LowPolyGD.metal_material()
	check(metal.metallic > 0.9 and metal.roughness < 0.4, "metal channel actually reflects the sky")
	check(LowPolyGD.paint_material().clearcoat_enabled, "paint channel has a clearcoat")
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = BoxMesh.new()
	var xf := Transform3D(Basis.from_euler(Vector3(0.2, 0.7, 0.1)).scaled(Vector3(2.0, 0.5, 1.25)), Vector3(3.0, 4.0, 5.0))
	var xforms: Array[Transform3D] = []
	var cols: Array[Color] = []
	xforms.append(xf)
	cols.append(Color(0.2, 0.4, 0.6, 0.8))
	LowPolyGD.fill_multimesh(mm, xforms, cols)
	var packed: PackedFloat32Array = mm.get_buffer()
	check(packed.size() == 16, "multimesh buffer is one TRANSFORM_3D + colour")
	check(is_equal_approx(packed[3], xf.origin.x) and is_equal_approx(packed[7], xf.origin.y) and is_equal_approx(packed[11], xf.origin.z), "multimesh buffer round-trips the instance origin")
	check(is_equal_approx(packed[12], 0.2) and is_equal_approx(packed[15], 0.8), "multimesh buffer round-trips the instance colour")

	var chunk: Node3D = RoadChunkGD.new()
	chunk.name = "VisualChunkTest"
	get_root().add_child(chunk)
	chunk.call("setup", 0, RoadChunkGD.Env.CITY)
	check(chunk.get_node_or_null("RoadSurface") != null, "chunk has a dedicated road surface")
	check(chunk.get_node_or_null("RoadDetails") != null, "chunk has visible edge and marking details")
	check(chunk.get_node_or_null("PowerLine") == null, "distant cable ribbons cannot spike through the skyline")
	check(chunk.get_node_or_null("Terrain") != null, "chunk has a separate terrain ribbon")
	check(chunk.get_node_or_null("Cubes") != null, "chunk has batched roadside furniture")
	var cubes := chunk.get_node_or_null("Cubes") as MultiMeshInstance3D
	var planted_cubes: Array = chunk.get("_cubes")
	var cube_buf: PackedFloat32Array = PackedFloat32Array() if cubes == null else cubes.multimesh.get_buffer()
	check(
		cubes != null and planted_cubes.size() > 0 and cube_buf.size() >= 12 and is_equal_approx(cube_buf[3], planted_cubes[0].origin.x),
		"batched props keep their authored transforms"
	)
	check(chunk.get_node_or_null("RoadSurface/RoadDetails") == null, "road details are not nested over the road surface")
	var road_surface := chunk.get_node("RoadSurface") as MeshInstance3D
	check(road_surface.material_override == road_material, "road surface uses the road material")
	check(road_surface.mesh.get_surface_count() == 1, "road surface has one clean material surface")
	# Road space, not world space: the tarmac shader places wheel tracks from UVs.
	var road_arrays: Array = road_surface.mesh.surface_get_arrays(0)
	var road_uvs: PackedVector2Array = road_arrays[Mesh.ARRAY_TEX_UV]
	check(road_uvs.size() > 0, "road surface carries road-space UVs")
	var widest := 0.0
	for uv in road_uvs:
		widest = maxf(widest, absf(uv.x))
	check(is_equal_approx(widest, RoadChunkGD.HALF_WIDTH), "road UV.x spans the full carriageway in metres")

	chunk.free()
	var country: Node3D = RoadChunkGD.new()
	country.name = "CableVisualTest"
	get_root().add_child(country)
	country.call("setup", 4, RoadChunkGD.Env.COUNTRY)
	var furniture := country.get_node_or_null("Cubes") as MultiMeshInstance3D
	var cable_segments := 0
	var vertical_cables := 0
	var cable_transforms: Array = country.get("_cubes")
	for value in cable_transforms:
		if value is Transform3D:
			var cable_transform := value as Transform3D
			var x_size := cable_transform.basis.x.length()
			var y_size := cable_transform.basis.y.length()
			var z_size := cable_transform.basis.z.length()
			if x_size < 0.05 and z_size < 0.05 and y_size > 2.0 and y_size < 6.0:
				cable_segments += 1
				if absf(cable_transform.basis.y.normalized().y) > 0.75:
					vertical_cables += 1
	check(cable_segments > 0, "utility poles retain visible batched power cables (%d transforms)" % cable_transforms.size())
	check(vertical_cables == 0, "power cables run between poles instead of spiking vertically")
	check(furniture != null and furniture.visibility_range_end <= 280.0, "power cables leave the distant skyline clean")
	country.free()

	var farm: Node3D = RoadChunkGD.new()
	farm.name = "WallLandmarkVisualTest"
	get_root().add_child(farm)
	farm.call("setup", 3, RoadChunkGD.Env.COUNTRY)
	check(farm.get_node_or_null("RidgeWall") != null, "country landmarks lay a dry-stone wall along the hill")
	check((farm.get("_cubes") as Array).size() > 8, "the wall is built of stones, not an empty marker")
	farm.free()

	# The overlook chunk carries the whole set piece: the spur's own road surface
	# inside the ribbon, the water, and the range across it.
	var viewpoint: Node3D = RoadChunkGD.new()
	viewpoint.name = "ViewpointChunkTest"
	get_root().add_child(viewpoint)
	viewpoint.call("setup", overlook_chunk, RoadChunkGD.Env.COUNTRY)
	check(viewpoint.get_node_or_null("ViewpointLake") != null, "the overlook generates its lake")
	var lake := viewpoint.get_node_or_null("ViewpointLake") as MeshInstance3D
	check(lake != null and lake.material_override == RoadChunkGD.water_material(), "the lake uses the reflective shared water")
	check(viewpoint.get_node_or_null("ViewpointRange") != null, "the overlook builds the range it looks at")
	check(viewpoint.get_node_or_null("ViewpointFarGround") != null, "the drawn ground reaches the foot of the range")
	var far_ground := viewpoint.get_node("ViewpointFarGround") as MeshInstance3D
	check(
		far_ground.mesh != null and far_ground.mesh.get_aabb().get_longest_axis_size() > 80.0,
		"far ground is a skirt under the range, not a buried stub (%.0f m)"
		% (far_ground.mesh.get_aabb().get_longest_axis_size() if far_ground.mesh else 0.0)
	)
	# The old range put one gaussian blob in the middle of the lake, low enough
	# that the seated eye looked down onto a pale-yellow lid. Then two parabolic
	# noses did the same job as ice-cream hills. A country overlook is a pass
	# between two peaks: the centre of the view is water and sky.
	check(not bool(RoadChunkGD.RANGE_LAYERS[0].get("cliff", false)), "the waterline is scree, not a range cliff")
	check(
		float(RoadChunkGD.RANGE_LAYERS[0]["lateral"]) > float(RoadPathGD.LAKE_FAR),
		"the range sits behind the lake, not in it"
	)
	check(float(RoadChunkGD.RANGE_LAYERS[0]["height"]) >= 200.0, "the near range is a fell, not a bump")
	check(RoadChunkGD.RANGE_LAYERS.size() >= 4, "the view stacks four distances, not one lump")
	check(float(RoadPathGD.SEAT_EYE) >= 1.5, "the seated eye sits above the terrace, not in the water")
	check(float(RoadPathGD.SEAT_TILT) > deg_to_rad(3.0), "the seated eye still dips toward the lake")
	check(float(RoadPathGD.SEAT_TILT) < deg_to_rad(10.0), "the seated eye looks out at the far shore, not down at the near water")
	for layer in RoadChunkGD.RANGE_LAYERS:
		check(not layer.has("peak"), "range layers no longer author a single central summit")
		check(not layer.has("snow"), "the range is not wearing a pale snow lid")
		check(float(layer["pass_width"]) >= 360.0, "the pass is wide enough to read from the bench")
		var mid: Vector2 = viewpoint.call("_range_sample", RoadPathGD.VIEWPOINT_FIRST, layer, 0.0)
		var left: Vector2 = viewpoint.call(
			"_range_sample", RoadPathGD.VIEWPOINT_FIRST + float(layer["left"]), layer, 0.0
		)
		var right: Vector2 = viewpoint.call(
			"_range_sample", RoadPathGD.VIEWPOINT_FIRST + float(layer["right"]), layer, 0.0
		)
		check(left.x > mid.x * 1.35, "range has a left peak, not a central blob (%.0f vs %.0f)" % [left.x, mid.x])
		check(right.x > mid.x * 1.35, "range has a right peak, not a central blob (%.0f vs %.0f)" % [right.x, mid.x])
	var range_mesh := viewpoint.get_node("ViewpointRange") as MeshInstance3D
	check(
		range_mesh.material_override == LowPolyGD.terrain_material(),
		"the range uses the landscape material, not a toon-lit prop"
	)
	check(
		is_equal_approx(
			float(RoadChunkGD.range_strip_count()) * float(RoadChunkGD.range_strip_length()),
			float(RoadChunkGD.LENGTH)
		),
		"range strips tile the chunk instead of leaving a remainder gap"
	)
	var range_aabb: AABB = range_mesh.mesh.get_aabb()
	var along_span: float = minf(range_aabb.size.x, range_aabb.size.z)
	check(
		along_span >= float(RoadChunkGD.LENGTH) - 2.0,
		"the range mesh spans the chunk, not a striped remainder (%.1f m)" % along_span
	)
	# Rocky scree runs the length of the far shore, low through the pass.
	check(viewpoint.get_node_or_null("ViewpointCliffs") != null, "the far shore builds scree that meets the water")
	var spur_centre: float = float(path.call("spur_offset", RoadPathGD.VIEWPOINT_FIRST)) * float(
		path.call("viewpoint_side_for", RoadPathGD.VIEWPOINT_FIRST)
	)
	check(
		bool(viewpoint.call("_on_tarmac", RoadPathGD.VIEWPOINT_FIRST, spur_centre, 0.0)),
		"the scenic spur centreline counts as tarmac"
	)
	check(
		not bool(
			viewpoint.call(
				"_on_tarmac",
				RoadPathGD.VIEWPOINT_FIRST,
				spur_centre + float(path.call("viewpoint_side_for", RoadPathGD.VIEWPOINT_FIRST)) * 16.0,
				0.0
			)
		),
		"sixteen metres off the apron is not tarmac"
	)
	var on_road_trees := _count_trees_on_tarmac(viewpoint, path, overlook_chunk)
	check(on_road_trees == 0, "the platform chunk does not plant trees on the scenic road (%d)" % on_road_trees)
	var platform_grass: int = (viewpoint.get("_grass") as Array).size()
	check(platform_grass < 100, "the platform does not scatter field grass over the lake (%d)" % platform_grass)
	check(viewpoint.get_node_or_null("Birds") != null, "country overlooks have a small flock over the water")
	check(viewpoint.is_processing(), "country flock keeps the platform chunk awake")
	var climb: Node3D = RoadChunkGD.new()
	climb.name = "SpurWoodlandTest"
	get_root().add_child(climb)
	var climb_chunk := overlook_chunk - 10
	climb.call("setup", climb_chunk, RoadChunkGD.Env.FOREST)
	var climb_trees := _count_trees_on_tarmac(climb, path, climb_chunk)
	check(climb_trees == 0, "the scenic climb does not plant trees on the tarmac (%d)" % climb_trees)
	check(bool(climb.get("_on_lake")), "the climb chunk sits in the lake basin")
	var climb_inland := _count_inland_verge_trees(climb, path, climb_chunk)
	check(climb_inland > 4, "the carriageway beside the scenic climb still has trees (%d)" % climb_inland)
	climb.free()
	var approach: Node3D = RoadChunkGD.new()
	approach.name = "ScenicApproachVergeTest"
	get_root().add_child(approach)
	var approach_chunk := overlook_chunk - 40
	approach.call("setup", approach_chunk, RoadChunkGD.Env.FOREST)
	check(bool(approach.get("_on_spur")), "the approach chunk is inside the scenic spur window")
	check(not bool(approach.get("_on_lake")), "the approach chunk is not the lake basin")
	var approach_road := _count_trees_on_tarmac(approach, path, approach_chunk)
	check(approach_road == 0, "the scenic approach does not plant trees on the tarmac (%d)" % approach_road)
	var approach_inland := _count_inland_verge_trees(approach, path, approach_chunk)
	check(approach_inland > 4, "the main road near the scenic turnoff still has trees (%d)" % approach_inland)
	approach.free()
	var spur_surface := viewpoint.get_node("RoadSurface") as MeshInstance3D
	var spur_aabb: AABB = spur_surface.mesh.get_aabb()
	# Far wider than the 16 m carriageway on its own: the spur and its parking
	# platform are built into the same ribbon, not bolted on as a separate mesh.
	check(spur_aabb.size.x > 60.0, "the spur road is part of the chunk's road surface (%.0f m wide)" % spur_aabb.size.x)
	check(spur_aabb.size.y > 8.0, "the spur road climbs away from the carriageway (%.0f m)" % spur_aabb.size.y)
	# The furniture that makes the parking a place rather than a slab. Nothing
	# guarded this, so resizing the platform could have silently emptied it and
	# the only symptom would have been a screenshot nobody took.
	check(viewpoint.get_node_or_null("ViewpointWaterfall") == null, "the overlook does not hang a cardboard waterfall in the view")
	check(not viewpoint.has_method("_build_islands"), "the lake has no wooded islands")
	check(not viewpoint.has_method("_build_far_settlement"), "the far shore has no hamlet, chapel or towers")
	check(viewpoint.get_node_or_null("PlatformKerbs") != null, "the platform has its kerb lines")
	var props := viewpoint.get_node_or_null("Cubes") as MultiMeshInstance3D
	check(
		props != null and props.multimesh.instance_count > 0,
		"the platform builds its benches, board and viewer"
	)
	check(RoadPathGD.SPUR_MOUTH >= 120.0, "the junction mouth is long enough to read at speed")
	# Furniture is placed on the spur deck along the road normal. World-up boxes
	# on a pitched terrace is how the benches used to hover.
	var bench_z: float = RoadPathGD.VIEWPOINT_FIRST + float(RoadPathGD.PLATFORM_BENCH_Z[0])
	var bench_lat: float = (
		float(path.call("viewpoint_side_for", RoadPathGD.VIEWPOINT_FIRST))
		* (float(path.call("spur_offset", bench_z)) + RoadPathGD.PLATFORM_BENCH_OUT)
	)
	var deck: Vector3 = path.call("point_at", bench_z, bench_lat)
	var origin: Vector3 = viewpoint.get("_origin")
	var nearest_lift := 99.0
	for xform in viewpoint.get("_cubes") as Array:
		var world: Vector3 = xform.origin + origin
		if absf(world.x - deck.x) < 2.5 and absf(world.z - deck.z) < 2.5:
			nearest_lift = minf(nearest_lift, absf(world.y - deck.y))
	check(nearest_lift < 1.2, "benches sit on the terrace rather than hovering above it (%.2f m)" % nearest_lift)
	# Country fence posts already use the prop clearance path. Its long rails must
	# use it too or the posts disappear while two bare beams remain across the
	# viewpoint approach.
	var beam_z: float = RoadPathGD.VIEWPOINT_FIRST - RoadPathGD.SPUR_HALF_SPAN + 100.0
	var beam_lateral: float = float(path.call("viewpoint_side_for", RoadPathGD.VIEWPOINT_FIRST)) * (RoadPathGD.HALF_WIDTH + 4.0)
	var cubes_before: int = (viewpoint.get("_cubes") as Array).size()
	viewpoint.call("_terrain_beam", beam_z, beam_z + 4.0, beam_lateral, 0.09, 0.09, Color.WHITE, 0.92)
	check((viewpoint.get("_cubes") as Array).size() == cubes_before, "country fence rails stay out of the viewpoint road")
	# The platform is the one place the rider can leave the bike.
	check(
		path.call("at_platform", RoadPathGD.VIEWPOINT_FIRST, path.call("viewpoint_side_for", RoadPathGD.VIEWPOINT_FIRST) * RoadPathGD.SPUR_OUT),
		"the built platform is the one the path offers a seat on"
	)
	# Riding past a scenic turnoff must keep the highway trees, and taking the
	# spur must drop the unused corridor so both paths are not drawn at once.
	viewpoint.call("apply_corridor", false, true)
	var lake_mesh := viewpoint.get_node_or_null("ViewpointLake") as Node3D
	check(lake_mesh != null and not lake_mesh.visible, "the main road does not draw the unused scenic basin")
	var highway_shown := false
	for child in viewpoint.get_children():
		if str(child.get_meta("corridor", "")) == "highway" and bool(child.visible):
			highway_shown = true
			break
	check(highway_shown, "the main road keeps its trees while the scenic spur is unused")
	viewpoint.call("apply_corridor", true, true)
	check(lake_mesh.visible, "the scenic basin draws once the rider takes the spur")
	var highway_hidden := true
	for child in viewpoint.get_children():
		if str(child.get_meta("corridor", "")) == "highway" and bool(child.visible):
			highway_hidden = false
			break
	check(highway_hidden, "the scenic spur does not draw the unused highway trees")
	viewpoint.call("apply_corridor", false, true, true)
	check(viewpoint.get_node_or_null("ViewpointLake") == null, "committed highway frees the unused lake")
	viewpoint.call("apply_corridor", false, false)
	viewpoint.free()

	# Streaming past a turnoff must not upload the lake. Tests and the catalog
	# still call setup() with scenic included; runtime passes false until the
	# rider is on the spur, then late-builds.
	var highway_only: Node3D = RoadChunkGD.new()
	highway_only.name = "HighwayOnlyOverlook"
	get_root().add_child(highway_only)
	highway_only.call("setup", overlook_chunk, RoadChunkGD.Env.COUNTRY, false)
	check(highway_only.get_node_or_null("ViewpointLake") == null, "highway streaming skips the unused lake")
	check(
		_count_inland_verge_trees(highway_only, path, overlook_chunk) > 0,
		"highway-only overlook still plants inland trees"
	)
	highway_only.call("_build_scenic_props")
	check(highway_only.get_node_or_null("ViewpointLake") != null, "taking the spur late-builds the lake")
	highway_only.free()

	# The climb must not plant unused highway trees. Returning to the carriageway
	# late-builds them; the lake is already there.
	var scenic_only: Node3D = RoadChunkGD.new()
	scenic_only.name = "ScenicOnlyOverlook"
	get_root().add_child(scenic_only)
	scenic_only.call("setup", overlook_chunk, RoadChunkGD.Env.COUNTRY, true, false)
	check(scenic_only.get_node_or_null("ViewpointLake") != null, "the climb still builds the lake")
	check(
		_count_inland_verge_trees(scenic_only, path, overlook_chunk) == 0,
		"the climb does not plant unused highway trees"
	)
	scenic_only.call("_build_highway_props")
	check(
		_count_inland_verge_trees(scenic_only, path, overlook_chunk) > 0,
		"returning to the highway late-builds the verge"
	)
	scenic_only.free()

	# Riding past the turnoff still needs woodland at the gore so the exit is not
	# a hole, without uploading the lake.
	var stub_index := overlook_chunk
	for i in range(overlook_chunk - 42, overlook_chunk - 8):
		var d: float = float(path.call("spur_divergence", (float(i) + 0.5) * RoadChunkGD.LENGTH))
		if d >= 0.08 and d < RoadPathGD.CORRIDOR_COMMIT:
			stub_index = i
			break
	check(stub_index != overlook_chunk, "the exit has a readable junction strip")
	var stub: Node3D = RoadChunkGD.new()
	stub.name = "JunctionStubOverlook"
	get_root().add_child(stub)
	stub.call("setup", stub_index, RoadChunkGD.Env.COUNTRY, false)
	check(stub.get_node_or_null("ViewpointLake") == null, "the unused climb does not build the lake at the exit")
	var stub_scenic := 0
	for child in stub.get_children():
		if str(child.get_meta("corridor", "")) == "scenic":
			stub_scenic += 1
	check(stub_scenic > 0, "the exit still shows woodland where the spur peels off")
	stub.free()

	# Other rural biomes still produce a viewpoint landscape: water, a far side,
	# no towers or hamlets. The spur maths are shared; only the dressing changes.
	for env in [RoadChunkGD.Env.FOREST, RoadChunkGD.Env.COAST, RoadChunkGD.Env.MOUNTAIN]:
		var themed: Node3D = RoadChunkGD.new()
		themed.name = "ViewpointTheme%d" % env
		get_root().add_child(themed)
		themed.call("setup", overlook_chunk, env)
		check(themed.get_node_or_null("ViewpointLake") != null, "biome %d overlook still has water" % env)
		var dressed := (
			themed.get_node_or_null("ViewpointRange") != null
			or themed.get_node_or_null("ViewpointCliffs") != null
			or themed.get_node_or_null("ViewpointFarGround") != null
		)
		check(dressed, "biome %d overlook is not an empty platform" % env)
		check(themed.get_node_or_null("Architecture") == null, "biome %d overlook has no towers" % env)
		check(themed.get_node_or_null("ViewpointWaterfall") == null, "biome %d overlook has no cardboard waterfall" % env)
		if env == RoadChunkGD.Env.COAST:
			check(themed.get_node_or_null("ViewpointRange") != null, "the coast keeps a distant headland on the horizon")
			check(themed.get_node_or_null("ViewpointCliffs") == null, "the coast overlook has no far-shore wall in the water")
			check(themed.get_node_or_null("ViewpointHeadland") != null, "the coast overlook has a cliff under the bench")
			check(themed.get_node_or_null("ViewpointCypress") != null, "the coast view has a framing sea-stack")
			check(themed.get_node_or_null("Birds") != null, "gulls circle the coast water")
			check(themed.is_processing(), "the coast flock keeps the chunk awake")
		if env == RoadChunkGD.Env.MOUNTAIN:
			check(themed.get_node_or_null("Birds") != null, "raptors circle the mountain col")
			check(themed.is_processing(), "the mountain flock keeps the chunk awake")
		if env == RoadChunkGD.Env.FOREST:
			check(themed.get_node_or_null("Birds") == null, "the forest gorge does not run a flock")
			check(not themed.is_processing(), "a forest platform with no clouds or birds does not process")
		check(not themed.has_method("_build_islands"), "biome %d lake has no wooded islands" % env)
		check(not themed.has_method("_build_far_settlement"), "biome %d far shore has no hamlet" % env)
		themed.free()

	var sea: ShaderMaterial = RoadChunkGD.water_material_sea()
	check(float(sea.get_shader_parameter("wave_height")) < 0.03, "the coast sheet is calmer than the lake")

	var country_view := _first_overlook(path, RoadChunkGD.Env.COUNTRY)
	var forest_view := _first_overlook(path, RoadChunkGD.Env.FOREST)
	var coast_view := _first_overlook(path, RoadChunkGD.Env.COAST)
	var mountain_view := _first_overlook(path, RoadChunkGD.Env.MOUNTAIN)
	check(country_view > 0.0 and forest_view > 0.0 and coast_view > 0.0 and mountain_view > 0.0, "each biome owns an overlook")
	var country_far: float = float(path.call("viewpoint_far_shore", country_view, country_view))
	var forest_far: float = float(path.call("viewpoint_far_shore", forest_view, forest_view))
	var coast_far: float = float(path.call("viewpoint_far_shore", coast_view, coast_view))
	var mountain_far: float = float(path.call("viewpoint_far_shore", mountain_view, mountain_view))
	check(coast_far > country_far * 1.35, "coast water runs out to the horizon (%.0f vs %.0f)" % [coast_far, country_far])
	check(forest_far < country_far * 0.72, "forest is a gorge, not a lake (%.0f vs %.0f)" % [forest_far, country_far])
	check(mountain_far < country_far * 0.82, "mountain is a tarn in a pass (%.0f vs %.0f)" % [mountain_far, country_far])

	var cairn_index := int(floor((mountain_view + 200.0) / RoadChunkGD.LENGTH))
	var cairn: Node3D = RoadChunkGD.new()
	cairn.name = "ViewpointCairnTest"
	get_root().add_child(cairn)
	cairn.call("setup", cairn_index, RoadChunkGD.Env.MOUNTAIN)
	check(cairn.get_node_or_null("ViewpointCairn") != null, "the mountain view has a cairn on the far shore")
	cairn.free()
	var wall_index := int(floor((country_view + 200.0) / RoadChunkGD.LENGTH))
	var wall: Node3D = RoadChunkGD.new()
	wall.name = "ViewpointWallTest"
	get_root().add_child(wall)
	wall.call("setup", wall_index, RoadChunkGD.Env.COUNTRY)
	check(wall.get_node_or_null("ViewpointWall") != null, "the country view has a dry-stone wall on the far shore")
	wall.free()
	var peak_index := int(floor((mountain_view + float(RoadChunkGD.RANGE_LAYERS[0]["left"])) / RoadChunkGD.LENGTH))
	var peak: Node3D = RoadChunkGD.new()
	peak.name = "PeakCloudTest"
	get_root().add_child(peak)
	peak.call("setup", peak_index, RoadChunkGD.Env.MOUNTAIN)
	check(peak.get_node_or_null("Clouds") != null, "planted summits wear a collar of cloud")
	check(peak.is_processing(), "peak clouds drift, so their chunk processes")
	peak.free()

	# Forest, coast and mountain roadside scenery still builds when those biomes
	# are the chunk theme — not just countryside hedges.
	var forest_chunk: Node3D = RoadChunkGD.new()
	forest_chunk.name = "ForestSceneryTest"
	get_root().add_child(forest_chunk)
	forest_chunk.call("setup", 2, RoadChunkGD.Env.FOREST)
	check(
		forest_chunk.get_node_or_null("Trunks") != null or forest_chunk.get_node_or_null("Conifers") != null,
		"forest chunks still plant trees"
	)
	check(not forest_chunk.is_processing(), "a roadside chunk does not run a vista animator")
	forest_chunk.free()
	var coast_chunk: Node3D = RoadChunkGD.new()
	coast_chunk.name = "CoastSceneryTest"
	get_root().add_child(coast_chunk)
	coast_chunk.call("setup", 2, RoadChunkGD.Env.COAST)
	check(
		coast_chunk.get_node_or_null("Fronds") != null or coast_chunk.get_node_or_null("Rocks") != null,
		"coast chunks still have shoreline scenery"
	)
	coast_chunk.free()
	var mountain_chunk: Node3D = RoadChunkGD.new()
	mountain_chunk.name = "MountainSceneryTest"
	get_root().add_child(mountain_chunk)
	mountain_chunk.call("setup", 2, RoadChunkGD.Env.MOUNTAIN)
	check(mountain_chunk.get_node_or_null("Conifers") != null, "mountain chunks still have montane trees")
	mountain_chunk.free()

	# Landmarks sit off the road and are country, not infrastructure.
	var copse: Node3D = RoadChunkGD.new()
	copse.name = "CopseLandmarkTest"
	get_root().add_child(copse)
	copse.call("setup", 3, RoadChunkGD.Env.FOREST)
	check(copse.get_node_or_null("Copse") != null, "forest landmarks are a copse on a knoll")
	check(copse.get_node_or_null("WindFarm") == null, "forest no longer plants a wind farm")
	copse.free()
	var fall: Node3D = RoadChunkGD.new()
	fall.name = "FallLandmarkTest"
	get_root().add_child(fall)
	fall.call("setup", 3, RoadChunkGD.Env.COAST)
	check(fall.get_node_or_null("Waterfall") != null, "coast landmarks are a hillside fall")
	var fall_mesh := fall.get_node_or_null("Waterfall") as MeshInstance3D
	check(fall_mesh != null and fall_mesh.mesh != null and fall_mesh.mesh.get_surface_count() > 0, "the fall is a sheet of water, not an empty node")
	check(fall.get_node_or_null("ViewpointWaterfall") == null, "the fall is not bolted to an overlook")
	fall.free()
	var ridge: Node3D = RoadChunkGD.new()
	ridge.name = "WallLandmarkTest"
	get_root().add_child(ridge)
	ridge.call("setup", 3, RoadChunkGD.Env.COUNTRY)
	check(ridge.get_node_or_null("RidgeWall") != null, "country landmarks are a dry-stone wall")
	ridge.free()

	# The café racer has to exist as a complete machine: title shot and bench
	# both see the whole bike, so a headlight-only cockpit is a regression.
	var bike_vis := Node3D.new()
	bike_vis.set_script(MotorcycleVisualGD)
	bike_vis.name = "BikeVisualTest"
	get_root().add_child(bike_vis)
	check(bike_vis.get_node_or_null("Body") != null, "bike builds engine and frame")
	check(bike_vis.get_node_or_null("Steering") != null, "bike builds a steering head")
	check(bike_vis.get_node_or_null("Steering/FrontWheel") != null, "bike has a front wheel")
	check(bike_vis.get_node_or_null("RearWheel") != null, "bike has a rear wheel")
	check(bike_vis.get_node_or_null("HeroRig/HeroCamera") != null, "bike has a title-screen camera")
	check(bike_vis.get_node_or_null("Steering/Headlight") != null, "bike keeps a headlight")
	const KITS := ["MesaKit", "SabreKit", "HalcyonKit", "TempestKit", "RavenKit"]
	for kit_name in KITS:
		var kit := bike_vis.get_node_or_null(kit_name)
		check(kit != null, "%s is a built café, not a missing overlay" % kit_name)
		if kit:
			var body := kit.get_child(0) as MeshInstance3D
			check(body != null and body.mesh != null and body.mesh.get_surface_count() > 0, "%s has painted bodywork" % kit_name)
	for style in KITS.size():
		bike_vis.call("set_bike_style", style)
		for i in KITS.size():
			var shown: bool = bike_vis.get_node(KITS[i]).visible
			check(shown == (i == style), "%s visibility matches style %d" % [KITS[i], style])
	bike_vis.free()

	var HorizonGD: GDScript = load("res://scripts/horizon_mountains.gd")
	var horizon_consts: Dictionary = HorizonGD.get_script_constant_map()
	var horizon_layers: Array = horizon_consts["LAYERS"]
	check(horizon_layers.size() >= 4, "the skyline is stacked ranges, not one cutout")
	check(float(horizon_consts["CLIP_FAR"]) >= 2600.0, "the riding clip clears the far range")
	var nearest_radius := INF
	var previous_radius := 0.0
	for layer in horizon_layers:
		var radius := float(layer["radius"])
		check(radius > 1400.0, "a horizon range at %.0f m would sit inside the streamed world" % radius)
		check(radius > previous_radius, "each range sits behind the one in front")
		check(float(layer["face"]) >= 150.0, "range at %.0f m has a front slope, not a vertical wall" % radius)
		previous_radius = radius
		nearest_radius = minf(nearest_radius, radius)
	check(
		nearest_radius + 400.0 < float(horizon_consts["CLIP_FAR"]),
		"the near range is inside the riding far clip"
	)
	check(
		float(horizon_layers[horizon_layers.size() - 1]["high"]) > float(horizon_layers[0]["high"]) * 1.4,
		"distant peaks rise behind the near foothills, not hide under them"
	)
	var horizon: Node3D = HorizonGD.new()
	horizon.name = "HorizonTest"
	get_root().add_child(horizon)
	check(horizon.get_node_or_null("Range0") != null, "the near range builds")
	check(horizon.get_node_or_null("Range2") != null, "the far range builds")
	var clouds := horizon.get_node_or_null("Clouds") as MultiMeshInstance3D
	check(clouds != null and clouds.multimesh != null and clouds.multimesh.instance_count > 8, "high peaks wear a collar of cloud")
	var near_range := horizon.get_node("Range0") as MeshInstance3D
	var range_mat := near_range.material_override as ShaderMaterial
	check(range_mat != null and range_mat.shader != null, "the skyline is painted as air, not a lit rock card")
	check(range_mat.shader.resource_path.ends_with("horizon.gdshader"), "distant ranges use the horizon haze shader")
	var cloud_mat := clouds.material_override as ShaderMaterial
	check(cloud_mat != null and cloud_mat.shader != null and cloud_mat.shader.resource_path.ends_with("horizon_cloud.gdshader"), "collar puffs are soft cards, not solid spheres")
	horizon.call("apply_mood", {"horizon_color": Color("f6b06a"), "fog_color": Color("8b625f"), "light_color": Color("ff9e62"), "cloud_lit": Color("f4b07d")})
	var haze: Color = range_mat.get_shader_parameter("haze_color")
	check(haze.r > 0.7 and haze.g > 0.4, "dusk paints the skyline with the horizon, not navy")
	horizon.free()

	if owns_path:
		path.free()
	print("visual self-check: %d failures" % failures)
	quit(1 if failures > 0 else 0)
