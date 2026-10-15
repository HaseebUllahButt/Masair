extends Node3D
## Compiles the ride's programs in the ride's own world while the start menu is
## up, so the first ride after a fresh install or a shader change does not stall.
##
## ScenicWarmup draws the materials in a private preview world. On a cold
## shader cache that still left every one of them to compile again on the first
## frames of the ride (Terrain, Cubes, Grass, Foliage and the cars: ~1.5 s of
## 150-600 ms frames), and it never saw a material under the two kinds of local
## light the game uses: the bike's headlight (a spot) and the street, deck and
## lantern lamps (omnis). Compatibility gives a material a separate program for
## each mix of those lights touching it, so on a cold cache each first meeting
## was a 130-290 ms freeze mid-ride: the headlight reaching a new kind of
## surface, the first street lamp, the deck lights at an overlook after dark.
##
## Here every surface kind is drawn once inside the real scene — real sky, real
## sun and its shadow box, real fill, real camera — in four sets: unlit, under
## a spot, under an omni, under both. Each speck is a millimetre wide and sits
## a few metres ahead of the camera, under a pixel on screen; the lights reach
## a few centimetres. Items show a handful per frame, so a cold cache costs a
## string of slow menu frames rather than one long freeze, and a warm cache
## costs nothing visible at all.

const RoadChunkGD: GDScript = preload("res://scripts/road_chunk.gd")
const LowPolyGD: GDScript = preload("res://scripts/low_poly.gd")
const LookoutLifeGD: GDScript = preload("res://scripts/lookout_life.gd")
const TrafficCarGD: GDScript = preload("res://scripts/traffic_car.gd")
const CONTACT_SHADOW_SHADER: Shader = preload("res://shaders/contact_shadow.gdshader")

## How many specks turn on per frame. A cold program is ~100-200 ms on the
## laptop, so this bounds a cold menu frame; a cached one costs ~nothing.
const PER_FRAME := 6
const SPECK := 0.001
const AHEAD := 2.5

## Once per process: the programs outlive the scene, so a restart has nothing
## left to compile.
static var _warmed: bool = false

var _queue: Array[Node3D] = []


func _ready() -> void:
	# SPLENDOR_NO_WORLD_WARMUP: perf-sweep hook for A/B runs, unset in play.
	if DisplayServer.get_name() == "headless" or _warmed or OS.has_environment("SPLENDOR_NO_WORLD_WARMUP"):
		queue_free()
		return
	_warmed = true
	process_mode = Node.PROCESS_MODE_ALWAYS
	# The camera is placed with the bike; wait a frame so it is the one drawing.
	await get_tree().process_frame
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		queue_free()
		return
	var rack := Node3D.new()
	rack.name = "Rack"
	cam.add_child(rack)
	rack.position = Vector3(0.0, 0.0, -AHEAD)
	for group: int in 4:
		_build_group(rack, group, Vector3((float(group) - 1.5) * 0.4, 0.0, 0.0))
	while not _queue.is_empty():
		var batch: Array[Node3D] = []
		for _i in mini(PER_FRAME, _queue.size()):
			var item: Node3D = _queue.pop_front()
			item.visible = true
			batch.append(item)
		# Two frames: one to draw, one to be sure the draw was submitted before
		# the item goes again.
		await get_tree().process_frame
		await get_tree().process_frame
		for item in batch:
			item.visible = false
	rack.queue_free()
	queue_free()


func _build_group(rack: Node3D, group: int, at: Vector3) -> void:
	## group 0 unlit, 1 spot, 2 omni, 3 both.
	var root := Node3D.new()
	root.position = at
	rack.add_child(root)
	if group == 1 or group == 3:
		var spot := SpotLight3D.new()
		spot.position = Vector3(0.0, 0.0, 0.12)
		spot.spot_range = 0.3
		spot.spot_angle = 60.0
		spot.shadow_enabled = false
		spot.light_energy = 0.01
		root.add_child(spot)
	if group == 2 or group == 3:
		var omni := OmniLight3D.new()
		omni.omni_range = 0.12
		omni.shadow_enabled = false
		omni.light_energy = 0.01
		# The deck and street lamps fade with distance; it is a uniform, not a
		# program key, but matching it costs nothing.
		omni.distance_fade_enabled = true
		root.add_child(omni)
	var items: Array[Node3D] = []
	for entry: Array in _surfaces(group == 0):
		var material: Material = entry[0]
		var casts: bool = entry[1]
		items.append(_mesh_item(RoadChunkGD.unit_cube(), material, casts))
		items.append(_batch_item(material, casts))
	# The traffic bodies and lamps: paint, chrome, glass, glow, in one mesh.
	items.append(_mesh_item(TrafficCarGD.call("_mesh_for", 0, 0), null, true))
	items.append(_mesh_item(TrafficCarGD.call("_brake_mesh", 0), null, false))
	# Every road sign's text.
	var label := Label3D.new()
	label.text = "Lookout 2 km"
	label.font_size = 128
	label.pixel_size = 0.0001
	label.double_sided = false
	label.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	items.append(label)
	# Imported boulders and the overlook's packed props carry their own
	# materials; the overlook is where the deck lamps meet them after dark.
	for prefer_a: bool in [true, false]:
		var rock: PackedScene = RoadChunkGD.call("_rock_scene", prefer_a)
		if rock:
			items.append(rock.instantiate() as Node3D)
	for asset: String in ["lookout_bench", "lookout_board", "lookout_bollard", "lookout_grove",
		"lookout_deck", "lookout_rail", "lookout_pier", "lookout_balcony",
		"lookout_stop", "lookout_bays", "lookout_tree"]:
		var packed: PackedScene = RoadChunkGD.call("_lookout_scene", "res://scenes/%s.tscn" % asset)
		if packed:
			items.append(packed.instantiate() as Node3D)
	if group == 0:
		var shadow := MeshInstance3D.new()
		shadow.mesh = RoadChunkGD.unit_cube()
		shadow.material_override = ShaderMaterial.new()
		(shadow.material_override as ShaderMaterial).shader = CONTACT_SHADOW_SHADER
		shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		items.append(shadow)
	if group == 0 or group == 2:
		# Birds, spray, mist, balloons, lanterns: what moves once the rider sits.
		var life := Node3D.new()
		LookoutLifeGD.call("warm_into", life)
		items.append(life)
	var i := 0
	for item in items:
		# A tight grid inside the lights' reach; the specks never touch.
		item.position = Vector3(float(i % 6) * 0.012 - 0.03, float(i / 6) * 0.012 - 0.03, 0.0)
		item.scale = Vector3.ONE * SPECK
		item.visible = false
		root.add_child(item)
		_queue.append(item)
		i += 1


func _surfaces(all: bool) -> Array:
	## [material, casts a sun shadow in the game]. Lit sets keep to what a
	## headlight or a lamp can actually reach: the road, its ground and what
	## stands beside it. The far ranges, the lake and the beacon stay unlit.
	var near: Array = [
		[LowPolyGD.solid_material(), true], [LowPolyGD.glow_material(), true],
		[LowPolyGD.road_material(), false], [LowPolyGD.terrain_material(), false],
		[LowPolyGD.field_material(), false], [LowPolyGD.foliage_material(), true],
		[LowPolyGD.metal_material(), true], [LowPolyGD.paint_material(), true],
		[LowPolyGD.mirror_material(), true], [RoadChunkGD.water_material(), false],
	]
	if not all:
		return near
	var far_ground: StandardMaterial3D = LowPolyGD.terrain_material().duplicate() as StandardMaterial3D
	far_ground.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return near + [
		[RoadChunkGD.beacon_material(), false], [far_ground, false],
		[RoadChunkGD.call("_vista_rock_material", Color("5a5148")), false],
	]


func _mesh_item(mesh: Mesh, material: Material, casts: bool) -> Node3D:
	var item := MeshInstance3D.new()
	item.mesh = mesh
	item.material_override = material
	item.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON if casts else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	return item


func _batch_item(material: Material, casts: bool) -> Node3D:
	var item := MultiMeshInstance3D.new()
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = RoadChunkGD.unit_cube()
	multimesh.instance_count = 1
	multimesh.set_instance_transform(0, Transform3D.IDENTITY)
	multimesh.set_instance_color(0, Color.WHITE)
	item.multimesh = multimesh
	item.material_override = material
	item.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON if casts else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	return item
