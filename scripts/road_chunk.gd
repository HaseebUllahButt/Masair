extends Node3D
## One 40 m section of world: road ribbon + themed scenery.
##
## Everything static in a chunk collapses into five nodes: one MeshInstance3D for
## the ribbon (tarmac + markings) and three MultiMeshInstance3Ds for props. The
## old version allocated a BoxMesh *and* a StandardMaterial3D per box, so nothing
## batched and a chunk cost hundreds of draw calls.

const LowPoly := preload("res://scripts/low_poly.gd")
const RoadPathGD := preload("res://scripts/road_path.gd")
## Loaded lazily so a missing/unimported .glb cannot break road_streamer compile.
const ROCK_A_PATH := "res://assets/kenney/Models/GLTF format/rock_largeA.glb"
const ROCK_B_PATH := "res://assets/kenney/Models/GLTF format/rock_largeB.glb"
const TurbineGD: GDScript = preload("res://scripts/turbine.gd")
const BEACON_SHADER: Shader = preload("res://shaders/beacon.gdshader")
const WATER_SHADER: Shader = preload("res://shaders/water.gdshader")

static var _rock_a: PackedScene
static var _rock_b: PackedScene
static var _rocks_loaded: bool = false


static func _ensure_rocks() -> void:
	if _rocks_loaded:
		return
	_rocks_loaded = true
	if ResourceLoader.exists(ROCK_A_PATH):
		_rock_a = load(ROCK_A_PATH) as PackedScene
	if ResourceLoader.exists(ROCK_B_PATH):
		_rock_b = load(ROCK_B_PATH) as PackedScene


static func _rock_scene(prefer_a: bool) -> PackedScene:
	_ensure_rocks()
	if prefer_a:
		return _rock_a if _rock_a else _rock_b
	return _rock_b if _rock_b else _rock_a


enum Env { CITY, FOREST, COAST, MOUNTAIN, COUNTRY }

const LENGTH := 40.0
const STEPS := 12  # 3.3 m cross-sections stay smooth on broad grades and keep mesh uploads inside a frame
const RIBBON_STEPS_PER_FRAME := 2
const HALF_WIDTH := 8.0
## Asphalt is one continuous road, even when the surrounding biome changes.
## Keeping this outside the palettes prevents visible colour seams at run edges.
## Dry asphalt reflects about a third of the light that hits it. "3b3b3d" was
## picked back when vertex colour was being read as linear, where it rendered as
## a mid grey; read correctly it is the colour of wet tarmac at dusk, and the road
## came out as a black hole with the landscape glowing on either side of it.
const ROAD_TARMAC := Color("636369")
const DASH_PERIOD := 5.0
const DASH_ON := 2.8
const PROP_ROAD_CLEARANCE := 0.75
## Hard cap on GLB instances per chunk. The Kenney kit is suburban, so it stocks
## the countryside and villages; the city builds its own frontage.
const MAX_IMPORTED_ASSETS_PER_CHUNK := 6
## Real omni lights per chunk. A glowing quad on a pole floats; the pool of light
## it drops on the tarmac is what sells a lit road at dusk. Kept to a hard few and
## faded out at 35 m: this is an integrated-GPU game and clustered lights are the
## first thing to cost frames.
const MAX_LIGHTS_PER_CHUNK := 2

## Restrained HDR colours. With bloom intentionally disabled, extreme values
## clip into hard white pixels in the distance; these retain hue under ACES.
const LAMP_WARM := Color(1.8, 1.18, 0.58)  # sodium street lamp lens
const LAMP_LIGHT := Color(1.0, 0.72, 0.42)  # the omni that matches it
const REFLECTOR := Color(1.55, 0.78, 0.28)  # shoulder marker, amber not white
const GLASS_DARK := Color("161b28")
## Lit windows are never all the same white. Warm flats, cool offices, a few
## blue-white ones — that variety is most of what makes a skyline read.
const WINDOW_LIGHTS: Array[Color] = [
	Color(1.7, 1.25, 0.72),
	Color(1.85, 1.08, 0.58),
	Color(1.42, 1.4, 1.32),
	Color(0.92, 1.34, 1.72),
]
const NEON: Array[Color] = [
	Color(3.0, 0.7, 1.6),
	Color(0.7, 2.2, 2.8),
	Color(3.0, 1.2, 0.5),
	Color(1.2, 2.8, 1.4),
]

## Half of the road cross-section, walked from the centreline outward:
## [lateral, drop below the tarmac, palette key of the band ending here].
## Tarmac and curbs stay flat-shaded; everything keyed "ground" is smooth-shaded
## and finely enough divided that the hills roll instead of folding.
const HALF_PROFILE := [
	[0.0, 0.0, "road"],
	[HALF_WIDTH, 0.0, "road"],
	[HALF_WIDTH, -0.16, "curb"],  # curb inner face
	[8.7, -0.16, "curb"],  # curb top
	[8.7, 0.14, "curb"],  # curb outer face
	[11.5, 0.55, "verge"],
	[14.0, 0.6, "ground"],
	[20.5, 0.4, "ground"],
	[29.0, 0.0, "ground"],
	[47.0, 0.0, "ground"],
	[75.0, 0.0, "ground"],
	[125.0, 0.0, "ground"],
	[195.0, 0.0, "ground"],
	[305.0, 0.0, "ground"],
	[370.0, 0.0, "ground"],
]

## Roadside tree species. One shape — a ball on a stick — at every scale in every
## theme is what made a pine forest, an orchard and a coastal palm grove all read
## as the same green lollipops going past.
enum Flora { BROADLEAF, CONIFER, BIRCH, PALM, BARE, CYPRESS }

## Bark colours. Wood is never the same green-brown twice, and a birch stand is
## recognisable at 200 m purely from the pale trunks.
## Pale bark is deliberately grey rather than white: at 150 m a true birch white
## stops reading as a tree and starts reading as scaffolding stuck in the field.
const BARK := Color("3f3026")
const BARK_PALE := Color("a8a79a")
const BARK_PALM := Color("7d6a4e")
const BARK_DEAD := Color("5f5346")

## Shared instance meshes for the prop MultiMeshes.
static var _unit_cube: ArrayMesh
static var _unit_box_sharp: ArrayMesh
static var _unit_prism: ArrayMesh
static var _unit_sphere: ArrayMesh
static var _unit_trunk: ArrayMesh
static var _unit_crown: ArrayMesh
static var _unit_conifer: ArrayMesh
static var _unit_frond: ArrayMesh
static var _unit_ridge: ArrayMesh
static var _unit_hay_bale: ArrayMesh
static var _unit_bird: ArrayMesh
static var _rotor: ArrayMesh
static var _grass_tuft: ArrayMesh
static var _beacon_material: ShaderMaterial
static var _water_material: ShaderMaterial
static var _water_material_sea: ShaderMaterial
static var _cloud_material: StandardMaterial3D
static var _bird_material: StandardMaterial3D
static var _bands_cache: Array = []
static var _view_bands_left_cache: Array = []
static var _view_bands_right_cache: Array = []

var theme: int = Env.CITY
var chunk_index: int = 0


static func unit_cube() -> ArrayMesh:
	## Lightly chamfered — props and roadside furniture. Not for architecture;
	## heavy bevels turn towers into cans.
	if _unit_cube == null:
		var b := LowPoly.new()
		b.add_rounded_box(Transform3D.IDENTITY, Vector3.ONE, 0.04, Color.WHITE)
		_unit_cube = b.commit()
	return _unit_cube


static func unit_box_sharp() -> ArrayMesh:
	## Near-hard edges for buildings. Reads as concrete slabs, not soft cans.
	if _unit_box_sharp == null:
		var b := LowPoly.new()
		b.add_rounded_box(Transform3D.IDENTITY, Vector3.ONE, 0.012, Color.WHITE)
		_unit_box_sharp = b.commit()
	return _unit_box_sharp


static func unit_cone() -> ArrayMesh:
	## Base on Y=0, apex at Y=1, so scale.y is simply the height. Ten-sided and
	## smooth-shaded: conifers and boulders read round rather than crystalline.
	if _unit_prism == null:
		var b := LowPoly.new()
		b.smooth = true
		b.add_cone(Transform3D.IDENTITY, 0.5, 1.0, 10, Color.WHITE)
		_unit_prism = b.commit()
	return _unit_prism

static func unit_sphere() -> ArrayMesh:
	## Smooth ball of unit diameter — hedges, canopies, roadside growth. Squash it
	## on any axis for free variation; smooth normals are what makes the verge look
	## planted rather than built out of gravel.
	if _unit_sphere == null:
		var b := LowPoly.new()
		b.smooth = true
		b.add_sphere(Transform3D.IDENTITY, 0.5, 9, 6, Color.WHITE)
		_unit_sphere = b.commit()
	return _unit_sphere


static func unit_bird() -> ArrayMesh:
	## V-wing of unit span, nose on -Z so Basis.looking_at() points it along
	## its velocity. Cheap silhouette — raptors and gulls from a kilometre.
	if _unit_bird == null:
		var b := LowPoly.new()
		var c := Color.WHITE
		b.add_tri(Vector3(0.0, 0.0, -0.22), Vector3(-0.5, 0.07, 0.18), Vector3(0.0, 0.0, 0.12), c)
		b.add_tri(Vector3(0.0, 0.0, -0.22), Vector3(0.0, 0.0, 0.12), Vector3(0.5, 0.07, 0.18), c)
		_unit_bird = b.commit()
	return _unit_bird


static func unit_trunk() -> ArrayMesh:
	## Tapered, faceted trunk: root flare of radius 0.5 on Y=0, thin tip at Y=1.
	## Every woody part in the world is this one mesh under a different transform —
	## trunks, boughs, twigs, palm stems — so the whole forest is a single bucket.
	if _unit_trunk == null:
		var b := LowPoly.new()
		const SIDES := 6
		# [height, radius]: a flare at the roots, then a steady taper.
		const RINGS := [[0.0, 0.5], [0.08, 0.35], [0.45, 0.29], [0.8, 0.21], [1.0, 0.12]]
		# Per-side radius scale, shared by every ring, so the trunk is an irregular
		# prism rather than a lathe-turned dowel — the same trick that keeps the
		# rocks from reading as billiard balls.
		const LOBE := [1.12, 0.9, 1.06, 0.88, 1.1, 0.94]
		var ring := func(level: Array) -> Array:
			var points: Array[Vector3] = []
			for i in SIDES:
				var a: float = TAU * float(i) / float(SIDES)
				var r: float = float(level[1]) * LOBE[i]
				points.append(Vector3(cos(a) * r, float(level[0]), sin(a) * r))
			return points
		b.hull_origin = Vector3(0, 0.5, 0)
		for level in RINGS.size() - 1:
			var lower: Array = ring.call(RINGS[level])
			var upper: Array = ring.call(RINGS[level + 1])
			# Roots sit in their own shadow; the crown-side wood catches the sky.
			var shade: float = 0.84 + 0.06 * float(level)
			var band := Color(shade, shade, shade)
			for i in SIDES:
				var j: int = (i + 1) % SIDES
				b.add_hull_quad(lower[i], lower[j], upper[j], upper[i], band)
		var tip: Array = ring.call(RINGS[RINGS.size() - 1])
		for i in SIDES:
			b.add_hull_tri(Vector3(0, 1.0, 0), tip[i], tip[(i + 1) % SIDES], Color(1.02, 1.02, 1.02))
		_unit_trunk = b.commit()
	return _unit_trunk


static func unit_crown() -> ArrayMesh:
	## A whole broadleaf canopy in one mesh: overlapping lobes filling a unit
	## cylinder, base on Y=0. One instance per tree rather than a stack of balls,
	## which is also what makes the wind hinge at the bottom of the canopy instead
	## of halfway up a floating sphere.
	if _unit_crown == null:
		var b := LowPoly.new()
		# Faceted, chunky masses fit the hand-cut landscape. Smooth normals made
		# these read as imported green bubbles beside the low-poly terrain.
		b.smooth = false
		b.channel = LowPoly.FOLIAGE
		# [x, y, z, radius, shade]. Shade is a multiplier on the per-tree instance
		# colour: undersides darker, the sunlit shoulders slightly lifted.
		const LOBES := [
			[0.00, 0.48, 0.00, 0.46, 0.92],
			[0.29, 0.36, 0.08, 0.30, 0.78],
			[-0.25, 0.40, -0.17, 0.32, 0.76],
			[0.08, 0.32, -0.30, 0.28, 0.72],
			[-0.25, 0.62, 0.24, 0.29, 0.96],
			[-0.07, 0.78, 0.12, 0.30, 1.10],
			[0.23, 0.69, -0.15, 0.27, 1.04],
		]
		for lobe in LOBES:
			var shade: float = lobe[4]
			b.add_sphere(
				Transform3D(Basis.IDENTITY.scaled(Vector3(1.0, 0.84, 1.0)), Vector3(lobe[0], lobe[1], lobe[2])),
				lobe[3],
				6,
				3,
				Color(shade, shade, shade)
			)
		_unit_crown = b.commit()
	return _unit_crown


static func unit_conifer() -> ArrayMesh:
	## Spruce: five overlapping skirts, apex at Y=1, widest at the bottom. Kept
	## flat-shaded — the hard edge of each skirt is the whole silhouette, and a
	## smooth-shaded version is just a green traffic cone.
	if _unit_conifer == null:
		var b := LowPoly.new()
		b.channel = LowPoly.FOLIAGE
		# Four uneven bough masses with deliberate gaps and generous overlap, so
		# the tiers blend into one rounded mass rather than stacking into a sharp
		# stepped spike — a well-fed pine, not a Christmas-tree cutout.
		# [base height, radius, height, shade]
		const TIERS := [
			[0.02, 0.52, 0.42, 0.75],
			[0.24, 0.42, 0.40, 0.86],
			[0.47, 0.33, 0.37, 0.98],
			[0.69, 0.22, 0.34, 1.06],
		]
		for i in TIERS.size():
			var tier: Array = TIERS[i]
			var shade: float = tier[3]
			# Nine sides and a twist per tier, so the facets never line up into a
			# single vertical seam down the tree and the cross-section reads round.
			b.add_cone(
				Transform3D(Basis(Vector3.UP, float(i) * 0.63), Vector3(0, tier[0], 0)),
				tier[1],
				tier[2],
				9,
				Color(shade, shade, shade)
			)
		_unit_conifer = b.commit()
	return _unit_conifer


static func unit_ridge() -> ArrayMesh:
	## A soft, rounded swell rather than a rotational cone or a sharp folded
	## crest. The old single-apex tent produced a row of unmistakable pyramids
	## on the skyline; this widens the crest into a flat-topped hump and smooth-
	## shades it, so a whole range of these reads as English downland rolling
	## into the distance instead of a saw blade of peaks.
	if _unit_ridge == null:
		var b := LowPoly.new()
		b.smooth = true
		b.hull_origin = Vector3(0.0, 0.22, 0.0)
		const FRONT := [
			Vector3(-0.55, 0.0, -0.30), Vector3(-0.34, 0.40, -0.20), Vector3(-0.10, 0.62, -0.12),
			Vector3(0.16, 0.60, -0.12), Vector3(0.40, 0.32, -0.17), Vector3(0.55, 0.0, -0.30)
		]
		const BACK := [
			Vector3(-0.55, 0.0, 0.30), Vector3(-0.34, 0.40, 0.20), Vector3(-0.10, 0.62, 0.12),
			Vector3(0.16, 0.60, 0.12), Vector3(0.40, 0.32, 0.17), Vector3(0.55, 0.0, 0.30)
		]
		var base_col := Color(0.64, 0.68, 0.60)
		var top_col := Color(0.90, 0.90, 0.86)
		for i in FRONT.size() - 1:
			var t: float = (float(i) + 0.5) / float(FRONT.size() - 1)
			b.add_hull_quad(FRONT[i], FRONT[i + 1], BACK[i + 1], BACK[i], base_col.lerp(top_col, t))
		# Fan each broad face from its baseline. The value difference paints in the
		# raking-light separation without another shadow render pass.
		var front_col := base_col.lerp(top_col, 0.55).darkened(0.08)
		var back_col := base_col.lerp(top_col, 0.55).darkened(0.22)
		for i in range(1, FRONT.size() - 1):
			b.add_hull_tri(FRONT[0], FRONT[i], FRONT[i + 1], front_col)
			b.add_hull_tri(BACK[0], BACK[i + 1], BACK[i], back_col)
		b.add_hull_quad(FRONT[0], BACK[0], BACK[FRONT.size() - 1], FRONT[FRONT.size() - 1], base_col.darkened(0.15))
		_unit_ridge = b.commit()
	return _unit_ridge


static func unit_frond() -> ArrayMesh:
	## One palm leaf: spine along +X from the origin, arcing up and then drooping,
	## with the blade folded into a shallow V so it never reads as a flat card.
	## Both windings, like the grass, so a frond is lit from either side.
	if _unit_frond == null:
		var b := LowPoly.new()
		b.channel = LowPoly.FOLIAGE
		const SEGS := 5
		var spine := func(t: float) -> Vector3: return Vector3(t, 0.34 * t - 0.86 * t * t, 0.0)
		var blade := func(t: float) -> float: return 0.16 * sin(PI * t) * (1.0 - 0.4 * t) + 0.012
		for i in SEGS:
			var t0 := float(i) / float(SEGS)
			var t1 := float(i + 1) / float(SEGS)
			var p0: Vector3 = spine.call(t0)
			var p1: Vector3 = spine.call(t1)
			var w0: float = blade.call(t0)
			var w1: float = blade.call(t1)
			var shade: float = 1.06 - 0.2 * t1
			var color := Color(shade, shade, shade)
			for side in [-1.0, 1.0]:
				var e0: Vector3 = p0 + Vector3(0.0, -0.32 * w0, side * w0)
				var e1: Vector3 = p1 + Vector3(0.0, -0.32 * w1, side * w1)
				b.add_quad(p0, p1, e1, e0, color)
				b.add_quad(e0, e1, p1, p0, color)
		_unit_frond = b.commit()
	return _unit_frond


static func grass_tuft() -> ArrayMesh:
	## A few crossed blades on a unit footprint. Two-sided, since a blade is one
	## quad and half of them would otherwise vanish depending on which way the
	## road turned. Instanced by the thousand, so it stays at eight triangles.
	if _grass_tuft == null:
		var b := LowPoly.new()
		b.channel = LowPoly.FOLIAGE
		var rng := RandomNumberGenerator.new()
		rng.seed = 0x6A55
		for i in 4:
			var yaw := TAU * float(i) / 4.0 + rng.randf_range(-0.3, 0.3)
			var dir := Vector3(cos(yaw), 0.0, sin(yaw))
			var side := Vector3(-dir.z, 0.0, dir.x) * rng.randf_range(0.05, 0.085)
			var lean := dir * rng.randf_range(0.10, 0.26)
			var tall := rng.randf_range(0.62, 1.0)
			# Tapered blade: wide at the root, meeting at a tip.
			b.add_tri(-side, side, Vector3(0, tall, 0) + lean, Color.WHITE)
			b.add_tri(side, -side, Vector3(0, tall, 0) + lean, Color.WHITE)
		_grass_tuft = b.commit()
	return _grass_tuft


static func unit_hay_bale() -> ArrayMesh:
	## A round bale on its side: a squat cylinder with two darker binder-twine
	## bands let into the body near each end. The old hay prop was a plain box,
	## which read as a straw-coloured crate rather than anything grown in a
	## field — this is instanced lying down, axis along local Y, radius and
	## length both 1 so a single instance transform sets both.
	if _unit_hay_bale == null:
		var b := LowPoly.new()
		b.add_cylinder(Transform3D.IDENTITY, 0.5, 1.0, 10, Color(1.0, 1.0, 1.0))
		for band_y in [-0.3, 0.3]:
			b.add_cylinder(
				Transform3D(Basis.IDENTITY, Vector3(0, band_y, 0)), 0.505, 0.07, 10, Color(0.66, 0.6, 0.42)
			)
		_unit_hay_bale = b.commit()
	return _unit_hay_bale


static func rotor_mesh() -> ArrayMesh:
	## Three blades and a hub, spinning about local Z. Shared by every turbine in
	## the world; only the node transform differs.
	if _rotor == null:
		var b := LowPoly.new()
		var lie := Basis.from_euler(Vector3(PI * 0.5, 0.0, 0.0))  # cylinder axis Y -> Z
		b.add_cylinder(Transform3D(lie, Vector3.ZERO), 0.62, 1.30, 10, Color("dfe3e8"))
		b.add_sphere(Transform3D(Basis.IDENTITY, Vector3(0, 0, 0.72)), 0.52, 9, 5, Color("eef1f4"))
		for i in 3:
			var spin := Basis(Vector3.BACK, TAU * float(i) / 3.0)
			b.add_rounded_box(
				Transform3D(spin, spin * Vector3(0.0, 6.3, 0.0)),
				Vector3(0.62, 11.4, 0.20),
				0.09,
				Color("f2f4f7")
			)
		_rotor = b.commit()
	return _rotor


static func beacon_material() -> ShaderMaterial:
	if _beacon_material == null:
		_beacon_material = ShaderMaterial.new()
		_beacon_material.shader = BEACON_SHADER
	return _beacon_material


static func water_material() -> ShaderMaterial:
	if _water_material == null:
		_water_material = ShaderMaterial.new()
		_water_material.shader = WATER_SHADER
	return _water_material


static func water_material_sea() -> ShaderMaterial:
	## Same shader, quieter waves. The lake mesh is a few dozen metres across; the
	## coast sheet is kilometres, and the same 18 cm chop reads as corduroy.
	if _water_material_sea == null:
		_water_material_sea = ShaderMaterial.new()
		_water_material_sea.shader = WATER_SHADER
		_water_material_sea.set_shader_parameter("wave_height", 0.012)
		_water_material_sea.set_shader_parameter("wave_speed", 0.18)
		_water_material_sea.set_shader_parameter("wave_scale", 0.22)
		_water_material_sea.set_shader_parameter("shimmer_amount", 0.18)
	return _water_material_sea


static func cloud_material() -> StandardMaterial3D:
	## Soft peak-wrapping puffs. Unshaded so dusk paints them the same way as the
	## sky deck; no depth write so overlapping ellipsoids blend instead of cutting
	## holes in each other.
	if _cloud_material == null:
		_cloud_material = StandardMaterial3D.new()
		_cloud_material.vertex_color_use_as_albedo = true
		_cloud_material.vertex_color_is_srgb = true
		_cloud_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_cloud_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_cloud_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		_cloud_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		_cloud_material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return _cloud_material


static func bird_material() -> StandardMaterial3D:
	if _bird_material == null:
		_bird_material = StandardMaterial3D.new()
		_bird_material.vertex_color_use_as_albedo = true
		_bird_material.vertex_color_is_srgb = true
		_bird_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_bird_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		_bird_material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return _bird_material


static func warm_shared_resources() -> void:
	## Fill every static mesh/material/asset cache once, up front.
	##
	## `_build_theme_scenery()` runs synchronously for the chunk under the bike —
	## on first load from `bind_player()`, and on every restart from
	## `reset_world()` (a new seed frees the whole ring, so the first chunk rebuilt
	## afterwards is routinely the first user of a cache nothing had touched yet).
	## That first-use lazy init — SurfaceTool building the unit meshes, `load()`
	## pulling the two rock GLBs, `ShaderMaterial` creation — measured ~48 ms cold
	## versus ~5 ms warm, which is the intermittent restart spike test_restart sees.
	##
	## This is deliberately static and side-effect-free: it allocates no node,
	## joins no tree, and draws nothing from `_rng` or the world seed, so it cannot
	## disturb streaming state. Call it during scene load, before the first chunk
	## is built. (An earlier attempt to warm from `RoadStreamer._ready()` left the
	## world empty; do the warming from plain static factories, not there.)
	unit_cube()
	unit_box_sharp()
	unit_cone()
	unit_sphere()
	unit_trunk()
	unit_crown()
	unit_conifer()
	unit_ridge()
	unit_frond()
	grass_tuft()
	unit_hay_bale()
	unit_bird()
	rotor_mesh()
	beacon_material()
	water_material()
	water_material_sea()
	cloud_material()
	bird_material()
	_ensure_rocks()
	_bands()
	# The shared LowPoly channels — two of them (road, foliage) are ShaderMaterials
	# whose creation is part of the same cold init.
	LowPoly.solid_material()
	LowPoly.glow_material()
	LowPoly.road_material()
	LowPoly.terrain_material()
	LowPoly.metal_material()
	LowPoly.paint_material()
	LowPoly.foliage_material()
	LowPoly.mirror_material()


var _rng := RandomNumberGenerator.new()
var _path: Node
var _origin: Vector3
var _pal: Dictionary
var _cubes: Array[Transform3D] = []
var _cube_cols: Array[Color] = []
var _arch: Array[Transform3D] = []
var _arch_cols: Array[Color] = []
var _prisms: Array[Transform3D] = []
var _prism_cols: Array[Color] = []
var _lamps: Array[Transform3D] = []
var _lamp_cols: Array[Color] = []
var _blobs: Array[Transform3D] = []
var _blob_cols: Array[Color] = []
var _leaves: Array[Transform3D] = []
var _leaf_cols: Array[Color] = []
var _trunks: Array[Transform3D] = []
var _trunk_cols: Array[Color] = []
var _crowns: Array[Transform3D] = []
var _crown_cols: Array[Color] = []
var _conifers: Array[Transform3D] = []
var _conifer_cols: Array[Color] = []
var _fronds: Array[Transform3D] = []
var _frond_cols: Array[Color] = []
var _ridges: Array[Transform3D] = []
var _ridge_cols: Array[Color] = []
var _grass: Array[Transform3D] = []
var _grass_cols: Array[Color] = []
var _hay: Array[Transform3D] = []
var _hay_cols: Array[Color] = []
var _clouds: Array[Transform3D] = []
var _cloud_cols: Array[Color] = []
var _birds: Array[Transform3D] = []
var _bird_cols: Array[Color] = []
var _cloud_mm: MultiMesh
var _cloud_rest: Array[Transform3D] = []
var _bird_mm: MultiMesh
var _bird_orbit: Array[Vector3] = []
var _bird_radius: PackedFloat32Array = PackedFloat32Array()
var _bird_speed: PackedFloat32Array = PackedFloat32Array()
var _bird_phase: PackedFloat32Array = PackedFloat32Array()
var _bird_amp: PackedFloat32Array = PackedFloat32Array()
var _bird_span: PackedFloat32Array = PackedFloat32Array()
var _light_count: int = 0
var _asset_count: int = 0
## One shared ground anchor for every box in a procedural city building. Without
## it, windows and roofs sample different terrain and visibly detach on hills.
var _structure_foundation_y: float = 0.0
var _structure_active: bool = false
## Temporary build caches. A ribbon asks for the same road sample hundreds of
## times; retaining these only while it is built avoids repeated trig without
## keeping a large per-chunk dictionary alive during play.
var _road_samples: Dictionary = {}
var _point_samples: Dictionary = {}
## Overlook this chunk overlaps, resolved once in _configure(). Every chunk in
## the world would otherwise pay the deck and basin queries per ribbon vertex.
var _vp_centre: float = 0.0
var _vp_side: float = 0.0
var _vp_water_y: float = 0.0
## Deterministic per-overlook phase for the landscape's shaping sines. Derived
## from the centre and the world seed rather than from `_rng`, because every
## chunk across the basin has to agree on the same shoreline and skyline — an
## RNG draw would give each of the twenty chunks a different one.
var _vp_phase: float = 0.0
var _on_spur: bool = false
var _on_lake: bool = false
var _owns_platform: bool = false
var _vp_theme: int = Env.COUNTRY


func setup(index: int, theme_id: int) -> void:
	_configure(index, theme_id)
	_build_ribbon()
	_build_props()


func setup_incremental(index: int, theme_id: int) -> void:
	## Runtime streaming must not consume an entire render frame. The chunk is far
	## beyond the camera when queued, so build its ribbon in small invisible slices.
	_configure(index, theme_id)
	var builders := _new_ribbon_builders()
	var hard: LowPoly = builders[0]
	var road: LowPoly = builders[1]
	var soft_left: LowPoly = builders[2]
	var soft_right: LowPoly = builders[3]
	var z0: float = float(chunk_index) * LENGTH
	for first_step in range(0, STEPS, RIBBON_STEPS_PER_FRAME):
		_build_ribbon_rows(hard, road, soft_left, soft_right, z0, first_step, mini(first_step + RIBBON_STEPS_PER_FRAME, STEPS))
		if not await _keep_streaming():
			return
	await _finish_ribbon_incremental(hard, road, soft_left, soft_right, z0)
	if not await _keep_streaming():
		return
	await _build_props_incremental()


func _build_props_incremental() -> void:
	## The prop half of a streamed chunk, split across frames. These are the same
	## stages `_build_props()` runs in one frame, spelled out here with an
	## `_keep_streaming()` yield between each so none costs a visible frame.
	await _build_furniture_incremental()
	if not await _keep_streaming():
		return
	_build_theme_scenery()
	if not await _keep_streaming():
		return
	_build_distant_scenery()
	if not await _keep_streaming():
		return
	# Split across frames: the overlook landscape is the heaviest single thing a
	# chunk builds, and the whole point of the incremental path is that nothing in
	# it costs a visible frame. The stages are the same three calls the immediate
	# path makes — spelling the individual builders out here a second time is how
	# the islands and the far settlement came to exist everywhere except in the
	# running game, which streams every chunk through this function.
	if _on_lake:
		_build_lake_basin()
		if not await _keep_streaming():
			return
		_build_lake_distance()
		if not await _keep_streaming():
			return
		_build_lake_dressing()
		if not await _keep_streaming():
			return
	_build_set_piece()
	await _commit_props_incremental()


func _keep_streaming() -> bool:
	## Restart frees this chunk mid-build. Stop rather than finishing a lake
	## mesh into a world the bike has already left.
	if not is_instance_valid(self) or not is_inside_tree():
		return false
	await get_tree().process_frame
	return is_instance_valid(self) and is_inside_tree()


func _configure(index: int, theme_id: int) -> void:
	chunk_index = index
	theme = theme_id
	_path = get_node("/root/RoadPath")
	_rng.seed = hash(Vector3i(index, theme_id, int(_path.world_seed)))
	_pal = palette(theme)
	_origin = _path.center_at(float(index) * LENGTH)
	position = _origin
	set_process(false)
	_cloud_mm = null
	_cloud_rest.clear()
	_bird_mm = null
	_bird_orbit.clear()
	_bird_radius = PackedFloat32Array()
	_bird_speed = PackedFloat32Array()
	_bird_phase = PackedFloat32Array()
	_bird_amp = PackedFloat32Array()
	_bird_span = PackedFloat32Array()
	_resolve_viewpoint()


func _resolve_viewpoint() -> void:
	## Which parts of the overlook this chunk has to build, resolved once. Every
	## chunk in the world would otherwise pay the spur and basin queries per
	## ribbon vertex.
	var z0 := float(chunk_index) * LENGTH
	_vp_centre = float(_path.viewpoint_centre_for(z0 + LENGTH * 0.5))
	_vp_side = float(_path.viewpoint_side_for(_vp_centre))
	# Gap from the *near edge* of the chunk: a chunk 39 m outside the span still
	# has spur in it.
	var gap: float = maxf(absf(z0 + LENGTH * 0.5 - _vp_centre) - LENGTH * 0.5, 0.0)
	_on_spur = gap <= RoadPathGD.SPUR_HALF_SPAN
	_on_lake = gap <= RoadPathGD.LAKE_SPAN + 70.0
	_owns_platform = int(_path.viewpoint_index_for(_vp_centre)) == chunk_index
	# The basin dresses as the centre's biome even if a spur kisses a region edge.
	_vp_theme = int(_path.theme_for_chunk(int(_path.viewpoint_index_for(_vp_centre))))
	if _owns_platform:
		_vp_theme = theme
	_vp_phase = (
		float(posmod(hash(Vector2i(int(round(_vp_centre)), int(_path.world_seed))), 1000)) * 0.00628
	)
	if _on_lake:
		_vp_water_y = float(_path.viewpoint_water_y(_vp_centre))


func _build_props() -> void:
	_build_furniture()
	_build_theme_scenery()
	_build_distant_scenery()
	_build_viewpoint_landscape()
	_build_set_piece()
	_commit_props()


func _build_theme_scenery() -> void:
	# Scenic access is its own biome: a close, layered forest tunnel that screens
	# the highway, then opens just before the destination. It is authored here
	# because lake chunks intentionally skip the ordinary countryside scatter.
	if _on_spur:
		_build_spur_woodland()
	# The overlook has its own authored planting, far shore and range.
	# Layering a complete random biome over it both muddies the composition and
	# makes every scenic chunk generate hundreds of transforms it never needs.
	if _on_lake:
		return
	match theme:
		Env.CITY:
			_scenery_city()
		Env.FOREST:
			_scenery_forest()
		Env.COAST:
			_scenery_coast()
		Env.MOUNTAIN:
			_scenery_mountain()
		Env.COUNTRY:
			_scenery_country()


func _build_spur_woodland() -> void:
	## Planting along the climb. The spur geometry is the same everywhere; what
	## grows beside it follows the biome of this stretch, so a coastal headland
	## is not ridden through a pine tunnel.
	var z0: float = float(chunk_index) * LENGTH
	for station in 5:
		var z: float = z0 + 3.2 + float(station) * 7.4
		if z >= z0 + LENGTH:
			continue
		var distance: float = absf(z - _vp_centre)
		var divergence: float = float(_path.spur_divergence(z))
		var half: float = float(_path.spur_half_width(z))
		var reveal: float = smoothstep(
			RoadPathGD.PLATFORM_HALF_LENGTH + 90.0,
			RoadPathGD.PLATFORM_HALF_LENGTH + 260.0,
			distance
		)
		if divergence < 0.08 or half < 2.8 or reveal < 0.08:
			continue
		var towards_summit: float = 1.0 - clampf((distance - 80.0) / 1100.0, 0.0, 1.0)
		for road_side in [-1.0, 1.0]:
			for row in 2:
				var jitter_z: float = z + _rng.randf_range(-2.0, 2.0)
				# Sample the spur at the plant point, not the station. The apron
				# widens through the taper; a setback computed 2 m uphill lands
				# in the middle of the wider tarmac.
				var plant_half: float = float(_path.spur_half_width(jitter_z))
				var plant_centre: float = _vp_side * float(_path.spur_offset(jitter_z))
				var setback: float = plant_half + RoadPathGD.SPUR_SHOULDER + 2.8 + float(row) * 7.2
				var lateral: float = plant_centre + road_side * (setback + _rng.randf_range(-0.8, 1.1))
				if _on_tarmac(jitter_z, lateral, 1.4):
					continue
				match _vp_theme:
					Env.COAST:
						var s := _rng.randf_range(1.4, 3.2)
						_blob(
							jitter_z,
							lateral,
							Vector3(s * 1.8, s * 0.7, s * 1.5),
							Color("8a8070").lerp(Color("6a6458"), _rng.randf()),
							0.0,
							false,
							true
						)
						if row == 0 and _rng.randf() < 0.28:
							_tree(
								Flora.CYPRESS if _rng.randf() < 0.55 else Flora.PALM,
								jitter_z,
								lateral,
								_rng.randf_range(5.5, 9.0) * reveal,
								Color("3a5c44").darkened(_rng.randf() * 0.2),
								true
							)
					Env.MOUNTAIN:
						var height: float = _rng.randf_range(8.0, 14.0) * lerpf(0.70, 1.0, reveal)
						var species: int = Flora.CONIFER if _rng.randf() < 0.78 + towards_summit * 0.15 else Flora.BARE
						_tree(species, jitter_z, lateral, height, Color("1c3028").lerp(Color("3a4638"), _rng.randf() * 0.3), true)
						if _rng.randf() < 0.4:
							var rock_s := _rng.randf_range(1.2, 2.8)
							_blob(
								jitter_z,
								lateral + road_side * _rng.randf_range(1.0, 3.0),
								Vector3(rock_s * 1.6, rock_s * 0.9, rock_s * 1.4),
								Color("6a6458").darkened(_rng.randf() * 0.2),
								0.0,
								false,
								true
							)
					_:
						var height: float = _rng.randf_range(11.0, 17.5) * lerpf(0.70, 1.0, reveal)
						if _vp_theme == Env.FOREST:
							height *= 1.08
						var tint: Color = Color("243e2c").lerp(Color("3f5c38"), _rng.randf() * 0.42)
						var conifer_odds := 0.22 + towards_summit * 0.55
						if _vp_theme == Env.FOREST:
							conifer_odds = 0.42 + towards_summit * 0.35
						var species: int = Flora.CONIFER if _rng.randf() < conifer_odds else Flora.BROADLEAF
						_tree(species, jitter_z, lateral, height, tint.darkened(float(row) * 0.14), true)
			if _vp_theme == Env.COAST:
				continue
			var under_z: float = z + _rng.randf_range(-2.6, 2.6)
			var under_half: float = float(_path.spur_half_width(under_z))
			var under_centre: float = _vp_side * float(_path.spur_offset(under_z))
			var under_lateral: float = under_centre + road_side * (
				under_half + RoadPathGD.SPUR_SHOULDER + _rng.randf_range(4.6, 7.6)
			)
			if _on_tarmac(under_z, under_lateral, 1.4):
				continue
			var under_species: int = Flora.CONIFER if _vp_theme == Env.MOUNTAIN else (Flora.BIRCH if _rng.randf() < 0.48 else Flora.BROADLEAF)
			_tree(
				under_species,
				under_z,
				under_lateral,
				_rng.randf_range(4.6, 7.4) * reveal,
				Color("4e6844").darkened(_rng.randf() * 0.2),
				true
			)
			var bush_z: float = z + _rng.randf_range(-3.0, 3.0)
			var bush_half: float = float(_path.spur_half_width(bush_z))
			var bush_centre: float = _vp_side * float(_path.spur_offset(bush_z))
			var bush_lateral: float = bush_centre + road_side * (
				bush_half + RoadPathGD.SPUR_SHOULDER + _rng.randf_range(2.4, 5.2)
			)
			if not _on_tarmac(bush_z, bush_lateral, 1.2):
				_blob(
					bush_z,
					bush_lateral,
					Vector3(_rng.randf_range(2.0, 3.8), _rng.randf_range(0.9, 2.0), _rng.randf_range(1.8, 3.4)),
					Color("1c3628").lightened(_rng.randf() * 0.1),
					0.0,
					true,
					true
				)
			if _rng.randf() < 0.45:
				var rock_z: float = z + _rng.randf_range(-2.0, 2.0)
				var rock_half: float = float(_path.spur_half_width(rock_z))
				var rock_centre: float = _vp_side * float(_path.spur_offset(rock_z))
				var rock_lateral: float = rock_centre + road_side * (
					rock_half + RoadPathGD.SPUR_SHOULDER + _rng.randf_range(1.6, 3.4)
				)
				if not _on_tarmac(rock_z, rock_lateral, 1.2):
					_blob(
						rock_z,
						rock_lateral,
						Vector3(_rng.randf_range(0.9, 1.8), _rng.randf_range(0.5, 1.1), _rng.randf_range(0.8, 1.6)),
						Color("5a5348").darkened(_rng.randf() * 0.16),
						0.0,
						false,
						true
					)


func _p(z: float, lateral: float, drop: float) -> Vector3:
	var point_key := Vector3(z, lateral, drop)
	if _point_samples.has(point_key):
		return _point_samples[point_key]
	var sample: Array
	if _road_samples.has(z):
		sample = _road_samples[z]
	else:
		var flat: Basis = _path.frame_flat_at(z)
		sample = [_path.center_at(z), flat.x, flat.y, _path.bank_at(z)]
		_road_samples[z] = sample
	var bank_taper: float = 1.0 - smoothstep(HALF_WIDTH, HALF_WIDTH + 6.0, absf(lateral))
	var bank_height: float = lateral * tan(float(sample[3])) * bank_taper
	# The spur road and the ground it is built on ride above the carriageway
	# plane; everything else in the chunk sits on it.
	var lift: float = float(_path.spur_lift(z, lateral)) if _on_spur else 0.0
	var point: Vector3 = (
		(sample[0] as Vector3)
		+ (sample[1] as Vector3) * lateral
		+ (sample[2] as Vector3) * (bank_height + lift - _path.terrain_drop(lateral, z) - drop)
		- _origin
	)
	_point_samples[point_key] = point
	return point


# ---------------------------------------------------------------- road ribbon


func _ground_color(lateral: float, z: float) -> Color:
	## Smooth function of position, sampled per vertex — a per-quad colour would
	## stop index() merging vertices and smooth shading would never kick in.
	var mix: float = 0.5 + 0.5 * sin(lateral * 0.055 + z * 0.038) * sin(lateral * 0.017 - z * 0.021)
	var color: Color = (_pal["ground"] as Color).lerp(_pal["ground_alt"], mix * 0.9)
	if _on_spur:
		color = color.lerp(_deck_color(z, lateral), _deck_mix(z, lateral))
		color = color.lerp(_terrace_color(), _terrace_mix(z, lateral))
	if _on_lake:
		color = color.lerp(_face_color(), _face_mix(z, lateral))
		color = color.lerp(_shore_color(), _shore_mix(z, lateral))
	return color


func _face_mix(z: float, lateral: float) -> float:
	## Rock on the steep part of the headland face.
	##
	## This is the one piece of ground in the game a player is invited to stop and
	## look at, and twenty-seven metres of drop painted in a single flat green
	## reads as a wall rather than as a hillside. Grass does not hold on the top
	## third of a slope this steep in any case.
	##
	## `_on_lake` first, for the reason `_resolve_viewpoint` exists at all. Every
	## chunk in the world runs this once per ribbon vertex, and without the guard
	## the outer half of every ordinary verge in the game — where `out` clears the
	## headland crest — went on to ask the path for a near-shore distance that
	## only means anything at an overlook.
	if not _on_lake:
		return 0.0
	if lateral * _vp_side <= 0.0:
		return 0.0
	var out := absf(lateral)
	var top := RoadPathGD.HEADLAND_CREST - 6.0
	if out < top:
		return 0.0
	var near: float = float(_path.viewpoint_near_shore(z))
	if out > near:
		return 0.0
	var t: float = (out - top) / maxf(near - top, 1.0)
	# Strongest just under the lip and carried all the way to the waterline.
	#
	# It used to fade out by the middle of the face, on the theory that the scree
	# at the foot takes over from there — but the scree is scattered stones, not a
	# surface, and what showed between them was the theme's ordinary ground colour.
	# On mountain that is a dark grey-green, on a bank steep enough to catch
	# neither the low key nor the overhead fill, and the bottom quarter of the
	# seated frame came out as an unlit void with a few reeds floating in it.
	var band: float = smoothstep(0.0, 0.18, t) * (1.0 - smoothstep(0.86, 1.0, t))
	# Broken along the route as well as down the slope, so it comes out as
	# outcrop and gully instead of a stripe painted round the headland.
	var grain: float = 0.5 + 0.5 * sin(z * 0.058 + out * 0.047) * sin(z * 0.019 - out * 0.021)
	return band * (0.3 + 0.7 * grain)


func _face_color() -> Color:
	## Stone, from the same family as the range across the water, so the headland
	## reads as belonging to the same country as its own skyline. Tinting the
	## theme's foliage colour toward grey instead just gives greyish grass.
	match theme:
		Env.MOUNTAIN:
			return Color("7c828a")
		Env.COAST:
			return Color("a2977f")
		Env.FOREST:
			return Color("74705f")
	return Color("8d8470")


func _deck_mix(z: float, lateral: float) -> float:
	## Gravel is what a road is *edged* with, not what a hillside is paved in.
	##
	## This used to follow the whole geometric deck blend, so every square metre
	## of made ground — thirty metres of embankment either side of the spur, plus
	## the whole platform skirt — came out the colour of a car park. That pale
	## apron, mottled by the grain below, is the patchwork the approach to the
	## overlook was covered in. Now it is a shoulder: a couple of metres of
	## surfacing beside the tarmac, and graded grass past that.
	if not _on_spur:
		return 0.0
	var deck: float = float(_path.spur_deck_blend(z, lateral))
	if deck <= 0.0:
		return 0.0
	var out: float = absf(absf(lateral) - float(_path.spur_offset(z))) - float(_path.spur_half_width(z))
	return smoothstep(0.18, 0.75, deck) * (1.0 - smoothstep(RoadPathGD.SPUR_SHOULDER, RoadPathGD.SPUR_SHOULDER + 2.6, out))


func _terrace_mix(z: float, lateral: float) -> float:
	## Limestone paving on the view-side terrace. Without this the made ground
	## past the shoulder stays hillside grass, and a grass shelf over a drop is
	## what made the benches look like they were hovering over the lake.
	if not _on_spur:
		return 0.0
	if float(_path.platform_blend(z)) <= 0.0:
		return 0.0
	if lateral * _vp_side <= 0.0:
		return 0.0
	var deck: float = float(_path.spur_deck_blend(z, lateral))
	if deck <= 0.2:
		return 0.0
	var out: float = absf(absf(lateral) - float(_path.spur_offset(z))) - float(_path.spur_half_width(z))
	return (
		float(_path.platform_blend(z))
		* deck
		* smoothstep(0.15, 0.9, out)
		* (1.0 - smoothstep(RoadPathGD.PLATFORM_TERRACE + 0.4, RoadPathGD.PLATFORM_TERRACE + 1.6, out))
	)


func _terrace_color() -> Color:
	## Weathered dark stone, not pale limestone. This paving is the closest ground
	## to the eye and runs the full width of the bottom of the frame, so at the
	## old value it was the brightest object in a picture of a lake and a range of
	## mountains — a bar of light across the foreground pulling the eye straight
	## down out of the view. Foreground reads as foreground by being darker than
	## what it frames, not by being lit.
	return Color("574f45")


func _deck_color(z: float, lateral: float) -> Color:
	## Compacted gravel in the theme's own shoulder colour. The grain is long and
	## shallow on purpose: at a couple of metres of wavelength it read as damage
	## to the road rather than as texture on the ground beside it.
	var grain: float = 0.5 + 0.5 * sin(lateral * 0.11 + z * 0.055) * sin(lateral * 0.043 - z * 0.026)
	# Dark enough to sit under the view rather than in front of it: this surfacing
	# is the nearest thing to a parked rider and fills the bottom of the frame, so
	# at anything lighter it is the brightest object in a picture of a lake.
	return (_pal["shoulder"] as Color).darkened(0.24 + grain * 0.08)


func _shore_mix(z: float, lateral: float) -> float:
	## Pale shingle in the first few metres above the waterline, on both shores.
	## Terrain and water meet in a line the depth buffer draws for free; this is
	## what stops that line looking like grass clipped off with a razor.
	if lateral * _vp_side <= 0.0 or absf(lateral) < RoadPathGD.HEADLAND_CREST:
		return 0.0
	# Height above the water without building a transform: past the bank taper
	# the terrain is simply the centreline height less its drop.
	var here: float = float(_path.height_at(z)) - float(_path.terrain_drop(lateral, z)) - _vp_water_y
	if here > 1.7:
		return 0.0
	return 1.0 - smoothstep(0.1, 1.7, here)


func _shore_color() -> Color:
	## Damp shingle. Barely lifted off the shoulder colour: at +0.22 the waterline
	## drew a bright band right around the basin, and a hard pale line where land
	## meets water is the one thing that makes a lake look like a texture rather
	## than like a body of water sitting in a valley.
	return (_pal["shoulder"] as Color).lightened(0.08)


static var _road_mat_configured := false


func _road_material() -> ShaderMaterial:
	## The tarmac shader places wheel tracks and seams in road space, so it needs
	## the same lane geometry the path drives on. Pushed once — every chunk shares
	## the one material.
	var mat: ShaderMaterial = LowPoly.road_material()
	if not _road_mat_configured:
		_road_mat_configured = true
		mat.set_shader_parameter("lane_width", HALF_WIDTH * 2.0 / float(_path.LANE_COUNT))
		mat.set_shader_parameter("half_width", HALF_WIDTH)
	return mat


func _build_ribbon() -> void:
	var builders := _new_ribbon_builders()
	var hard: LowPoly = builders[0]
	var road: LowPoly = builders[1]
	var soft_left: LowPoly = builders[2]
	var soft_right: LowPoly = builders[3]
	var z0: float = float(chunk_index) * LENGTH
	_build_ribbon_rows(hard, road, soft_left, soft_right, z0, 0, STEPS)
	_finish_ribbon(hard, road, soft_left, soft_right, z0)


func _new_ribbon_builders() -> Array[LowPoly]:
	var hard := LowPoly.new()  # curbs and markings — crisp edges
	# Keep the tarmac flat shaded.  The ribbon is intentionally made from broad
	# quads; averaging their normals made each triangle catch a different dusk
	# highlight and produced the pale triangular patches visible from the cockpit.
	var road := LowPoly.new()  # tarmac — crisp, original-style road surface
	var soft_left := LowPoly.new()  # terrain — averaged normals so the hills roll
	var soft_right := LowPoly.new()
	soft_left.smooth = true
	soft_right.smooth = true
	return [hard, road, soft_left, soft_right]


func _build_ribbon_rows(
	hard: LowPoly,
	road: LowPoly,
	soft_left: LowPoly,
	soft_right: LowPoly,
	z0: float,
	first_step: int,
	end_step: int
) -> void:
	var step := LENGTH / float(STEPS)
	var bands := _view_bands()

	for i in range(first_step, end_step):
		var za := z0 + float(i) * step
		var zb := za + step
		for band in bands:
			var l0: float = band[0]
			var d0: float = band[1]
			var l1: float = band[2]
			var d1: float = band[3]
			var pa := _p(za, l0, _band_drop(za, l0, d0))
			var pb := _p(za, l1, _band_drop(za, l1, d1))
			var pc := _p(zb, l1, _band_drop(zb, l1, d1))
			var pd := _p(zb, l0, _band_drop(zb, l0, d0))
			if band[4] == "road":
				# UV is road space: lateral metres, then metres along the route.
				road.add_quad_uv(
					pa,
					pb,
					pc,
					pd,
					_pal["road"],
					Vector2(l0, za),
					Vector2(l1, za),
					Vector2(l1, zb),
					Vector2(l0, zb)
				)
			elif band[4] == "ground":
				var soft := soft_left if (l0 + l1) < 0.0 else soft_right
				soft.add_quad_shaded(
					pa,
					pb,
					pc,
					pd,
					_ground_color(l0, za),
					_ground_color(l1, za),
					_ground_color(l1, zb),
					_ground_color(l0, zb)
				)
			else:
				var band_color: Color = _pal[band[4]]
				if _on_spur:
					# Curb and verge bands turn into made ground where the spur
					# road crosses the carriageway's profile at a junction.
					band_color = band_color.lerp(
						_deck_color((za + zb) * 0.5, (l0 + l1) * 0.5),
						_deck_mix((za + zb) * 0.5, (l0 + l1) * 0.5)
					)
				hard.add_quad(pa, pb, pc, pd, band_color)



func _finish_ribbon(
	hard: LowPoly, road: LowPoly, soft_left: LowPoly, soft_right: LowPoly, z0: float
) -> void:
	_prepare_ribbon(hard, road, z0)
	_commit_hard_ribbon(hard)
	_commit_road_ribbon(road)
	_commit_terrain_ribbon(soft_left, "Terrain")
	_commit_terrain_ribbon(soft_right, "TerrainRight")
	_clear_ribbon_samples()


func _finish_ribbon_incremental(
	hard: LowPoly, road: LowPoly, soft_left: LowPoly, soft_right: LowPoly, z0: float
) -> void:
	## ArrayMesh creation uploads geometry to the renderer. Publishing all three
	## unique surfaces in one frame caused the remaining one-hitch-per-chunk spike,
	## even though their CPU-side vertices were already built incrementally.
	_prepare_ribbon(hard, road, z0)
	_commit_hard_ribbon(hard)
	await get_tree().process_frame
	_commit_road_ribbon(road)
	await get_tree().process_frame
	_commit_terrain_ribbon(soft_left, "Terrain")
	await get_tree().process_frame
	_commit_terrain_ribbon(soft_right, "TerrainRight")
	_clear_ribbon_samples()


func _prepare_ribbon(hard: LowPoly, road: LowPoly, z0: float) -> void:
	_build_markings(hard, z0)
	if _on_spur:
		_build_spur_ribbon(hard, road, z0)
	if theme == Env.COAST:
		_build_sea(hard, z0)


func _commit_hard_ribbon(hard: LowPoly) -> void:
	var hard_mesh: MeshInstance3D = hard.commit_to(self, "RoadDetails")
	if hard_mesh:
		# Markings and curb faces should stay crisp and matte; their vertex colours
		# carry the reflective/painted distinction without extra materials.
		hard_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _commit_road_ribbon(road: LowPoly) -> void:
	var road_mesh: MeshInstance3D = road.commit_to(self, "RoadSurface")
	if road_mesh:
		road_mesh.material_override = _road_material()
		road_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _commit_terrain_ribbon(soft: LowPoly, node_name: String) -> void:
	var terrain_mesh: MeshInstance3D = soft.commit_to(self, node_name)
	if terrain_mesh:
		terrain_mesh.material_override = LowPoly.terrain_material()
		# Flat ground casting onto itself buys nothing and costs a shadow pass.
		terrain_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _clear_ribbon_samples() -> void:
	_road_samples.clear()
	_point_samples.clear()


static func _bands() -> Array:
	## Mirror the half-profile into full-width bands, always with the lower
	## lateral first so the generated quads face up (or inward, for curb faces).
	if not _bands_cache.is_empty():
		return _bands_cache
	var out: Array = []
	for i in range(HALF_PROFILE.size() - 1):
		var a: Array = HALF_PROFILE[i]
		var c: Array = HALF_PROFILE[i + 1]
		out.append([a[0], a[1], c[0], c[1], c[2]])
		if c[0] > 0.001:
			out.append([-c[0], c[1], -a[0], a[1], c[2]])
	_bands_cache = out
	return _bands_cache


## Where an overlook needs a finer cross-section than the road does, and how
## fine. Out past the verge the profile steps in twenty- and forty-metre bands,
## which is plenty for rolling country seen from a saddle — and nowhere near
## enough for the one place the game asks you to stop and look at the ground.
## Two quads used to carry the entire face from the crest to the water, so the
## drop the platform exists for came out as a single flat wedge.
const VIEW_REFINE_INNER := 62.0
const VIEW_REFINE_OUTER := 150.0
const VIEW_REFINE_STEP := 7.0


func _view_bands() -> Array:
	## The road profile, subdivided across the drop — and only on the view side of
	## chunks that have a view, so no ordinary stretch of road pays for it.
	var cached: Array = _view_bands_right_cache if _vp_side > 0.0 else _view_bands_left_cache
	if not cached.is_empty():
		return cached
	var bands := _bands()
	if not _on_lake:
		return bands
	var out: Array = []
	for band in bands:
		var lo: float = minf(float(band[0]), float(band[2]))
		var hi: float = maxf(float(band[0]), float(band[2]))
		var near: float = minf(absf(lo), absf(hi))
		var far: float = maxf(absf(lo), absf(hi))
		if (
			lo * _vp_side < 0.0 and hi * _vp_side < 0.0  # wrong side of the road
			or far < VIEW_REFINE_INNER
			or near > VIEW_REFINE_OUTER
			or hi - lo <= VIEW_REFINE_STEP
		):
			out.append(band)
			continue
		var parts := int(ceil((hi - lo) / VIEW_REFINE_STEP))
		for i in parts:
			var t0 := float(i) / float(parts)
			var t1 := float(i + 1) / float(parts)
			out.append(
				[
					lerpf(float(band[0]), float(band[2]), t0),
					lerpf(float(band[1]), float(band[3]), t0),
					lerpf(float(band[0]), float(band[2]), t1),
					lerpf(float(band[1]), float(band[3]), t1),
					band[4],
				]
			)
	if _vp_side > 0.0:
		_view_bands_right_cache = out
	else:
		_view_bands_left_cache = out
	return out


func _build_markings(b: LowPoly, z0: float) -> void:
	const LIFT := 0.015  # sits proud of the tarmac; no z-fighting
	var stripe: Color = _pal["stripe"]
	var step := LENGTH / float(STEPS)

	# Continuous edge lines, the whole length of the route including through a
	# junction. The spur is a lane bolted to the outside of this line, not a
	# surface laid across it, so the line is exactly what a rider crosses to take
	# the exit — and the only thing that says where the carriageway ends while
	# the two roads run side by side.
	for side in [-1.0, 1.0]:
		var lx: float = side * (HALF_WIDTH - 0.55)
		for i in STEPS:
			var za := z0 + float(i) * step
			var zb := za + step
			b.add_quad(
				_p(za, lx - 0.11, -LIFT),
				_p(za, lx + 0.11, -LIFT),
				_p(zb, lx + 0.11, -LIFT),
				_p(zb, lx - 0.11, -LIFT),
				stripe
			)

	# Dashed lane dividers. Phase comes from world z, so dashes run unbroken
	# across chunk seams.
	var lanes: int = _path.LANE_COUNT
	var dz := 0.5
	var z := z0
	while z < z0 + LENGTH - 0.001:
		if fposmod(z + dz * 0.5, DASH_PERIOD) < DASH_ON:
			for lane in range(1, lanes):
				var lx: float = (_path.lane_x(lane - 1) + _path.lane_x(lane)) * 0.5
				b.add_quad(
					_p(z, lx - 0.09, -LIFT),
					_p(z, lx + 0.09, -LIFT),
					_p(z + dz, lx + 0.09, -LIFT),
					_p(z + dz, lx - 0.09, -LIFT),
					stripe
				)
		z += dz


func _build_sea(b: LowPoly, z0: float) -> void:
	var step := LENGTH / float(STEPS)
	for i in STEPS:
		var za := z0 + float(i) * step
		var zb := za + step
		var wa := 7.6 + sin(za * 0.08) * 0.25
		var wb := 7.6 + sin(zb * 0.08) * 0.25
		b.add_quad(_p(za, 30.0, wa), _p(za, 150.0, wa), _p(zb, 150.0, wb), _p(zb, 30.0, wb), _pal["accent"])


# ------------------------------------------------------------------ prop API


func _on_tarmac(z: float, lateral: float, clearance: float = PROP_ROAD_CLEARANCE) -> bool:
	## True if this point is on the carriageway or the scenic spur, plus a
	## clearance strip. The old check only knew about HALF_WIDTH, so anything
	## planted at the spur's 160 m offset was "off the road".
	if absf(lateral) <= HALF_WIDTH + clearance:
		return true
	var spur: Vector2 = _path.spur_interval(z)
	if spur == Vector2.ZERO:
		return false
	return lateral >= spur.x - clearance and lateral <= spur.y + clearance


func _footprint_is_clear(
	z: float, lateral: float, half_lateral: float, half_depth: float, clearance: float = PROP_ROAD_CLEARANCE
) -> bool:
	## Props are checked at their full conservative footprint, not just at their
	## centre point. Sampling against the path at front/middle/back also catches
	## large objects placed on a bend.
	##
	## The early-out matters: this is the hottest function in chunk building (nine
	## trig-heavy path samples per prop) and most props are nowhere near the road.
	## Over a span L the centreline wanders about curvature*L²/2 ≈ 0.005*L² at the
	## sharpest curvature the path generates, so that plus a metre is a safe bound.
	# Across the footprint, not just at the centre: a boulder five metres wide
	# whose middle clears the spur by four still has half of itself parked on the
	# road, and the overlook is where the widest props in the game are scattered.
	if (
		_viewpoint_reserves_sightline(z, lateral)
		or _viewpoint_reserves_sightline(z, lateral - half_lateral)
		or _viewpoint_reserves_sightline(z, lateral + half_lateral)
		or _viewpoint_reserves_sightline(z - half_depth, lateral)
		or _viewpoint_reserves_sightline(z + half_depth, lateral)
	):
		return false
	var curve_slop: float = 1.0 + half_depth * half_depth * 0.005
	var far_from_main: bool = absf(lateral) - half_lateral > HALF_WIDTH + clearance + curve_slop
	var spur: Vector2 = _path.spur_interval(z)
	var far_from_spur := true
	if spur != Vector2.ZERO:
		far_from_spur = (
			lateral + half_lateral < spur.x - clearance - curve_slop
			or lateral - half_lateral > spur.y + clearance + curve_slop
		)
	if far_from_main and far_from_spur:
		return true

	var centre: Vector3 = _path.ground_at(z, lateral)
	var frame: Basis = _path.frame_flat_at(z)
	var forward := Vector3(sin(_path.yaw_at(z)), 0.0, cos(_path.yaw_at(z)))
	for depth_factor in [-1.0, 0.0, 1.0]:
		var dz := half_depth * float(depth_factor)
		var sample_z := z + dz
		var sample_centre: Vector3 = _path.center_at(sample_z)
		var sample_right: Vector3 = _path.frame_flat_at(sample_z).x
		for lateral_factor in [-1.0, 0.0, 1.0]:
			var point := centre + frame.x * (half_lateral * float(lateral_factor)) + forward * dz
			var sample_lateral := (point - sample_centre).dot(sample_right)
			if _on_tarmac(sample_z, sample_lateral, clearance):
				return false
	return true


func _viewpoint_reserves_sightline(z: float, lateral: float) -> bool:
	## Ordinary random scenery must not fill the overlook deck, stand between the
	## parked rider and the water, or get planted on the lake bed. Set-piece
	## geometry bypasses this through its own explicit builders after the scenery
	## pass.
	if not (_on_lake or _on_spur):
		return false
	# Below the waterline nothing random is allowed at all. `viewpoint_reserves`
	# covers the lake *bed* the set piece digs, but the water sheet reaches far
	# past it — out to the horizon on a coast — and the ordinary verge scatter was
	# happily planting bushes over the whole of it. That went unnoticed only while
	# every biome palette was the same low-chroma beige as the sea it was strewn
	# across; the moment the palettes got their hues back it read as confetti
	# floating on the water.
	if _on_lake and _path.height_at(z) - _path.terrain_drop(lateral, z) < _vp_water_y + 0.6:
		return true
	return bool(_path.viewpoint_reserves(z, lateral))


func _profile_drop_at(lateral: float, z: float) -> float:
	## Match the outer terrain ribbon's profile. ground_at() is the road/path
	## surface; the rendered verge/ground bands add this extra drop below it.
	return _path.terrain_profile_drop(lateral, z)


func _band_drop(z: float, lateral: float, drop: float) -> float:
	## Curb lip and verge camber, cancelled where the spur road crosses the
	## carriageway's own profile at a junction: a curb through the middle of a
	## junction mouth is exactly the seam that gives a bolted-on feature away.
	if drop == 0.0 or not _on_spur:
		return drop
	return drop * (1.0 - float(_path.spur_deck_blend(z, lateral)))


func _terrain_surface_at(z: float, lateral: float) -> Vector3:
	var point: Vector3 = _path.ground_at(z, lateral)
	return point - _path.frame_flat_at(z).y * _profile_drop_at(lateral, z)


func _ground_base_for_footprint(
	z: float, lateral: float, half_lateral: float, half_depth: float, follow_terrain: bool = true
) -> Vector3:
	var centre: Vector3 = _terrain_surface_at(z, lateral)
	if not follow_terrain:
		return centre
	# A small prop cannot straddle enough ground to need nine samples.
	if half_lateral < 1.2 and half_depth < 1.2:
		return centre

	# Wide props need to sit on the lowest nearby terrain sample. This slightly
	# buries the uphill side when the ground slopes, but prevents the far side
	# from floating above the terrain.
	var lowest_y: float = centre.y
	for depth_factor in [-1.0, 0.0, 1.0]:
		var sample_z: float = z + half_depth * float(depth_factor)
		for lateral_factor in [-1.0, 0.0, 1.0]:
			var sample_lateral: float = lateral + half_lateral * float(lateral_factor)
			lowest_y = minf(lowest_y, _terrain_surface_at(sample_z, sample_lateral).y)

	return Vector3(centre.x, lowest_y, centre.z)


func _cube(
	z: float,
	lateral: float,
	size: Vector3,
	color: Color,
	yaw: float = 0.0,
	lift: float = 0.0,
	allow_road_overlap: bool = false,
	follow_terrain: bool = true
) -> void:
	var half_lateral := absf(cos(yaw)) * size.x * 0.5 + absf(sin(yaw)) * size.z * 0.5
	var half_depth := absf(sin(yaw)) * size.x * 0.5 + absf(cos(yaw)) * size.z * 0.5
	if not allow_road_overlap and not _footprint_is_clear(z, lateral, half_lateral, half_depth):
		return
	var base: Vector3 = _ground_base_for_footprint(z, lateral, half_lateral, half_depth, follow_terrain) - _origin + Vector3(0, lift, 0)
	var basis := Basis(Vector3.UP, _path.yaw_at(z) + yaw).scaled(size)
	_cubes.append(Transform3D(basis, base + Vector3(0, size.y * 0.5, 0)))
	_cube_cols.append(color)


func _deck_cube(
	z: float, lateral: float, size: Vector3, color: Color, yaw: float = 0.0, lift: float = 0.0
) -> void:
	## Sit a box on the spur deck, along the road's own up. World-Y placement is
	## what left the benches hovering whenever the headland was pitched.
	var flat: Basis = _path.frame_flat_at(z)
	var frame := Basis(flat.x, flat.y, flat.z).rotated(flat.y, yaw)
	var scaled := Basis(frame.x * size.x, frame.y * size.y, frame.z * size.z)
	_cubes.append(Transform3D(scaled, _p(z, lateral, -(lift + size.y * 0.5))))
	_cube_cols.append(color)


func _deck_blob(
	z: float, lateral: float, size: Vector3, color: Color, lift: float = 0.0, leafy: bool = true
) -> void:
	## Heather, turf and low planting on the terrace — same deck placement as
	## `_deck_cube`, or it floats the moment the headland pitches.
	var flat: Basis = _path.frame_flat_at(z)
	var frame := Basis(flat.x, flat.y, flat.z).rotated(flat.y, _rng.randf_range(0.0, TAU))
	var scaled := Basis(frame.x * size.x, frame.y * size.y, frame.z * size.z)
	var xform := Transform3D(scaled, _p(z, lateral, -(lift + size.y * 0.42)))
	if leafy:
		_leaves.append(xform)
		_leaf_cols.append(color)
	else:
		_blobs.append(xform)
		_blob_cols.append(color)


func _deck_lamp(z: float, lateral: float, size: Vector3, color: Color, lift: float) -> void:
	var flat: Basis = _path.frame_flat_at(z)
	var scaled := Basis(flat.x * size.x, flat.y * size.y, flat.z * size.z)
	_lamps.append(Transform3D(scaled, _p(z, lateral, -(lift + size.y * 0.5))))
	_lamp_cols.append(color)


func _deck_light(z: float, lateral: float, lift: float, color: Color, radius: float, energy: float) -> void:
	if _light_count >= MAX_LIGHTS_PER_CHUNK:
		return
	var light := OmniLight3D.new()
	light.position = _p(z, lateral, -lift)
	light.light_color = color
	light.light_energy = energy
	light.omni_range = radius
	light.omni_attenuation = 1.5
	light.shadow_enabled = false
	light.distance_fade_enabled = true
	light.distance_fade_begin = 35.0
	light.distance_fade_length = 20.0
	add_child(light)
	_light_count += 1


func _arch_cube(
	z: float,
	lateral: float,
	size: Vector3,
	color: Color,
	yaw: float = 0.0,
	lift: float = 0.0,
	allow_road_overlap: bool = false,
	follow_terrain: bool = true
) -> void:
	## Sharp-edged box for architecture. Same placement rules as `_cube`.
	var half_lateral := absf(cos(yaw)) * size.x * 0.5 + absf(sin(yaw)) * size.z * 0.5
	var half_depth := absf(sin(yaw)) * size.x * 0.5 + absf(cos(yaw)) * size.z * 0.5
	if not allow_road_overlap and not _footprint_is_clear(z, lateral, half_lateral, half_depth):
		return
	var base: Vector3 = _ground_base_for_footprint(z, lateral, half_lateral, half_depth, follow_terrain) - _origin + Vector3(0, lift, 0)
	var basis := Basis(Vector3.UP, _path.yaw_at(z) + yaw).scaled(size)
	_arch.append(Transform3D(basis, base + Vector3(0, size.y * 0.5, 0)))
	_arch_cols.append(color)


func _prism(
	z: float, lateral: float, size: Vector3, color: Color, lift: float = 0.0, allow_road_overlap: bool = false
) -> void:
	var radius := maxf(size.x, size.z) * 0.5
	if not allow_road_overlap and not _footprint_is_clear(z, lateral, radius, radius):
		return
	var base: Vector3 = _ground_base_for_footprint(z, lateral, radius, radius) - _origin + Vector3(0, lift, 0)
	var basis := Basis(Vector3.UP, _rng.randf_range(0.0, TAU)).scaled(size)
	_prisms.append(Transform3D(basis, base))
	_prism_cols.append(color)


func _ridge(z: float, lateral: float, size: Vector3, color: Color) -> void:
	## A cone on the far landscape, forming the skyline. No footprint or terrain
	## sampling: at this distance the road is irrelevant and the nine path samples
	## every other prop pays for would be wasted.
	var base: Vector3 = _terrain_surface_at(z, lateral) - _origin
	var basis := Basis(Vector3.UP, _rng.randf_range(0.0, TAU)).scaled(size)
	_ridges.append(Transform3D(basis, base - Vector3(0, size.y * 0.06, 0)))
	_ridge_cols.append(color)


func _blob(
	z: float,
	lateral: float,
	size: Vector3,
	color: Color,
	lift: float = 0.0,
	leafy: bool = false,
	forced: bool = false,
	follow_terrain: bool = true
) -> void:
	## Smooth-shaded ball: shrubs, canopies, hedges — and also boulders and hill
	## humps, which is why `leafy` exists. Only the growing things go in the wind
	## bucket; a swaying rock is worse than a still tree.
	##
	## follow_terrain=false takes one terrain sample instead of the nine-sample
	## corner fit — right for a big smooth hill hump, where a single centre sample
	## is imperceptible but the nine were a real streaming cost.
	var radius := maxf(size.x, size.z) * 0.5
	if not forced and not _footprint_is_clear(z, lateral, radius, radius):
		return
	var base: Vector3 = _ground_base_for_footprint(z, lateral, radius, radius, follow_terrain) - _origin + Vector3(0, lift, 0)
	var basis := Basis(Vector3.UP, _rng.randf_range(0.0, TAU)).scaled(size)
	var xform := Transform3D(basis, base + Vector3(0, size.y * 0.42, 0))
	if leafy:
		_leaves.append(xform)
		_leaf_cols.append(color)
	else:
		_blobs.append(xform)
		_blob_cols.append(color)


func _hay_bale(z: float, lateral: float, radius: float, length: float, color: Color) -> void:
	## Round bale lying on its side in a field, at a random roll and yaw so a
	## cluster never lines up like crates off a truck.
	if not _footprint_is_clear(z, lateral, length * 0.5, length * 0.5):
		return
	var base: Vector3 = _ground_base_for_footprint(z, lateral, length * 0.5, length * 0.5) - _origin
	# Tip the cylinder's axis flat onto its side, then yaw it to a random
	# compass heading so a cluster of bales never lines up like crates.
	var lie := Basis(Vector3.RIGHT, PI * 0.5)
	var yaw := Basis(Vector3.UP, _rng.randf_range(0.0, TAU))
	var basis := (yaw * lie).scaled(Vector3(radius * 2.0, length, radius * 2.0))
	_hay.append(Transform3D(basis, base + Vector3(0, radius, 0)))
	_hay_cols.append(color)


# -------------------------------------------------------------------- trees


func _tree(
	species: int, z: float, lateral: float, height: float, color: Color, forced: bool = false, lift: float = 0.0
) -> void:
	## One whole tree, grounded and road-checked exactly once.
	##
	## The old builder tested each part against the road separately, so a tree on
	## the verge could keep its trunk and lose its crown. Here the trunk footprint
	## decides, and the canopy is free to lean out over the tarmac — a bough over
	## the road is worth more than another identical ball five metres back.
	##
	## `forced` is for authored planting inside ground the overlook reserves — the
	## far shore of its lake is exactly the place the random pass must not touch
	## and the set piece must. `lift` raises the whole tree off the ground it was
	## sampled on, which is how anything gets planted on an island: the terrain
	## under one is the lake bed, several metres down.
	var foot: float = clampf(height * 0.1, 0.35, 1.1)
	if not forced and not _footprint_is_clear(z, lateral, foot, foot):
		return
	var base: Vector3 = _ground_base_for_footprint(z, lateral, foot, foot) - _origin + Vector3(0.0, lift, 0.0)
	var frame := Transform3D(Basis(Vector3.UP, _rng.randf_range(0.0, TAU)), base)
	match species:
		Flora.CONIFER:
			_grow_conifer(frame, height, color)
		Flora.CYPRESS:
			_grow_cypress(frame, height, color)
		Flora.BIRCH:
			_grow_birch(frame, height, color)
		Flora.PALM:
			_grow_palm(frame, height, color)
		Flora.BARE:
			_grow_bare(frame, height, color)
		_:
			_grow_broadleaf(frame, height, color)


func _limb(frame: Transform3D, from: Vector3, to: Vector3, thickness: float, color: Color) -> void:
	## One tapered woody segment between two points of the tree's local frame.
	## `thickness` is the width across the root flare.
	var span := to - from
	var length := span.length()
	if length < 0.02:
		return
	var up := span / length
	var side := up.cross(Vector3.FORWARD)
	if side.length_squared() < 1e-5:
		side = up.cross(Vector3.RIGHT)
	side = side.normalized()
	var forward := side.cross(up).normalized()
	_trunks.append(frame * Transform3D(Basis(side * thickness, up * length, forward * thickness), from))
	_trunk_cols.append(color)


func _canopy(frame: Transform3D, at: Vector3, width: float, height: float, color: Color) -> void:
	## A broadleaf crown instance. Yaw and a slightly oval footprint are free
	## variation; a tilt would look drunk, so the lean lives in the trunk instead.
	var basis := Basis(Vector3.UP, _rng.randf_range(0.0, TAU)).scaled(
		Vector3(width, height, width * _rng.randf_range(0.82, 1.16))
	)
	_crowns.append(frame * Transform3D(basis, at))
	_crown_cols.append(color)


func _grow_broadleaf(frame: Transform3D, height: float, color: Color) -> void:
	## Oak/beech shape: a short leaning trunk that forks into two or three boughs
	## disappearing into a wide canopy.
	var bark: Color = BARK.lightened(_rng.randf() * 0.14)
	var trunk_h: float = height * _rng.randf_range(0.32, 0.44)
	var thickness: float = height * _rng.randf_range(0.055, 0.075)
	var lean := Vector3(_rng.randf_range(-0.09, 0.09), 0.0, _rng.randf_range(-0.09, 0.09)) * height
	var fork := lean + Vector3(0, trunk_h, 0)
	_limb(frame, Vector3.ZERO, fork, thickness, bark)

	var width: float = height * _rng.randf_range(0.66, 0.9)
	var boughs: int = 2 if height < 6.0 else 3
	for i in boughs:
		var a: float = TAU * (float(i) + _rng.randf_range(0.0, 0.5)) / float(boughs)
		var reach: float = width * _rng.randf_range(0.22, 0.34)
		var tip := fork + Vector3(cos(a) * reach, height * _rng.randf_range(0.14, 0.24), sin(a) * reach)
		_limb(frame, fork - Vector3(0, trunk_h * 0.18, 0), tip, thickness * 0.52, bark.darkened(0.08))

	var crown_h: float = (height - fork.y) * _rng.randf_range(1.0, 1.15)
	_canopy(frame, fork + Vector3(lean.x * 0.3, -crown_h * 0.08, lean.z * 0.3), width, crown_h, color)


func _grow_cypress(frame: Transform3D, height: float, color: Color) -> void:
	## Italian cypress: a dark needle. The conifer mesh is a cone; scaled this
	## thin it is a column, which is the tree that turns a pine lake into a
	## Mediterranean one.
	var bark: Color = BARK.darkened(_rng.randf_range(0.25, 0.45))
	_limb(frame, Vector3.ZERO, Vector3(0, height * 0.62, 0), height * 0.022, bark)
	var width: float = height * _rng.randf_range(0.048, 0.062)
	var basis := Basis(Vector3.UP, _rng.randf_range(0.0, TAU)).scaled(Vector3(width, height * 0.96, width))
	_conifers.append(frame * Transform3D(basis, Vector3(0, height * 0.02, 0)))
	_conifer_cols.append(color.darkened(0.18 + _rng.randf() * 0.12))


func _grow_conifer(frame: Transform3D, height: float, color: Color) -> void:
	## Spruce: bare lower trunk, then skirts all the way to a point. The one shape
	## on the roadside that is allowed a sharp apex.
	var bark: Color = BARK.darkened(_rng.randf_range(0.1, 0.3))
	var skirt: float = height * _rng.randf_range(0.08, 0.16)
	_limb(frame, Vector3.ZERO, Vector3(0, height * 0.42, 0), height * 0.05, bark)
	var width: float = height * _rng.randf_range(0.3, 0.42)
	var basis := Basis(Vector3.UP, _rng.randf_range(0.0, TAU)).scaled(
		Vector3(width, height - skirt, width * _rng.randf_range(0.88, 1.12))
	)
	_conifers.append(frame * Transform3D(basis, Vector3(0, skirt, 0)))
	_conifer_cols.append(color)


func _grow_birch(frame: Transform3D, height: float, color: Color) -> void:
	## A clump of two or three pale stems from one root, each with a small high
	## crown. Slim and bright: the tree that breaks up a wall of dark conifer.
	var stems: int = _rng.randi_range(2, 3)
	for i in stems:
		var a: float = TAU * float(i) / float(stems) + _rng.randf_range(-0.4, 0.4)
		var tall: float = height * _rng.randf_range(0.78, 1.0)
		var out: float = tall * _rng.randf_range(0.06, 0.16)
		var top := Vector3(cos(a) * out, tall * 0.72, sin(a) * out)
		_limb(frame, Vector3.ZERO, top, tall * 0.05, BARK_PALE.darkened(_rng.randf() * 0.3))
		var width: float = tall * _rng.randf_range(0.42, 0.56)
		_canopy(frame, top - Vector3(0, tall * 0.1, 0), width, tall * 0.5, color.lightened(_rng.randf() * 0.12))


func _grow_palm(frame: Transform3D, height: float, color: Color) -> void:
	## Curved stem in three segments, a spray of fronds and a nut cluster. The
	## curve is the whole point — a straight palm is a mop on a pole.
	const SEGMENTS := 3
	var bark: Color = BARK_PALM.darkened(_rng.randf() * 0.2)
	var curve: float = height * _rng.randf_range(0.08, 0.2) * (1.0 if _rng.randf() < 0.5 else -1.0)
	var previous := Vector3.ZERO
	for i in SEGMENTS:
		var t: float = float(i + 1) / float(SEGMENTS)
		var point := Vector3(curve * t * t, height * t, 0.0)
		_limb(frame, previous, point, height * 0.075 * (1.0 - 0.3 * t), bark)
		previous = point

	var fronds: int = _rng.randi_range(7, 9)
	var length: float = height * _rng.randf_range(0.4, 0.55)
	for i in fronds:
		var a: float = TAU * float(i) / float(fronds) + _rng.randf_range(-0.16, 0.16)
		var pitch: float = _rng.randf_range(-0.1, 0.65)
		var basis := (Basis(Vector3.UP, a) * Basis(Vector3.BACK, pitch)).scaled(
			Vector3(length, length * _rng.randf_range(0.8, 1.1), length)
		)
		_fronds.append(frame * Transform3D(basis, previous))
		_frond_cols.append(color.darkened(_rng.randf() * 0.18))
	# Nuts under the crown, in the still bucket: they hang off the stem, not the leaves.
	var nut: float = height * 0.06
	_blobs.append(frame * Transform3D(Basis.IDENTITY.scaled(Vector3(nut * 2.2, nut * 1.6, nut * 2.2)), previous))
	_blob_cols.append(Color("6b5b33"))


func _grow_bare(frame: Transform3D, height: float, color: Color) -> void:
	## Dead or winter-bare: a forked trunk and two levels of branches, no canopy.
	## Pure silhouette, which is exactly what a bare mountain ridge needs.
	var trunk_h: float = height * _rng.randf_range(0.4, 0.55)
	var thickness: float = height * _rng.randf_range(0.07, 0.1)
	var fork := Vector3(_rng.randf_range(-0.06, 0.06) * height, trunk_h, _rng.randf_range(-0.06, 0.06) * height)
	_limb(frame, Vector3.ZERO, fork, thickness, color)
	var branches: int = _rng.randi_range(3, 4)
	for i in branches:
		var a: float = TAU * (float(i) + _rng.randf_range(0.0, 0.4)) / float(branches)
		var reach: float = height * _rng.randf_range(0.2, 0.34)
		var tip := fork + Vector3(cos(a) * reach, height * _rng.randf_range(0.2, 0.34), sin(a) * reach)
		_limb(frame, fork, tip, thickness * 0.55, color.lightened(0.05))
		for _j in _rng.randi_range(1, 2):
			var twist: float = a + _rng.randf_range(-1.1, 1.1)
			var far: float = reach * _rng.randf_range(0.3, 0.6)
			_limb(
				frame,
				tip,
				tip + Vector3(cos(twist) * far, height * _rng.randf_range(0.1, 0.2), sin(twist) * far),
				thickness * 0.3,
				color.lightened(0.12)
			)


func _glow_light(z: float, lateral: float, lift: float, color: Color, radius: float, energy: float) -> void:
	if _light_count >= MAX_LIGHTS_PER_CHUNK:
		return
	var light := OmniLight3D.new()
	light.position = _terrain_surface_at(z, lateral) - _origin + Vector3(0, lift, 0)
	light.light_color = color
	light.light_energy = energy
	light.omni_range = radius
	light.omni_attenuation = 1.5
	light.shadow_enabled = false
	light.distance_fade_enabled = true
	light.distance_fade_begin = 35.0
	light.distance_fade_length = 20.0
	add_child(light)
	_light_count += 1


func _lamp(z: float, lateral: float, size: Vector3, color: Color, lift: float, allow_road_overlap: bool = false) -> void:
	var half_lateral := size.x * 0.5
	var half_depth := size.z * 0.5
	if not allow_road_overlap and not _footprint_is_clear(z, lateral, half_lateral, half_depth, -0.5):
		return
	var base: Vector3 = _ground_base_for_footprint(z, lateral, half_lateral, half_depth) - _origin + Vector3(0, lift, 0)
	var basis := Basis(Vector3.UP, _path.yaw_at(z)).scaled(size)
	_lamps.append(Transform3D(basis, base + Vector3(0, size.y * 0.5, 0)))
	_lamp_cols.append(color)


## Albedos for imported boulders, one per biome, cached because every rock in
## the view would otherwise carry its own copy of the same material.
static var _vista_rock_mats: Dictionary = {}


static func _vista_rock_material(tint: Color) -> StandardMaterial3D:
	var key: String = tint.to_html(false)
	if _vista_rock_mats.has(key):
		return _vista_rock_mats[key]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = tint
	mat.roughness = 0.94
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	mat.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT
	_vista_rock_mats[key] = mat
	return mat


func _vista_rock_tint() -> Color:
	## Whatever the imported asset thinks it is, in this game it is a rock in
	## *this* valley. The Kenney boulders ship with a bright moss-green cap over
	## an orange body, and dropped unaltered into a dusk sea-stack field they read
	## as painted confetti floating on the water — the most conspicuous thing in
	## the coast view, and the only object in it not built from the biome palette.
	match _vp_theme:
		Env.COAST:
			return Color("4a5560")
		Env.MOUNTAIN:
			return Color("5a5148")
		Env.FOREST:
			return Color("3b4438")
	return Color("6a5b45")


func _vista_rock(z: float, lateral: float, scale: float, lift: float = 0.0, in_water: bool = false) -> void:
	## Kenney boulders as real mass in the overlook: sea stacks, talus, a knoll.
	## Bypasses the roadside import cap — six rocks on a 40 m verge is plenty,
	## six rocks on a kilometre of view is nothing.
	##
	## `in_water` is the sea stacks and nothing else. Every other caller places
	## talus on a slope, and the drowning test has to be made here against the
	## very surface the rock is about to be stood on: doing it in the callers
	## against `_height_above_water` compared a *different* query — centreline
	## height less a profile drop, not the sampled terrain — and the two disagree
	## exactly where the headland face falls away, which is where all the talus
	## is. The callers' guards passed and the rocks still came up under the lake.
	var ground: Vector3 = _terrain_surface_at(z, lateral)
	if not in_water and ground.y < _vp_water_y + 0.8:
		return
	var tint: Color = _vista_rock_tint()
	var rock: PackedScene = _rock_scene(_rng.randf() < 0.5)
	if rock == null:
		_blob(z, lateral, Vector3(scale * 1.6, scale, scale * 1.4), tint, lift, false, true)
		return
	var instance: Node3D = rock.instantiate() as Node3D
	if instance == null:
		return
	var base: Vector3 = ground - _origin + Vector3(0.0, lift, 0.0)
	instance.position = base
	instance.rotation.y = _rng.randf_range(0.0, TAU)
	# A sea stack is a column, not a boulder. The Kenney rocks are wide and low,
	# and scaled uniformly they lie on the water like skipping stones however big
	# you make them; squeezed in plan and pulled up, the same mesh reads as a
	# remnant of a cliff the sea has cut away — which is what it is.
	if in_water:
		instance.scale = Vector3(scale * 0.52, scale * 1.55, scale * 0.52)
	else:
		instance.scale = Vector3.ONE * scale
	_dress_imported_rock(instance, _vista_rock_material(tint.darkened(_rng.randf() * 0.22)))
	add_child(instance)


func _dress_imported_rock(node: Node, mat: StandardMaterial3D) -> void:
	if node is GeometryInstance3D:
		var geo := node as GeometryInstance3D
		geo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		geo.material_override = mat
	for child in node.get_children():
		_dress_imported_rock(child, mat)


func _silence_imported_shadows(node: Node) -> void:
	if node is GeometryInstance3D:
		(node as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in node.get_children():
		_silence_imported_shadows(child)


func _asset_prop(
	scene: PackedScene,
	z: float,
	lateral: float,
	scale: float,
	footprint_radius: float,
	lift: float = 0.0,
	face_road: bool = false
) -> void:
	## Imported props use the same road-footprint guard as generated scenery. A
	## few instances per chunk add authored silhouettes without turning streaming
	## into a large physics or draw-call system.
	if _asset_count >= MAX_IMPORTED_ASSETS_PER_CHUNK:
		return
	if not _footprint_is_clear(z, lateral, footprint_radius, footprint_radius):
		return
	var instance: Node3D = scene.instantiate() as Node3D
	if instance == null:
		return
	var base: Vector3 = _ground_base_for_footprint(z, lateral, footprint_radius, footprint_radius) - _origin + Vector3(0, lift, 0)
	instance.position = base
	if face_road:
		# Kenney buildings face local -Z; swing that axis toward the centreline.
		instance.rotation.y = _path.yaw_at(z) + (PI * 0.5 if lateral > 0.0 else -PI * 0.5)
	else:
		instance.rotation.y = _rng.randf_range(0.0, TAU)
	instance.scale = Vector3.ONE * scale
	add_child(instance)
	_asset_count += 1


func _commit_props() -> void:
	_commit_mm(_cubes, _cube_cols, unit_cube(), LowPoly.solid_material(), "Cubes", true)
	_commit_mm(_arch, _arch_cols, unit_box_sharp(), LowPoly.solid_material(), "Architecture", true)
	_commit_mm(_prisms, _prism_cols, unit_cone(), LowPoly.solid_material(), "Cones", true)
	_commit_mm(_blobs, _blob_cols, unit_sphere(), LowPoly.solid_material(), "Rocks", false)
	_commit_mm(_leaves, _leaf_cols, unit_sphere(), LowPoly.foliage_material(), "Foliage", false)
	_commit_mm(_trunks, _trunk_cols, unit_trunk(), LowPoly.solid_material(), "Trunks", true)
	_commit_mm(_crowns, _crown_cols, unit_crown(), LowPoly.foliage_material(), "Crowns", false)
	_commit_mm(_conifers, _conifer_cols, unit_conifer(), LowPoly.foliage_material(), "Conifers", false)
	_commit_mm(_fronds, _frond_cols, unit_frond(), LowPoly.foliage_material(), "Fronds", false)
	_commit_mm(_ridges, _ridge_cols, unit_ridge(), LowPoly.solid_material(), "Ridges", false)
	_commit_mm(_grass, _grass_cols, grass_tuft(), LowPoly.foliage_material(), "Grass", false)
	_commit_mm(_hay, _hay_cols, unit_hay_bale(), LowPoly.solid_material(), "HayBales", false)
	_commit_mm(_lamps, _lamp_cols, unit_cube(), LowPoly.glow_material(), "Lamps", false)
	_commit_mm(_clouds, _cloud_cols, unit_sphere(), cloud_material(), "Clouds", false)
	_commit_mm(_birds, _bird_cols, unit_bird(), bird_material(), "Birds", false)
	_arm_vista_motion()


func _commit_props_incremental() -> void:
	## Creating and filling every MultiMesh bucket in one frame was the remaining
	## large streaming spike. The chunk is still beyond the camera here, so publish
	## it in four small groups and give the renderer a frame between them.
	_commit_mm(_cubes, _cube_cols, unit_cube(), LowPoly.solid_material(), "Cubes", true)
	_commit_mm(_arch, _arch_cols, unit_box_sharp(), LowPoly.solid_material(), "Architecture", true)
	_commit_mm(_prisms, _prism_cols, unit_cone(), LowPoly.solid_material(), "Cones", true)
	await get_tree().process_frame
	_commit_mm(_blobs, _blob_cols, unit_sphere(), LowPoly.solid_material(), "Rocks", false)
	_commit_mm(_leaves, _leaf_cols, unit_sphere(), LowPoly.foliage_material(), "Foliage", false)
	_commit_mm(_trunks, _trunk_cols, unit_trunk(), LowPoly.solid_material(), "Trunks", true)
	await get_tree().process_frame
	_commit_mm(_crowns, _crown_cols, unit_crown(), LowPoly.foliage_material(), "Crowns", false)
	_commit_mm(_conifers, _conifer_cols, unit_conifer(), LowPoly.foliage_material(), "Conifers", false)
	_commit_mm(_fronds, _frond_cols, unit_frond(), LowPoly.foliage_material(), "Fronds", false)
	await get_tree().process_frame
	_commit_mm(_ridges, _ridge_cols, unit_ridge(), LowPoly.solid_material(), "Ridges", false)
	_commit_mm(_grass, _grass_cols, grass_tuft(), LowPoly.foliage_material(), "Grass", false)
	_commit_mm(_hay, _hay_cols, unit_hay_bale(), LowPoly.solid_material(), "HayBales", false)
	_commit_mm(_lamps, _lamp_cols, unit_cube(), LowPoly.glow_material(), "Lamps", false)
	_commit_mm(_clouds, _cloud_cols, unit_sphere(), cloud_material(), "Clouds", false)
	_commit_mm(_birds, _bird_cols, unit_bird(), bird_material(), "Birds", false)
	_arm_vista_motion()


func _commit_mm(
	xforms: Array[Transform3D], cols: Array[Color], mesh: Mesh, mat: Material, node_name: String, shadows: bool
) -> void:
	if xforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
		mm.set_instance_color(i, cols[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	mmi.material_override = mat
	# The road ribbon stays visible to the horizon; small props do not need to.
	# Range-culling removes their draw and shadow cost before fog hides them.
	# Ridges are the skyline; culling them at the prop distance would blink the
	# horizon in and out. Everything else stops well before the fog does.
	if node_name == "Ridges" or node_name == "Clouds" or node_name == "Birds":
		mmi.visibility_range_end = 0.0
	elif node_name == "Grass" or node_name == "HayBales":
		mmi.visibility_range_end = 95.0
	elif _on_lake and node_name in ["Conifers", "Cubes", "Architecture", "Rocks", "Trunks", "Crowns", "Foliage"]:
		# The far shore and the stacks sit a kilometre out. The old 720 m window
		# popped the trees off the opposite bank while the rider was still looking.
		mmi.visibility_range_end = 1800.0
	else:
		mmi.visibility_range_end = 360.0 if node_name == "Architecture" else 280.0
	if not shadows or _on_lake:
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	if node_name == "Clouds":
		_cloud_mm = mm
		_cloud_rest = xforms.duplicate()
		mmi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	elif node_name == "Birds":
		_bird_mm = mm
		mmi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF


func _arm_vista_motion() -> void:
	## Only chunks that actually have peak cloud or a flock pay a _process.
	if _cloud_mm != null or _bird_mm != null:
		set_process(true)


func _process(delta: float) -> void:
	var t := Time.get_ticks_msec() * 0.001
	if _cloud_mm != null:
		for i in _cloud_rest.size():
			var rest: Transform3D = _cloud_rest[i]
			var along := sin(t * 0.07 + float(i) * 0.41) * 8.0
			var bob := sin(t * 0.13 + float(i) * 0.9) * 2.6
			_cloud_mm.set_instance_transform(i, Transform3D(rest.basis, rest.origin + Vector3(0.0, bob, along)))
	if _bird_mm == null:
		return
	for i in _bird_mm.instance_count:
		_bird_phase[i] = _bird_phase[i] + delta * _bird_speed[i]
		var a: float = _bird_phase[i]
		var r: float = _bird_radius[i]
		var flap: float = 0.72 + 0.28 * absf(sin(a * 5.5))
		var pos: Vector3 = _bird_orbit[i] + Vector3(cos(a) * r, sin(a * 2.0) * _bird_amp[i], sin(a) * r)
		var vel := Vector3(-sin(a) * r, 2.0 * cos(a * 2.0) * _bird_amp[i], cos(a) * r)
		if vel.length_squared() < 0.01:
			continue
		var span: float = _bird_span[i]
		var basis := Basis.looking_at(vel, Vector3.UP).scaled(Vector3(span, span * 0.38 * flap, span))
		_bird_mm.set_instance_transform(i, Transform3D(basis, pos))


# ------------------------------------------------------------ shared furniture


func _build_furniture() -> void:
	## Reflector posts on both shoulders. Cheap, and the strobe of them going past
	## is most of what sells speed at 200 km/h. Amber and small: a white cube of
	## glow on every post read as floating litter.
	_build_reflectors()
	_verge_planting()
	if theme_carries_power_line(theme):
		_power_line()
	_build_guardrail()


func _build_furniture_incremental() -> void:
	## These stages used to land together in one 5–11 ms frame. Keeping the same
	## furniture while yielding between independent buckets removes that recurring
	## CPU spike each time a country chunk streams in.
	_build_reflectors()
	await get_tree().process_frame
	_verge_planting()
	await get_tree().process_frame
	if theme_carries_power_line(theme):
		_power_line()
		await get_tree().process_frame
	_build_guardrail()


func _build_reflectors() -> void:
	var z0: float = float(chunk_index) * LENGTH
	var z := z0
	while z < z0 + LENGTH - 0.01:
		for side in [-1.0, 1.0]:
			var lx: float = side * (HALF_WIDTH + 1.5)
			_cube(z, lx, Vector3(0.1, 1.0, 0.1), _pal["curb"].lightened(0.25))
			_cube(z, lx, Vector3(0.14, 0.16, 0.11), _pal["curb"].darkened(0.35), 0.0, 0.8)
			_lamp(z, lx, Vector3(0.11, 0.09, 0.045), REFLECTOR, 0.86)
		z += 10.0



func _build_guardrail() -> void:
	# Armco on the outside of anything fast, and always where there is a drop.
	# The lake shore counts as a drop: the ground falls nine metres to the water
	# a few strides past the verge for the whole run up to the overlook, and it
	# takes the barrier for that to read as a road along a lake rather than a
	# road that happens to end.
	var z0: float = float(chunk_index) * LENGTH
	var curv: float = _path.curvature_at(z0 + LENGTH * 0.5)
	var side_for_curve: float = -signf(curv) if absf(curv) > 0.0018 else 0.0
	if _on_lake:
		side_for_curve = _vp_side
	if side_for_curve == 0.0 and theme != Env.MOUNTAIN and theme != Env.COAST:
		return
	var side: float = side_for_curve if side_for_curve != 0.0 else 1.0
	var zz := z0
	while zz < z0 + LENGTH - 0.01:
		_cube(zz, side * (HALF_WIDTH + 1.1), Vector3(0.16, 0.85, 0.16), _pal["rail"])
		_cube(zz + 1.0, side * (HALF_WIDTH + 1.1), Vector3(0.1, 0.32, 2.2), _pal["rail"], 0.0, 0.62)
		zz += 2.0


func _grass_verge() -> void:
	## Blades along the first few metres of verge. This is the band that moves
	## fastest past the rider, so it is where wind reads at all — thirty metres out
	## the sway is invisible and the tufts are wasted.
	var z0: float = float(chunk_index) * LENGTH
	var base: Color = _pal["verge"]
	for _i in 90:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var side: float = 1.0 if _rng.randf() < 0.5 else -1.0
		# Packed against the curb, thinning outward.
		var lx: float = side * (HALF_WIDTH + 1.3 + pow(_rng.randf(), 2.0) * 12.0)
		if _viewpoint_reserves_sightline(z, lx):
			continue
		var height := _rng.randf_range(0.32, 0.72)
		var xform := Transform3D(
			Basis(Vector3.UP, _rng.randf_range(0.0, TAU)).scaled(
				Vector3(_rng.randf_range(0.5, 0.9), height, _rng.randf_range(0.5, 0.9))
			),
			_terrain_surface_at(z, lx) - _origin - Vector3(0, 0.04, 0)
		)
		_grass.append(xform)
		_grass_cols.append((base as Color).lerp(_pal["prop_a"], _rng.randf() * 0.5).darkened(_rng.randf() * 0.25))


static func theme_carries_power_line(theme_id: int) -> bool:
	## Open country only. The wire is a landscape line, and the forest and coast
	## sections are the ones that read as untouched.
	return theme_id == Env.COUNTRY or theme_id == Env.MOUNTAIN


func _power_line_lateral() -> float:
	## Which side the wire runs down, and how far out. Fixed by the world seed so
	## the line is continuous across chunk seams.
	var side: float = 1.0 if posmod(hash(int(_path.world_seed)), 2) == 0 else -1.0
	return side * (HALF_WIDTH + 7.5)


func _junction_occupies(z: float, lateral: float) -> bool:
	## Whether the overlook's junction formation reaches this lateral: the spur
	## carriageway, its shoulders, the platform terrace, and the gore of open
	## ground between the spur and the carriageway it peels off.
	##
	## Anything positioned by a fixed offset from the centreline has to ask this.
	## The spur sweeps from the road edge out to 56 m over 440 m of route, so a
	## prop parked at a constant lateral is crossed by it somewhere, and a
	## telegraph pole planted at 15.5 m stood in the middle of the slip road.
	var centre: float = float(_path.viewpoint_centre_for(z))
	if absf(z - centre) > RoadPathGD.SPUR_HALF_SPAN:
		return false
	if lateral * float(_path.viewpoint_side_for(centre)) <= 0.0:
		return false
	var outer: float = (
		float(_path.spur_offset(z))
		+ float(_path.spur_half_width(z))
		+ RoadPathGD.SPUR_SHOULDER
		+ RoadPathGD.PLATFORM_TERRACE * float(_path.platform_blend(z))
	)
	return absf(lateral) <= outer + 3.0


func _pole_exists_at(z: float) -> bool:
	## Whether the chunk owning route distance `z` builds power poles at all. Own
	## theme first: a chunk built with an explicit theme (the self-checks do this)
	## must agree with itself even when the route would have picked another.
	var index := floori(z / LENGTH)
	var theme_id: int = theme if index == chunk_index else int(_path.theme_for_chunk(index))
	if not theme_carries_power_line(theme_id):
		return false
	# Cables follow these same pole decisions, so a span is only built when both
	# endpoints exist and never crosses a theme boundary or scenic junction.
	return not _junction_occupies(z, _power_line_lateral())


func _power_line() -> void:
	## Utility poles and three gently sagging cables down one side of the route.
	## Cables use the shared cube MultiMesh rather than a unique ribbon mesh per
	## chunk, so they inherit the 280 m prop cutoff and cannot alias into the long
	## black skyline needles the old unbounded ribbons produced.
	##
	## Pole positions come from world z, not from the chunk, so spacing stays
	## continuous across chunk seams. The side is fixed by the world seed too.
	const SPACING := 24.0
	const CABLE_SEGMENTS := 6
	var lx: float = _power_line_lateral()
	var pole_color := Color("4a382c")
	var cable_color := Color("17171b")
	var z0: float = float(chunk_index) * LENGTH
	var first: float = ceilf(z0 / SPACING) * SPACING
	var arm_height := func(z: float) -> float: return 8.4 + sin(z * 0.017) * 0.35

	var z: float = first
	# Half-open [z0, z0 + LENGTH): a pole landing exactly on a chunk seam belongs
	# to the chunk starting there, and used to be built twice.
	while z < z0 + LENGTH - 0.01:
		if not _pole_exists_at(z):
			z += SPACING
			continue
		# Pole and crossarm. Both are chunk-local geometry, so a pole that belongs
		# to this chunk is drawn here even when its span reaches into the next.
		var foot: Vector3 = _terrain_surface_at(z, lx) - _origin
		var head: float = arm_height.call(z)
		_cubes.append(Transform3D(Basis.IDENTITY.scaled(Vector3(0.34, head, 0.34)), foot + Vector3(0, head * 0.5, 0)))
		_cube_cols.append(pole_color)
		_cubes.append(Transform3D(Basis.IDENTITY.scaled(Vector3(2.1, 0.15, 0.15)), foot + Vector3(0, head - 0.35, 0)))
		_cube_cols.append(pole_color)
		for index in 3:
			_cubes.append(
				Transform3D(
					Basis.IDENTITY.scaled(Vector3(0.13, 0.22, 0.13)),
					foot + Vector3((float(index) - 1.0) * 0.85, head - 0.18, 0)
				)
			)
			_cube_cols.append(Color("6e7276"))
		z += SPACING

	# Each span belongs to the chunk containing its first pole. It may extend past
	# the chunk origin, which is fine; this ownership rule prevents doubled cables
	# at seams. Endpoints derive from the same pole foot and crossarm height above,
	# so no road-bank or terrain sign can stretch a segment vertically.
	var span_start: float = ceilf(z0 / SPACING) * SPACING
	while span_start < z0 + LENGTH - 0.01:
		if _pole_exists_at(span_start) and _pole_exists_at(span_start + SPACING):
			for cable_index in 3:
				for segment in CABLE_SEGMENTS:
					var ta := float(segment) / float(CABLE_SEGMENTS)
					var tb := float(segment + 1) / float(CABLE_SEGMENTS)
					var za := span_start + SPACING * ta
					var zb := span_start + SPACING * tb
					var pa := _cable_point(za, span_start, ta, cable_index, lx, arm_height)
					var pb := _cable_point(zb, span_start, tb, cable_index, lx, arm_height)
					_local_cable_segment(pa, pb, cable_color)
		span_start += SPACING


func _cable_point(
	z: float, span_start: float, t: float, cable_index: int, lateral: float, arm_height: Callable
) -> Vector3:
	var foot: Vector3 = _terrain_surface_at(z, lateral) - _origin
	var top: float = lerpf(float(arm_height.call(span_start)), float(arm_height.call(span_start + 24.0)), t)
	var sag: float = sin(t * PI) * 0.72
	var across: float = (float(cable_index) - 1.0) * 0.85
	return foot + Vector3(across, top - 0.18 - sag, 0.0)


func _local_cable_segment(a: Vector3, b: Vector3, color: Color) -> void:
	var span := b - a
	var length := span.length()
	if length < 0.001:
		return
	var up := span / length
	var side := up.cross(Vector3.FORWARD)
	if side.length_squared() < 0.0001:
		side = up.cross(Vector3.RIGHT)
	side = side.normalized()
	# Scale the local axes explicitly. Basis.scaled() applies scale in parent axes;
	# on a sloped cable that turns its long dimension toward world Y and recreates
	# the vertical needles this path exists to prevent.
	var forward := side.cross(up).normalized()
	var basis := Basis(side * 0.035, up * length, forward * 0.035)
	_cubes.append(Transform3D(basis, (a + b) * 0.5))
	_cube_cols.append(color)



func _verge_planting() -> void:
	## Rounded growth packed along the first few metres of verge, every theme.
	## This is the band the rider actually looks at, and it used to be a bare
	## coloured stripe between the curb and whatever was 20 m away.
	const DENSITY := {Env.CITY: 8, Env.FOREST: 30, Env.COAST: 16, Env.MOUNTAIN: 22, Env.COUNTRY: 26}
	var z0: float = float(chunk_index) * LENGTH
	# City verge is concrete-grey; planting it that colour reads as rubble.
	var base: Color = Color("2c4a33") if theme == Env.CITY else _pal["prop_a"]
	var alt: Color = Color("3d5c3c") if theme == Env.CITY else _pal["verge"]
	for _i in int(DENSITY[theme]):
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var side: float = 1.0 if _rng.randf() < 0.5 else -1.0
		# Sparser the further out, so the near verge stays the dense, fast-moving band.
		var lx: float = side * (HALF_WIDTH + 2.4 + pow(_rng.randf(), 1.7) * 26.0)
		var s := _rng.randf_range(0.55, 1.9)
		var col: Color = (base as Color).lerp(alt, _rng.randf() * 0.7).darkened(_rng.randf() * 0.22)
		_blob(z, lx, Vector3(s * 1.6, s * _rng.randf_range(0.7, 1.25), s * 1.5), col, 0.0, true)

	_grass_verge()

	# Low grass fringe right against the curb — reads as a soft edge to the tarmac.
	if theme == Env.CITY:
		return
	var gz := z0 + _rng.randf_range(0.0, 2.0)
	while gz < z0 + LENGTH:
		for side in [-1.0, 1.0]:
			var s := _rng.randf_range(0.35, 0.7)
			_blob(
				gz,
				side * (HALF_WIDTH + 1.9 + _rng.randf_range(0.0, 0.9)),
				Vector3(s * 2.2, s * 0.7, s * 1.4),
				(_pal["verge"] as Color).darkened(_rng.randf() * 0.3),
				0.0,
				true
			)
		gz += _rng.randf_range(1.6, 3.2)


# --------------------------------------------------------------------- themes


func _scenery_city() -> void:
	## Open tree-lined boulevard. Large procedural and imported building rows were
	## removed: at riding distance they became an oppressive wall of blank blocks.
	var z0: float = float(chunk_index) * LENGTH

	# Street lights first: they get first claim on the chunk's light budget.
	var lz := z0 + fposmod(z0, 2.0)
	while lz < z0 + LENGTH:
		var lamp_side: float = 1.0 if int(round(lz / 24.0)) % 2 == 0 else -1.0
		_street_lamp(lz, lamp_side)
		lz += 24.0

	# Sidewalk strip both sides.
	for side in [-1.0, 1.0]:
		var sz := z0 + 2.0
		while sz < z0 + LENGTH - 2.0:
			_arch_cube(sz, side * (HALF_WIDTH + 2.4), Vector3(3.2, 0.12, 4.5), _pal["curb"])
			sz += 5.0

	# Street trees in the sidewalk, offset from the lamps so they alternate.
	var tz := z0 + 8.0
	while tz < z0 + LENGTH:
		for side in [-1.0, 1.0]:
			var lx: float = side * (HALF_WIDTH + 3.1)
			_arch_cube(tz, lx, Vector3(1.5, 0.34, 1.5), _pal["curb"].darkened(0.2))
			_tree(Flora.BROADLEAF, tz, lx, _rng.randf_range(5.5, 7.0), Color("2c4a33").lightened(_rng.randf() * 0.18))
		tz += 24.0

func _street_lamp(z: float, side: float, height: float = 7.6) -> void:
	## Tapered pole, arm reaching out over the lane, a dark shade with the lens
	## tucked underneath, and a real pool of light on the tarmac. The old lamp was
	## a bare white glow box on a stick, lighting nothing.
	var lx: float = side * (HALF_WIDTH + 2.1)
	var head_lx: float = side * (HALF_WIDTH - 1.2)
	var pole: Color = (_pal["rail"] as Color).darkened(0.55)
	_cube(z, lx, Vector3(0.24, height * 0.55, 0.24), pole)
	_cube(z, lx, Vector3(0.16, height * 0.5, 0.16), pole.lightened(0.08), 0.0, height * 0.55)
	# Arm and head hang over the road, so they skip the road-footprint guard.
	_cube(
		z,
		(lx + head_lx) * 0.5,
		Vector3(absf(lx - head_lx) + 0.2, 0.13, 0.15),
		pole.lightened(0.08),
		0.0,
		height - 0.3,
		true
	)
	_cube(z, head_lx, Vector3(1.25, 0.2, 0.55), pole.darkened(0.3), 0.0, height - 0.52, true)
	_lamp(z, head_lx, Vector3(1.0, 0.07, 0.4), LAMP_WARM, height - 0.56, true)
	_glow_light(z, head_lx, height - 0.65, LAMP_LIGHT, 19.0, 4.5)


func _wall(z: float, lateral: float, size: Vector3, color: Color, lift: float = 0.0) -> void:
	## Part of a building whose footprint has already been cleared once. Skipping
	## the per-piece road check and the nine-sample terrain fit is the difference
	## between a city chunk costing a frame and costing a stutter.
	if not _structure_active:
		_arch_cube(z, lateral, size, color, 0.0, lift, true, false)
		return
	var point: Vector3 = _terrain_surface_at(z, lateral)
	point.y = _structure_foundation_y
	var basis := Basis(Vector3.UP, _path.yaw_at(z)).scaled(size)
	_arch.append(Transform3D(basis, point - _origin + Vector3(0, lift + size.y * 0.5, 0)))
	_arch_cols.append(color)


func _glass(z: float, lateral: float, size: Vector3, color: Color, lift: float) -> void:
	if not _structure_active:
		_lamp(z, lateral, size, color, lift, true)
		return
	var point: Vector3 = _terrain_surface_at(z, lateral)
	point.y = _structure_foundation_y
	var basis := Basis(Vector3.UP, _path.yaw_at(z)).scaled(size)
	_lamps.append(Transform3D(basis, point - _origin + Vector3(0, lift + size.y * 0.5, 0)))
	_lamp_cols.append(color)


func _begin_structure(z: float, lateral: float, half_lateral: float, half_depth: float) -> void:
	_structure_foundation_y = _ground_base_for_footprint(z, lateral, half_lateral, half_depth).y
	_structure_active = true


func _end_structure() -> void:
	_structure_active = false


func _city_concrete() -> Color:
	## Mix of cool concrete, warm stone, brick, glass-blue. Avoids monochrome purple cans.
	var picks: Array[Color] = [
		_pal["prop_a"] as Color,
		_pal["prop_b"] as Color,
		_pal["prop_c"] as Color,
		(_pal["prop_a"] as Color).lightened(0.12),
		(_pal["prop_c"] as Color).darkened(0.1),
	]
	return picks[_rng.randi() % picks.size()]


func _city_shop(z: float, lx: float, side: float) -> void:
	## Low street block: flat roof, lit shopfront, awning, neon. `w` is the
	## across-road size, `d` the along-road size, so the wall the rider rides past
	## is the one at lateral lx - side * w/2 — the old code offset the frontage by
	## `d` and hung the glass inside the building.
	var h := _rng.randf_range(4.5, 7.5)
	var w := _rng.randf_range(6.0, 10.0)
	var d := _rng.randf_range(6.0, 9.0)
	if not _footprint_is_clear(z, lx, w * 0.55, d * 0.55):
		return
	_begin_structure(z, lx, w * 0.55, d * 0.55)
	var col := _city_concrete()
	_wall(z, lx, Vector3(w, h, d), col)
	_wall(z, lx, Vector3(w * 1.06, 0.35, d * 1.06), col.darkened(0.25), h)

	var face: float = lx - side * (w * 0.5 + 0.06)
	# Shopfront: dark frame, warm lit glass behind it.
	_wall(z, face, Vector3(0.14, 2.6, d * 0.8), col.darkened(0.4), 0.2)
	var warm: Color = _pal["glow"]
	_glass(z, face - side * 0.06, Vector3(0.08, 1.7, d * 0.66), Color(warm.r * 0.7, warm.g * 0.62, warm.b * 0.5), 0.55)
	# Awning + neon: a sign band over the door and a tube down the corner.
	var neon: Color = NEON[_rng.randi() % NEON.size()]
	_wall(z, face - side * 0.5, Vector3(1.1, 0.14, d * 0.7), _pal["accent"], 3.0)
	_glass(z, face - side * 0.12, Vector3(0.1, 0.55, d * 0.5), neon, 3.35)
	_glass(z + d * 0.42, face - side * 0.12, Vector3(0.1, 2.4, 0.16), neon, 3.9)
	# Upper floor windows on the same wall.
	_city_facade(z, lx, side, w, d, 4.0, h - 0.6)
	_end_structure()


func _city_apartment(z: float, lx: float, side: float) -> void:
	## Mid-rise on the frontage: dark retail plinth, lit window grid, balcony slabs
	## down the road-facing wall, and clutter on the roof so the skyline is not a
	## row of flat lids.
	var w := _rng.randf_range(8.0, 12.0)
	var d := _rng.randf_range(8.5, 13.0)
	var h := _rng.randf_range(9.0, 15.0)
	if not _footprint_is_clear(z, lx, w * 0.55, d * 0.55):
		return
	_begin_structure(z, lx, w * 0.55, d * 0.55)
	var col := _city_concrete()
	var face: float = lx - side * (w * 0.5 + 0.06)
	_wall(z, lx, Vector3(w, 3.2, d), col.darkened(0.35))
	_wall(z, lx, Vector3(w, h - 3.2, d), col, 3.2)
	_wall(z, lx, Vector3(w * 1.05, 0.5, d * 1.05), col.darkened(0.28), h)
	# Lit ground-floor retail behind the plinth.
	var warm: Color = _pal["glow"]
	_glass(z, face - side * 0.05, Vector3(0.08, 1.9, d * 0.7), Color(warm.r * 0.6, warm.g * 0.52, warm.b * 0.42), 0.6)
	_wall(z, face - side * 0.35, Vector3(0.8, 0.16, d * 0.8), _pal["accent"], 3.0)
	# Balconies.
	var by := 4.4
	while by < h - 1.6:
		_wall(z, face - side * 0.55, Vector3(1.2, 0.14, d * 0.62), col.lightened(0.1), by)
		_wall(z, face - side * 1.1, Vector3(0.1, 0.9, d * 0.62), col.darkened(0.3), by + 0.14)
		by += 2.7
	_city_facade(z, lx, side, w, d, 4.6, h - 1.0)
	# Roof plant, and an aircraft light on the taller ones.
	_wall(z + d * 0.2, lx + side * w * 0.2, Vector3(2.2, 1.1, 2.4), col.darkened(0.18), h + 0.5)
	_wall(z - d * 0.25, lx - side * w * 0.15, Vector3(0.9, 1.6, 0.9), _pal["rail"].darkened(0.2), h + 0.5)
	if h > 17.0:
		_glass(z, lx, Vector3(0.3, 0.3, 0.3), Color(3.0, 0.4, 0.3), h + 2.1)
	_end_structure()


func _city_tower(z: float, lx: float, side: float) -> void:
	## Rectangular skyline piece — sharp edges, setbacks, dark window grid.
	var style := _rng.randi() % 3
	# Towers sit 20 m+ back, so one clearance check for the whole massing is plenty.
	if not _footprint_is_clear(z, lx, 9.0, 7.0):
		return
	_begin_structure(z, lx, 9.0, 7.0)
	var col := _city_concrete()
	var base_col: Color = col.darkened(0.2)

	match style:
		0:
			# Office slab.
			var w := _rng.randf_range(8.0, 13.0)
			var d := _rng.randf_range(7.0, 11.0)
			var h := _rng.randf_range(15.0, 26.0)
			_wall(z, lx, Vector3(w * 1.08, 3.5, d * 1.08), base_col)
			_wall(z, lx, Vector3(w, h - 3.5, d), col, 3.5)
			var top := h * _rng.randf_range(0.12, 0.22)
			_wall(z, lx, Vector3(w * 0.68, top, d * 0.68), col.lightened(0.06), h)
			_wall(z, lx, Vector3(w * 0.75, 0.4, d * 0.75), base_col, h + top)
			_city_facade(z, lx, side, w, d, 4.0, h - 1.0)
		1:
			# Stepped two-tier.
			var w := _rng.randf_range(10.0, 15.0)
			var d := _rng.randf_range(8.0, 12.0)
			var h0 := _rng.randf_range(10.0, 16.0)
			var h1 := _rng.randf_range(8.0, 14.0)
			_wall(z, lx, Vector3(w, h0, d), col)
			_wall(z, lx, Vector3(w * 0.72, h1, d * 0.72), col.darkened(0.06), h0)
			_wall(z, lx, Vector3(w * 0.8, 0.4, d * 0.8), base_col, h0 + h1)
			_city_facade(z, lx, side, w, d, 3.0, h0 - 0.5)
			_city_facade(z, lx, side, w * 0.72, d * 0.72, h0 + 2.0, h0 + h1 - 0.5)
		_:
			# Podium + slim tower.
			var pw := _rng.randf_range(12.0, 17.0)
			var pd := _rng.randf_range(10.0, 14.0)
			var ph := _rng.randf_range(5.0, 7.5)
			var tw := _rng.randf_range(6.0, 9.0)
			var td := _rng.randf_range(6.0, 8.5)
			var th := _rng.randf_range(14.0, 24.0)
			var off := side * _rng.randf_range(1.0, 2.5)
			_wall(z, lx, Vector3(pw, ph, pd), base_col)
			_wall(z, lx, Vector3(pw * 1.04, 0.35, pd * 1.04), col.darkened(0.15), ph)
			_wall(z + 0.8, lx + off, Vector3(tw, th, td), col, ph)
			_wall(z + 0.8, lx + off, Vector3(tw * 1.05, 0.4, td * 1.05), base_col, ph + th)
			_city_facade(z + 0.8, lx + off, side, tw, td, ph + 2.0, ph + th - 1.0)
	_end_structure()


func _city_facade(z: float, lx: float, side: float, w: float, d: float, y0: float, y1: float) -> void:
	## A grid of small panes on the two walls you can actually see: the one facing
	## the road (lateral lx - side*w/2) and the one facing the oncoming rider
	## (z - d/2). Each pane is lit or dark on its own. One full-width slab per
	## floor is what turned every building into a white billboard.
	var side_face: float = lx - side * (w * 0.5 + 0.05)
	var front_z: float = z - d * 0.5 - 0.05
	var floor_h := 2.7
	var pane_h := 1.55
	var y := y0
	while y + pane_h < y1:
		var along := maxi(int(d / 2.3), 2)
		for i in along:
			var t := (float(i) + 0.5) / float(along) - 0.5
			_window_pane(
				z + t * d * 0.92, side_face, Vector3(0.1, pane_h, d / float(along) * 0.6), y
			)
		var across := maxi(int(w / 2.3), 2)
		for i in across:
			var t := (float(i) + 0.5) / float(across) - 0.5
			_window_pane(
				front_z, lx + t * w * 0.92, Vector3(w / float(across) * 0.6, pane_h, 0.1), y
			)
		y += floor_h


func _window_pane(z: float, lateral: float, size: Vector3, lift: float) -> void:
	if _rng.randf() < 0.48:
		var lit: Color = WINDOW_LIGHTS[_rng.randi() % WINDOW_LIGHTS.size()]
		var k := _rng.randf_range(0.45, 1.05)  # alpha must stay 1, so scale rgb only
		_glass(z, lateral, size, Color(lit.r * k, lit.g * k, lit.b * k), lift)
	else:
		_wall(z, lateral, size, GLASS_DARK.lightened(_rng.randf() * 0.12), lift)


func _scenery_forest() -> void:
	## Woodland comes in stands: a patch of one species, one tint, one size range,
	## with the odd stray between. An even scatter of individually random trees
	## reads as an orchard planted by a computer, which is what this used to be.
	var z0: float = float(chunk_index) * LENGTH
	for side in [-1.0, 1.0]:
		for _stand in 3:
			var stand_z := z0 + _rng.randf_range(0.0, LENGTH)
			var stand_x: float = side * (HALF_WIDTH + 5.0 + _rng.randf_range(0.0, 44.0))
			var roll := _rng.randf()
			var species: int = Flora.CONIFER if roll < 0.58 else (Flora.BIRCH if roll < 0.74 else Flora.BROADLEAF)
			var tint: Color = (_pal["prop_a"] as Color).lerp(_pal["prop_c"], _rng.randf() * 0.7)
			var tall: float = _rng.randf_range(8.0, 15.0) if species == Flora.CONIFER else _rng.randf_range(6.0, 11.0)
			for _i in 6:
				var z := stand_z + _rng.randf_range(-11.0, 11.0)
				var lx: float = stand_x + _rng.randf_range(-11.0, 11.0)
				_tree(species, z, lx, tall * _rng.randf_range(0.72, 1.15), tint.darkened(_rng.randf() * 0.2))
		# Saplings and stumps in the first few metres, so the wood starts at the verge
		# instead of behind an empty strip.
		for _i in 4:
			var z := z0 + _rng.randf_range(0.0, LENGTH)
			var lx: float = side * (HALF_WIDTH + 3.0 + _rng.randf_range(0.0, 6.0))
			_tree(
				Flora.CONIFER if _rng.randf() < 0.6 else Flora.BROADLEAF,
				z,
				lx,
				_rng.randf_range(2.2, 4.2),
				(_pal["prop_a"] as Color).darkened(_rng.randf() * 0.3)
			)
		for _i in 8:
			var z := z0 + _rng.randf_range(0.0, LENGTH)
			var lx: float = side * (HALF_WIDTH + 2.5 + _rng.randf_range(0.0, 8.0))
			var s := _rng.randf_range(0.7, 1.8)
			if _rng.randf() < 0.5:
				var rock: PackedScene = _rock_scene(_rng.randf() < 0.5)
				if rock:
					_asset_prop(rock, z, lx, s * 2.1, s * 1.1)
				else:
					_cube(z, lx, Vector3(s * 1.6, s, s * 1.6), (_pal["prop_c"] as Color).darkened(_rng.randf() * 0.25))
			else:
				_cube(z, lx, Vector3(s * 1.6, s, s * 1.6), (_pal["prop_c"] as Color).darkened(_rng.randf() * 0.25))


func _scenery_coast() -> void:
	var z0: float = float(chunk_index) * LENGTH
	# The inland bank. Eight low cool-grey blobs on warm sand used to leave this
	# side a flat, colourless strip — the one dull quarter of the coast ride. It is
	# a rugged rocky shoulder now: rocks that vary warm against cool and tall
	# against low so the dusk light has edges to catch, imported boulders for real
	# silhouette, and dune scrub in green and marram breaking the sand with colour.
	for _i in 11:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var lx := -(HALF_WIDTH + 8.0 + _rng.randf_range(0.0, 58.0))
		var roll := _rng.randf()
		if roll < 0.38:
			var rock: PackedScene = _rock_scene(_rng.randf() < 0.5)
			var s := _rng.randf_range(1.7, 4.2)
			if rock:
				_asset_prop(rock, z, lx, s * 1.7, s * 0.9, -_rng.randf_range(0.0, 2.0))
			else:
				_prism(z, lx, Vector3(s * 1.8, s * 1.4, s * 1.8), _pal["prop_c"], -_rng.randf_range(0.0, 2.0))
		elif roll < 0.68:
			# Tall angular stack, warm stone, for the skyline edge the land side lacked.
			var w := _rng.randf_range(3.0, 6.5)
			_prism(z, lx, Vector3(w, _rng.randf_range(3.4, 7.2), w * 0.8), (_pal["prop_c"] as Color).darkened(_rng.randf() * 0.32))
		else:
			# Rounded boulder, warm/cool mixed so no two catch the light the same.
			var w := _rng.randf_range(4.0, 9.0)
			_blob(z, lx, Vector3(w, _rng.randf_range(2.4, 4.8), w * 0.75), (_pal["prop_b"] as Color).lerp(_pal["prop_c"], _rng.randf() * 0.6))
	for _i in 9:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var lx := -(HALF_WIDTH + 5.0 + _rng.randf_range(0.0, 64.0))
		var w := _rng.randf_range(1.5, 3.4)
		_blob(z, lx, Vector3(w, _rng.randf_range(0.6, 1.4), w * 0.9), (_pal["prop_a"] as Color).lerp(_pal["ground_alt"], _rng.randf()).darkened(_rng.randf() * 0.2), 0.0, true)
	# Palms leaning out of the land side, with a few scrubby broadleaves behind.
	for _i in 7:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var lx := HALF_WIDTH + 3.0 + _rng.randf_range(0.0, 14.0)
		if _rng.randf() < 0.75:
			_tree(Flora.PALM, z, lx, _rng.randf_range(6.0, 10.5), (_pal["prop_a"] as Color).darkened(_rng.randf() * 0.2))
		else:
			_tree(Flora.BROADLEAF, z, lx, _rng.randf_range(4.0, 6.5), _pal["prop_a"])
	for _i in 10:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var lx := HALF_WIDTH + 14.0 + _rng.randf_range(0.0, 90.0)
		var s := _rng.randf_range(1.2, 4.5)
		if _rng.randf() < 0.65:
			var rock: PackedScene = _rock_scene(false)
			if rock:
				_asset_prop(rock, z, lx, s * 1.9, s * 0.95, -_rng.randf_range(0.0, 6.0))
			else:
				_prism(z, lx, Vector3(s * 1.8, s, s * 1.8), _pal["prop_c"], -_rng.randf_range(0.0, 6.0))
		else:
			_prism(z, lx, Vector3(s * 1.8, s, s * 1.8), _pal["prop_c"], -_rng.randf_range(0.0, 6.0))


func _scenery_mountain() -> void:
	var z0: float = float(chunk_index) * LENGTH
	for side in [-1.0, 1.0]:
		# Dark montane conifer, thinning into bare snags on the exposed ground.
		for _i in 16:
			var z := z0 + _rng.randf_range(0.0, LENGTH)
			var lx: float = side * (HALF_WIDTH + 5.0 + _rng.randf_range(0.0, 60.0))
			var h := _rng.randf_range(6.0, 15.0)
			var tint: Color = (_pal["prop_a"] as Color).darkened(_rng.randf() * 0.3)
			var roll := _rng.randf()
			if roll < 0.76:
				_tree(Flora.CONIFER, z, lx, h, tint)
			elif roll < 0.9:
				_tree(Flora.BIRCH, z, lx, h * 0.7, tint.lightened(0.12))
			else:
				_tree(Flora.BARE, z, lx, h * 0.6, BARK_DEAD.darkened(_rng.randf() * 0.3))
		for _i in 5:
			var z := z0 + _rng.randf_range(0.0, LENGTH)
			var lx: float = side * (HALF_WIDTH + 22.0 + _rng.randf_range(0.0, 75.0))
			var w := _rng.randf_range(14.0, 32.0)
			var h := _rng.randf_range(3.5, 8.0)
			var hill_color: Color = (_pal["prop_c"] as Color).darkened(_rng.randf() * 0.16)
			# Wide, low smooth-shaded forms only—never an apex or cone silhouette.
			# Single terrain sample (follow_terrain=false): a 14–32 m hump reads the
			# same on one centre sample as on the nine-sample corner fit, and twenty
			# of these per chunk were the montane equivalent of the country hedges.
			_blob(z, lx, Vector3(w, h, w * _rng.randf_range(0.75, 1.15)), hill_color, 0.0, false, false, false)
			_blob(
				z + _rng.randf_range(-w * 0.22, w * 0.22),
				lx + side * _rng.randf_range(-w * 0.18, w * 0.18),
				Vector3(w * 0.62, h * 0.72, w * 0.68),
				hill_color.lightened(0.06),
				h * 0.12,
				false,
				false,
				false
			)
	# Grass over the open ground between the trees and hills, so the slopes
	# read as turf rather than a bare tinted plane between the planting.
	for _i in 55:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var side: float = 1.0 if _rng.randf() < 0.5 else -1.0
		var lx: float = side * (HALF_WIDTH + 6.0 + pow(_rng.randf(), 1.4) * 70.0)
		var height := _rng.randf_range(0.28, 0.58)
		var xform := Transform3D(
			Basis(Vector3.UP, _rng.randf_range(0.0, TAU)).scaled(
				Vector3(_rng.randf_range(0.5, 0.9), height, _rng.randf_range(0.5, 0.9))
			),
			_terrain_surface_at(z, lx) - _origin - Vector3(0, 0.04, 0)
		)
		_grass.append(xform)
		_grass_cols.append((_pal["verge"] as Color).lerp(_pal["prop_a"], _rng.randf() * 0.5).darkened(_rng.randf() * 0.25))

	# A vermilion gate every few chunks — the landmark that tells you where you are.
	if chunk_index % 7 == 3:
		var z := z0 + LENGTH * 0.5
		for side in [-1.0, 1.0]:
			_cube(z, side * (HALF_WIDTH + 1.8), Vector3(0.55, 8.0, 0.55), _pal["accent"])
		_cube(z, 0.0, Vector3(HALF_WIDTH * 2.0 + 7.0, 0.6, 0.7), _pal["accent"], 0.0, 7.2, true, false)
		_cube(z - 0.9, 0.0, Vector3(HALF_WIDTH * 2.0 + 9.0, 0.5, 0.8), _pal["accent"], 0.0, 8.2, true, false)


func _scenery_country() -> void:
	## Rolling farmland: hedged fields running off over the hills, post-and-rail
	## along the verge, broadleaf trees and hay bales. No buildings — this route
	## is meant to feel like nobody lives out here.
	var z0: float = float(chunk_index) * LENGTH

	# Post-and-rail fence hugging both verges.
	var fz := z0
	var fseg := 0
	while fz < z0 + LENGTH - 0.01:
		for side in [-1.0, 1.0]:
			var lx: float = side * (HALF_WIDTH + 4.0)
			_cube(fz, lx, Vector3(0.12, 1.15, 0.12), _pal["rail"])
			# Rails span two post bays (8 m), the way real post-and-rail runs do,
			# rather than one terrain-fitted beam per 4 m: half the beam count, and
			# each beam is two `_terrain_surface_at` + a footprint query, so the fence
			# was the second-largest streaming cost after the hedgerows.
			if fseg % 2 == 0:
				var zend: float = minf(fz + 8.0, z0 + LENGTH)
				_terrain_beam(fz, zend, lx, 0.09, 0.09, _pal["rail"], 0.92)
				_terrain_beam(fz, zend, lx, 0.09, 0.09, _pal["rail"], 0.58)
		fz += 4.0
		fseg += 1

	# Hedgerows: field boundaries marching away from the road over the swells.
	for side in [-1.0, 1.0]:
		var hz := z0 + _rng.randf_range(0.0, 22.0)
		while hz < z0 + LENGTH:
			var out := HALF_WIDTH + 7.0
			while out < 95.0:
				var h := _rng.randf_range(1.5, 2.4)
				# follow_terrain=false: a 2.6 m hedge segment sits on a single terrain
				# sample instead of the nine-sample corner fit wide props use. That fit
				# was ~945 terrain lookups per chunk across the ~100 segments and was the
				# single largest per-chunk streaming hitch; one sample is imperceptible
				# on a hedge this narrow.
				_cube(
					hz,
					side * out,
					Vector3(2.6, h, 1.5),
					(_pal["prop_a"] as Color).darkened(_rng.randf() * 0.25),
					0.0,
					0.0,
					false,
					false
				)
				out += _rng.randf_range(2.2, 3.0)
			hz += _rng.randf_range(30.0, 60.0)

	# Hedgerow oaks, pines, the odd birch clump, and one big field tree standing
	# alone — a restrained English-country mix with no palms or tropical foliage.
	for side in [-1.0, 1.0]:
		for _i in 7:
			var z := z0 + _rng.randf_range(0.0, LENGTH)
			var lx: float = side * (HALF_WIDTH + 8.0 + _rng.randf_range(0.0, 70.0))
			var tint: Color = (_pal["prop_a"] as Color).darkened(_rng.randf() * 0.24)
			var species_roll := _rng.randf()
			if species_roll < 0.55:
				_tree(Flora.BROADLEAF, z, lx, _rng.randf_range(6.0, 10.0), tint)
			elif species_roll < 0.9:
				_tree(Flora.CONIFER, z, lx, _rng.randf_range(7.0, 12.0), tint.darkened(0.12))
			else:
				_tree(Flora.BIRCH, z, lx, _rng.randf_range(5.0, 8.0), tint.lightened(0.14))
		if _rng.randf() < 0.5:
			_tree(
				Flora.BROADLEAF,
				z0 + _rng.randf_range(0.0, LENGTH),
				side * (HALF_WIDTH + 26.0 + _rng.randf_range(0.0, 50.0)),
				_rng.randf_range(11.0, 15.0),
				(_pal["prop_a"] as Color).darkened(_rng.randf() * 0.15)
			)

	# Grass out across the fields themselves, thinning with distance — the verge
	# planting alone stops at ~13 m and left everything beyond it a bare tinted
	# ground plane instead of pasture.
	for _i in 70:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var side: float = 1.0 if _rng.randf() < 0.5 else -1.0
		var lx: float = side * (HALF_WIDTH + 10.0 + pow(_rng.randf(), 1.4) * 80.0)
		var height := _rng.randf_range(0.3, 0.62)
		var xform := Transform3D(
			Basis(Vector3.UP, _rng.randf_range(0.0, TAU)).scaled(
				Vector3(_rng.randf_range(0.5, 0.9), height, _rng.randf_range(0.5, 0.9))
			),
			_terrain_surface_at(z, lx) - _origin - Vector3(0, 0.04, 0)
		)
		_grass.append(xform)
		_grass_cols.append((_pal["verge"] as Color).lerp(_pal["prop_a"], _rng.randf() * 0.5).darkened(_rng.randf() * 0.25))

	# Round hay bales dotted through the fields, in loose little clusters rather
	# than an even scatter — the way a baler actually leaves them behind.
	for _i in 4:
		var cz := z0 + _rng.randf_range(0.0, LENGTH)
		var clx: float = (1.0 if _rng.randf() > 0.5 else -1.0) * (HALF_WIDTH + 14.0 + _rng.randf_range(0.0, 65.0))
		var bales: int = _rng.randi_range(2, 4)
		var bale_color: Color = (_pal["prop_c"] as Color).lightened(_rng.randf_range(0.0, 0.1))
		for _j in bales:
			var z := cz + _rng.randf_range(-4.0, 4.0)
			var lx: float = clx + _rng.randf_range(-4.0, 4.0)
			_hay_bale(z, lx, _rng.randf_range(0.55, 0.7), _rng.randf_range(1.1, 1.4), bale_color)

	# No farmstead, no telegraph stubs: buildings are out, and the power line is
	# built by _power_line() with real spans rather than bare poles.


func _build_distant_scenery() -> void:
	## The skyline. Two bands of overlapping cones out where the drawn ground ends,
	## so the horizon reads as a landscape continuing past the road rather than a
	## coloured plane meeting the sky.
	##
	## The near band is solid and the far band is deliberately pale: distance haze
	## is what separates one ridge line from the next, and without that fade they
	## merge into a single lump. Fog finishes the job at these ranges.
	##
	## Wide and low rather than tall and narrow — an English-downland skyline of
	## rolling hills, not an alpine wall. Every theme shares the same proportions
	## now; Mountain only goes a little higher, never back to a sharp peak.
	const BANDS := [
		{"lateral": [175.0, 235.0], "width": [110.0, 195.0], "height": [16.0, 30.0], "fade": 0.22, "count": 3},
		{"lateral": [275.0, 350.0], "width": [185.0, 305.0], "height": [26.0, 46.0], "fade": 0.48, "count": 2},
	]
	var z0 := float(chunk_index) * LENGTH
	# Pale haze colour the far ridges wash toward. Cool, so warm ground reads as
	# nearer than the ridge behind it.
	var haze := Color("899aa2")
	for side in [-1.0, 1.0]:
		if theme == Env.COAST and side < 0.0:
			continue  # preserve the open-ocean horizon
		if _on_lake and side == _vp_side:
			continue  # the overlook builds its own, taller range over the water
		for band in BANDS:
			var count: int = band["count"]
			for i in count:
				var z := z0 + (float(i) + 0.5) * LENGTH / float(count) + _rng.randf_range(-6.0, 6.0)
				var lateral_range: Array = band["lateral"]
				var lx: float = side * _rng.randf_range(lateral_range[0], lateral_range[1])
				var width_range: Array = band["width"]
				var height_range: Array = band["height"]
				var width: float = _rng.randf_range(width_range[0], width_range[1])
				var height: float = _rng.randf_range(height_range[0], height_range[1])
				# Mountain keeps a taller, more alpine range — rolling hills in
				# country, real massifs here — without going back to a saw blade.
				height *= 1.85 if theme == Env.MOUNTAIN else 0.62
				var base_color: Color = _pal["ground_alt"]
				if theme == Env.CITY:
					base_color = _pal["prop_c"]
				var color: Color = (base_color as Color).darkened(_rng.randf_range(0.16, 0.34))
				_ridge(z, lx, Vector3(width, height, width * _rng.randf_range(0.7, 1.15)), color.lerp(haze, band["fade"]))


# --------------------------------------------------------------- set pieces


func _build_landmark() -> void:
	## Something worth turning your head for. These sit far off the road, tall
	## enough to clear the roadside planting, and are the payoff for the Q/E
	## glance — the verge alone gives the rider no reason to look sideways.
	## No buildings: a copse, a dry-stone wall, a fall. Wind farms and masts
	## read as infrastructure; these read as country.
	match theme:
		Env.FOREST:
			_landmark_copse()
		Env.COAST:
			_landmark_waterfall()
		Env.MOUNTAIN:
			_landmark_waterfall()
		_:
			_landmark_wall()


func _strut(b: LowPoly, from: Vector3, to: Vector3, radius: float, color: Color) -> void:
	## Capsule spanning two points, at any angle. The primitives are all axis
	## aligned, and a lattice is nothing but slanted members.
	var span := to - from
	var length := span.length()
	if length < 1e-4:
		return
	var up := span / length
	var side := up.cross(Vector3.FORWARD)
	if side.length_squared() < 1e-6:
		side = up.cross(Vector3.RIGHT)
	side = side.normalized()
	b.add_capsule(
		Transform3D(Basis(side, up, side.cross(up).normalized()), (from + to) * 0.5), radius, length, 6, color
	)


func _landmark_mesh(b: LowPoly, node_name: String) -> void:
	## Landmarks get their own mesh instead of joining the batched prop buckets,
	## because those cull at 280 m and the streamer runs 360 m ahead — a forty
	## metre mast would visibly pop into existence down the road.
	var mesh: MeshInstance3D = b.commit_to(self, node_name)
	if mesh:
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _landmark_wind_farm() -> void:
	## Tower, nacelle and rotor are one machine. The old version stuffed the
	## tower into the ridge bucket — a downland hump scaled up — so the spinning
	## disc hung in the air above a hill.
	var z0 := float(chunk_index) * LENGTH
	var side: float = 1.0 if _rng.randf() < 0.5 else -1.0
	var steel: Color = Color("e6e9ee").darkened(0.08)
	var nacelle_col: Color = Color("d5dae2")
	var b := LowPoly.new()
	for i in 3:
		var z := z0 + 5.0 + float(i) * 13.0 + _rng.randf_range(-3.0, 3.0)
		var lx: float = side * _rng.randf_range(82.0, 155.0)
		var height: float = _rng.randf_range(24.0, 34.0)
		var scale: float = height / 30.0
		var ground: Vector3 = _terrain_surface_at(z, lx) - _origin
		var hub: Vector3 = ground + Vector3(0.0, height, 0.0)
		var forward: Vector3 = (_path.frame_flat_at(z).x * -side)
		if forward.length_squared() < 1e-6:
			forward = Vector3.FORWARD
		else:
			forward = forward.normalized()
		# +Z toward the road so the disc faces the saddle and the nacelle sits
		# behind the hub instead of in front of the blades.
		var facing := Basis.looking_at(forward, Vector3.UP, true)

		b.add_loft(
			PackedVector3Array([ground + Vector3(0.0, -1.4, 0.0), hub]),
			PackedVector2Array([Vector2(1.22, 1.22) * scale, Vector2(0.50, 0.50) * scale]),
			8,
			steel
		)
		b.add_cylinder(Transform3D(Basis.IDENTITY, hub - Vector3(0.0, 0.28 * scale, 0.0)), 0.58 * scale, 1.0 * scale, 8, steel)

		var nacelle_len := 4.6 * scale
		var nacelle_h := 1.58 * scale
		var nacelle_w := 1.62 * scale
		# Front face of the nacelle is at the hub, so the rotor mounts into it.
		var nacelle_pos: Vector3 = hub - forward * (nacelle_len * 0.5) + Vector3(0.0, 0.18 * scale, 0.0)
		b.add_rounded_box(
			Transform3D(facing, nacelle_pos),
			Vector3(nacelle_w, nacelle_h, nacelle_len),
			0.22 * scale,
			nacelle_col
		)

		var rotor_pos: Vector3 = hub + forward * (0.52 * scale)
		var node := Node3D.new()
		node.name = "Turbine%d" % i
		node.set_script(TurbineGD)
		node.set("speed", _rng.randf_range(0.42, 0.72) * (-1.0 if _rng.randf() < 0.3 else 1.0))
		node.transform = Transform3D(facing, rotor_pos)
		node.scale = Vector3.ONE * scale
		var mesh := MeshInstance3D.new()
		mesh.mesh = rotor_mesh()
		mesh.material_override = LowPoly.solid_material()
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.add_child(mesh)
		add_child(node)
	_landmark_mesh(b, "WindFarm")


func _landmark_mast() -> void:
	## Lattice mast with a beacon on top: barely there by day, a slow red pulse on
	## the skyline at night. Built as real slanted legs and bracing — a stack of
	## tapering boxes reads as a chimney, not a mast.
	var z := float(chunk_index) * LENGTH + _rng.randf_range(8.0, 30.0)
	var side: float = 1.0 if _rng.randf() < 0.5 else -1.0
	var lx: float = side * _rng.randf_range(75.0, 135.0)
	var height: float = _rng.randf_range(32.0, 48.0)
	var steel: Color = Color("aab1bb").darkened(0.18)
	var base: Vector3 = _terrain_surface_at(z, lx) - _origin
	var corners := [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]
	var spread := func(t: float) -> float: return lerpf(1.75, 0.42, t)
	var at := func(corner: Vector2, t: float) -> Vector3:
		var r: float = spread.call(t)
		return base + Vector3(corner.x * r, height * t, corner.y * r)

	var b := LowPoly.new()
	const LEVELS := 6
	for i in corners.size():
		var corner: Vector2 = corners[i]
		var next: Vector2 = corners[(i + 1) % corners.size()]
		_strut(b, at.call(corner, 0.0), at.call(corner, 1.0), 0.16, steel)
		for level in LEVELS + 1:
			var t := float(level) / float(LEVELS)
			_strut(b, at.call(corner, t), at.call(next, t), 0.10, steel)
			# Diagonal in each bay, alternating direction up the mast.
			if level < LEVELS:
				var t_next := float(level + 1) / float(LEVELS)
				if (level + i) % 2 == 0:
					_strut(b, at.call(corner, t), at.call(next, t_next), 0.08, steel)
				else:
					_strut(b, at.call(next, t), at.call(corner, t_next), 0.08, steel)
	_landmark_mesh(b, "Mast")

	var beacon := MeshInstance3D.new()
	beacon.name = "Beacon"
	beacon.mesh = unit_sphere()
	beacon.material_override = beacon_material()
	beacon.position = base + Vector3(0, height + 0.9, 0)
	beacon.scale = Vector3.ONE * 1.6
	beacon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(beacon)


func _landmark_side(z: float) -> float:
	return 1.0 if posmod(hash(Vector2i(chunk_index, int(_path.world_seed))), 2) == 0 else -1.0


func _landmark_waterfall() -> void:
	## A fall on a hillside, far enough out that it is a glance not a roadside
	## fountain. Never on the overlook: that view is empty country, and a strip
	## of white water in it reads as a prop.
	var z0 := float(chunk_index) * LENGTH
	var z: float = z0 + _rng.randf_range(10.0, 28.0)
	var side: float = _landmark_side(z)
	var lx: float = side * _rng.randf_range(96.0, 148.0)
	if _on_tarmac(z, lx, 8.0):
		return
	var high: Vector3 = _terrain_surface_at(z, lx) - _origin
	var low: Vector3 = _terrain_surface_at(z, lx + side * 16.0) - _origin
	var drop: float = high.y - low.y
	if drop < 8.0:
		low = high + Vector3(0.0, -_rng.randf_range(14.0, 22.0), 0.0)
		drop = high.y - low.y
	if theme == Env.MOUNTAIN:
		low.y -= 8.0
		drop = high.y - low.y
	var rock := Color("5a554c").darkened(_rng.randf() * 0.08)
	for i in 5:
		var s := _rng.randf_range(2.2, 4.4)
		_blob(
			z + _rng.randf_range(-3.0, 3.0),
			lx + side * _rng.randf_range(-2.0, 10.0),
			Vector3(s * 1.6, s * 1.1, s * 1.4),
			rock.darkened(_rng.randf() * 0.1),
			0.0,
			false,
			true
		)
	var b := LowPoly.new()
	var width: float = 3.4 if theme == Env.COAST else 2.6
	var along: Vector3 = (_path.frame_flat_at(z) as Basis).z * width
	var water := Color("8eb8b4")
	var foam := Color("c5ddd8")
	var top_a: Vector3 = high + Vector3(0.0, 0.6, 0.0) - along * 0.5
	var top_b: Vector3 = high + Vector3(0.0, 0.6, 0.0) + along * 0.5
	var bot_a: Vector3 = low + Vector3(0.0, 0.4, 0.0) - along * 0.35
	var bot_b: Vector3 = low + Vector3(0.0, 0.4, 0.0) + along * 0.35
	b.add_quad(top_a, top_b, bot_b, bot_a, water)
	b.add_quad(top_a + along * 0.18, top_b - along * 0.18, bot_b - along * 0.12, bot_a + along * 0.12, foam)
	var mesh: MeshInstance3D = b.commit_to(self, "Waterfall")
	if mesh:
		mesh.material_override = water_material()
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mesh.visibility_range_end = 420.0


func _landmark_wall() -> void:
	## Dry-stone following a fold of the hill, not a property boundary. It has
	## to run with the ground or it reads as a fence the chunk forgot to hide.
	var z0 := float(chunk_index) * LENGTH
	var side: float = _landmark_side(z0)
	var base_lat: float = side * _rng.randf_range(88.0, 132.0)
	var stone := Color("8a8478").darkened(0.08)
	var cap := stone.lightened(0.12)
	var built := false
	for i in 8:
		var za: float = z0 + 4.0 + float(i) * 4.0
		var zb: float = za + 4.0
		var lat: float = base_lat + side * 4.2 * sin(za * 0.045)
		if _on_tarmac(za, lat, 2.2) or _on_tarmac(zb, lat, 2.2):
			continue
		_terrain_beam(za, zb, lat, 0.42, 0.92, stone, 0.46)
		_terrain_beam(za, zb, lat, 0.48, 0.16, cap, 0.96)
		if i % 2 == 0:
			_cube(za, lat, Vector3(0.5, 1.05, 0.55), stone.darkened(0.06))
		built = true
	if built:
		var marker := Node3D.new()
		marker.name = "RidgeWall"
		add_child(marker)


func _landmark_copse() -> void:
	## A knoll with its own stand, dense enough to read as one thing from the
	## saddle. Scattered verge trees are already everywhere; this is a place.
	var z0 := float(chunk_index) * LENGTH
	var z: float = z0 + _rng.randf_range(12.0, 26.0)
	var side: float = _landmark_side(z)
	var lx: float = side * _rng.randf_range(90.0, 140.0)
	if _on_tarmac(z, lx, 10.0):
		return
	var knoll := Color("3a4a38").lerp(_pal["ground"], 0.35)
	_blob(z, lx, Vector3(16.0, 4.2, 13.0), knoll, 0.0, false, true)
	var tint := Color("1a3026").lerp(Color("2a4a34"), 0.4)
	for i in 11:
		var tz: float = z + _rng.randf_range(-6.5, 6.5)
		var tlat: float = lx + _rng.randf_range(-7.0, 7.0)
		if _on_tarmac(tz, tlat, 1.6):
			continue
		var species: int = Flora.CONIFER if _rng.randf() < 0.55 else Flora.BROADLEAF
		if theme == Env.FOREST and _rng.randf() < 0.25:
			species = Flora.BIRCH
		_tree(species, tz, tlat, _rng.randf_range(9.0, 16.0), tint, true, 1.6)
	var marker := Node3D.new()
	marker.name = "Copse"
	add_child(marker)


func _build_set_piece() -> void:
	## Set pieces are deterministic per chunk, so a streamed chunk is identical
	## whenever the player reaches it and the route keeps a readable rhythm.
	## There are no painted detour overlays: every visible strip is part of the
	## one continuous road ribbon, and scenery stays outside its hard boundary.
	##
	## Villages, fuel stations, roadworks and bridges are gone on purpose. They
	## put houses, forecourts, cone lines and slab pylons beside the road, and
	## this is meant to read as an empty country route.
	# The viewpoint owns its chunk. A tunnel or switchback here used to put a wall
	# directly across the parking entrance and hide the sign.
	if _on_spur:
		# No tunnel mouth, switchback wall or wind farm inside an overlook: they
		# put geometry across the junction and the view.
		_build_spur_furniture()
		_build_junction()
		if _owns_platform:
			_set_piece_platform()
		return
	if theme == Env.MOUNTAIN:
		match absi(chunk_index) % 4:
			0:
				_set_piece_tunnel()
			1:
				_set_piece_switchback()
			_:
				pass
	if absi(chunk_index) % 7 == 3:
		_build_landmark()


static func is_viewpoint_chunk(index: int, theme_id: int) -> bool:
	## Which chunk owns the platform furniture. The overlook itself spans a dozen
	## chunks — spur road, headland, lake — and this picks out the one sitting
	## over its centre, so the benches get built exactly once.
	var centre := viewpoint_centre_static((float(index) + 0.5) * LENGTH)
	return floori(centre / LENGTH) == index and theme_id in [Env.FOREST, Env.COAST, Env.MOUNTAIN, Env.COUNTRY]


static func viewpoint_centre_static(z: float) -> float:
	return RoadPathGD.viewpoint_centre_static(z)


static func viewpoint_side(index: int, world_seed: int) -> float:
	var centre := viewpoint_centre_static((float(index) + 0.5) * LENGTH)
	return 1.0 if posmod(hash(Vector2i(int(round(centre)), world_seed)), 2) == 0 else -1.0


# ------------------------------------------------------------------- overlooks
#
# The detour, in the order the rider meets it:
#
#   a sign 240 m out  ->  a deceleration lane  ->  a hatched gore where a spur
#   peels away  ->  a long climbing forest road  ->  a ridge  ->  a parking
#   terrace on a headland above a dark lake  ->  scree to the water, a pass
#   between fells, haze  ->  the spur back down to a second junction.
#
# No hamlet, no campanile, no trees standing in the water. The view is empty
# country: Wastwater's screes, a Glen Coe pass, a lake that holds the sky.
#
# The shape of all of it — where the spur runs, how high it climbs, where the
# headland falls into the water — belongs to RoadPath, so every chunk agrees.
# What follows is the surfacing, the furniture and the planting on top. The
# basin geometry is shared; the view from the platform follows this chunk's
# biome: country lake and pass, forest gorge, coastal headland, mountain tarn.


func _build_spur_ribbon(hard: LowPoly, road: LowPoly, z0: float) -> void:
	## The spur's own road surface. It is a separate ribbon laid over ground the
	## path has already flattened for it, sitting 60 mm proud like real
	## surfacing — which is also what keeps it out of a z-fight with the terrain
	## it covers.
	const PROUD := 0.06
	const LINE := 0.012
	## Below this the gore is too narrow to hold a shoulder and an edge line of
	## its own: they would be painted on the carriageway's own edge, which is what
	## the two roads share until the spur pulls away.
	const GORE_OPEN := 1.6
	var step := LENGTH / float(STEPS)
	var shoulder: Color = _pal["shoulder"]
	var stripe: Color = _pal["stripe"]
	var inner_edge := 0 if _vp_side > 0.0 else 1  # which end of the span faces the road
	for i in STEPS:
		var za := z0 + float(i) * step
		var zb := za + step
		var span_a := _spur_span(za)
		var span_b := _spur_span(zb)
		if span_a == Vector2.ZERO and span_b == Vector2.ZERO:
			continue
		# The junction closes to a point on the carriageway's edge, never on the
		# spur's outer one — pinned to the wrong corner, the last quad of the mouth
		# is a triangle laid across the road.
		if span_a == Vector2.ZERO:
			var pin_a: float = span_b.x if inner_edge == 0 else span_b.y
			span_a = Vector2(pin_a, pin_a)
		if span_b == Vector2.ZERO:
			var pin_b: float = span_a.x if inner_edge == 0 else span_a.y
			span_b = Vector2(pin_b, pin_b)
		var gore_a: float = float(_path.spur_gap(za))
		var gore_b: float = float(_path.spur_gap(zb))
		road.add_quad_uv(
			_p(za, span_a.x, -PROUD),
			_p(za, span_a.y, -PROUD),
			_p(zb, span_b.y, -PROUD),
			_p(zb, span_b.x, -PROUD),
			_pal["road"],
			# Road space local to the spur, so the shader's wheel tracks land in
			# its lanes rather than in the main carriageway's.
			Vector2(_spur_local(za, span_a.x), za),
			Vector2(_spur_local(za, span_a.y), za),
			Vector2(_spur_local(zb, span_b.y), zb),
			Vector2(_spur_local(zb, span_b.x), zb)
		)
		# Surfaced shoulder falling back to the flattened ground either side. The
		# one facing the road waits for the gore to open: laid before that it runs
		# up the carriageway's edge line as a two-metre band of gravel, which is
		# most of what made the junction look like a repair rather than a road.
		for edge in [-1.0, 1.0]:
			var facing_road: bool = (edge < 0.0) == (inner_edge == 0)
			if facing_road and minf(gore_a, gore_b) < RoadPathGD.SPUR_SHOULDER + GORE_OPEN:
				continue
			var la: float = span_a.x if edge < 0.0 else span_a.y
			var lb: float = span_b.x if edge < 0.0 else span_b.y
			var oa: float = la + edge * RoadPathGD.SPUR_SHOULDER
			var ob: float = lb + edge * RoadPathGD.SPUR_SHOULDER
			if edge < 0.0:
				hard.add_quad(_p(za, oa, 0.0), _p(za, la, -PROUD), _p(zb, lb, -PROUD), _p(zb, ob, 0.0), shoulder)
			else:
				hard.add_quad(_p(za, la, -PROUD), _p(za, oa, 0.0), _p(zb, ob, 0.0), _p(zb, lb, -PROUD), shoulder)
		if span_a.y - span_a.x < 1.2:
			continue
		# Edge lines, and a dashed centre line on the running sections only — a
		# painted centre line across a car park would be nonsense.
		for edge in [-1.0, 1.0]:
			var on_road_side: bool = (edge < 0.0) == (inner_edge == 0)
			if on_road_side and minf(gore_a, gore_b) < GORE_OPEN:
				continue  # the carriageway's own edge line is already there
			var la: float = (span_a.x + 0.45) if edge < 0.0 else (span_a.y - 0.45)
			var lb: float = (span_b.x + 0.45) if edge < 0.0 else (span_b.y - 0.45)
			hard.add_quad(
				_p(za, la - 0.1, -PROUD - LINE),
				_p(za, la + 0.1, -PROUD - LINE),
				_p(zb, lb + 0.1, -PROUD - LINE),
				_p(zb, lb - 0.1, -PROUD - LINE),
				stripe
			)
		if float(_path.spur_half_width(za)) < RoadPathGD.SPUR_HALF_WIDTH + 1.0 and fposmod(za, 7.0) < 3.6:
			var ca := (span_a.x + span_a.y) * 0.5
			var cb := (span_b.x + span_b.y) * 0.5
			hard.add_quad(
				_p(za, ca - 0.09, -PROUD - LINE),
				_p(za, ca + 0.09, -PROUD - LINE),
				_p(zb, cb + 0.09, -PROUD - LINE),
				_p(zb, cb - 0.09, -PROUD - LINE),
				stripe
			)
	_build_platform_bays(hard, z0)
	_build_decel_lane(hard, z0)
	_build_gore_hatch(hard, z0)
	_build_spur_barrier(hard, z0)


func _spur_barrier_out(z: float) -> float:
	## Unsigned lateral of the barrier line: just inside the outer lip of the made
	## ground, so it stands where the ground starts to fall away. It follows the
	## terrace out around the platform and back, which is what makes it one line
	## from junction to junction rather than three fences in a row.
	return (
		float(_path.spur_offset(z))
		+ float(_path.spur_half_width(z))
		+ RoadPathGD.SPUR_SHOULDER
		+ RoadPathGD.PLATFORM_TERRACE * float(_path.platform_blend(z))
		- 0.45
	)


func _spur_yaw(z: float) -> float:
	## Heading of the spur relative to the carriageway. Everything placed beside
	## the spur needs it: a post or a sign squared up to the route is visibly
	## crooked once the road it belongs to has turned away from it.
	var ahead: float = float(_path.spur_offset(z + 2.0)) - float(_path.spur_offset(z - 2.0))
	return atan2(_vp_side * ahead, 4.0)


func _build_decel_lane(hard: LowPoly, z0: float) -> void:
	## Dashed line along the old carriageway edge while the extra lane is still
	## bolted on. Without it the mouth is just the road getting wider, which is
	## how the junction used to vanish into a smear of tarmac.
	const PROUD := 0.07
	const LINE := 0.012
	var stripe: Color = _pal["stripe"]
	var step := LENGTH / float(STEPS)
	var edge: float = _vp_side * (HALF_WIDTH + 0.08)
	for i in STEPS:
		var za := z0 + float(i) * step
		var zb := za + step
		if float(_path.spur_half_width(za)) < 1.4:
			continue
		if float(_path.spur_gap(za)) > 2.2:
			continue
		if int(floor(za / 4.5)) % 2 == 0:
			continue
		hard.add_quad(
			_p(za, edge - 0.11, -PROUD - LINE),
			_p(za, edge + 0.11, -PROUD - LINE),
			_p(zb, edge + 0.11, -PROUD - LINE),
			_p(zb, edge - 0.11, -PROUD - LINE),
			stripe
		)


func _build_gore_hatch(hard: LowPoly, z0: float) -> void:
	## Painted chevrons in the gore, so the fork is a mark on the road rather than
	## a sudden extra lane of tarmac. Only while the gap is wide enough to hold
	## paint and narrow enough to still read as a junction.
	const PROUD := 0.07
	var stripe: Color = _pal["stripe"]
	var step := LENGTH / float(STEPS)
	for i in STEPS:
		var za := z0 + float(i) * step
		var zb := za + step
		var ga: float = float(_path.spur_gap(za))
		var gb: float = float(_path.spur_gap(zb))
		if minf(ga, gb) < 1.6 or maxf(ga, gb) > 11.0:
			continue
		if int(floor(za / 2.8)) % 2 == 0:
			continue
		var inner_a: float = _vp_side * (HALF_WIDTH + 0.35)
		var inner_b: float = _vp_side * (HALF_WIDTH + 0.35)
		var outer_a: float = _vp_side * (float(_path.spur_offset(za)) - float(_path.spur_half_width(za)) - 0.35)
		var outer_b: float = _vp_side * (float(_path.spur_offset(zb)) - float(_path.spur_half_width(zb)) - 0.35)
		if _vp_side > 0.0:
			hard.add_quad(
				_p(za, inner_a, -PROUD),
				_p(za, outer_a, -PROUD),
				_p(zb, outer_b, -PROUD),
				_p(zb, inner_b, -PROUD),
				stripe
			)
		else:
			hard.add_quad(
				_p(za, outer_a, -PROUD),
				_p(za, inner_a, -PROUD),
				_p(zb, inner_b, -PROUD),
				_p(zb, outer_b, -PROUD),
				stripe
			)


func _build_spur_barrier(hard: LowPoly, z0: float) -> void:
	## The barrier along the drop, built as one continuous beam.
	##
	## It used to be a box for the post and a box for the rail, spaced along the
	## *route* and yawed to the *carriageway*. Neither survives a road that runs
	## across the route: fifty metres out, two metres of route is not two metres
	## of barrier, so every rail fell short of the next one and turned the wrong
	## way — a line of staples dropped in the grass with daylight between them.
	## Here each segment spans two points on the barrier's own line, so
	## consecutive segments share their end faces exactly and it closes up. Both
	## neighbours evaluate the same pure function at a chunk seam, so it closes
	## there too.
	## Deep enough to be a crash barrier along the climb, and thinned to a rail
	## across the platform. That is a sight-line decision: the bench is two metres
	## inside this line, and a 40 cm beam at that distance blocks everything
	## between 8 and 20 degrees below the horizon — which is the near half of the
	## water, the part that says the platform is standing above it.
	const FOOT := 0.52  # underside of the beam above the deck
	const RAIL_FOOT := 0.12  # ...on the platform, where it becomes a low view curb
	const HEAD := 0.94  # and its top, throughout
	const VIEW_HEAD := 0.20
	const THICK := 0.045  # half section, taken across the line
	var rail: Color = _pal["rail"]
	var step := LENGTH / float(STEPS)
	for i in STEPS:
		var za := z0 + float(i) * step
		var zb := za + step
		# Nothing at the very mouth of the junction: there is no drop to guard
		# there and a barrier would be standing in the road.
		if float(_path.spur_half_width(za)) < 2.2 or float(_path.spur_half_width(zb)) < 2.2:
			continue
		# The platform owns a stone parapet; a steel rail here would sit on top of
		# the belvedere and read as scaffolding.
		if float(_path.platform_blend(za)) > 0.55 and float(_path.platform_blend(zb)) > 0.55:
			continue
		var la: float = _vp_side * _spur_barrier_out(za)
		var lb: float = _vp_side * _spur_barrier_out(zb)
		var foot_a: float = lerpf(FOOT, RAIL_FOOT, float(_path.platform_blend(za)))
		var foot_b: float = lerpf(FOOT, RAIL_FOOT, float(_path.platform_blend(zb)))
		var platform_mix: float = maxf(float(_path.platform_blend(za)), float(_path.platform_blend(zb)))
		var segment_rail: Color = rail.lerp(Color("455356"), platform_mix * 0.82)
		var head_a: float = lerpf(HEAD, VIEW_HEAD, float(_path.platform_blend(za)))
		var head_b: float = lerpf(HEAD, VIEW_HEAD, float(_path.platform_blend(zb)))
		var a_top := _p(za, la, -head_a)
		var b_top := _p(zb, lb, -head_b)
		var a_foot := _p(za, la, -foot_a)
		var b_foot := _p(zb, lb, -foot_b)
		var out: Vector3 = (_p(za, la + 1.0, -head_a) - a_top).normalized() * THICK
		hard.add_quad(a_foot - out, b_foot - out, b_top - out, a_top - out, segment_rail.lightened(0.1))
		hard.add_quad(b_foot + out, a_foot + out, a_top + out, b_top + out, segment_rail.darkened(0.14))
		hard.add_quad(a_top - out, b_top - out, b_top + out, a_top + out, segment_rail)
		if fposmod(za, 4.0) < step:
			_deck_cube(za, la, Vector3(0.13, head_a, 0.13), segment_rail.darkened(0.22), _spur_yaw(za), 0.0)


func _spur_span(z: float) -> Vector2:
	## Signed lateral span of the spur surface at z, ordered low to high so every
	## quad built from it winds face-up whichever side the overlook is on.
	var span: Vector2 = _path.spur_interval(z)
	if span == Vector2.ZERO:
		return span
	return Vector2(minf(span.x, span.y), maxf(span.x, span.y))


func _spur_local(z: float, lateral: float) -> float:
	return (lateral - _vp_side * float(_path.spur_offset(z))) * _vp_side


func _build_platform_bays(hard: LowPoly, z0: float) -> void:
	## Marked parking bays along the outer edge of the platform, drawn into the
	## ribbon so they lie exactly on it however the ground rolls underneath.
	const PROUD := 0.072
	# One bay deep, set off the outer kerb. Expressed against the platform's own
	# half-width rather than in absolute metres, so narrowing the platform moves
	# the markings with it instead of painting them off the edge.
	const BAY_DEPTH := 5.5
	const BAY_SETBACK := 1.2
	var stripe: Color = _pal["stripe"]
	var full: float = RoadPathGD.PLATFORM_HALF_WIDTH * 0.84
	var reach: float = RoadPathGD.PLATFORM_HALF_LENGTH - 4.0
	var bay := _vp_centre - reach
	while bay <= _vp_centre + reach + 0.01:
		if bay >= z0 and bay < z0 + LENGTH:
			var offset: float = float(_path.spur_offset(bay))
			var half: float = float(_path.spur_half_width(bay))
			if half > full:
				var inner: float = offset + half - BAY_DEPTH - BAY_SETBACK
				var outer: float = offset + half - BAY_SETBACK
				for t in 8:
					var la: float = _vp_side * lerpf(inner, outer, float(t) / 8.0)
					var lb: float = _vp_side * lerpf(inner, outer, float(t + 1) / 8.0)
					if la > lb:
						var swap := la
						la = lb
						lb = swap
					hard.add_quad(
						_p(bay - 0.09, la, -PROUD),
						_p(bay - 0.09, lb, -PROUD),
						_p(bay + 0.09, lb, -PROUD),
						_p(bay + 0.09, la, -PROUD),
						stripe
					)
		bay += 4.8
	# A painted line along the front of the bays, so they read as bays rather
	# than as stripes on an apron.
	var run := z0
	var step := LENGTH / float(STEPS)
	while run < z0 + LENGTH - 0.001:
		var next := run + step
		var half_a: float = float(_path.spur_half_width(run))
		var half_b: float = float(_path.spur_half_width(next))
		if half_a > full and half_b > full and absf(run - _vp_centre) <= reach:
			var la: float = _vp_side * (float(_path.spur_offset(run)) + half_a - BAY_DEPTH - BAY_SETBACK)
			var lb: float = _vp_side * (float(_path.spur_offset(next)) + half_b - BAY_DEPTH - BAY_SETBACK)
			hard.add_quad(
				_p(run, la - 0.1, -PROUD),
				_p(run, la + 0.1, -PROUD),
				_p(next, lb + 0.1, -PROUD),
				_p(next, lb - 0.1, -PROUD),
				stripe
			)
		run = next


func _build_spur_furniture() -> void:
	## Marker posts along the inner edge of the climb. The barrier on the drop
	## side is ribbon geometry — see _build_spur_barrier() — because a fence made
	## of boxes spaced along the route cannot follow a road that leaves it.
	var z0 := float(chunk_index) * LENGTH
	var rail: Color = _pal["rail"]
	var z := z0
	while z < z0 + LENGTH - 0.01:
		var half: float = float(_path.spur_half_width(z))
		# Inner edge only, where the road is cut into the hillside: marked rather
		# than fenced.
		if half > 2.2 and fposmod(z, 12.0) < 3.0:
			var inner: float = _vp_side * (float(_path.spur_offset(z)) - half - 1.4)
			_cube(z, inner, Vector3(0.1, 0.95, 0.1), rail.lightened(0.2), _spur_yaw(z), 0.0, true)
			_lamp(z, inner, Vector3(0.1, 0.09, 0.05), REFLECTOR, 0.8, true)
		z += 3.0


func _build_junction() -> void:
	## Where the spur leaves and rejoins the carriageway: the sign, a hatched
	## gore, and a chevron board at the nose. This is the whole invitation — if
	## it is not legible at 180 km/h the rider never takes the detour.
	var z0 := float(chunk_index) * LENGTH
	var entry := _vp_centre - RoadPathGD.SPUR_HALF_SPAN
	# Both boards stand on the main-road verge *before* the extra lane exists, so
	# the rider is not asked to read a sign standing in the tarmac they just
	# opened. The far one is a distance plate; the near one is the P.
	for pair in [[entry - 240.0, true], [entry - 90.0, false]]:
		var at: float = float(pair[0])
		if at >= z0 and at < z0 + LENGTH:
			_build_viewpoint_sign(at, _vp_side, bool(pair[1]))
	# Chevron board at the nose of the gore — where the gore is actually wide
	# enough to stand a board in. Placed at a fixed distance into the mouth it
	# stood on tarmac the rider is invited to ride across, and they rode through
	# it every time.
	var nose := _spur_nose()
	if nose >= z0 and nose < z0 + LENGTH:
		var lateral: float = _vp_side * (float(_path.spur_offset(nose)) - float(_path.spur_half_width(nose)) - 1.8)
		var yaw := _spur_yaw(nose) * 0.5  # splits the angle between the two roads
		_cube(nose, lateral, Vector3(0.18, 1.7, 0.18), Color("626a70"), yaw, 0.0, true)
		_cube(nose, lateral, Vector3(2.3, 1.05, 0.16), Color("f0b33b"), yaw, 1.7, true)
		_cube(nose, lateral, Vector3(2.3, 0.14, 0.18), Color("2b2f36"), yaw, 2.2, true)


func _spur_nose() -> float:
	## First point past the junction where the gore has opened enough to hold the
	## chevron board clear of both carriageways.
	var entry := _vp_centre - RoadPathGD.SPUR_HALF_SPAN
	var z := entry
	while z < entry + RoadPathGD.SPUR_RAMP:
		if float(_path.spur_gap(z)) >= 3.0:
			return z
		z += 2.0
	return entry + RoadPathGD.SPUR_MOUTH


func _build_viewpoint_landscape() -> void:
	## Runs in every chunk the basin reaches, so the water and the far side
	## stream with the ground they sit on. Built once in the centre chunk they
	## vanished the moment that chunk unloaded, leaving a dry hole in the valley.
	if not _on_lake:
		return
	_build_lake_basin()
	_build_lake_distance()
	_build_lake_dressing()


## The three stages of an overlook's landscape, in the order the eye reads them.
## Kept as named stages because the streaming path builds them one per frame and
## has to be able to reach exactly the same set of work.
func _build_lake_basin() -> void:
	_build_lake_water()
	_build_far_ground()


func _build_lake_distance() -> void:
	_build_view_range()
	_build_peak_clouds()
	_build_far_shore()
	_build_far_cliffs()
	_build_coast_headland()


func _build_lake_dressing() -> void:
	_build_lake_edges()
	_build_view_frame()
	_dress_vista()
	_build_vista_birds()
	_build_vista_landmarks()


## The framing stand, written as (angle off the view axis, distance out from the
## eye, height).
##
## The angle is measured horizontally and has to be judged against the *hori-
## zontal* field of view, which on a 16:9 frame is far wider than the number on
## the camera: at the seated 62° vertical it is about 94° across, so the edge of
## the picture is 47° off the axis, not 31°. Sized against the vertical figure
## the whole stand landed inside 38° — which is halfway to the middle of the
## frame, standing in the view rather than framing it.
##
## Distance matters as much as angle. The headland falls away steeply, so a tree
## a hundred metres out has its feet forty metres below the eye and its top still
## under the horizon, where it reads as scrub on a far bank. Close and tall is
## what puts a dark edge against the sky.
const FRAME_CLUMP := [
	[34.0, 30.0, 24.0], [39.0, 42.0, 30.0], [36.0, 55.0, 27.0],
	[43.0, 36.0, 22.0], [41.0, 64.0, 29.0], [45.0, 50.0, 25.0],
	[33.0, 72.0, 32.0], [47.0, 44.0, 23.0],
]


func _build_view_frame() -> void:
	## The dark mass that makes the view a picture instead of a panorama.
	##
	## This used to plant its pines at the *bench's own lateral*, a metre and a
	## half outboard of where the rider sits, spaced along the route. From a seat
	## looking square out across the valley that is ninety degrees off the axis:
	## the entire framing stand stood directly to the viewer's left and right,
	## outside the lens, and every overlook was an unframed panorama with its
	## horizon running uninterrupted from one edge of the screen to the other.
	##
	## Placed by angle instead, on the drop side where the bike cannot reach, and
	## tall enough that the tops break the skyline and overlap the far range —
	## which is what makes the distance read as distance.
	##
	## One side only, chosen from the seed. A stand on both is a proscenium arch;
	## the asymmetry is what stops the composition being a diagram.
	if _vp_theme == Env.COAST:
		# A cliff view wants open sky and open water. Pines in it are a lie about
		# what a coast is, and they would hide the one thing worth looking at.
		return
	var z0 := float(chunk_index) * LENGTH
	var hand: float = (
		1.0
		if posmod(hash(Vector2i(int(round(_vp_centre)), int(_path.world_seed) ^ 0x5f3a)), 2) == 0
		else -1.0
	)
	# Where the eye actually is, so the angles below mean what they say.
	var eye_out: float = float(_path.spur_offset(_vp_centre)) + RoadPathGD.PLATFORM_BENCH_OUT
	for spec in FRAME_CLUMP:
		var angle: float = deg_to_rad(float(spec[0]))
		var out: float = float(spec[1])
		# Jittered off the overlook's own phase so the eight specs do not read as
		# eight trees planted on a surveyor's arc.
		var wobble: float = sin(_vp_phase + float(spec[1]) * 0.11)
		var z: float = _vp_centre + hand * (out * tan(angle) + wobble * 7.0)
		if z < z0 or z >= z0 + LENGTH:
			continue
		var lateral: float = _vp_side * (eye_out + out + wobble * 5.0)
		if _on_tarmac(z, lateral, 1.6):
			continue
		# Never below the waterline: the stand sits on the face of the headland,
		# and past the near shore it would be standing in the lake.
		if _height_above_water(z, absf(lateral)) < 3.0:
			continue
		var height: float = float(spec[2]) * (0.86 + 0.22 * absf(wobble))
		var species: int = Flora.CONIFER
		var tint := Color("14261f")
		if _vp_theme == Env.MOUNTAIN:
			# Snags and dwarf pine, enough to break the skyline. Skipping most of
			# the stand left a bare shoulder and the pass read as an empty quarry.
			species = Flora.BARE if absf(wobble) < 0.45 else Flora.CONIFER
			height *= 0.78 if species == Flora.CONIFER else 0.62
			tint = Color("1a2420") if species == Flora.CONIFER else Color("2a3234")
		elif _vp_theme == Env.FOREST and absf(wobble) > 0.6:
			species = Flora.BROADLEAF
			tint = Color("12241c")
		_tree(species, z, lateral, height, tint, true)
	# Talus at the foot of the stand, tying it to the slope. Without this the
	# trees read as posts stuck into a smooth hillside.
	if _vp_theme != Env.MOUNTAIN:
		return
	for spec in FRAME_CLUMP:
		var angle: float = deg_to_rad(float(spec[0]) * 0.92)
		var out: float = float(spec[1]) * 1.06
		var z: float = _vp_centre + hand * out * tan(angle)
		if z < z0 or z >= z0 + LENGTH:
			continue
		var lateral: float = _vp_side * (eye_out + out)
		if _height_above_water(z, absf(lateral)) < 3.0:
			continue
		_vista_rock(z, lateral, _rng.randf_range(5.5, 11.0), -1.2)


func _dress_vista() -> void:
	## Each overlook is a different place. Shared basin, then a dedicated pass
	## that pours the biome: Art of Rally / Firewatch country, Big Sur coast,
	## Mononoke gorge, Glen Coe tarn. Kenney rocks are the only imported mass.
	match _vp_theme:
		Env.FOREST:
			_dress_vista_forest()
		Env.COAST:
			_dress_vista_coast()
		Env.MOUNTAIN:
			_dress_vista_mountain()
		_:
			_dress_vista_country()


func _dress_vista_forest() -> void:
	## Yakushima / Ghost of Tsushima shrine forest: the gorge is a dark slot,
	## water a long way down, cedar walls you cannot see the top of until you
	## sit. The reveal is depth, not a postcard lake.
	var z0 := float(chunk_index) * LENGTH
	for _i in 28:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		if absf(z - _vp_centre) < 18.0:
			continue
		var out: float = float(_path.viewpoint_far_shore(z, _vp_centre)) + _rng.randf_range(8.0, 55.0)
		if _height_above_water(z, out) < 6.0:
			continue
		_tree(
			Flora.CONIFER if _rng.randf() < 0.75 else Flora.BROADLEAF,
			z,
			_vp_side * out,
			_rng.randf_range(18.0, 34.0),
			Color("0e1c16").lerp(Color("1c3328"), _rng.randf()),
			true
		)
	for _i in 14:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var out: float = RoadPathGD.HEADLAND_CREST + 8.0 + _rng.randf_range(0.0, 40.0)
		if _height_above_water(z, out) < 10.0:
			continue
		if float(_path.spur_deck_blend(z, _vp_side * out)) > 0.1:
			continue
		_tree(
			Flora.CONIFER,
			z,
			_vp_side * out,
			_rng.randf_range(14.0, 24.0),
			Color("14241c"),
			true
		)
	for _i in 6:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var out: float = float(_path.viewpoint_near_shore(z)) + _rng.randf_range(-6.0, 14.0)
		_vista_rock(z, _vp_side * out, _rng.randf_range(2.4, 5.5), _rng.randf_range(-0.4, 0.8))


func _dress_vista_coast() -> void:
	## Big Sur: open water, a cliffed drop under the rail, one headland in the
	## mid-ground. Kenney boulders on the lip, not hovering in the sea.
	var z0 := float(chunk_index) * LENGTH
	for _i in 10:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var out: float = RoadPathGD.HEADLAND_CREST + 4.0 + _rng.randf_range(0.0, 22.0)
		if float(_path.spur_deck_blend(z, _vp_side * out)) > 0.12:
			continue
		if _height_above_water(z, out) < 4.0:
			continue
		_vista_rock(z, _vp_side * out, _rng.randf_range(2.8, 7.0), _rng.randf_range(-0.4, 0.2))


func _dress_vista_mountain() -> void:
	## Glen Coe from the pass: a small tarn, scree to the water, peaks that
	## actually fill the sky. Talus, snags, a few dwarf pines on the folds —
	## not a forest, but not a quarry either.
	var z0 := float(chunk_index) * LENGTH
	for _i in 22:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var out: float = RoadPathGD.HEADLAND_CREST + 4.0 + _rng.randf_range(0.0, 80.0)
		if float(_path.spur_deck_blend(z, _vp_side * out)) > 0.12:
			continue
		if _height_above_water(z, out) < 3.0:
			continue
		_vista_rock(z, _vp_side * out, _rng.randf_range(2.4, 8.5), _rng.randf_range(-0.5, 0.5))
	for _i in 20:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var out: float = RoadPathGD.HEADLAND_CREST + 8.0 + _rng.randf_range(0.0, 64.0)
		if _height_above_water(z, out) < 4.0:
			continue
		if float(_path.spur_deck_blend(z, _vp_side * out)) > 0.1:
			continue
		var s: float = _rng.randf_range(1.6, 3.8)
		_blob(
			z,
			_vp_side * out,
			Vector3(s * 1.8, s * 0.9, s * 1.5),
			Color("5a5348").lerp(Color("3a3834"), _rng.randf()),
			0.0,
			false,
			true
		)
	for _i in 10:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var out: float = RoadPathGD.HEADLAND_CREST + 6.0 + _rng.randf_range(0.0, 40.0)
		if _height_above_water(z, out) < 8.0:
			continue
		if float(_path.spur_deck_blend(z, _vp_side * out)) > 0.1:
			continue
		_tree(
			Flora.BARE,
			z,
			_vp_side * out,
			_rng.randf_range(6.0, 12.0),
			Color("2c3436"),
			true
		)
	for _i in 16:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		if absf(z - _vp_centre) < 48.0:
			continue
		var out: float = float(_path.viewpoint_far_shore(z, _vp_centre)) + _rng.randf_range(14.0, 78.0)
		if _height_above_water(z, out) < 8.0:
			continue
		var dwarf: bool = _rng.randf() < 0.55
		_tree(
			Flora.CONIFER if dwarf else Flora.BARE,
			z,
			_vp_side * out,
			_rng.randf_range(7.0, 13.0) if dwarf else _rng.randf_range(8.0, 15.0),
			Color("1c2a24") if dwarf else Color("2a3230"),
			true
		)
	for _i in 8:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		if absf(z - _vp_centre) < 40.0:
			continue
		var out: float = float(_path.viewpoint_far_shore(z, _vp_centre)) + _rng.randf_range(10.0, 36.0)
		if _height_above_water(z, out) < 6.0:
			continue
		var s: float = _rng.randf_range(2.4, 5.2)
		_blob(
			z,
			_vp_side * out,
			Vector3(s * 2.4, s * 0.7, s * 1.6),
			Color("6a6358").lerp(Color("4a453c"), _rng.randf()),
			0.0,
			false,
			true
		)


func _dress_vista_country() -> void:
	## Wastwater / Art of Rally Wales: dark water, a sun path, screes, a pass
	## between fells you look *through*. Heather on the near face, Kenney
	## boulders as talus, trees only on the side folds.
	var z0 := float(chunk_index) * LENGTH
	for _i in 9:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var out: float = RoadPathGD.HEADLAND_CREST + 5.0 + _rng.randf_range(0.0, 55.0)
		if float(_path.spur_deck_blend(z, _vp_side * out)) > 0.12:
			continue
		_vista_rock(z, _vp_side * out, _rng.randf_range(2.2, 5.8), _rng.randf_range(-0.4, 0.5))
	for _i in 16:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var out: float = RoadPathGD.HEADLAND_CREST + 10.0 + _rng.randf_range(0.0, 48.0)
		if _height_above_water(z, out) < 8.0:
			continue
		if float(_path.spur_deck_blend(z, _vp_side * out)) > 0.1:
			continue
		_blob(
			z,
			_vp_side * out,
			Vector3(_rng.randf_range(1.4, 2.8), _rng.randf_range(0.5, 1.0), _rng.randf_range(1.2, 2.2)),
			Color("3a4a30").lerp(Color("5a4638"), _rng.randf()),
			0.0,
			true,
			true
		)
	for _i in 18:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		if absf(z - _vp_centre) < 55.0:
			continue
		var out: float = float(_path.viewpoint_far_shore(z, _vp_centre)) + _rng.randf_range(16.0, 70.0)
		if _height_above_water(z, out) < 6.0:
			continue
		_tree(
			Flora.CONIFER if _rng.randf() < 0.7 else Flora.BROADLEAF,
			z,
			_vp_side * out,
			_rng.randf_range(10.0, 20.0),
			Color("1a3026"),
			true
		)


func _chunk_covers(z: float) -> bool:
	var z0 := float(chunk_index) * LENGTH
	return z >= z0 and z < z0 + LENGTH


func _build_coast_headland() -> void:
	## The drop under the rail, plus one nose of land in the mid-ground. Named
	## ViewpointHeadland so tests can see it; never ViewpointCliffs — that node
	## is the far-shore wall the coast is forbidden from building in the water.
	if _vp_theme != Env.COAST:
		return
	var z0 := float(chunk_index) * LENGTH
	var b := LowPoly.new()
	var rock := Color("8a8072")
	var scarp := Color("5a5448")
	var turf := Color("4a5844")
	var built := false
	var t := z0
	while t < z0 + LENGTH - 0.4:
		var t1: float = minf(t + 10.0, z0 + LENGTH)
		if _add_coast_scarp(b, t, t1, rock, scarp, turf):
			built = true
		t = t1
	if _add_coast_peninsula(b, z0, rock, scarp, turf):
		built = true
	if not built:
		return
	var mesh: MeshInstance3D = b.commit_to(self, "ViewpointHeadland")
	if mesh:
		mesh.material_override = LowPoly.terrain_material()
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mesh.visibility_range_end = 0.0


func _add_coast_scarp(b: LowPoly, za: float, zb: float, rock: Color, scarp: Color, turf: Color) -> bool:
	## Only the drop under the rail. Running this the length of the lake put a
	## paper wall along the water that the seated eye reads as cards.
	if absf((za + zb) * 0.5 - _vp_centre) > 80.0:
		return false
	var lip_out := RoadPathGD.HEADLAND_CREST + 4.0
	var near_a: float = float(_path.viewpoint_near_shore(za))
	var near_b: float = float(_path.viewpoint_near_shore(zb))
	var lip_a: Vector3 = _terrain_surface_at(za, _vp_side * lip_out)
	var lip_b: Vector3 = _terrain_surface_at(zb, _vp_side * lip_out)
	if lip_a.y < _vp_water_y + 8.0 and lip_b.y < _vp_water_y + 8.0:
		return false
	var mid_out_a: float = lerpf(lip_out, near_a, 0.22)
	var mid_out_b: float = lerpf(lip_out, near_b, 0.22)
	var crest_a := _far_point(za, _vp_side * lip_out, lip_a.y)
	var crest_b := _far_point(zb, _vp_side * lip_out, lip_b.y)
	var mid_a := _far_point(za, _vp_side * mid_out_a, lerpf(lip_a.y, _vp_water_y, 0.62))
	var mid_b := _far_point(zb, _vp_side * mid_out_b, lerpf(lip_b.y, _vp_water_y, 0.62))
	var toe_a := _far_point(za, _vp_side * (near_a - 8.0), _vp_water_y)
	var toe_b := _far_point(zb, _vp_side * (near_b - 8.0), _vp_water_y)
	if _vp_side > 0.0:
		b.add_quad_shaded(toe_a, mid_a, mid_b, toe_b, scarp, rock, rock, scarp)
		b.add_quad_shaded(mid_a, crest_a, crest_b, mid_b, rock, turf, turf, rock)
	else:
		b.add_quad_shaded(toe_b, mid_b, mid_a, toe_a, scarp, rock, rock, scarp)
		b.add_quad_shaded(mid_b, crest_b, crest_a, mid_a, rock, turf, turf, rock)
	return true


func _add_coast_peninsula(b: LowPoly, z0: float, rock: Color, scarp: Color, turf: Color) -> bool:
	## A wedge in the water whose *face* points at the bench. A strip of tops
	## along the route is seen edge-on from the platform and reads as cards.
	var face_z: float = _vp_centre + 130.0
	if not _chunk_covers(face_z):
		return false
	var near: float = float(_path.viewpoint_near_shore(face_z))
	var inner: float = near - 12.0
	var outer: float = near + 200.0
	var height := 48.0
	var back_z: float = face_z + 55.0
	var water_i := _far_point(face_z, _vp_side * inner, _vp_water_y)
	var water_o := _far_point(face_z, _vp_side * outer, _vp_water_y)
	var crest := _far_point(face_z, _vp_side * lerpf(inner, outer, 0.42), _vp_water_y + height)
	var ledge := _far_point(face_z, _vp_side * lerpf(inner, outer, 0.22), _vp_water_y + height * 0.55)
	var back_i := _far_point(back_z, _vp_side * inner, _vp_water_y)
	var back_o := _far_point(back_z, _vp_side * (inner + 40.0), _vp_water_y)
	var back_c := _far_point(back_z, _vp_side * lerpf(inner, outer, 0.28), _vp_water_y + height * 0.35)
	b.add_quad_shaded(water_i, ledge, crest, water_o, scarp, rock, turf, scarp)
	b.add_quad_shaded(crest, back_c, back_o, water_o, turf, scarp, scarp, rock)
	b.add_quad_shaded(water_i, back_i, back_c, crest, turf, scarp, scarp, rock)
	return true


func _build_vista_birds() -> void:
	## One flock per overlook, on the platform chunk. Raptors in the mountain
	## col, gulls over the coast water. Empty chunks must not pay a _process.
	if not _owns_platform:
		return
	if _vp_theme == Env.FOREST:
		return
	var n := 4
	var radius := 90.0
	var height := 70.0
	var span := 7.0
	var col := Color("2a2824")
	match _vp_theme:
		Env.COAST:
			n = 7
			radius = 140.0
			height = 88.0
			span = 8.0
			col = Color("d4d0c8")
		Env.MOUNTAIN:
			n = 5
			radius = 110.0
			height = 140.0
			span = 12.0
			col = Color("1a1816")
	var near: float = float(_path.viewpoint_near_shore(_vp_centre))
	var far: float = float(_path.viewpoint_far_shore(_vp_centre, _vp_centre))
	var centre := _far_point(_vp_centre, _vp_side * lerpf(near, far, 0.38), _vp_water_y + height)
	for i in n:
		var a: float = TAU * float(i) / float(n) + _vp_phase
		var r: float = radius * (0.82 + 0.28 * _rng.randf())
		var pos: Vector3 = centre + Vector3(cos(a) * r, 0.0, sin(a) * r)
		_birds.append(Transform3D(Basis.IDENTITY.scaled(Vector3(span, span * 0.38, span)), pos))
		_bird_cols.append(col)
		_bird_orbit.append(centre)
		_bird_radius.append(r)
		_bird_speed.append(_rng.randf_range(0.18, 0.34) if _vp_theme == Env.COAST else _rng.randf_range(0.12, 0.22))
		_bird_phase.append(a)
		_bird_amp.append(_rng.randf_range(4.0, 9.0))
		_bird_span.append(span * _rng.randf_range(0.88, 1.14))


func _build_vista_landmarks() -> void:
	## One authored silhouette in the view, not a building: cairn, dry-stone
	## wall, lone cypress. Planted on the chunk that owns a fixed z offset so
	## each overlook gets exactly one.
	match _vp_theme:
		Env.MOUNTAIN:
			_vista_cairn()
		Env.COUNTRY:
			_vista_shore_wall()
		Env.COAST:
			_vista_cypress()


func _vista_cairn() -> void:
	var z: float = _vp_centre + 200.0
	if not _chunk_covers(z):
		z = _vp_centre - 200.0
		if not _chunk_covers(z):
			return
	var out: float = float(_path.viewpoint_far_shore(z, _vp_centre)) + 16.0
	var found := false
	for _try in 8:
		if _height_above_water(z, out) >= 6.0:
			found = true
			break
		out += 18.0
	if not found:
		return
	var lat: float = _vp_side * out
	var stone := Color("6a6458")
	var sizes: Array[Vector3] = [
		Vector3(4.2, 1.35, 3.6),
		Vector3(3.2, 1.2, 2.8),
		Vector3(2.4, 1.05, 2.1),
		Vector3(1.6, 0.95, 1.45),
		Vector3(0.95, 1.4, 0.9),
	]
	var lift := 0.0
	for s in sizes:
		_cube(z, lat, s, stone.darkened(_rng.randf() * 0.1), _rng.randf_range(-0.28, 0.28), lift, true)
		lift += s.y
	var marker := Node3D.new()
	marker.name = "ViewpointCairn"
	add_child(marker)


func _vista_shore_wall() -> void:
	var z0 := float(chunk_index) * LENGTH
	var stone := Color("8a8478").darkened(0.08)
	var cap := stone.lightened(0.12)
	var built := false
	for i in 10:
		var za: float = _vp_centre + 180.0 + float(i) * 4.0
		var zb: float = za + 4.0
		if zb < z0 or za >= z0 + LENGTH:
			continue
		var out: float = float(_path.viewpoint_far_shore(za, _vp_centre)) + 16.0
		var placed := false
		for _try in 8:
			if _height_above_water(za, out) >= 4.0:
				placed = true
				break
			out += 16.0
		if not placed:
			continue
		var lat: float = _vp_side * out
		_terrain_beam(za, zb, lat, 0.72, 1.55, stone, 0.78, true)
		_terrain_beam(za, zb, lat, 0.80, 0.22, cap, 1.58, true)
		built = true
	if not built:
		return
	var marker := Node3D.new()
	marker.name = "ViewpointWall"
	add_child(marker)


func _vista_cypress() -> void:
	## One dark needle in the picture, not beside the camera. 40 m in front of
	## the eye and 28 m along the route is 35° off the view axis — the edge of
	## a 94° seated frame, which is where a framing tree belongs.
	var z: float = _vp_centre + 28.0
	if not _chunk_covers(z):
		return
	var eye_out: float = float(_path.spur_offset(_vp_centre)) + RoadPathGD.PLATFORM_BENCH_OUT
	var out: float = eye_out + 40.0
	if _height_above_water(z, out) < 2.0:
		out = RoadPathGD.HEADLAND_CREST + 8.0
	_tree(Flora.CYPRESS, z, _vp_side * out, 22.0, Color("14241c"), true)
	var marker := Node3D.new()
	marker.name = "ViewpointCypress"
	add_child(marker)


func _water_color() -> Color:
	## Deep and frankly teal. This is an albedo under a 1.5 sun and the lake fills
	## a third of the frame, so it has to be dark enough to stay the calmest mass
	## in the composition — but the desaturated slate it used to be gave the middle
	## of the picture no colour to hold against the ochre of the fells around it.
	## The whole warm-land / cool-water opposition is what the view is built on.
	match _vp_theme:
		Env.MOUNTAIN:
			return Color("103f52")
		Env.COAST:
			return Color("0f5f75")
		Env.FOREST:
			return Color("0c3742")
	return Color("104350")


func _far_point(z: float, lateral: float, y: float) -> Vector3:
	## A point out in the landscape at an absolute height rather than on the road
	## surface: the water and the ranges are level, the road under them is not.
	var flat: Basis = _path.frame_flat_at(z)
	var p: Vector3 = _path.center_at(z) + flat.x * lateral
	p.y = y
	return p - _origin


func _build_lake_water() -> void:
	## One level sheet, drawn from the foot of the headland out past the far
	## shore. Where the ground stands above it the ground hides it, so the
	## shoreline is the exact line the terrain crosses the sheet: an irregular
	## edge following every fold of the bank, for free, instead of the blue
	## rectangle laid on the grass that a fitted quad gives you.
	const ZS := 8
	var zs: int = 6 if _vp_theme == Env.COAST else ZS
	var ls: int = 16
	# Started well inside the near shore so the sheet's own inner edge is always
	# buried under the headland face. At 40 m it surfaced wherever the bank ran
	# shallow and drew a dead straight line across the bottom of the view — the
	# one edge in a lake that must never be visible, because the shoreline is
	# supposed to be wherever the terrain happens to cross the water.
	var inner: float = float(_path.viewpoint_near_shore(_vp_centre)) - 140.0
	var outer: float = float(_path.viewpoint_far_shore(_vp_centre, _vp_centre)) + (
		980.0 if _vp_theme == Env.COAST else 520.0
	)
	var z0 := float(chunk_index) * LENGTH
	var surface := _water_color()
	var b := LowPoly.new()
	b.smooth = true
	for i in zs:
		var za := z0 + LENGTH * float(i) / float(zs)
		var zb := z0 + LENGTH * float(i + 1) / float(zs)
		for j in ls:
			var out_a: float = lerpf(inner, outer, float(j) / float(ls))
			var out_b: float = lerpf(inner, outer, float(j + 1) / float(ls))
			var col_aa := _water_shade(surface, out_a, za)
			var col_ab := _water_shade(surface, out_b, za)
			var col_ba := _water_shade(surface, out_a, zb)
			var col_bb := _water_shade(surface, out_b, zb)
			var lat_a := _vp_side * out_a
			var lat_b := _vp_side * out_b
			if lat_a > lat_b:
				var swap_lat := lat_a
				lat_a = lat_b
				lat_b = swap_lat
				var swap_a := col_aa
				col_aa = col_ab
				col_ab = swap_a
				var swap_b := col_ba
				col_ba = col_bb
				col_bb = swap_b
			b.add_quad_shaded(
				_far_point(za, lat_a, _vp_water_y),
				_far_point(za, lat_b, _vp_water_y),
				_far_point(zb, lat_b, _vp_water_y),
				_far_point(zb, lat_a, _vp_water_y),
				col_aa,
				col_ab,
				col_bb,
				col_ba
			)
	var mesh: MeshInstance3D = b.commit_to(self, "ViewpointLake")
	if mesh:
		mesh.material_override = water_material_sea() if _vp_theme == Env.COAST else water_material()
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _water_shade(surface: Color, out: float, z: float) -> Color:
	## Depth, and nothing else.
	##
	## This used to lerp the middle of the lake up to 38% toward a pale mint, on
	## the theory that a sun path gives the water a centre and leads the eye to the
	## far shore. Both true, and neither achievable here: the path was pinned to
	## the geometric middle of the basin rather than to the sun, so it sat wherever
	## the lake happened to be widest and pointed at nothing. What it reliably did
	## was wash the largest surface in the frame out to a flat lavender — brighter
	## than the sky it was supposed to be reflecting, and the reason the lake read
	## as a slab of frosted glass.
	##
	## The path now lives in the water shader's light(), where it can sit on the
	## actual line between the eye and the sun. Vertex colour keeps the one job it
	## can do honestly: shallow near the shore, deep out in the middle, which is
	## the only distance cue the surface has of its own.
	var deep: float = smoothstep(RoadPathGD.LAKE_NEAR - 30.0, RoadPathGD.LAKE_NEAR + 220.0, out)
	var color := surface.lightened(0.16).lerp(surface.darkened(0.14), deep)
	if _vp_theme == Env.COAST:
		return color
	# Very broad horizontal variations catch the sky as painted planes. Kept
	# below four percent so the water gains facets without becoming stripy.
	return color.lightened((0.5 + 0.5 * sin(out * 0.043 + z * 0.018)) * 0.035)


func _build_far_ground() -> void:
	## Skirt from the far waterline out under the range. Dark fell, not a sunlit
	## sand table: it climbs off the shore in folds so the ridgelines have a floor.
	var z0 := float(chunk_index) * LENGTH
	var b := LowPoly.new()
	# Faceted, not smoothed. This is the mass the far shore stands on and the
	# floor the ridgelines rise out of; averaging its normals turns every fold
	# into the same soft gradient and the whole far side reads as one sanded
	# lump. Hard normals give each fold a plane of its own to catch the light,
	# which is the entire reason the game is built out of flat polygons.
	b.smooth = _vp_theme == Env.COAST
	var color := Color("3a4a44")
	match _vp_theme:
		Env.COAST:
			color = Color("3a464e")
		Env.FOREST:
			color = Color("2e4036")
		Env.MOUNTAIN:
			color = Color("453c36")
		Env.COUNTRY:
			color = Color("56492e")
	var inner: float = float(_path.viewpoint_far_shore(_vp_centre, _vp_centre)) + 50.0
	var outer: float = inner + 720.0
	# 180 m across by 10 m along is a sliver, and a sliver split into two hard-
	# normalled triangles shades as a herringbone rather than as a fold. Finer
	# across the slope — where the height actually changes — squares the quads up
	# enough that each one reads as a plane.
	const FAR_ZS := 6
	const FAR_LS := 10
	for i in FAR_ZS:
		var za := z0 + LENGTH * float(i) / float(FAR_ZS)
		var zb := z0 + LENGTH * float(i + 1) / float(FAR_ZS)
		for j in FAR_LS:
			var out_a: float = lerpf(inner, outer, float(j) / float(FAR_LS))
			var out_b: float = lerpf(inner, outer, float(j + 1) / float(FAR_LS))
			var lat_a := _vp_side * out_a
			var lat_b := _vp_side * out_b
			if lat_a > lat_b:
				var swap := lat_a
				lat_a = lat_b
				lat_b = swap
			var ya0: float = _far_ground_y(za, absf(lat_a))
			var ya1: float = _far_ground_y(za, absf(lat_b))
			var yb1: float = _far_ground_y(zb, absf(lat_b))
			var yb0: float = _far_ground_y(zb, absf(lat_a))
			# A skirt sitting on the water, seen edge-on, is the ribbon stretched
			# between the peaks. Only keep ground that actually rises into a hill.
			if (
				ya0 < _vp_water_y + 12.0
				and ya1 < _vp_water_y + 12.0
				and yb1 < _vp_water_y + 12.0
				and yb0 < _vp_water_y + 12.0
			):
				continue
			b.add_quad(
				_far_point(za, lat_a, ya0),
				_far_point(za, lat_b, ya1),
				_far_point(zb, lat_b, yb1),
				_far_point(zb, lat_a, yb0),
				color
			)
	var mesh: MeshInstance3D = b.commit_to(self, "ViewpointFarGround")
	if mesh == null:
		var buried := _vp_water_y - 60.0
		var lat := _vp_side * 1800.0
		b.add_quad(
			_far_point(z0, lat, buried),
			_far_point(z0 + LENGTH, lat, buried),
			_far_point(z0 + LENGTH, lat + _vp_side * 8.0, buried),
			_far_point(z0, lat + _vp_side * 8.0, buried),
			color
		)
		mesh = b.commit_to(self, "ViewpointFarGround")
	if mesh:
		mesh.material_override = LowPoly.terrain_material()
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mesh.visibility_range_end = 0.0


func _far_ground_y(z: float, out: float) -> float:
	## Rises under the side peaks and stays down in the col, so the pass is sky
	## rather than a sunlit table. Coast barely rises: the sea is the view.
	var far: float = float(_path.viewpoint_far_shore(_vp_centre, _vp_centre))
	var bank: float = 24.0
	var col: float = 1.0 - 0.88 * exp(-pow((z - _vp_centre) / 300.0, 2.0))
	match _vp_theme:
		Env.FOREST:
			bank = 48.0
			col = 1.0 - 0.18 * exp(-pow((z - _vp_centre) / 220.0, 2.0))
		Env.COAST:
			bank = 7.0
			col = 0.22 + 0.18 * (1.0 - exp(-pow((z - _vp_centre) / 400.0, 2.0)))
		Env.MOUNTAIN:
			bank = 52.0
			col = 1.0 - 0.90 * exp(-pow((z - _vp_centre) / 260.0, 2.0))
		Env.COUNTRY:
			bank = 24.0
	var rise: float = bank * smoothstep(far + 40.0, far + 480.0, out)
	var fold: float = 18.0 * sin((z - _vp_centre) * 0.007 + out * 0.0034)
	var roll: float = (10.0 * sin(z * 0.011 + out * 0.0048) + fold) * smoothstep(
		far + 60.0, far + 540.0, out
	)
	return _vp_water_y + (rise + roll) * col


func _height_above_water(z: float, out: float) -> float:
	## How far the ground stands above the water at this distance out, measured
	## against the surface everything is actually *placed* on.
	##
	## This used to reconstruct the height itself — centreline height less a
	## profile drop — on the grounds that it was cheaper than a transform. It is,
	## and it also disagrees with `_terrain_surface_at` precisely where the
	## headland face falls away, which is the only place any of its callers ever
	## ask. Every shore-dressing guard in the overlook was therefore passing on
	## rock the sampled terrain put several metres under the lake, and the talus,
	## the boulders and the framing stand all came up standing on the water.
	return _terrain_surface_at(z, _vp_side * out).y - _vp_water_y


func _build_lake_edges() -> void:
	## Boulders and reeds along the waterline, and scree on the face of the
	## headland. All of it sits below the platform, dressing the drop without
	## ever standing in the view from it.
	var z0 := float(chunk_index) * LENGTH
	# Boulders at and just under the waterline, in groups, and big enough to
	# matter at a hundred and forty metres. The whole near shore sits in the
	# bottom of the seated frame; at the old two-to-six metres, evenly sprinkled,
	# it contributed nothing but noise and the foreground read as empty water.
	# Not on a coast. A boulder field standing in the surf a hundred metres out
	# is a lake shore, not a sea: the whole point of the Big Sur view is an
	# unbroken plane of water running to the horizon with the stacks as the only
	# things interrupting it, and strewing it with rocks turned that plane into
	# gravel spread over glass.
	var groups: int = 0 if _vp_theme == Env.COAST else (6 if _vp_theme == Env.MOUNTAIN else 4)
	for group in groups:
		var head_z: float = z0 + _rng.randf_range(0.0, LENGTH)
		var head_out: float = float(_path.viewpoint_near_shore(head_z)) + _rng.randf_range(-14.0, 2.0)
		for _i in 5:
			var z: float = head_z + _rng.randf_range(-9.0, 9.0)
			var out: float = head_out + _rng.randf_range(-7.0, 7.0)
			if _height_above_water(z, out) > 3.0:
				continue
			# Big enough to read at a hundred and forty metres, small enough to still
			# be a boulder. At 5.2 the blob is ten metres across — a third the height
			# of the pines framing the shot — and the shore came out as a heap of
			# eggs. Wet stone is also dark: a mid grey albedo under a raking warm key
			# turns cream, which is what put a string of highlights along the one
			# edge of the picture that should be settling into shadow.
			var s := _rng.randf_range(1.2, 3.2)
			_blob(
				z,
				_vp_side * out,
				Vector3(s * 2.0, s * 1.1, s * 1.7),
				Color("4f554f").lightened(_rng.randf() * 0.10),
				# Sunk a little, so the ones nearest the water stand *in* it rather
				# than balancing on a line. A boulder half in a lake is the cheapest
				# thing there is that says the water has a depth.
				-s * _rng.randf_range(0.0, 0.45),
				false,
				true
			)
	# Talus first, and unconditionally: it is the surface of the drop, not
	# dressing on top of it, and every theme has one.
	_build_face_scree()
	# Reeds, where reeds actually grow. A mountain tarn sits above the line where
	# anything roots in its margins, and a sea cliff has surf at the bottom of it
	# — on both, these were half a dozen saturated green chips lying flat on a
	# dark bank, reading as litter rather than as planting.
	if _vp_theme == Env.MOUNTAIN or _vp_theme == Env.COAST:
		return
	for _i in 18:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var out: float = float(_path.viewpoint_near_shore(z)) + _rng.randf_range(-3.0, 8.0)
		if _height_above_water(z, out) > 1.2:
			continue
		var s := _rng.randf_range(0.7, 1.6)
		_blob(
			z,
			_vp_side * out,
			Vector3(s * 1.9, s * 1.5, s * 1.6),
			Color("22382e").darkened(_rng.randf() * 0.18),
			0.0,
			true,
			true
		)


## How many separate runs of talus a chunk's worth of face carries, and how
## tightly each one gathers. Scree comes off a crag in fans with bare rock
## between them; scattered at an even density over the whole slope it reads as
## gravel spread by hand, which is exactly what the old uniform pass produced —
## the same size of stone at the same spacing from the lip to the waterline.
const SCREE_FANS := 3
const SCREE_PER_FAN := 11


func _build_face_scree() -> void:
	## Talus on the face under the platform, in fans rather than in a wash.
	##
	## Two things separate scree from confetti, and neither is the number of
	## stones. The first is clustering: a fan has a source high on the face and
	## spreads as it falls, so the stones bunch and there are bare runs between.
	## The second is grading — big blocks end up at the bottom because they carry
	## furthest, fines stay high — and it is the size gradient down the slope that
	## tells the eye how big the slope is. A field of identically-sized pebbles
	## has no scale in it at all, which is why the drop used to read as a low bank
	## with gravel on it however deep it actually was.
	var z0 := float(chunk_index) * LENGTH
	var face_run: float = maxf(
		float(_path.viewpoint_near_shore(_vp_centre)) - RoadPathGD.HEADLAND_CREST - 8.0, 24.0
	)
	for fan in (SCREE_FANS * 2 if _vp_theme == Env.MOUNTAIN or _vp_theme == Env.COAST else SCREE_FANS):
		# Source of the fan: a point high on the face, in this chunk.
		var head_z: float = z0 + _rng.randf_range(0.0, LENGTH)
		var head_out: float = RoadPathGD.HEADLAND_CREST + 3.0 + _rng.randf_range(0.0, face_run * 0.35)
		var spread: float = _rng.randf_range(9.0, 22.0)
		for _i in SCREE_PER_FAN:
			# Fall line, biased downslope, spreading as it goes.
			var run: float = _rng.randf() * _rng.randf()  # bunched near the head
			var out: float = head_out + run * (face_run - (head_out - RoadPathGD.HEADLAND_CREST))
			var z: float = head_z + _rng.randf_range(-1.0, 1.0) * spread * (0.35 + run)
			var above := _height_above_water(z, out)
			if above < 1.0 or float(_path.spur_deck_blend(z, _vp_side * out)) > 0.15:
				continue
			# Graded: fines at the head of the fan, blocks at the foot.
			var s: float = lerpf(0.55, 3.1, run * run) * _rng.randf_range(0.82, 1.24)
			# And graded in value the same way. A stone lying in the shade of the
			# lip is not the same colour as one out on the open apron below it, and
			# a single pale grey for all of them is what made them read as popcorn
			# scattered over a dark slope.
			var stone := Color("4c463c").lerp(Color("6b6357"), run)
			if _vp_theme == Env.COAST:
				stone = Color("7a7060").lerp(Color("9a8e78"), run)
			_blob(
				z,
				_vp_side * out,
				Vector3(s * 1.7, s * 1.1, s * 1.5),
				stone.darkened(_rng.randf() * 0.20),
				0.0,
				false,
				true
			)


func _build_far_cliffs() -> void:
	## Continuous far-shore scree with a pass in the middle of the view. Two
	## parabolic "noses" near the centre read as ice-cream hills in the lake;
	## Wastwater and Glen Coe put the mass on the *sides* and leave the col open.
	## Coast skips this: a cliff wall across the sea is the old blob-hills problem.
	if _vp_theme == Env.COAST:
		return
	var z0 := float(chunk_index) * LENGTH
	var b := LowPoly.new()
	var face := Color("4a453c")
	var lip := Color("6a6458")
	var pass_rise := 10.0
	var fell_rise := 58.0
	match _vp_theme:
		Env.FOREST:
			face = Color("2e3a2c")
			lip = Color("44503c")
			pass_rise = 36.0
			fell_rise = 88.0
		Env.MOUNTAIN:
			face = Color("52463a")
			lip = Color("7a6a54")
			pass_rise = 18.0
			fell_rise = 168.0
		Env.COUNTRY:
			# Ochre, not grey. This wall is the mid-ground the lake is read against,
			# and the whole composition rests on warm land against cool water.
			face = Color("6a5334")
			lip = Color("937a4e")
			pass_rise = 22.0
			fell_rise = 72.0
	var built := false
	var t := z0
	while t < z0 + LENGTH - 0.4:
		var t1: float = minf(t + 13.0, z0 + LENGTH)
		_cliff_span(b, t, t1, _far_scree_rise(t, pass_rise, fell_rise), _far_scree_rise(t1, pass_rise, fell_rise), face, lip)
		built = true
		t = t1
	if not built:
		return
	var mesh: MeshInstance3D = b.commit_to(self, "ViewpointCliffs")
	if mesh:
		mesh.material_override = LowPoly.terrain_material()
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mesh.visibility_range_end = 0.0


func _far_scree_rise(z: float, pass_rise: float, fell_rise: float) -> float:
	## Low through the middle third of the view, climbing toward the ends of the
	## lake. A pair of gaussians parked at ±100 m is what made the two blobs.
	##
	## Undulated along its length as well. A shore wall whose height is a pure
	## function of distance from the axis is a perfectly smooth ramp on both
	## sides, and against a bright sky that reads as a flat-topped dam wall — the
	## hard horizontal edge that used to run the width of the frame.
	var dist: float = absf(z - _vp_centre)
	var base: float = lerpf(pass_rise, fell_rise, smoothstep(180.0, 380.0, dist))
	var local: float = z - _vp_centre
	var fold: float = (
		0.20 * sin(local * 0.0091 + _vp_phase)
		+ 0.12 * sin(local * 0.0173 + _vp_phase * 1.7)
		+ 0.07 * sin(local * 0.0339 + _vp_phase * 0.6)
	)
	return maxf(base * (1.0 + fold), pass_rise * 0.5)


func _cliff_span(
	b: LowPoly,
	za: float,
	zb: float,
	h_a: float,
	h_b: float,
	face: Color,
	lip: Color
) -> void:
	var shore_a: float = float(_path.viewpoint_far_shore(za, _vp_centre))
	var shore_b: float = float(_path.viewpoint_far_shore(zb, _vp_centre))
	var water_a := _far_point(za, _vp_side * (shore_a - 3.0), _vp_water_y)
	var water_b := _far_point(zb, _vp_side * (shore_b - 3.0), _vp_water_y)
	var ledge_a := _far_point(za, _vp_side * (shore_a + 6.0), _vp_water_y + h_a * 0.58)
	var ledge_b := _far_point(zb, _vp_side * (shore_b + 6.0), _vp_water_y + h_b * 0.58)
	var crown_a := _far_point(za, _vp_side * (shore_a + 22.0), _vp_water_y + h_a)
	var crown_b := _far_point(zb, _vp_side * (shore_b + 22.0), _vp_water_y + h_b)
	var back_a := _far_point(za, _vp_side * (shore_a + 48.0), _vp_water_y + h_a * 0.42)
	var back_b := _far_point(zb, _vp_side * (shore_b + 48.0), _vp_water_y + h_b * 0.42)
	var scarp := face.darkened(0.1)
	if _vp_side > 0.0:
		b.add_quad_shaded(water_a, ledge_a, ledge_b, water_b, scarp, face, face, scarp)
		b.add_quad_shaded(ledge_a, crown_a, crown_b, ledge_b, face, lip, lip, face)
		b.add_quad_shaded(crown_a, back_a, back_b, crown_b, lip, scarp, scarp, lip)
	else:
		b.add_quad_shaded(water_b, ledge_b, ledge_a, water_a, scarp, face, face, scarp)
		b.add_quad_shaded(ledge_b, crown_b, crown_a, ledge_a, face, lip, lip, face)
		b.add_quad_shaded(crown_b, back_b, back_a, crown_a, lip, scarp, scarp, lip)


func _build_far_shore() -> void:
	## Banks well above the water. Forest is a wooded terrace; coast is rock and
	## sky; mountain is scree; country keeps a few side-fold conifers. Nothing
	## stands in the lake; the pass stays open.
	var z0 := float(chunk_index) * LENGTH
	if _vp_theme != Env.COAST:
		var tree_count := 8
		var min_height := 4.0
		var keep_out := 70.0
		if _vp_theme == Env.FOREST:
			tree_count = 20
			min_height = 3.0
			keep_out = 48.0
		elif _vp_theme == Env.MOUNTAIN:
			tree_count = 12
			min_height = 5.0
			keep_out = 52.0
		for _i in tree_count:
			var z := z0 + _rng.randf_range(0.0, LENGTH)
			if absf(z - _vp_centre) < keep_out:
				continue
			var out: float = float(_path.viewpoint_far_shore(z, _vp_centre)) + _rng.randf_range(18.0, 70.0)
			if _height_above_water(z, out) < min_height:
				continue
			var tint := Color("162820").lerp(Color("24362c"), _rng.randf() * 0.3)
			var species: int = Flora.CONIFER
			if _vp_theme == Env.FOREST and _rng.randf() < 0.35:
				species = Flora.BROADLEAF
			elif _vp_theme == Env.MOUNTAIN and _rng.randf() < 0.55:
				species = Flora.BARE
			var tall: float = _rng.randf_range(16.0, 28.0) if _vp_theme == Env.FOREST else (
				_rng.randf_range(7.0, 13.0) if _vp_theme == Env.MOUNTAIN else _rng.randf_range(10.0, 16.0)
			)
			_tree(species, z, _vp_side * out, tall, tint, true)
	for _i in (14 if _vp_theme == Env.MOUNTAIN else 7):
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var out: float = float(_path.viewpoint_far_shore(z, _vp_centre)) + _rng.randf_range(8.0, 28.0)
		if _height_above_water(z, out) < 4.0:
			continue
		var s := _rng.randf_range(1.8, 4.8 if _vp_theme == Env.MOUNTAIN else 4.0)
		_blob(
			z,
			_vp_side * out,
			Vector3(s * 2.2, s * 0.8, s * 1.7),
			Color("4a453c").lerp(Color("5c564c"), _rng.randf() * 0.2),
			0.0,
			false,
			true
		)


## A country range, not one central lump. Each layer is two offset peaks with a
## pass between them, so the middle of the view is a col you look through rather
## than a blob you look down onto. Every layer sits *behind* the lake; the far
## shore's own scree owns the waterline.
## No snow cap. A pale lid on a round hill is how the last version read as a
## cheap primitive under the dusk sun. Form light lives in the vertex colour.
## `haze` only tints; distance is the engine's fog to draw.
## Four stacked ranges so the view has a near fell, a pass, and two blue
## distances behind it — Art of Rally / Firewatch composition, not one lump.
## Heights are what the seated 78° lens can actually read: 110 m at a kilometre
## was a bump on the horizon.
##
## `haze` is only a tint toward the layer's haze colour. The real depth cue is
## the engine's aerial perspective, which the overlook mood turns *up* — see
## `Main._protect_scenic_visibility`.
## `left` and `right` are where this layer's two shoulders stand, as an offset
## along the route from the centre of the view. They are not decoration: the
## composition is a col you look *through*, and a col is only legible if it has
## a defined summit on either side of it. Leaving the shoulders to the general
## run of tents meant whether the pass read at all came down to which way the
## per-layer phase happened to fall, and on most seeds it did not read.
const RANGE_LAYERS := [
	{"lateral": 860.0, "height": 280.0, "spread": 42.0, "width": 180.0, "haze": 0.05, "pass_width": 360.0, "left": -280.0, "right": 400.0, "cliff": false},
	{"lateral": 1380.0, "height": 420.0, "spread": 56.0, "width": 220.0, "haze": 0.22, "pass_width": 400.0, "left": -400.0, "right": 240.0, "cliff": false},
	{"lateral": 2100.0, "height": 560.0, "spread": 70.0, "width": 280.0, "haze": 0.40, "pass_width": 460.0, "left": -310.0, "right": 400.0, "cliff": false},
	{"lateral": 3100.0, "height": 720.0, "spread": 88.0, "width": 340.0, "haze": 0.58, "pass_width": 520.0, "left": -400.0, "right": 270.0, "cliff": false},
]
## Facet size along the crest. At 10 m a ridge a kilometre away is subdivided
## far below the eye's ability to read it as anything but corduroy — a mountain
## made of a hundred near-identical strips. Twenty gives the flanks planes big
## enough to take a definite side of the light, which is the point of building
## the world out of polygons in the first place.
const RANGE_STEP := 20.0


func _build_peak_clouds() -> void:
	## Soft puffs wrapped around the planted summits. The sky shader's deck sits
	## at infinity; these are in the world, so a peak can wear a collar of cloud
	## the way Art of Rally and Firewatch do.
	if _vp_theme == Env.COAST:
		return
	var z0 := float(chunk_index) * LENGTH
	var first_layer := 0
	var height_mul := 1.15
	var lateral_mul := 1.0
	var puffs := 3
	if _vp_theme == Env.FOREST:
		height_mul = 1.05
		lateral_mul = 0.70
		puffs = 3
	elif _vp_theme == Env.MOUNTAIN:
		height_mul = 1.34
		lateral_mul = 1.02
		puffs = 8
	elif _vp_theme == Env.COUNTRY:
		height_mul = 0.86
		lateral_mul = 1.0
		puffs = 4
	var lit := Color("f2c8b4")
	var cool := Color("c8d0e0")
	for index in range(first_layer, RANGE_LAYERS.size()):
		var layer: Dictionary = RANGE_LAYERS[index]
		var phase: float = float(posmod(hash(Vector2i(index, int(_path.world_seed))), 1000)) * 0.00628
		var stack: float = 1.0
		if _vp_theme == Env.MOUNTAIN:
			stack = 1.0 + 0.14 * float(index)
		elif _vp_theme == Env.COUNTRY:
			stack = 1.0 - 0.10 * float(index)
		var fade: float = float(layer["haze"])
		var tint: Color = lit.lerp(cool, fade)
		tint.a = lerpf(0.52, 0.34, fade)
		for side_key in ["left", "right"]:
			var at: float = float(layer[side_key])
			var peak_z: float = _vp_centre + at
			if peak_z < z0 or peak_z >= z0 + LENGTH:
				continue
			var sample: Vector2 = _range_sample(peak_z, layer, phase, index)
			var height: float = sample.x * height_mul * stack
			if height < 40.0:
				continue
			var out: float = sample.y * lateral_mul
			var metre: float = clampf(out * 0.12, 90.0, 260.0)
			for k in puffs:
				var f := float(k)
				var along: float = (f - float(puffs - 1) * 0.5) * metre * 0.32 + sin(phase + f * 1.7) * metre * 0.14
				var lift: float = height * (0.78 + 0.32 * sin(phase * 1.1 + f * 2.3))
				var pull: float = metre * (0.18 + 0.16 * sin(phase * 0.8 + f))
				var z: float = peak_z + along
				var lateral: float = _vp_side * (out - pull)
				var y: float = _vp_water_y + lift
				var size := Vector3(
					metre * (1.25 + 0.40 * sin(phase + f * 0.9)),
					metre * (0.48 + 0.16 * sin(phase * 1.4 + f)),
					metre * (0.95 + 0.28 * sin(phase * 0.6 + f * 1.3))
				)
				var pos := _far_point(z, lateral, y)
				var basis := Basis.from_euler(
					Vector3(_rng.randf_range(-0.18, 0.18), _rng.randf_range(0.0, TAU), _rng.randf_range(-0.12, 0.12))
				).scaled(size)
				_clouds.append(Transform3D(basis, pos))
				var puff: Color = tint
				puff.a *= 0.82 + 0.18 * sin(phase + f * 2.1)
				_cloud_cols.append(puff)


func _build_view_range() -> void:
	## Coast keeps only the far headlands: water and sky in the near field, a
	## Big Sur peninsula on the horizon. Forest/mountain/country get the lot.
	var z0 := float(chunk_index) * LENGTH
	var b := LowPoly.new()
	# Warm rock, cool haze, and the layers walk from one to the other.
	#
	# Distance in a landscape is carried by hue as much as by value: the near
	# fells hold their own warm colour and each range behind them gives more of it
	# up to the air, so a stack of ridges reads as ochre, then dusty violet, then
	# nearly sky. Both ends used to sit in the same desaturated blue-grey family,
	# which is why four layers of mountain arrived as one silhouette — there was
	# nothing for the `haze` mix to actually move *between*.
	# Near rock has to hold its own hue or four layers collapse into one dusk
	# silhouette — which is what the overlook was. Warm near, cool far; the haze
	# mix is the whole distance cue once aerial perspective has done its job.
	var haze := Color("8a90b8")
	var rock := Color("3a4a3c")
	if _vp_theme == Env.COUNTRY:
		rock = Color("6a5334")
		haze = Color("9a8eb0")
	elif _vp_theme == Env.FOREST:
		rock = Color("2f4a3a")
		haze = Color("5a7a92")
	elif _vp_theme == Env.MOUNTAIN:
		rock = Color("5c564e")
		haze = Color("7a849c")
	elif _vp_theme == Env.COAST:
		rock = Color("3a4e58")
		haze = Color("8aa8c8")
	var base_y := _vp_water_y - 4.0
	var first_layer := 0
	var height_mul := 1.15
	var lateral_mul := 1.0
	if _vp_theme == Env.COAST:
		# Far headlands only, and only the two nearest of those. Alpine tents on
		# the sea were a Matterhorn; a low plateau just past the waterline is a
		# peninsula. Layer 0 sits at 860 m, inside the coast's 1180 m of water,
		# and would read as an island.
		first_layer = 1
		height_mul = 0.40
		lateral_mul = 1.02
	elif _vp_theme == Env.FOREST:
		height_mul = 1.05
		lateral_mul = 0.70
	elif _vp_theme == Env.MOUNTAIN:
		height_mul = 1.34
		lateral_mul = 1.02
	elif _vp_theme == Env.COUNTRY:
		# Lower than the alpine stack. Same tents as mountain made two biomes
		# read as one pass photographed twice.
		height_mul = 0.86
		lateral_mul = 1.0
	var last_layer: int = 2 if _vp_theme == Env.COAST else RANGE_LAYERS.size()
	for index in range(first_layer, last_layer):
		var layer: Dictionary = RANGE_LAYERS[index]
		var phase: float = float(posmod(hash(Vector2i(index, int(_path.world_seed))), 1000)) * 0.00628
		var fade: float = layer["haze"]
		var body: Color = rock.lerp(haze, fade)
		var foot: Color = rock.darkened(0.16).lerp(haze, fade * 0.72)
		var steps := int(LENGTH / RANGE_STEP)
		for i in steps:
			var za := z0 + RANGE_STEP * float(i)
			var zb := za + RANGE_STEP
			# Depth is the absolute layer index, not one relative to first_layer:
			# coast starts at layer 1 and wants its headlands sunk on the horizon
			# (a distant peninsula), so the sag those indices carry is right for it.
			var sample_a: Vector2 = _range_sample(za, layer, phase, index)
			var sample_b: Vector2 = _range_sample(zb, layer, phase, index)
			var stack: float = 1.0
			if _vp_theme == Env.MOUNTAIN:
				stack = 1.0 + 0.14 * float(index)
			elif _vp_theme == Env.COUNTRY:
				stack = 1.0 - 0.10 * float(index)
			sample_a.x *= height_mul * stack
			sample_b.x *= height_mul * stack
			sample_a.y *= lateral_mul
			sample_b.y *= lateral_mul
			# Through the col the three-shelf face collapses to a sliver, and from
			# the bench that sliver reads as a ribbon stretched between the peaks.
			if sample_a.x < 10.0 and sample_b.x < 10.0:
				continue
			_range_face(
				b,
				za,
				zb,
				sample_a,
				sample_b,
				layer,
				base_y,
				body,
				foot
			)
	var mesh: MeshInstance3D = b.commit_to(self, "ViewpointRange")
	if mesh == null:
		# The centre chunk of a deep pass / open sea has no crest of its own.
		# Tests and the streamer still key off this node, so bury a stub.
		var buried := _vp_water_y - 60.0
		var lat := _vp_side * 2200.0
		b.add_quad(
			_far_point(z0, lat, buried),
			_far_point(z0 + LENGTH, lat, buried),
			_far_point(z0 + LENGTH, lat + _vp_side * 8.0, buried),
			_far_point(z0, lat + _vp_side * 8.0, buried),
			Color("000000")
		)
		mesh = b.commit_to(self, "ViewpointRange")
	if mesh:
		mesh.material_override = LowPoly.terrain_material()
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# The skyline never culls: blinking a mountain range out at the prop
		# distance would be the most obvious pop in the game.
		mesh.visibility_range_end = 0.0


## How far along the route the skyline is actually built. The range is drawn by
## the same chunks that carry the lake, so it exists over this half-window and
## nowhere else — and a crest still at full height when the mesh runs out is a
## vertical wall standing in the sky. Everything below is distributed inside this
## window and tapered to nothing at the edge of it.
const RANGE_REACH := RoadPathGD.LAKE_SPAN + 60.0
## Few massifs. A 0.30 pitch packed nine similar tents into the window and the
## skyline read as corduroy — a corrugated wall, not a mountain range.
const RANGE_PEAK_PITCH := 0.62
const RANGE_PEAKS_MAX := 4


func _range_tent(t: float, sharpness: float = 1.12) -> float:
	## 1 at the summit so planted shoulders and the visuals test stay put.
	## Sharpness > 1 is alpine. < 1 is a round fell. ≤ 0.35 is a coastal plateau.
	if sharpness <= 0.35:
		return minf(1.0, 1.0 - pow(1.0 - t, 2.4))
	return pow(t, sharpness)


func _range_massif(
	local: float, centre: float, inner_w: float, outer_w: float, peak: float, sharpness: float
) -> float:
	## Steep face toward the pass, long backslope the other way.
	var toward_pass: bool = (local - centre) * centre < 0.0
	var half: float = inner_w if toward_pass else outer_w
	var t: float = 1.0 - clampf(absf(local - centre) / maxf(half, 1.0), 0.0, 1.0)
	return peak * _range_tent(t, sharpness)


func _range_sample(z: float, layer: Dictionary, phase: float, depth: int = 0) -> Vector2:
	## x = crest height above the base, y = how far out the crest line runs.
	## Mountain: horns and a deep col. Country: round fells you look through.
	## Coast: wide low headlands, open water in the middle.
	var local: float = z - _vp_centre
	var pass_w: float = float(layer["pass_width"])
	var left_at: float = float(layer["left"])
	var right_at: float = float(layer["right"])
	var left_hero: bool = absf(left_at) >= absf(right_at)
	var sharpness := 1.12
	var other := 0.80
	var sag0 := 0.55
	var jag_a := 0.06
	var jag_b := 0.04
	var inner_k := 0.48
	var outer_k := 0.36
	var extra: int = mini(RANGE_PEAKS_MAX - 2, 2)
	var foothill_lo := 0.28
	var foothill_span := 0.16
	var floor_h := 0.07
	match _vp_theme:
		Env.MOUNTAIN:
			sharpness = 1.38
			other = 0.62
			sag0 = 0.68
			jag_a = 0.10
			jag_b = 0.07
			inner_k = 0.48
			outer_k = 0.34
			foothill_lo = 0.42
			foothill_span = 0.22
			floor_h = 0.04
		Env.COUNTRY:
			sharpness = 0.48
			other = 0.94
			sag0 = 0.40
			jag_a = 0.02
			jag_b = 0.015
			inner_k = 0.70
			outer_k = 0.68
			foothill_lo = 0.52
			foothill_span = 0.18
			floor_h = 0.12
		Env.COAST:
			sharpness = 0.30
			other = 0.70
			sag0 = 0.82
			jag_a = 0.01
			jag_b = 0.008
			inner_k = 1.05
			outer_k = 0.85
			extra = 0
			floor_h = 0.02
		Env.FOREST:
			sharpness = 1.08
			other = 0.84
			sag0 = 0.50
	var crest := floor_h
	for k in extra:
		var f := float(k)
		var side: float = -1.0 if k == 0 else 1.0
		var planted: float = left_at if side < 0.0 else right_at
		var centre: float = planted + side * (RANGE_PEAK_PITCH * 160.0 + 70.0 * sin(phase + f * 2.1))
		if absf(centre) < pass_w * 0.55:
			continue
		var foothill: float = foothill_lo + foothill_span * (0.5 + 0.5 * sin(phase * 0.9 + f * 2.713))
		var inner_w: float = 130.0 + 40.0 * sin(phase * 1.4 + f)
		var outer_w: float = 210.0 + 50.0 * sin(phase * 0.7 + f * 1.3)
		crest = maxf(crest, _range_massif(local, centre, inner_w, outer_w, foothill, sharpness))
	var left_inner: float = pass_w * (inner_k + 0.10 * sin(phase * 1.3))
	var left_outer: float = RANGE_REACH * (outer_k + 0.08 * sin(phase * 0.9))
	var right_inner: float = pass_w * (inner_k * 0.84 + 0.12 * sin(phase * 1.1 + 2.1))
	var right_outer: float = RANGE_REACH * (outer_k + 0.10 * sin(phase * 0.7 + 1.4))
	crest = maxf(
		crest,
		_range_massif(local, left_at, left_inner, left_outer, 1.0 if left_hero else other, sharpness)
	)
	crest = maxf(
		crest,
		_range_massif(local, right_at, right_inner, right_outer, 1.0 if not left_hero else other, sharpness)
	)
	var flank_weight: float = crest * (1.0 - crest)
	crest += (jag_a * sin(local * 0.018 + phase * 0.7) + jag_b * sin(local * 0.037 + phase * 1.9)) * flank_weight
	var sag_depth: float = sag0 + float(depth) * 0.14
	var sag_width: float = pass_w * (1.0 + float(depth) * 0.55)
	var saddle: float = 1.0 - sag_depth * exp(-pow(local / sag_width, 2.0))
	var ends: float = 1.0 - smoothstep(RANGE_REACH * 0.72, RANGE_REACH, absf(local))
	var height: float = float(layer["height"]) * clampf(crest * saddle, 0.0, 1.0) * ends
	var out: float = float(layer["lateral"]) + float(layer["spread"]) * sin(local * 0.0074 + phase * 1.4)
	return Vector2(height, out)


func _range_face(
	b: LowPoly,
	za: float,
	zb: float,
	a: Vector2,
	c: Vector2,
	layer: Dictionary,
	base_y: float,
	body: Color,
	foot: Color
) -> void:
	var width: float = layer["width"]
	var cliff: bool = bool(layer.get("cliff", false)) or _vp_theme == Env.COAST
	var lift_a: float = clampf(a.x / maxf(float(layer["height"]), 1.0), 0.0, 1.0)
	var lift_b: float = clampf(c.x / maxf(float(layer["height"]), 1.0), 0.0, 1.0)
	# Form, not snow. A few percent of height-based lift is enough to read a
	# ridge; a beige cap is how the old hill got its pale-yellow lid.
	var top_a: Color = foot.lerp(body, 0.42 + 0.58 * lift_a)
	var top_b: Color = foot.lerp(body, 0.42 + 0.58 * lift_b)
	if _vp_theme == Env.MOUNTAIN:
		# Ice on the high rock, not a snow lid. Only the top third picks up a
		# cooler rim; the rest stays scree, so it does not read as a painted cap.
		top_a = top_a.lerp(Color("c2ced8"), smoothstep(0.58, 0.96, lift_a) * 0.52)
		top_b = top_b.lerp(Color("c2ced8"), smoothstep(0.58, 0.96, lift_b) * 0.52)
	var crest_a := _far_point(za, _vp_side * a.y, base_y + a.x)
	var crest_b := _far_point(zb, _vp_side * c.y, base_y + c.x)
	if cliff:
		var face_a := _far_point(za, _vp_side * (a.y - width * 0.22), base_y)
		var face_b := _far_point(zb, _vp_side * (c.y - width * 0.22), base_y)
		var ledge_a := _far_point(za, _vp_side * (a.y - width * 0.06), base_y + a.x * 0.70)
		var ledge_b := _far_point(zb, _vp_side * (c.y - width * 0.06), base_y + c.x * 0.70)
		var back_a := _far_point(za, _vp_side * (a.y + width * 1.35), base_y)
		var back_b := _far_point(zb, _vp_side * (c.y + width * 1.35), base_y)
		var scarp := foot.darkened(0.14)
		var turf := body.lerp(Color("3a5244"), 0.40)
		_range_quad_lit(b, face_a, ledge_a, ledge_b, face_b, scarp, foot, foot, scarp)
		_range_quad_lit(b, ledge_a, crest_a, crest_b, ledge_b, foot, turf, turf, foot)
		_range_quad_lit(b, crest_a, back_a, back_b, crest_b, turf, scarp, scarp, turf)
		return
	if _vp_theme == Env.COUNTRY:
		# One break, not three alpine shelves. A fell is a hillside, not a cliff.
		var front_a := _far_point(za, _vp_side * (a.y - width * 0.55), base_y)
		var front_b := _far_point(zb, _vp_side * (c.y - width * 0.55), base_y)
		var mid_a := _far_point(za, _vp_side * (a.y - width * 0.18), base_y + a.x * 0.58)
		var mid_b := _far_point(zb, _vp_side * (c.y - width * 0.18), base_y + c.x * 0.58)
		var back_a := _far_point(za, _vp_side * (a.y + width * 1.05), base_y)
		var back_b := _far_point(zb, _vp_side * (c.y + width * 1.05), base_y)
		var grass := body.lerp(Color("4a5a32"), 0.22)
		_range_quad_lit(b, front_a, mid_a, mid_b, front_b, foot, grass, grass, foot)
		_range_quad_lit(b, mid_a, crest_a, crest_b, mid_b, grass, top_a, top_b, grass)
		_range_quad_lit(b, crest_a, back_a, back_b, crest_b, top_a, foot.darkened(0.08), foot.darkened(0.08), top_b)
		return
	# Three shelves on the lake face: scree, mid-slope, crest. One quad from
	# water to summit was a single card; the break is what lets dusk light a
	# hillside instead of a silhouette.
	var front_a := _far_point(za, _vp_side * (a.y - width * 0.62), base_y)
	var front_b := _far_point(zb, _vp_side * (c.y - width * 0.62), base_y)
	var shelf_a := _far_point(za, _vp_side * (a.y - width * 0.20), base_y + a.x * 0.44)
	var shelf_b := _far_point(zb, _vp_side * (c.y - width * 0.20), base_y + c.x * 0.44)
	var back_a := _far_point(za, _vp_side * (a.y + width * 1.12), base_y)
	var back_b := _far_point(zb, _vp_side * (c.y + width * 1.12), base_y)
	var scree := foot.darkened(0.08)
	_range_quad_lit(b, front_a, shelf_a, shelf_b, front_b, scree, foot, foot, scree)
	_range_quad_lit(b, shelf_a, crest_a, crest_b, shelf_b, foot, top_a, top_b, foot)
	_range_quad_lit(b, crest_a, back_a, back_b, crest_b, top_a, foot.darkened(0.10), foot.darkened(0.10), top_b)


func _range_quad(
	b: LowPoly,
	q0: Vector3,
	q1: Vector3,
	q2: Vector3,
	q3: Vector3,
	c0: Color,
	c1: Color,
	c2: Color,
	c3: Color
) -> void:
	# Winding is written for a range on the rider's right. Mirrored, the same
	# vertex order faces away, so the pair order flips with the side.
	if _vp_side > 0.0:
		b.add_quad_shaded(q0, q1, q2, q3, c0, c1, c2, c3)
	else:
		b.add_quad_shaded(q3, q2, q1, q0, c3, c2, c1, c0)


func _range_quad_lit(
	b: LowPoly,
	q0: Vector3,
	q1: Vector3,
	q2: Vector3,
	q3: Vector3,
	c0: Color,
	c1: Color,
	c2: Color,
	c3: Color
) -> void:
	## Bake a dusk key into the vertex colour. The range faces the lake and the
	## sun sits along the route, so a Lambert-only hillside arrived as one value
	## — a silhouette. Raking it here is what gives a lit slope and a shaded one.
	var n: Vector3
	if _vp_side > 0.0:
		n = (q2 - q0).cross(q1 - q0)
	else:
		n = (q1 - q3).cross(q2 - q3)
	if n.length_squared() < 1e-12:
		_range_quad(b, q0, q1, q2, q3, c0, c1, c2, c3)
		return
	n = n.normalized()
	var sun := Vector3(0.22, 0.18, 1.0).normalized()
	var t := smoothstep(0.22, 0.78, clampf(n.dot(sun) * 0.5 + 0.5, 0.0, 1.0))
	var sky := clampf(n.y, 0.0, 1.0) * 0.10
	var shade := 0.42 * (1.0 - t)
	var key := 0.20 * t + sky
	_range_quad(
		b,
		q0,
		q1,
		q2,
		q3,
		c0.darkened(shade).lightened(key),
		c1.darkened(shade).lightened(key),
		c2.darkened(shade).lightened(key),
		c3.darkened(shade).lightened(key)
	)


func _platform_lateral(out: float, z: float = -1.0e12) -> float:
	## Lateral of a point `out` metres from the spur centreline at z.
	if z < -1.0e11:
		z = _vp_centre
	return _vp_side * (float(_path.spur_offset(z)) + out)


func _set_piece_platform() -> void:
	## The destination. Everything is placed from the overlook centre on ground
	## the path has already levelled, so nothing here needs a fudge height.
	var centre := _vp_centre
	var side := _vp_side
	# Out on the terrace, clear of anything the bike can reach.
	var edge: float = RoadPathGD.PLATFORM_HALF_WIDTH + 6.2
	var timber := Color("6d4f38")

	# Stone terrace, parapet, retaining wall. The rail along the climb is still
	# the spur barrier; across the platform the belvedere owns the edge.
	_build_belvedere()

	# Benches square on to the water, planted on the terrace rather than hovering
	# a world-up offset above a pitched deck.
	for offset in RoadPathGD.PLATFORM_BENCH_Z:
		_viewpoint_bench(centre + float(offset), side, RoadPathGD.PLATFORM_BENCH_OUT)
	_viewpoint_board(centre + 14.0, side, RoadPathGD.PLATFORM_HALF_WIDTH + 1.6, timber)
	_viewpoint_telescope(centre - 0.2, side, edge - 1.4)
	var bin_z := centre + 17.5
	var bin_lat: float = _platform_lateral(RoadPathGD.PLATFORM_HALF_WIDTH + 1.4, bin_z)
	_deck_cube(bin_z, bin_lat, Vector3(0.62, 0.92, 0.62), timber.darkened(0.2), 0.0, -0.04)
	_deck_cube(bin_z, bin_lat, Vector3(0.76, 0.1, 0.76), timber.lightened(0.15), 0.0, 0.88)

	# Three tiny amber bollards make the terrace feel cared for after sunset and
	# give the foreground a warm depth layer against blue water.  Only the outer
	# two own real lights (the per-chunk cap); all three keep their emissive lens.
	for offset in [-19.0, 0.0, 19.0]:
		var lamp_z: float = centre + offset
		var lamp_out: float = edge - 0.65
		var lamp_lateral: float = _platform_lateral(lamp_out, lamp_z)
		_deck_cube(lamp_z, lamp_lateral, Vector3(0.12, 0.62, 0.12), Color("343b3a"), 0.0, -0.04)
		_deck_lamp(lamp_z, lamp_lateral, Vector3(0.22, 0.18, 0.22), LAMP_WARM, 0.56)
		if absf(offset) > 1.0:
			_deck_light(lamp_z, lamp_lateral, 0.68, LAMP_LIGHT, 7.5, 0.72)

	# Pines along the back of the platform, screening the carriageway.
	# Coast keeps the sky; mountain is a couple of snags; forest and country
	# keep the wooded backstop.
	var reach: float = RoadPathGD.PLATFORM_HALF_LENGTH + 8.0
	if _vp_theme != Env.COAST:
		for _i in (10 if _vp_theme == Env.FOREST else 7):
			var z := centre + _rng.randf_range(-reach, reach)
			var species: int = Flora.CONIFER
			if _vp_theme == Env.MOUNTAIN and _rng.randf() < 0.4:
				species = Flora.BARE
			var back_lat: float = _platform_lateral(-RoadPathGD.PLATFORM_HALF_WIDTH - _rng.randf_range(2.0, 10.0), z)
			if _on_tarmac(z, back_lat, 1.4):
				continue
			_tree(
				species,
				z,
				back_lat,
				_rng.randf_range(8.0, 14.0),
				Color("1c3328").lerp(Color("2a4232"), _rng.randf()),
				true
			)
	# Two sentinel pines at the terrace ends — the silhouette that says this
	# is a belvedere and not a lay-by. Coast and mountain leave the view open.
	if _vp_theme == Env.FOREST or _vp_theme == Env.COUNTRY:
		for end in [-1.0, 1.0]:
			var cz: float = centre + end * (RoadPathGD.PLATFORM_HALF_LENGTH - 1.6)
			var sentinel_lat: float = _platform_lateral(RoadPathGD.PLATFORM_HALF_WIDTH + 2.4, cz)
			if _on_tarmac(cz, sentinel_lat, 1.4):
				continue
			_tree(
				Flora.CONIFER,
				cz,
				sentinel_lat,
				15.0 + end * 1.2,
				Color("182e26"),
				true
			)

	# A couple of stone planters at the ends, not a hedge across the view.
	for end in [-1.0, 1.0]:
		var pz: float = centre + end * 16.5
		var plat: float = _platform_lateral(RoadPathGD.PLATFORM_HALF_WIDTH + 1.8, pz)
		_deck_cube(pz, plat, Vector3(0.85, 0.42, 0.85), Color("c4b7a4"), 0.0, -0.04)
		_deck_blob(
			pz,
			plat,
			Vector3(0.9, 0.35, 0.9),
			Color("3a5c3c").darkened(_rng.randf() * 0.15),
			0.38,
			true
		)
	# Boulders and scrub on the back of the platform, screening the road.
	for _i in 11:
		var z := centre + _rng.randf_range(-reach, reach)
		var out: float = -RoadPathGD.PLATFORM_HALF_WIDTH - _rng.randf_range(1.0, 4.0)
		var s := _rng.randf_range(0.7, 2.1)
		if _rng.randf() < 0.45:
			_deck_blob(
				z,
				_platform_lateral(out, z),
				Vector3(s * 1.5, s * 0.9, s * 1.4),
				_face_color().darkened(_rng.randf() * 0.2),
				-0.08,
				false
			)
		else:
			_deck_blob(
				z,
				_platform_lateral(out, z),
				Vector3(s * 1.7, s * 0.6, s * 1.5),
				(_pal["verge"] as Color).darkened(_rng.randf() * 0.28),
				-0.06,
				true
			)


func _build_belvedere() -> void:
	## A limestone terrace with a wall under it. The old platform was a paper
	## shelf: furniture sat on a grass band and the lake showed through under
	## the legs. This is a built place — paving, a parapet you can lean on, and
	## four metres of masonry holding the drop.
	var b := LowPoly.new()
	var limestone := Color("9a8b76")
	var mortar := Color("7e7364")
	var shadow := Color("4f4a43")
	var step := 2.4
	var half: float = RoadPathGD.PLATFORM_HALF_LENGTH
	var z := _vp_centre - half
	while z < _vp_centre + half:
		var next: float = minf(z + step, _vp_centre + half)
		_kerb_run(b, z, next, RoadPathGD.PLATFORM_HALF_WIDTH + 0.32, 0.46, 0.12, limestone.lightened(0.08))
		_belvedere_pave(b, z, next, limestone)
		_belvedere_wall(b, z, next, limestone, mortar, shadow)
		z = next
	_belvedere_ends(b, limestone, shadow)
	var mesh: MeshInstance3D = b.commit_to(self, "PlatformKerbs")
	if mesh:
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Short stone piers at the corners, so the parapet has something to end on.
	for end in [-1.0, 1.0]:
		var pz: float = _vp_centre + end * (half - 0.4)
		var lat: float = _platform_lateral(RoadPathGD.PLATFORM_HALF_WIDTH + 6.15, pz)
		_deck_cube(pz, lat, Vector3(0.48, 0.72, 0.48), limestone.darkened(0.06), 0.0, -0.04)


func _belvedere_pave(b: LowPoly, za: float, zb: float, color: Color) -> void:
	## Stone deck from the parking kerb out to the parapet.
	var inner := RoadPathGD.PLATFORM_HALF_WIDTH + 0.55
	var outer := RoadPathGD.PLATFORM_HALF_WIDTH + 6.05
	var a0: float = _platform_lateral(inner, za)
	var a1: float = _platform_lateral(outer, za)
	var b0: float = _platform_lateral(inner, zb)
	var b1: float = _platform_lateral(outer, zb)
	var a_in := minf(a0, a1)
	var a_out := maxf(a0, a1)
	var b_in := minf(b0, b1)
	var b_out := maxf(b0, b1)
	b.add_quad(
		_p(za, a_in, -0.05), _p(za, a_out, -0.05), _p(zb, b_out, -0.05), _p(zb, b_in, -0.05), color
	)


func _belvedere_wall(b: LowPoly, za: float, zb: float, limestone: Color, mortar: Color, shadow: Color) -> void:
	## A masonry box under the lip, not a single face. A plane at the edge is
	## invisible from the parking and a white line from below; thickness is
	## what makes the terrace a place the benches can stand on.
	const LIP := 6.05
	const FACE := 6.85
	const CAP := 0.52
	const WALL := 9.5
	var lip_a: float = _platform_lateral(RoadPathGD.PLATFORM_HALF_WIDTH + LIP, za)
	var lip_b: float = _platform_lateral(RoadPathGD.PLATFORM_HALF_WIDTH + LIP, zb)
	var face_a: float = _platform_lateral(RoadPathGD.PLATFORM_HALF_WIDTH + FACE, za)
	var face_b: float = _platform_lateral(RoadPathGD.PLATFORM_HALF_WIDTH + FACE, zb)
	var in_a := minf(lip_a, face_a)
	var out_a := maxf(lip_a, face_a)
	var in_b := minf(lip_b, face_b)
	var out_b := maxf(lip_b, face_b)
	# Cap you can lean on.
	b.add_quad(
		_p(za, in_a, -CAP), _p(za, out_a, -CAP), _p(zb, out_b, -CAP), _p(zb, in_b, -CAP), limestone.lightened(0.12)
	)
	# Inner face, toward the parking.
	_wall_face(b, za, zb, lip_a, lip_b, 0.0, -CAP, mortar)
	_wall_face(b, za, zb, face_a, face_b, -CAP, 2.4, limestone)
	_wall_face(b, za, zb, face_a, face_b, 2.4, WALL, shadow)
	# Underside, so the shelf has a bottom when seen from the drop.
	b.add_quad(
		_p(za, in_a, WALL), _p(zb, in_b, WALL), _p(zb, out_b, WALL), _p(za, out_a, WALL), shadow.darkened(0.15)
	)


func _wall_face(
	b: LowPoly, za: float, zb: float, la: float, lb: float, drop_top: float, drop_bot: float, color: Color
) -> void:
	b.add_quad(
		_p(za, la, drop_top), _p(zb, lb, drop_top), _p(zb, lb, drop_bot), _p(za, la, drop_bot), color
	)
	b.add_quad(
		_p(za, la, drop_bot), _p(zb, lb, drop_bot), _p(zb, lb, drop_top), _p(za, la, drop_top), color.darkened(0.06)
	)


func _belvedere_ends(b: LowPoly, limestone: Color, shadow: Color) -> void:
	## Close the short ends of the terrace so it is a box of masonry, not a
	## ribbon that stops in mid-air.
	var half: float = RoadPathGD.PLATFORM_HALF_LENGTH
	var inner := RoadPathGD.PLATFORM_HALF_WIDTH + 0.55
	var face := RoadPathGD.PLATFORM_HALF_WIDTH + 6.45
	for end in [-1.0, 1.0]:
		var z: float = _vp_centre + end * half
		var la: float = _platform_lateral(inner, z)
		var lb: float = _platform_lateral(face, z)
		var a := minf(la, lb)
		var c := maxf(la, lb)
		b.add_quad(_p(z, a, -0.52), _p(z, c, -0.52), _p(z, c, 9.5), _p(z, a, 9.5), limestone.lerp(shadow, 0.35))


func _kerb_run(b: LowPoly, za: float, zb: float, out: float, width: float, height: float, color: Color) -> void:
	## One length of kerb between two points on its own line: a top face and the
	## face that shows toward the parking.
	var half := width * 0.5
	var a0: float = _platform_lateral(out - half, za)
	var a1: float = _platform_lateral(out + half, za)
	var b0: float = _platform_lateral(out - half, zb)
	var b1: float = _platform_lateral(out + half, zb)
	var a_in := minf(a0, a1)
	var a_out := maxf(a0, a1)
	var b_in := minf(b0, b1)
	var b_out := maxf(b0, b1)
	b.add_quad(
		_p(za, a_in, -height), _p(za, a_out, -height), _p(zb, b_out, -height), _p(zb, b_in, -height), color
	)
	var a_near: float = a_in if _vp_side > 0.0 else a_out
	var b_near: float = b_in if _vp_side > 0.0 else b_out
	b.add_quad(
		_p(za, a_near, 0.0), _p(zb, b_near, 0.0), _p(zb, b_near, -height), _p(za, a_near, -height), color.darkened(0.12)
	)


func _viewpoint_bench(z: float, side: float, out: float) -> void:
	## Slatted timber on a stone plinth, square on to the water. The plinth is
	## what stops the legs reading as hovering: they stand in masonry, not on a
	## grass shelf over the drop.
	var timber := Color("6a4a32")
	var iron := Color("3a3d42")
	var lateral := _platform_lateral(out, z)
	_deck_cube(z, lateral, Vector3(1.15, 0.16, 2.15), Color("8e8270"), 0.0, -0.05)
	const SINK := 0.08
	for leg in [-0.72, 0.72]:
		_deck_cube(z + leg, lateral - side * 0.5, Vector3(0.12, 0.38, 0.12), iron, 0.0, SINK)
		_deck_cube(z + leg, lateral + side * 0.5, Vector3(0.12, 0.38, 0.12), iron, 0.0, SINK)
	var seat := 0.38 + SINK
	for slat in [-0.42, -0.14, 0.14, 0.42]:
		_deck_cube(z, lateral + side * slat, Vector3(0.26, 0.07, 1.9), timber.darkened(_rng.randf() * 0.12), 0.0, seat)
	for post_z in [z - 0.72, z + 0.72]:
		_deck_cube(post_z, lateral - side * 0.46, Vector3(0.1, 0.52, 0.1), iron, 0.0, seat)
	for rail in [0.62, 0.86]:
		_deck_cube(z, lateral - side * 0.46, Vector3(0.09, 0.16, 1.9), timber, 0.0, 0.3 + rail + SINK - 0.08)


func _viewpoint_board(z: float, side: float, out: float, timber: Color) -> void:
	## Angled interpretation panel on two legs — the thing every real overlook
	## has, naming what you are looking at.
	var lateral := _platform_lateral(out, z)
	for leg in [-0.85, 0.85]:
		_deck_cube(z + leg, lateral, Vector3(0.12, 1.06, 0.12), timber.darkened(0.25), 0.0, -0.04)
	_deck_cube(z, lateral, Vector3(0.18, 0.1, 2.1), timber.darkened(0.1), 0.0, 1.02)
	# The panel leans back toward the reader; flat on its legs it would show only
	# its edge from the saddle.
	var flat: Basis = _path.frame_flat_at(z)
	var base: Vector3 = _p(z, lateral, -1.12)
	var lean := Basis(flat.z, side * deg_to_rad(36.0))
	_cubes.append(Transform3D(lean * Basis(flat.x * 0.78, flat.y * 0.07, flat.z * 2.0), base))
	_cube_cols.append(Color("d9d6c8"))
	_cubes.append(Transform3D(lean * Basis(flat.x * 0.5, flat.y * 0.075, flat.z * 1.2), base))
	_cube_cols.append(Color("3f6a72"))


func _viewpoint_telescope(z: float, side: float, out: float) -> void:
	## Coin viewer on a post, aimed across the water. Small, but it is the prop
	## that tells the rider this place is meant to be looked *from*.
	var body: Color = (_pal["rail"] as Color).darkened(0.15)
	var lateral := _platform_lateral(out, z)
	_deck_cube(z, lateral, Vector3(0.55, 0.18, 0.55), Color("cfc3b0"), 0.0, -0.04)
	_deck_cube(z, lateral, Vector3(0.16, 1.16, 0.16), Color("3a3d42"), 0.0, 0.14)
	_deck_cube(z, lateral, Vector3(0.42, 0.16, 0.42), body.darkened(0.2), 0.0, 1.26)
	# Barrel across the road axis, tipped down toward the water.
	var flat: Basis = _path.frame_flat_at(z)
	var base: Vector3 = _p(z, lateral, -1.48)
	var barrel := Basis(flat.z, side * deg_to_rad(-18.0)) * Basis(flat.x * 1.1, flat.y * 0.21, flat.z * 0.21)
	_cubes.append(Transform3D(barrel, base + flat.x * side * 0.25))
	_cube_cols.append(Color("2f3339"))


func _build_viewpoint_sign(z: float, side: float, advance: bool) -> void:
	## A brown tourist board over a blue parking board — the pair a rider
	## recognises at 180 km/h. The advance sign stands 240 m before the junction
	## with a distance plate; the second marks the start of the deceleration lane.
	var lateral := side * (HALF_WIDTH + 2.6)
	var blue := Color("1769aa")
	var brown := Color("6b4630")
	var white := Color("f5f7f2")
	_cube(z, lateral, Vector3(0.18, 4.2, 0.18), Color("626a70"), 0.0, 0.0, true)
	_cube(z, lateral, Vector3(2.5, 1.15, 0.16), brown, 0.0, 3.2, true)
	_cube(z, lateral, Vector3(2.2, 1.5, 0.18), blue, 0.0, 1.7, true)
	_sign_label(z, lateral, "200 m" if advance else "P", 2.45, 0.0075 if advance else 0.0095, white)
	_sign_label(z, lateral, "VIEWPOINT", 3.78, 0.0038, white)
	if advance:
		_cube(z, lateral, Vector3(2.65, 0.16, 0.22), Color("f0b33b"), 0.0, 4.35, true)


func _sign_label(z: float, lateral: float, text: String, lift: float, pixel_size: float, color: Color) -> void:
	## Use the engine's font rather than approximating glyphs with boxes. Two
	## front-facing labels keep the text correct from both travel directions —
	## double-sided text would mirror itself when seen from behind.
	var frame: Basis = _path.frame_flat_at(z)
	# Match `_cube`'s terrain-aware base exactly so the text stays centred on the
	# board even where the ground under the post is not at road height.
	var center: Vector3 = (
		_ground_base_for_footprint(z, lateral, 1.2, 0.09, true) - _origin + Vector3.UP * lift
	)
	for direction in [-1.0, 1.0]:
		var label := Label3D.new()
		label.name = "SignLabel"
		label.text = text
		label.font_size = 128
		label.pixel_size = pixel_size
		label.modulate = color
		label.double_sided = false
		label.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		label.visibility_range_end = 320.0
		label.position = center + frame.z * direction * 0.14
		# Label3D's printed face is local +Z (opposite Node3D's usual -Z forward).
		label.basis = Basis.looking_at(-frame.z * direction, frame.y)
		add_child(label)


static func tunnel_straight_span(path: Node, index: int) -> Vector2:
	## Where a tunnel in chunk `index` would run, or a zero span if the route
	## there is too bent to roof over. Short unbanked path segments: banked walls
	## lean into the lane on corners (visible ~700 m / any banked mountain
	## stretch) and a single long box chords through curves.
	var z0: float = float(index) * LENGTH
	var z_end: float = z0 + LENGTH
	var max_curv := 0.0
	var max_pitch_delta := 0.0
	var prev_pitch: float = path.pitch_at(z0 + 2.0)
	var sample_z := z0 + 2.0
	while sample_z < z_end - 2.0:
		max_curv = maxf(max_curv, absf(path.curvature_at(sample_z)))
		var pitch: float = path.pitch_at(sample_z)
		max_pitch_delta = maxf(max_pitch_delta, absf(pitch - prev_pitch))
		prev_pitch = pitch
		sample_z += 2.5
	# Unbanked + wide clearance handles mild bends; skip the really bent/hilly ones.
	if max_curv > 0.0045 or max_pitch_delta > 0.09:
		return Vector2.ZERO
	return Vector2(z0 + 3.0, z_end - 3.0)


static func tunnel_span_at(path: Node, z: float) -> Vector2:
	## The tunnel covering route distance `z`, or a zero span in the open. This
	## is the only thing that knows where a roof is: the geometry below and the
	## reverb in main.gd both read it, so they cannot drift apart.
	var index := floori(z / LENGTH)
	if path.theme_for_chunk(index) != Env.MOUNTAIN or absi(index) % 4 != 0:
		return Vector2.ZERO
	return tunnel_straight_span(path, index)


func _set_piece_tunnel() -> void:
	var z0: float = float(chunk_index) * LENGTH
	var z_end: float = z0 + LENGTH
	if tunnel_straight_span(_path, chunk_index) == Vector2.ZERO:
		return

	const SEG := 5.0
	## Inner face of wall must stay clear of HALF_WIDTH + curb (~8.7).
	## centre 11.2, thick 1.6 → inner face at 10.4.
	const WALL_LAT := HALF_WIDTH + 3.2
	const WALL_THICK := 1.6
	const HEADROOM := 7.5
	const ROOF_T := 1.4
	const WALL_H := HEADROOM + ROOF_T
	const PAD := 0.25

	var z := z0 + 3.0
	while z < z_end - 3.0:
		var seg_len: float = minf(SEG, z_end - 3.0 - z)
		var mid: float = z + seg_len * 0.5
		var depth: float = seg_len + PAD
		for side in [-1.0, 1.0]:
			_path_box(mid, side * WALL_LAT, Vector3(WALL_THICK, WALL_H, depth), _pal["prop_b"], 0.0)
		_path_box(
			mid,
			0.0,
			Vector3(WALL_LAT * 2.0 + WALL_THICK, ROOF_T, depth),
			_pal["prop_c"],
			HEADROOM
		)
		z += SEG

	for portal_z in [z0 + 3.5, z_end - 3.5]:
		for side in [-1.0, 1.0]:
			_path_box(portal_z, side * WALL_LAT, Vector3(1.8, WALL_H + 0.6, 1.5), _pal["accent"], 0.0)
		_path_box(
			portal_z,
			0.0,
			Vector3(WALL_LAT * 2.0 + 1.8, 0.9, 1.5),
			_pal["accent"],
			HEADROOM + ROOF_T
		)


func _path_box(z: float, lateral: float, size: Vector3, color: Color, lift: float = 0.0) -> void:
	## size.x = across-track, size.y = up from the road, size.z = along-track.
	## Uses the *unbanked* road frame so walls stay upright relative to the ribbon
	## and never lean into the lane on a banked corner. Pitch/yaw still follow the
	## path so segments track hills and gentle bends.
	var flat: Basis = _path.frame_flat_at(z)
	var origin: Vector3 = _path.point_at(z, lateral)
	var center: Vector3 = origin + flat.y * (lift + size.y * 0.5) - _origin
	var basis := Basis(flat.x * size.x, flat.y * size.y, flat.z * size.z)
	_cubes.append(Transform3D(basis, center))
	_cube_cols.append(color)


func _terrain_beam(
	z_a: float,
	z_b: float,
	lateral: float,
	width: float,
	height: float,
	color: Color,
	lift: float,
	forced: bool = false
) -> void:
	## Join exact ground endpoints so rails remain continuous through grades,
	## curves and streamed chunk boundaries.
	##
	## Posts already go through `_cube()`'s road-footprint check. Rails used to
	## bypass it, so a country fence lost its posts at an overlook but left two
	## floating beams running straight through the spur road. Check the complete
	## segment before emitting either rail.
	## `forced` is for authored overlook furniture on reserved ground — the far
	## shore wall would otherwise fail the sightline test that keeps random
	## verge props out of the view.
	var middle := (z_a + z_b) * 0.5
	if not forced and not _footprint_is_clear(middle, lateral, width * 0.5, absf(z_b - z_a) * 0.5):
		return
	var a: Vector3 = _terrain_surface_at(z_a, lateral) + Vector3.UP * lift
	var b: Vector3 = _terrain_surface_at(z_b, lateral) + Vector3.UP * lift
	var forward := (b - a).normalized()
	var path_right: Vector3 = (_path.frame_flat_at(z_a).x + _path.frame_flat_at(z_b).x).normalized()
	var up := forward.cross(path_right).normalized()
	if up.dot(Vector3.UP) < 0.0:
		path_right = -path_right
		up = -up
	var basis := Basis(path_right * width, up * height, forward * a.distance_to(b))
	_cubes.append(Transform3D(basis, (a + b) * 0.5 - _origin))
	_cube_cols.append(color)


func _set_piece_switchback() -> void:
	var z0: float = float(chunk_index) * LENGTH
	var middle := z0 + LENGTH * 0.5
	var curve: float = _path.curvature_at(middle)
	var side := -signf(curve) if absf(curve) > 0.001 else 1.0
	# Retaining wall, chevrons, and a tall warning post make the existing sharp
	# mountain bend read as a switchback while leaving the road maths untouched.
	for i in 7:
		var z := z0 + 3.0 + float(i) * 5.5
		_cube(z, side * (HALF_WIDTH + 2.0), Vector3(0.45, 2.4, 3.0), _pal["rail"], 0.0, 0.0, true)
		_cube(z, side * (HALF_WIDTH + 2.65), Vector3(1.1, 0.7, 0.16), _pal["accent"], 0.0, 2.0, true)
	_cube(middle, side * (HALF_WIDTH + 4.0), Vector3(0.32, 5.5, 0.32), _pal["accent"])
	_cube(middle, side * (HALF_WIDTH + 4.0), Vector3(1.8, 0.7, 0.18), _pal["accent"], 0.0, 5.0, true)


# -------------------------------------------------------------------- palette


static func palette(t: int) -> Dictionary:
	match t:
		Env.FOREST:
			return {
				"road": ROAD_TARMAC,
				"stripe": Color("ded2a0"),
				"shoulder": Color("736857"),
				"curb": Color("74563b"),
				"verge": Color("5f7138"),
				"ground": Color("4d6638"),
				"ground_alt": Color("304d39"),
				"rail": Color("796b5b"),
				"prop_a": Color("315e3e"),
				"prop_b": Color("70462e"),
				"prop_c": Color("234b3b"),
				"accent": Color("d7a84f"),
				"glow": Color(2.2, 2.4, 1.5),
			}
		Env.COAST:
			# Pale sand against grey-green marram, and driftwood against dune
			# fencing. Every one of these used to sit inside twenty degrees of the
			# same warm grey, so the whole biome arrived as one undifferentiated
			# beige field however the light fell on it — the ground/ground_alt pair
			# in particular had nothing to blend *between*.
			return {
				"road": ROAD_TARMAC,
				"stripe": Color("fff4cc"),
				"shoulder": Color("8f8371"),
				"curb": Color("a2957f"),
				"verge": Color("94a06e"),
				"ground": Color("c9ae74"),  # open sand
				"ground_alt": Color("7c9483"),  # scrub holding the dune
				"rail": Color("c9c0ae"),
				"prop_a": Color("39715b"),
				"prop_b": Color("6f7f86"),  # weathered driftwood, cool
				"prop_c": Color("b8895a"),  # dune fencing, warm
				"accent": Color("277b89"),
				"glow": Color(2.6, 2.2, 1.4),
			}
		Env.MOUNTAIN:
			# The mountain reads as green *or* as rock, and the interest is in the
			# alternation between them — a hillside is moss where water sits and
			# bare scree where it does not. Blending green into a slightly bluer
			# green, as this did, cannot produce that; it only produces mush.
			return {
				"road": ROAD_TARMAC,
				"stripe": Color("e6ddb8"),
				"shoulder": Color("6b6560"),
				"curb": Color("7c7168"),
				"verge": Color("5c6b3f"),
				"ground": Color("4a5940"),  # moss and alpine turf
				"ground_alt": Color("6a5e4e"),  # bare scree breaking through
				"rail": Color("a8afb4"),
				"prop_a": Color("2b5140"),  # spruce
				"prop_b": Color("8a5a34"),  # larch and rust
				"prop_c": Color("7d8794"),  # cold granite
				"accent": Color("d45a36"),
				"glow": Color(2.4, 1.8, 1.2),
			}
		Env.COUNTRY:
			# Ripe crop against pasture. The two ground tones were both olive and
			# eleven points apart in value, which is a stain rather than a patchwork
			# — and the patchwork is the entire reason to ride through farmland.
			return {
				"road": ROAD_TARMAC,
				"stripe": Color("efe6bc"),
				"shoulder": Color("8a7d63"),
				"curb": Color("857a66"),
				"verge": Color("7d8a3c"),
				"ground": Color("b39a4a"),  # standing corn
				"ground_alt": Color("5c6b34"),  # grazed pasture
				"rail": Color("b9ac8e"),
				"prop_a": Color("425e32"),
				"prop_b": Color("a74e32"),  # brick and rust
				"prop_c": Color("d8b96a"),  # cut hay
				"accent": Color("ead4a2"),
				"glow": Color(2.6, 2.2, 1.5),
			}
	# City — concrete, brick, glass. Distinct hues so slabs don't melt into one purple can.
	return {
		"road": ROAD_TARMAC,
		"stripe": Color("e8e2c6"),
		"shoulder": Color("565762"),
		"curb": Color("6e6e7a"),
		"verge": Color("3d3d4a"),
		"ground": Color("383844"),
		"ground_alt": Color("2e2e3a"),
		"rail": Color("7a7a88"),
		"prop_a": Color("5e6878"),  # cool concrete
		"prop_b": Color("7d5f52"),  # warm brick / sandstone
		"prop_c": Color("36435c"),  # glass-blue massing
		"accent": Color("c45a48"),  # awning / sign red
		"glow": Color(2.5, 2.15, 1.45),
	}
