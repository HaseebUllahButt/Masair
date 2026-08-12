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

	var chunk: Node3D = RoadChunkGD.new()
	chunk.name = "VisualChunkTest"
	get_root().add_child(chunk)
	chunk.call("setup", 0, RoadChunkGD.Env.CITY)
	check(chunk.get_node_or_null("RoadSurface") != null, "chunk has a dedicated road surface")
	check(chunk.get_node_or_null("RoadDetails") != null, "chunk has visible edge and marking details")
	check(chunk.get_node_or_null("Terrain") != null, "chunk has a separate terrain ribbon")
	check(chunk.get_node_or_null("Cubes") != null, "chunk has batched roadside furniture")
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
	var spur_surface := viewpoint.get_node("RoadSurface") as MeshInstance3D
	var spur_aabb: AABB = spur_surface.mesh.get_aabb()
	# Far wider than the 16 m carriageway on its own: the spur and its parking
	# platform are built into the same ribbon, not bolted on as a separate mesh.
	check(spur_aabb.size.x > 60.0, "the spur road is part of the chunk's road surface (%.0f m wide)" % spur_aabb.size.x)
	check(spur_aabb.size.y > 8.0, "the spur road climbs away from the carriageway (%.0f m)" % spur_aabb.size.y)
	# The furniture that makes the parking a place rather than a slab. Nothing
	# guarded this, so resizing the platform could have silently emptied it and
	# the only symptom would have been a screenshot nobody took.
	check(viewpoint.get_node_or_null("PlatformKerbs") != null, "the platform has its kerb lines")
	var props := viewpoint.get_node_or_null("Cubes") as MultiMeshInstance3D
	check(
		props != null and props.multimesh.instance_count > 0,
		"the platform builds its benches, board and viewer"
	)
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
	viewpoint.free()

	# The café racer has to exist as a complete machine: title shot and bench
	# both see the whole bike, so a headlight-only cockpit is a regression.
	var bike_vis := Node3D.new()
	bike_vis.set_script(MotorcycleVisualGD)
	bike_vis.name = "BikeVisualTest"
	get_root().add_child(bike_vis)
	check(bike_vis.get_node_or_null("BodyShell") != null, "bike builds a lofted painted shell")
	check(bike_vis.get_node_or_null("Body") != null, "bike builds engine and frame")
	check(bike_vis.get_node_or_null("Steering") != null, "bike builds a steering head")
	check(bike_vis.get_node_or_null("Steering/FrontWheel") != null, "bike has a front wheel")
	check(bike_vis.get_node_or_null("RearWheel") != null, "bike has a rear wheel")
	check(bike_vis.get_node_or_null("HeroRig/HeroCamera") != null, "bike has a title-screen camera")
	check(bike_vis.get_node_or_null("Steering/Headlight") != null, "bike keeps a headlight")
	var shell := bike_vis.get_node("BodyShell") as MeshInstance3D
	check(shell.mesh != null and shell.mesh.get_surface_count() > 0, "painted shell has geometry")
	check(bike_vis.get_node_or_null("SabreKit") != null, "sabre is a built machine, not a missing overlay")
	check(bike_vis.get_node_or_null("TempestKit") != null, "tempest is a built machine, not a missing overlay")
	bike_vis.call("set_bike_style", 1)
	check(not shell.visible, "sabre replaces the café shell instead of covering it")
	check(bike_vis.get_node("SabreKit").visible, "sabre kit is shown for the middle bike")
	check(not bike_vis.get_node("TempestKit").visible, "tempest kit stays hidden on the sabre")
	bike_vis.call("set_bike_style", 2)
	check(not shell.visible, "tempest replaces the café shell instead of covering it")
	check(bike_vis.get_node("TempestKit").visible, "tempest kit is shown for the open-class bike")
	bike_vis.call("set_bike_style", 0)
	check(shell.visible, "mesa restores the café shell")
	bike_vis.free()

	if owns_path:
		path.free()
	print("visual self-check: %d failures" % failures)
	quit(1 if failures > 0 else 0)
