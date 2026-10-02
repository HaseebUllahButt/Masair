extends Node
## Compatibility compiles a material the first time anything draws it, on the
## render thread, inside the draw call itself, so the boot frame is a 1.1-2.7 s
## wait: the driver builds a program for every mesh material that frame touches
## before a pixel appears.
##
## The first thing to be clear about is what this cannot do. The boot chunk, the
## mountain ring, the sky and the grade pass are all drawn on frame one, so
## whatever they need they need, and the compile is paid in that frame whoever
## pays it. The work is conserved: no ordering of two viewports inside one frame
## takes any of it out of that frame. Front-running the main viewport moves the
## compile, it does not shorten it. What this file can do is make the warmup cheap
## rather than expensive - measured, it adds ~300 ms to the boot frame where the
## version it replaces added ~900 ms - and pay for the programs the boot frame
## never touches (the lake and sea sheets, the vista rock, the overlook dressing,
## the contact patch under the first car) while the start menu is up rather than
## at the moment a chunk that uses one streams in at 165 km/h.
##
## Two things make it work that way.
##
## 1. The preview world has to be the game's world. Compatibility keys a
##    material's program on the scene that draws it - light count, each light's
##    sky mode, fog, ambient, the sky. The old preview had one bare light and no
##    Environment, so it asked for a different program for every material in the
##    list and the real scene then asked for all of them again. One
##    WorldEnvironment carrying main.gd's own sky, ambient, fog, tonemap and glow,
##    plus both of the game's directional lights, is what makes the preview's
##    compiles the real scene's compiles. `_build_world` is a copy to keep in
##    step with main.gd, not a decoration: drop the fog or the second light and
##    the double compile comes straight back.
## 2. A child viewport is drawn before its parent, so the preview's pass lands
##    first inside the boot frame's render pass and the main viewport draws
##    against programs that already exist. `frame_post_draw` is the signal that a
##    pass has been consumed, so the node waits on the viewport's own state
##    instead of on a frame count, and then frees itself: the menu, the ride and
##    every restart after it draw nothing extra.
##
## The one list the real scene cannot reuse is the four overlook props: their
## materials are sub-resources of the packed scene, so every instantiate is a new
## material object and therefore a new program. They still get drawn, one frame
## later and off the boot frame - see `_build_lookouts`.

const RoadChunkGD: GDScript = preload("res://scripts/road_chunk.gd")
const LowPolyGD: GDScript = preload("res://scripts/low_poly.gd")
const RangeMaterialGD: GDScript = preload("res://scripts/range_material.gd")
const SKY_SHADER: Shader = preload("res://shaders/sky.gdshader")
const GRADE_SHADER: Shader = preload("res://shaders/grade.gdshader")
const CONTACT_SHADOW_SHADER: Shader = preload("res://shaders/contact_shadow.gdshader")

## Once per process, not once per scene load. The programs live in the driver,
## which outlives the scene, so a restart that re-ran this paid ~100-170 ms for
## programs it already had - visible as runs two and three of profile_startup.gd
## costing more than the same run with no warmup at all.
static var _warmed: bool = false


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		return
	if _warmed:
		# A restart in the same process. The driver still has every program, so
		# there is nothing left to pay for and nothing to leave in the tree.
		queue_free()
		return
	_warmed = true
	process_mode = Node.PROCESS_MODE_ALWAYS
	var preview := SubViewport.new()
	preview.name = "ScenicMaterialPreview"
	preview.size = Vector2i(64, 64)
	preview.own_world_3d = true
	# UPDATE_ONCE, not ALWAYS: this is a one-shot cost, and a viewport left
	# updating would keep a second world in the render queue for the whole ride.
	preview.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(preview)
	_build_world(preview)
	_build_surfaces(preview)
	_build_canvas(preview)
	await _draw(preview)
	# Second pass, one frame later: the props the boot frame does not need.
	_build_lookouts(preview)
	await _draw(preview)
	queue_free()


func _build_world(preview: SubViewport) -> void:
	## main.gd's `_build_environment` and `_build_fill_light` with the nodes
	## left out. Every one of these settings is a term in the driver's program key
	## for the materials below, so this is a copy to keep in step with main.gd,
	## not a decoration: drop the fog or the second light and every material
	## compiles a second time in the real scene.
	var sky_material := ShaderMaterial.new()
	sky_material.shader = SKY_SHADER
	sky_material.set_shader_parameter("sky_phase", float(_world_seed() % 1000) * 0.17)
	var sky := Sky.new()
	sky.sky_material = sky_material
	# The game's own settings, so the radiance cubemap is the same size and takes
	# the same path. Compilation only cares that a sky exists; the fidelity is
	# here so the two worlds cannot drift.
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	sky.radiance_size = Sky.RADIANCE_SIZE_32

	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	environment.ssr_enabled = false
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	environment.glow_enabled = true
	environment.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	environment.glow_hdr_threshold = 1.25
	environment.glow_hdr_scale = 2.0
	environment.glow_intensity = 0.55
	environment.glow_strength = 1.0
	for level in [1, 2, 3, 4, 5, 6, 7]:
		environment.set("glow_levels/%d" % level, [0.0, 0.4, 1.0, 0.5, 0.15, 0.0, 0.0][level - 1])
	environment.fog_enabled = true
	environment.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	# The grade LUT itself is a texture uniform and costs no program, but the
	# adjustment pass it belongs to is part of the same tonemap chain.
	environment.adjustment_enabled = true
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	preview.add_child(world_environment)

	# Two directional lights, because the game has two. The key publishes itself
	# to the sky as well as lighting; the fill is light only.
	var key := DirectionalLight3D.new()
	key.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_AND_SKY
	key.shadow_enabled = false
	key.rotation_degrees = Vector3(-12.0, 30.0, 0.0)
	preview.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	fill.shadow_enabled = false
	fill.rotation_degrees = Vector3(-64.0, 152.0, 0.0)
	preview.add_child(fill)

	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 32.0
	camera.position = Vector3(0.0, 0.0, 20.0)
	preview.add_child(camera)
	camera.make_current()


func _build_surfaces(preview: SubViewport) -> void:
	## Every material the game can put on a mesh, each drawn twice: once as a
	## plain MeshInstance3D and once through a MultiMesh, because those are two
	## different programs and the game uses both - the road, the water sheets and
	## the beacon are single meshes, the foliage and the roadside props are
	## batches. Drawing only one form leaves the other's compile for the middle
	## of the ride.
	var materials: Array[Material] = [LowPolyGD.solid_material(), LowPolyGD.glow_material(),
		LowPolyGD.road_material(), LowPolyGD.terrain_material(), LowPolyGD.metal_material(),
		LowPolyGD.paint_material(), LowPolyGD.foliage_material(), LowPolyGD.mirror_material(),
		RoadChunkGD.water_material(), RoadChunkGD.water_material_sea(), RoadChunkGD.beacon_material(),
		RangeMaterialGD.ring(), RangeMaterialGD.overlook(1), RangeMaterialGD.overlook(2),
		RangeMaterialGD.overlook(3), RangeMaterialGD.overlook(4), RoadChunkGD._vista_rock_material(Color("5a5148"))]
	for i in materials.size():
		var position_hint := Vector3(float(i % 6) * 4.0 - 10.0, float(i / 6) * 4.0 - 6.0, 0.0)
		var mesh := MeshInstance3D.new()
		mesh.mesh = RoadChunkGD.unit_cube()
		mesh.material_override = materials[i]
		mesh.position = position_hint
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		preview.add_child(mesh)
		var instances := MultiMeshInstance3D.new()
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.use_colors = true
		multimesh.mesh = RoadChunkGD.unit_cube()
		multimesh.instance_count = 1
		multimesh.set_instance_transform(0, Transform3D.IDENTITY)
		multimesh.set_instance_color(0, Color.WHITE)
		instances.multimesh = multimesh
		instances.material_override = materials[i]
		instances.position = position_hint + Vector3(1.5, 0.0, 0.0)
		instances.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		preview.add_child(instances)

	# The contact patch under every car. Nothing draws one until traffic does,
	# so without this the first car to appear pays for it mid-ride.
	var contact_shadow := MeshInstance3D.new()
	contact_shadow.mesh = RoadChunkGD.unit_cube()
	contact_shadow.material_override = ShaderMaterial.new()
	(contact_shadow.material_override as ShaderMaterial).shader = CONTACT_SHADOW_SHADER
	contact_shadow.scale = Vector3(0.25, 0.01, 0.5)
	contact_shadow.position = Vector3(-13.0, 0.02, 0.0)
	contact_shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	preview.add_child(contact_shadow)


func _build_lookouts(preview: SubViewport) -> void:
	## The four overlook props, drawn on the frame after the world's, not this
	## one. Their materials are sub-resources of the packed scene, so every
	## instantiate is a new material object and a new program: this is the one
	## list the real scene cannot reuse, and the only part of the warmup that adds
	## cost to the frame the player is waiting for. They are still worth drawing -
	## they are the shapes the overlook chunks are built from, and a prop that
	## first appears at the lookoff is a visible hitch - but the boot frame does
	## not need them, so they go one frame later, while the start menu is up and
	## 2.8 km before the road gets there.
	for asset: String in ["lookout_bench", "lookout_board", "lookout_bollard", "lookout_grove"]:
		var packed: PackedScene = load("res://scenes/%s.tscn" % asset)
		var instance: Node3D = packed.instantiate()
		instance.scale = Vector3.ONE * 0.02 if asset == "lookout_grove" else Vector3.ONE
		instance.position = Vector3(0.0, 9.0, 0.0)
		preview.add_child(instance)


func _build_canvas(preview: SubViewport) -> void:
	## The 2D the game draws over the finished frame.
	##
	## grade.gdshader is a canvas_item shader reading `hint_screen_texture`, so it
	## needs the backbuffer copy as well as the program, and the game draws it on
	## frame one. The StyleBoxFlat is here to walk the 2D style path the start
	## menu's buttons and panels use; it has no program of its own to warm (the
	## renderer draws every flat box with one shared rect program), so that part is
	## free rather than a saving.
	var layer := CanvasLayer.new()
	layer.name = "WarmupCanvas"
	var grade := ColorRect.new()
	grade.name = "GradeRect"
	grade.size = preview.size
	grade.color = Color(0.0, 0.0, 0.0, 0.0)
	grade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grade.material = ShaderMaterial.new()
	(grade.material as ShaderMaterial).shader = GRADE_SHADER
	layer.add_child(grade)
	var panel := Panel.new()
	panel.name = "MenuBox"
	panel.size = Vector2(24.0, 12.0)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.075, 0.09, 0.1, 0.85)
	box.set_corner_radius_all(2)
	box.set_border_width_all(1)
	box.border_color = Color(0.6, 0.7, 0.8, 0.5)
	panel.add_theme_stylebox_override("panel", box)
	layer.add_child(panel)
	preview.add_child(layer)


func _world_seed() -> int:
	var path := get_node_or_null("/root/RoadPath")
	return int(path.world_seed) if path else 1


func _draw(preview: SubViewport) -> void:
	## Ask for one pass and wait for the frame that runs it.
	##
	## The renderer consumes `UPDATE_ONCE` and clears it on its own side; the
	## property on this node still reads `UPDATE_ONCE` afterwards, so it cannot be
	## used as a "it drew" flag, and setting it to `UPDATE_ONCE` again would be a
	## no-op that never reaches the renderer. Writing `UPDATE_DISABLED` first is
	## what makes the second write a change, and therefore a real request. The
	## signal is emitted at the end of every rendered frame whether or not the
	## tree is paused, which is the state the start menu is in.
	preview.render_target_update_mode = SubViewport.UPDATE_DISABLED
	preview.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
