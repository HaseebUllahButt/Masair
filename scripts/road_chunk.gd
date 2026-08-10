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
const STEPS := 24  # 1.67 m cross-sections keep crests visually round without expensive subdivision
const RIBBON_STEPS_PER_FRAME := 4
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
	[17.0, 0.6, "ground"],
	[20.5, 0.4, "ground"],
	[24.5, 0.2, "ground"],
	[29.0, 0.0, "ground"],
	[34.0, 0.0, "ground"],
	[40.0, 0.0, "ground"],
	[47.0, 0.0, "ground"],
	[55.0, 0.0, "ground"],
	[64.0, 0.0, "ground"],
	[75.0, 0.0, "ground"],
	[88.0, 0.0, "ground"],
	[104.0, 0.0, "ground"],
	[125.0, 0.0, "ground"],
	[155.0, 0.0, "ground"],
	[195.0, 0.0, "ground"],
	[245.0, 0.0, "ground"],
	[305.0, 0.0, "ground"],
	[370.0, 0.0, "ground"],
]

## Roadside tree species. One shape — a ball on a stick — at every scale in every
## theme is what made a pine forest, an orchard and a coastal palm grove all read
## as the same green lollipops going past.
enum Flora { BROADLEAF, CONIFER, BIRCH, PALM, BARE }

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
static var _rotor: ArrayMesh
static var _grass_tuft: ArrayMesh
static var _beacon_material: ShaderMaterial
static var _water_material: ShaderMaterial
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
var _on_spur: bool = false
var _on_lake: bool = false
var _owns_platform: bool = false


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
	var soft: LowPoly = builders[2]
	var z0: float = float(chunk_index) * LENGTH
	for first_step in range(0, STEPS, RIBBON_STEPS_PER_FRAME):
		_build_ribbon_rows(hard, road, soft, z0, first_step, mini(first_step + RIBBON_STEPS_PER_FRAME, STEPS))
		await get_tree().process_frame
	_finish_ribbon(hard, road, soft, z0)
	await get_tree().process_frame
	_build_furniture()
	await get_tree().process_frame
	_build_theme_scenery()
	await get_tree().process_frame
	_build_distant_scenery()
	await get_tree().process_frame
	# Split across frames: the overlook landscape is the heaviest single thing a
	# chunk builds, and the whole point of the incremental path is that nothing in
	# it costs a visible frame. The stages are the same three calls the immediate
	# path makes — spelling the individual builders out here a second time is how
	# the islands and the far settlement came to exist everywhere except in the
	# running game, which streams every chunk through this function.
	if _on_lake:
		_build_lake_basin()
		await get_tree().process_frame
		_build_lake_distance()
		await get_tree().process_frame
		_build_lake_dressing()
		await get_tree().process_frame
	_build_set_piece()
	await _commit_props_incremental()


func _configure(index: int, theme_id: int) -> void:
	chunk_index = index
	theme = theme_id
	_path = get_node("/root/RoadPath")
	_rng.seed = hash(Vector3i(index, theme_id, int(_path.world_seed)))
	_pal = palette(theme)
	_origin = _path.center_at(float(index) * LENGTH)
	position = _origin
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
	# The overlook has its own authored planting, islands, far shore and range.
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
	## Tall trees on both sides, in two staggered rows. Their broad crowns overlap
	## above the single carriageway while birch and conifer understory close the
	## lower sightline. The last stretch opens gradually so the lake is a reveal,
	## not something visible from the junction.
	var z0: float = float(chunk_index) * LENGTH
	for station in 4:
		var z: float = z0 + 4.0 + float(station) * 10.5
		if z >= z0 + LENGTH:
			continue
		var distance: float = absf(z - _vp_centre)
		var divergence: float = float(_path.spur_divergence(z))
		var half: float = float(_path.spur_half_width(z))
		# No planting in the junction mouth. Around the summit, clear a long visual
		# breath before the platform instead of ending the forest at a hard line.
		var reveal: float = smoothstep(
			RoadPathGD.PLATFORM_HALF_LENGTH + 72.0,
			RoadPathGD.PLATFORM_HALF_LENGTH + 190.0,
			distance
		)
		if divergence < 0.08 or half < 2.8 or reveal < 0.08:
			continue
		var centre: float = _vp_side * float(_path.spur_offset(z))
		for road_side in [-1.0, 1.0]:
			# The near row makes the overhead arch; the second row prevents daylight
			# behind it from turning the forest into two decorative tree lines.
			for row in 2:
				var jitter_z: float = z + _rng.randf_range(-2.2, 2.2)
				var setback: float = half + RoadPathGD.SPUR_SHOULDER + 3.2 + float(row) * 7.5
				var lateral: float = centre + road_side * (setback + _rng.randf_range(-0.9, 1.2))
				var height: float = _rng.randf_range(12.5, 18.5) * lerpf(0.72, 1.0, reveal)
				var tint: Color = Color("274b35").lerp(Color("476a3e"), _rng.randf() * 0.48)
				var species: int = Flora.BROADLEAF if _rng.randf() < 0.74 else Flora.CONIFER
				_tree(species, jitter_z, lateral, height, tint.darkened(float(row) * 0.12), true)

			# A lower second canopy makes the road feel wooded at eye level while the
			# taller crowns meet overhead. It stays beyond the surfaced shoulder.
			var under_lateral: float = centre + road_side * (
				half + RoadPathGD.SPUR_SHOULDER + _rng.randf_range(5.0, 8.0)
			)
			_tree(
				Flora.BIRCH if _rng.randf() < 0.55 else Flora.BROADLEAF,
				z + _rng.randf_range(-3.0, 3.0),
				under_lateral,
				_rng.randf_range(5.0, 8.0) * reveal,
				Color("55724a").darkened(_rng.randf() * 0.18),
				true
			)
			_blob(
				z + _rng.randf_range(-3.5, 3.5),
				centre + road_side * (half + RoadPathGD.SPUR_SHOULDER + _rng.randf_range(2.8, 5.5)),
				Vector3(_rng.randf_range(2.2, 4.0), _rng.randf_range(1.0, 2.2), _rng.randf_range(2.0, 3.8)),
				Color("203e2b").lightened(_rng.randf() * 0.08),
				0.0,
				true,
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
	# Strongest just under the lip, gone by the time the scree at the foot of it
	# takes over.
	var band: float = smoothstep(0.0, 0.2, t) * (1.0 - smoothstep(0.5, 0.95, t))
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
	var deck: float = float(_path.spur_deck_blend(z, lateral))
	if deck <= 0.0:
		return 0.0
	var out: float = absf(absf(lateral) - float(_path.spur_offset(z))) - float(_path.spur_half_width(z))
	return smoothstep(0.18, 0.75, deck) * (1.0 - smoothstep(RoadPathGD.SPUR_SHOULDER, RoadPathGD.SPUR_SHOULDER + 2.6, out))


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
	return (_pal["shoulder"] as Color).lightened(0.22)


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
	var soft: LowPoly = builders[2]
	var z0: float = float(chunk_index) * LENGTH
	_build_ribbon_rows(hard, road, soft, z0, 0, STEPS)
	_finish_ribbon(hard, road, soft, z0)


func _new_ribbon_builders() -> Array[LowPoly]:
	var hard := LowPoly.new()  # curbs and markings — crisp edges
	# Keep the tarmac flat shaded.  The ribbon is intentionally made from broad
	# quads; averaging their normals made each triangle catch a different dusk
	# highlight and produced the pale triangular patches visible from the cockpit.
	var road := LowPoly.new()  # tarmac — crisp, original-style road surface
	var soft := LowPoly.new()  # terrain — averaged normals so the hills roll
	soft.smooth = true
	return [hard, road, soft]


func _build_ribbon_rows(
	hard: LowPoly, road: LowPoly, soft: LowPoly, z0: float, first_step: int, end_step: int
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



func _finish_ribbon(hard: LowPoly, road: LowPoly, soft: LowPoly, z0: float) -> void:
	_build_markings(hard, z0)
	if _on_spur:
		_build_spur_ribbon(hard, road, z0)
	if theme == Env.COAST:
		_build_sea(hard, z0)

	var hard_mesh: MeshInstance3D = hard.commit_to(self, "RoadDetails")
	if hard_mesh:
		# Markings and curb faces should stay crisp and matte; their vertex colours
		# carry the reflective/painted distinction without extra materials.
		hard_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var road_mesh: MeshInstance3D = road.commit_to(self, "RoadSurface")
	if road_mesh:
		road_mesh.material_override = _road_material()
		road_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var terrain_mesh: MeshInstance3D = soft.commit_to(self, "Terrain")
	if terrain_mesh:
		terrain_mesh.material_override = LowPoly.terrain_material()
		# Flat ground casting onto itself buys nothing and costs a shadow pass.
		terrain_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
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
	if absf(lateral) - half_lateral > HALF_WIDTH + clearance + 1.0 + half_depth * half_depth * 0.005:
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
			if absf(sample_lateral) <= HALF_WIDTH + clearance:
				return false
	return true


func _viewpoint_reserves_sightline(z: float, lateral: float) -> bool:
	## Ordinary random scenery must not fill the overlook deck, stand between the
	## parked rider and the water, or get planted on the lake bed. Set-piece
	## geometry bypasses this through its own explicit builders after the scenery
	## pass.
	if not (_on_lake or _on_spur):
		return false
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
	forced: bool = false
) -> void:
	## Smooth-shaded ball: shrubs, canopies, hedges — and also boulders and hill
	## humps, which is why `leafy` exists. Only the growing things go in the wind
	## bucket; a swaying rock is worse than a still tree.
	var radius := maxf(size.x, size.z) * 0.5
	if not forced and not _footprint_is_clear(z, lateral, radius, radius):
		return
	var base: Vector3 = _ground_base_for_footprint(z, lateral, radius, radius) - _origin + Vector3(0, lift, 0)
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
	if node_name == "Ridges":
		mmi.visibility_range_end = 0.0
	elif node_name == "Grass":
		# Individual blades are sub-pixel well before the prop distance, and this
		# is the densest bucket in the chunk by an order of magnitude.
		mmi.visibility_range_end = 95.0
	elif _on_lake:
		# Islands, the far bank and the tiny settlement are authored distance
		# cues. The ordinary 280 m roadside cutoff made all of them disappear from
		# the platform even though their generation cost was still being paid.
		mmi.visibility_range_end = 1350.0
	else:
		mmi.visibility_range_end = 360.0 if node_name == "Architecture" else 280.0
	if not shadows:
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)


# ------------------------------------------------------------ shared furniture


func _build_furniture() -> void:
	## Reflector posts on both shoulders. Cheap, and the strobe of them going past
	## is most of what sells speed at 200 km/h. Amber and small: a white cube of
	## glow on every post read as floating litter.
	var z0: float = float(chunk_index) * LENGTH
	var z := z0
	while z < z0 + LENGTH - 0.01:
		for side in [-1.0, 1.0]:
			var lx: float = side * (HALF_WIDTH + 1.5)
			_cube(z, lx, Vector3(0.1, 1.0, 0.1), _pal["curb"].lightened(0.25))
			_cube(z, lx, Vector3(0.14, 0.16, 0.11), _pal["curb"].darkened(0.35), 0.0, 0.8)
			_lamp(z, lx, Vector3(0.11, 0.09, 0.045), REFLECTOR, 0.86)
		z += 10.0

	_verge_planting()
	if theme_carries_power_line(theme):
		_power_line()

	# Armco on the outside of anything fast, and always where there is a drop.
	# The lake shore counts as a drop: the ground falls nine metres to the water
	# a few strides past the verge for the whole run up to the overlook, and it
	# takes the barrier for that to read as a road along a lake rather than a
	# road that happens to end.
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
	# The wire is drawn straight into the mesh, without going through the prop
	# clearance test every scattered object gets, so it has to check for itself.
	# Ending the line at the last pole clear of the junction is what the span
	# logic below already does for a theme boundary.
	return not _junction_occupies(z, _power_line_lateral())


func _power_line() -> void:
	## Poles and catenary wire down one side, the length of the route.
	##
	## Pole positions come from world z, not from the chunk, so a span always
	## finds its neighbour across a chunk seam and the wire runs unbroken to the
	## horizon. The side is fixed by the world seed for the same reason.
	const SPACING := 24.0
	const SEGMENTS := 5
	var lx: float = _power_line_lateral()
	var pole_color := Color("4a382c")
	var wire_color := Color("15151c")
	var z0: float = float(chunk_index) * LENGTH
	var first: float = ceilf(z0 / SPACING) * SPACING
	var b := LowPoly.new()

	var arm_height := func(z: float) -> float: return 8.4 + sin(z * 0.017) * 0.35
	var wire_at := func(z: float, index: int) -> Vector3:
		# Catenary between the two poles either side of z, plus the crossarm offset.
		var span_start: float = floorf(z / SPACING) * SPACING
		var t: float = (z - span_start) / SPACING
		var sag: float = 0.95 * (1.0 - 4.0 * pow(t - 0.5, 2.0))
		var lift: float = lerpf(arm_height.call(span_start), arm_height.call(span_start + SPACING), t) - sag
		var offset: float = (float(index) - 1.0) * 0.85
		return _p(z, lx + offset, -lift)

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
		b.add_capsule(
			Transform3D(Basis.IDENTITY, foot + Vector3(0, head * 0.5, 0)), 0.17, head, 6, pole_color
		)
		b.add_box(
			Transform3D(Basis.IDENTITY, foot + Vector3(0, head - 0.35, 0)), Vector3(2.1, 0.15, 0.15), pole_color
		)
		for index in 3:
			b.add_box(
				Transform3D(Basis.IDENTITY, foot + Vector3((float(index) - 1.0) * 0.85, head - 0.18, 0)),
				Vector3(0.13, 0.22, 0.13),
				Color("6e7276")
			)
		z += SPACING

	# Spans. Each chunk draws the wire crossing it, sampled along the catenary.
	#
	# A span is only drawn when both of its poles are actually built. Poles stop at
	# the forest and coast sections, so a span reaching across that boundary had
	# nothing to hang from and the wire ran out into empty air — the line now ends
	# at the last real pole instead.
	var span_start: float = floorf(z0 / SPACING) * SPACING
	while span_start < z0 + LENGTH + 0.01:
		if not (_pole_exists_at(span_start) and _pole_exists_at(span_start + SPACING)):
			span_start += SPACING
			continue
		for index in 3:
			for seg in SEGMENTS:
				var za: float = span_start + SPACING * float(seg) / float(SEGMENTS)
				var zb: float = span_start + SPACING * float(seg + 1) / float(SEGMENTS)
				if zb < z0 - 0.01 or za > z0 + LENGTH + 0.01:
					continue
				var pa: Vector3 = wire_at.call(za, index)
				var pb: Vector3 = wire_at.call(zb, index)
				# A vertical ribbon rather than a tube: a wire is sub-pixel at any
				# real distance, and this is two triangles instead of eighty.
				var drop := Vector3(0, 0.045, 0)
				b.add_quad(pa + drop, pb + drop, pb - drop, pa - drop, wire_color)
				b.add_quad(pb + drop, pa + drop, pa - drop, pb - drop, wire_color)
		span_start += SPACING
	_landmark_mesh(b, "PowerLine")


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
	# Open coast: the old cube "cliffs" formed the giant blank wall beside the road.
	# Low, rounded rocks keep the land side readable without ever resembling buildings.
	for _i in 8:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var lx := -(HALF_WIDTH + 12.0 + _rng.randf_range(0.0, 42.0))
		var w := _rng.randf_range(4.0, 10.0)
		_blob(z, lx, Vector3(w, _rng.randf_range(2.0, 4.5), w * 0.75), _pal["prop_b"])
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
			_blob(z, lx, Vector3(w, h, w * _rng.randf_range(0.75, 1.15)), hill_color)
			_blob(
				z + _rng.randf_range(-w * 0.22, w * 0.22),
				lx + side * _rng.randf_range(-w * 0.18, w * 0.18),
				Vector3(w * 0.62, h * 0.72, w * 0.68),
				hill_color.lightened(0.06),
				h * 0.12
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
	while fz < z0 + LENGTH - 0.01:
		for side in [-1.0, 1.0]:
			var lx: float = side * (HALF_WIDTH + 4.0)
			_cube(fz, lx, Vector3(0.12, 1.15, 0.12), _pal["rail"])
			_terrain_beam(fz, fz + 4.0, lx, 0.09, 0.09, _pal["rail"], 0.92)
			_terrain_beam(fz, fz + 4.0, lx, 0.09, 0.09, _pal["rail"], 0.58)
		fz += 4.0

	# Hedgerows: field boundaries marching away from the road over the swells.
	for side in [-1.0, 1.0]:
		var hz := z0 + _rng.randf_range(0.0, 22.0)
		while hz < z0 + LENGTH:
			var out := HALF_WIDTH + 7.0
			while out < 95.0:
				var h := _rng.randf_range(1.5, 2.4)
				_cube(
					hz,
					side * out,
					Vector3(2.6, h, 1.5),
					(_pal["prop_a"] as Color).darkened(_rng.randf() * 0.25)
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
				# Mountain keeps a modestly taller range — big rolling hills, not
				# an alpine wall — while every other theme sits lower still.
				height *= 1.35 if theme == Env.MOUNTAIN else 0.62
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
	match theme:
		Env.COUNTRY, Env.COAST, Env.MOUNTAIN:
			_landmark_wind_farm()
		_:
			_landmark_mast()


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
	var z0 := float(chunk_index) * LENGTH
	var side: float = 1.0 if _rng.randf() < 0.5 else -1.0
	var tower: Color = Color("e6e9ee").darkened(0.06)
	for i in 3:
		var z := z0 + 5.0 + float(i) * 13.0 + _rng.randf_range(-3.0, 3.0)
		var lx: float = side * _rng.randf_range(82.0, 155.0)
		var height: float = _rng.randf_range(24.0, 34.0)
		# Tower goes in the ridge bucket, which is never culled — the rotor node
		# is not either, and a spinning rotor above a vanished tower is worse
		# than no turbine at all.
		_ridge(z, lx, Vector3(2.8, height, 2.8), tower)

		var hub: Vector3 = _terrain_surface_at(z, lx) - _origin + Vector3(0, height * 0.97, 0)
		# Face the rotor across the road, so its disc is seen flat from the saddle
		# rather than edge-on as a line.
		var axis: Vector3 = _path.frame_flat_at(z).x * -side
		var node := Node3D.new()
		node.name = "Turbine"
		node.set_script(TurbineGD)
		node.set("speed", _rng.randf_range(0.42, 0.72) * (-1.0 if _rng.randf() < 0.3 else 1.0))
		node.transform = Transform3D(Basis.looking_at(axis, Vector3.UP), hub)
		node.scale = Vector3.ONE * (height / 30.0)
		var mesh := MeshInstance3D.new()
		mesh.mesh = rotor_mesh()
		mesh.material_override = LowPoly.solid_material()
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.add_child(mesh)
		add_child(node)


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
	return (
		RoadPathGD.VIEWPOINT_FIRST
		+ RoadPathGD.VIEWPOINT_PERIOD * roundf((z - RoadPathGD.VIEWPOINT_FIRST) / RoadPathGD.VIEWPOINT_PERIOD)
	)


static func viewpoint_side(index: int, world_seed: int) -> float:
	var centre := viewpoint_centre_static((float(index) + 0.5) * LENGTH)
	return 1.0 if posmod(hash(Vector2i(int(round(centre)), world_seed)), 2) == 0 else -1.0


# ------------------------------------------------------------------- overlooks
#
# The detour, in the order the rider meets it:
#
#   a sign 120 m out  ->  a junction where a spur road diverges  ->  250 m of
#   climbing, curving single carriageway  ->  a parking platform on a headland
#   thirteen metres above the road  ->  a wall, benches and a viewer over a
#   drop to a lake  ->  ranges going back into the haze  ->  250 m of spur back
#   down to a second junction.
#
# The shape of all of it — where the spur runs, how high it climbs, where the
# headland falls into the water — belongs to RoadPath, so every chunk agrees.
# What follows is the surfacing, the furniture and the planting on top.


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
			_cube(za, la, Vector3(0.13, head_a, 0.13), segment_rail.darkened(0.22), _spur_yaw(za), 0.0, true)


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
	for advance in [entry - 150.0, entry - 12.0]:
		if advance >= z0 and advance < z0 + LENGTH:
			_build_viewpoint_sign(advance, _vp_side, advance < entry - 60.0)
	# Chevron board at the nose of the gore — where the gore is actually wide
	# enough to stand a board in. Placed at a fixed distance into the mouth it
	# stood on tarmac the rider is invited to ride across, and they rode through
	# it every time.
	var nose := _spur_nose()
	if nose >= z0 and nose < z0 + LENGTH:
		var lateral: float = _vp_side * (float(_path.spur_offset(nose)) - float(_path.spur_half_width(nose)) - 1.5)
		var yaw := _spur_yaw(nose) * 0.5  # splits the angle between the two roads
		_cube(nose, lateral, Vector3(0.16, 1.5, 0.16), Color("626a70"), yaw, 0.0, true)
		_cube(nose, lateral, Vector3(1.9, 0.85, 0.14), Color("f0b33b"), yaw, 1.5, true)
		_cube(nose, lateral, Vector3(1.9, 0.12, 0.16), Color("2b2f36"), yaw, 1.9, true)


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
	_build_far_shore()
	_build_far_settlement()
	_build_waterfall()


func _build_lake_dressing() -> void:
	_build_lake_edges()
	_build_islands()
	_build_view_frame()


## Wooded islands, placed from the overlook centre so they are the same three
## islands however the chunks around them stream. Nothing else in the view does
## as much: a lake with nothing floating in it has no middle distance at all, so
## the far shore reads as a painted edge and the water as a flat blue card. An
## island is a known size at a known place, and everything between the rail and
## the mountains falls into order behind it.
const VIEW_ISLANDS := [
	{"z": 76.0, "out": 520.0, "radius": 48.0, "rise": 10.0, "trees": 21},
	{"z": 330.0, "out": 322.0, "radius": 22.0, "rise": 5.5, "trees": 7},
	{"z": -54.0, "out": 650.0, "radius": 16.0, "rise": 4.0, "trees": 5},
]


func _build_view_frame() -> void:
	## A few near, dark pines at the extreme sides turn the lake into a composed
	## vista. The centre remains completely open; these only give the eye a near
	## silhouette to measure the islands, shore and ranges against.
	const FRAME_TREES := [
		[-304.0, 20.0], [-262.0, 16.0], [-224.0, 12.0],
		[226.0, 13.0], [266.0, 17.0], [308.0, 21.0],
	]
	var z0 := float(chunk_index) * LENGTH
	for spec in FRAME_TREES:
		var z: float = _vp_centre + float(spec[0])
		if z < z0 or z >= z0 + LENGTH:
			continue
		var out: float = float(_path.viewpoint_near_shore(z)) - 10.0
		var tint: Color = (_pal["prop_c"] as Color).darkened(0.28)
		_tree(Flora.CONIFER, z, _vp_side * out, float(spec[1]), tint, true)


func _build_islands() -> void:
	var z0 := float(chunk_index) * LENGTH
	for spec in VIEW_ISLANDS:
		var z: float = _vp_centre + float(spec["z"])
		if z < z0 or z >= z0 + LENGTH:
			continue
		_island(z, float(spec["out"]), float(spec["radius"]), float(spec["rise"]), int(spec["trees"]))


func _island(z: float, out: float, radius: float, rise: float, trees: int) -> void:
	## A dome standing out of the water with a few conifers on it. The terrain
	## under it is the lake bed, so everything here is lifted to the water line
	## first — `_height_above_water` is negative out there and lifting by its
	## negation is exactly the surface.
	var lateral: float = _vp_side * out
	if _height_above_water(z, out) > -1.0:
		return  # a shoal that is already dry land; nothing to stand up out of it
	# Country prop_c is sunlit sandstone.  At island scale it became a set of
	# floating gold lozenges in the water, so the lake owns a slate-and-moss rock
	# family independent of the roadside palette.
	var rock: Color = Color("344f4b").lerp(Color("506052"), _rng.randf() * 0.28)
	var island_center := _far_point(z, lateral, _vp_water_y)
	# Placed at an absolute height rather than on the ground beneath it. Grounded
	# the ordinary way, a prop this wide takes the *lowest* of nine terrain
	# samples so its far side cannot float — under a lake that is the bed, four
	# metres down, and the island quietly drowned.
	# A low wooded dome, not a boulder.  The old 2.4 multiplier left twice the
	# named rise above the surface and exposed a huge bare oval under every tree.
	var shore_size := Vector3(radius * 2.5, maxf(rise * 0.38, 2.2), radius * 2.3)
	var shore_spin := Basis(Vector3.UP, _rng.randf_range(0.0, TAU)).scaled(shore_size)
	_blobs.append(
		Transform3D(shore_spin, island_center + Vector3.UP * shore_size.y * 0.40)
	)
	_blob_cols.append(Color("718078").lerp(rock, 0.32))
	var size := Vector3(radius * 2.0, rise * 1.2, radius * 2.0)
	var seat: Vector3 = island_center
	_blobs.append(Transform3D(Basis(Vector3.UP, _rng.randf_range(0.0, TAU)).scaled(size), seat + Vector3(0.0, size.y * 0.42, 0.0)))
	_blob_cols.append(rock)
	for i in trees:
		var angle: float = _rng.randf_range(0.0, TAU)
		var spread: float = radius * 0.48 * sqrt(_rng.randf())
		var offset := Vector3(cos(angle) * spread, 0.0, sin(angle) * spread * 0.82)
		var edge: float = sqrt(
			maxf(1.0 - pow(offset.x / radius, 2.0) - pow(offset.z / radius, 2.0), 0.0)
		)
		var dome_height := size.y * (0.42 + 0.5 * edge)
		var tree_height := _rng.randf_range(10.0, 22.0) * (0.55 + 0.45 * edge)
		var tree_color := (_pal["prop_a"] as Color).darkened(0.12 + _rng.randf() * 0.32).lerp(
			Color("375968"), 0.14
		)
		var frame := Transform3D(
			Basis(Vector3.UP, _rng.randf_range(0.0, TAU)),
			island_center + offset + Vector3.UP * (dome_height - 0.35)
		)
		if _rng.randf() < 0.85:
			_grow_conifer(frame, tree_height, tree_color)
		else:
			_grow_broadleaf(frame, tree_height, tree_color)


func _water_color() -> Color:
	## Deep, because this is an albedo under a 1.5 sun and a lake fills a third of
	## the frame. At the old values the blue channel alone came out past 1.0 and
	## the whole surface clipped to pale cyan — a bright sheet where the darkest,
	## calmest mass in the composition ought to be.
	match theme:
		Env.MOUNTAIN:
			return Color("17475a")
		Env.COAST:
			return Color("17596a")
		Env.FOREST:
			return Color("174d58")
	return Color("1b5060")


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
	const LS := 16
	const INNER := 215.0
	const OUT := 860.0
	var z0 := float(chunk_index) * LENGTH
	var surface := _water_color()
	var b := LowPoly.new()
	b.smooth = true
	for i in ZS:
		var za := z0 + LENGTH * float(i) / float(ZS)
		var zb := z0 + LENGTH * float(i + 1) / float(ZS)
		for j in LS:
			var out_a: float = lerpf(INNER, OUT, float(j) / float(LS))
			var out_b: float = lerpf(INNER, OUT, float(j + 1) / float(LS))
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
		mesh.material_override = water_material()
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _water_shade(surface: Color, out: float, z: float) -> Color:
	## Shallows read lighter than open water. A single flat colour looks like
	## coloured glass laid over the valley.
	## Deep water is dark. The sheet is metallic enough to pick up the sky, and
	## with a pale albedo on top of that it stops reading as water at all.
	## The gradient is also depth cue: a lake that is one colour edge to edge has
	## no distance in it, and this is the largest single surface in the view.
	var deep: float = smoothstep(RoadPathGD.LAKE_NEAR - 30.0, RoadPathGD.LAKE_NEAR + 330.0, out)
	var color := surface.lightened(0.07).lerp(surface.darkened(0.22), deep)
	# Very broad horizontal variations catch the sky as painted planes. Kept
	# below four percent so the water gains facets without becoming stripy.
	color = color.lightened((0.5 + 0.5 * sin(out * 0.043 + z * 0.018)) * 0.035)
	# A restrained path of sky light gives the lake a centre and leads the eye to
	# the far shore. It is vertex colour, not another shader or reflection pass.
	var across: float = 1.0 - smoothstep(24.0, 105.0, absf(z - _vp_centre))
	var along: float = smoothstep(RoadPathGD.LAKE_NEAR, 360.0, out) * (1.0 - smoothstep(690.0, 840.0, out))
	return color.lerp(Color("a5bcb0"), across * along * 0.24)


func _build_far_ground() -> void:
	## The drawn terrain stops at 370 m, which is fine from a saddle at road
	## level and not fine from a platform thirteen metres up: from there the eye
	## clears the edge and sees sky under the mountains. This skirt carries the
	## far bank out to where the range stands on it.
	var z0 := float(chunk_index) * LENGTH
	var b := LowPoly.new()
	b.smooth = true
	var far_y := _vp_water_y + RoadPathGD.FAR_BANK_RISE
	var color: Color = (_pal["ground_alt"] as Color).lerp(Color("7d8ab0"), 0.35)
	for i in 4:
		var za := z0 + LENGTH * float(i) / 4.0
		var zb := z0 + LENGTH * float(i + 1) / 4.0
		for j in 3:
			var out_a: float = lerpf(780.0, 1720.0, float(j) / 3.0)
			var out_b: float = lerpf(780.0, 1720.0, float(j + 1) / 3.0)
			var lat_a := _vp_side * out_a
			var lat_b := _vp_side * out_b
			if lat_a > lat_b:
				var swap := lat_a
				lat_a = lat_b
				lat_b = swap
			b.add_quad(
				_far_point(za, lat_a, far_y),
				_far_point(za, lat_b, far_y),
				_far_point(zb, lat_b, far_y),
				_far_point(zb, lat_a, far_y),
				color
			)
	var mesh: MeshInstance3D = b.commit_to(self, "ViewpointFarGround")
	if mesh:
		mesh.material_override = LowPoly.terrain_material()
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mesh.visibility_range_end = 0.0


func _height_above_water(z: float, out: float) -> float:
	## Cheap height query for shore dressing: out here the ground is simply the
	## centreline height less its drop, so this needs no transform.
	return float(_path.height_at(z)) - float(_path.terrain_drop(_vp_side * out, z)) - _vp_water_y


func _build_lake_edges() -> void:
	## Boulders and reeds along the waterline, and scree on the face of the
	## headland. All of it sits below the platform, dressing the drop without
	## ever standing in the view from it.
	var z0 := float(chunk_index) * LENGTH
	for _i in 7:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var out: float = float(_path.viewpoint_near_shore(z)) + _rng.randf_range(-12.0, 6.0)
		if _height_above_water(z, out) > 3.0:
			continue
		var s := _rng.randf_range(1.0, 3.0)
		_blob(
			z,
			_vp_side * out,
			Vector3(s * 2.0, s * 1.1, s * 1.7),
			Color("69736f").lightened(_rng.randf() * 0.08),
			0.0,
			false,
			true
		)
	for _i in 10:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var out: float = float(_path.viewpoint_near_shore(z)) + _rng.randf_range(-3.0, 8.0)
		if _height_above_water(z, out) > 1.2:
			continue
		var s := _rng.randf_range(0.7, 1.6)
		_blob(
			z,
			_vp_side * out,
			Vector3(s * 1.9, s * 1.5, s * 1.6),
			Color("355647").darkened(_rng.randf() * 0.18),
			0.0,
			true,
			true
		)
	# Scree and scrub clinging to the face under the platform.
	for _i in 14:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		# Starts just outside the crest, never inside it. Reaching back a few
		# metres put waist-high scrub on the terrace itself — standing at the
		# parking edge, the two nearest things to the rider were a pair of bushes
		# with the view behind them.
		var out: float = RoadPathGD.HEADLAND_CREST + 3.0 + _rng.randf_range(0.0, 42.0)
		var above := _height_above_water(z, out)
		if above < 1.0 or float(_path.spur_deck_blend(z, _vp_side * out)) > 0.15:
			continue
		var s := _rng.randf_range(0.8, 2.4)
		if _rng.randf() < 0.5:
			_blob(
				z,
				_vp_side * out,
				Vector3(s * 1.7, s * 1.1, s * 1.5),
				Color("666b67").darkened(_rng.randf() * 0.16),
				0.0,
				false,
				true
			)
		else:
			_tree(
				Flora.CONIFER if _rng.randf() < 0.7 else Flora.BARE,
				z,
				_vp_side * out,
				_rng.randf_range(3.5, 8.0),
				(_pal["prop_a"] as Color).darkened(_rng.randf() * 0.35),
				true
			)


## A handful of roofs and a jetty on the far bank, around 120 m of shoreline
## either side of the overlook. This is the scale reference the whole view hangs
## on: a treeline can be any distance away, but a house is four metres tall and
## everybody knows it, so the moment there is one across the water the lake has
## a width and the mountains behind it have a size.
const FAR_HAMLET_Z := [-104.0, -72.0, -58.0, -18.0, 6.0, 34.0, 63.0]


func _build_far_settlement() -> void:
	var z0 := float(chunk_index) * LENGTH
	var wall: Color = (_pal["prop_c"] as Color).lerp(Color("d8d2c4"), 0.55)
	var roof := Color("7a4a3e")
	for index in FAR_HAMLET_Z.size():
		var z: float = _vp_centre + float(FAR_HAMLET_Z[index]) * 1.6
		if z < z0 or z >= z0 + LENGTH:
			continue
		# Set back from the water by a few metres, and only where the bank is
		# actually dry — the shoreline wanders, and a cottage standing in the
		# lake is worse than no cottage at all.
		var out: float = float(_path.viewpoint_far_shore(z, _vp_centre)) + 6.0 + float(index % 3) * 9.0
		if _height_above_water(z, out) < 1.4:
			continue
		var wide: float = 5.0 + float(index % 2) * 2.4
		var tall: float = 3.6 + float((index + 1) % 3) * 1.1
		var lateral: float = _vp_side * out
		_cube(z, lateral, Vector3(wide, tall, wide * 0.72), wall, 0.0, 0.0, true)
		_cube(z, lateral, Vector3(wide * 1.12, 0.9, wide * 0.84), roof.darkened(float(index % 3) * 0.08), 0.0, tall, true)
	# The jetty, and two boats tied up along it. A straight line of anything
	# man-made on a shore is the one shape a landscape never makes on its own.
	var jetty_z: float = _vp_centre + 18.0
	if jetty_z < z0 or jetty_z >= z0 + LENGTH:
		return
	var shore: float = float(_path.viewpoint_far_shore(jetty_z, _vp_centre))
	var timber := Color("6d5744")
	for plank in 9:
		var out: float = shore - float(plank) * 2.6
		var above := _height_above_water(jetty_z, out)
		if above > 1.2:
			continue
		_cube(
			jetty_z,
			_vp_side * out,
			Vector3(2.7, 0.34, 2.2),
			timber,
			0.0,
			-above + 0.5,
			true
		)
	for boat in 2:
		var out: float = shore - 9.0 - float(boat) * 7.0
		var bz: float = jetty_z + (3.4 if boat == 0 else -3.6)
		_blob(
			bz,
			_vp_side * out,
			Vector3(1.6, 0.7, 4.6),
			Color("e6e2d8") if boat == 0 else Color("bcc7cf"),
			-_height_above_water(bz, out) - 0.1,
			false,
			true
		)


func _build_waterfall() -> void:
	## One bright vertical accent across the lake. The layered ranges give scale,
	## but without a focal landmark the eye has nowhere to settle. This is twelve
	## triangles total and only exists in the chunk containing its route position.
	var z0 := float(chunk_index) * LENGTH
	var falls_z: float = _vp_centre - 92.0
	if falls_z < z0 or falls_z >= z0 + LENGTH:
		return
	var out: float = float(_path.viewpoint_far_shore(falls_z, _vp_centre)) + 26.0
	var lateral: float = _vp_side * out
	var bottom_y: float = _vp_water_y + 1.0
	var top_y: float = _vp_water_y + 42.0
	var width := 7.0
	var b := LowPoly.new()
	var pale := Color("a8d9df")
	var bright := Color("e0f4ed")
	var a := _far_point(falls_z - width, lateral, bottom_y)
	var c := _far_point(falls_z + width, lateral, bottom_y)
	var d := _far_point(falls_z + width * 0.55, lateral, top_y)
	var e := _far_point(falls_z - width * 0.55, lateral, top_y)
	b.add_quad_shaded(a, c, d, e, pale, pale, bright, bright)
	b.add_quad_shaded(c, a, e, d, pale, pale, bright, bright)
	var mesh: MeshInstance3D = b.commit_to(self, "ViewpointWaterfall")
	if mesh:
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for i in 5:
		var spread := (float(i) - 2.0) * 2.1
		var p: Vector3 = _far_point(falls_z + spread, lateral - _vp_side * 2.0, bottom_y)
		var size := Vector3(6.4 - absf(spread) * 0.35, 1.5, 4.2)
		_blobs.append(Transform3D(Basis.IDENTITY.scaled(size), p - _origin))
		_blob_cols.append(Color("a9c8cb").lightened(float(i % 2) * 0.08))


func _build_far_shore() -> void:
	## Forest on the far bank. This band is what gives the lake its scale:
	## without something of known size across the water, the range behind it
	## reads as a painted backdrop a hundred metres away.
	var z0 := float(chunk_index) * LENGTH
	for _i in 30:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var out: float = float(_path.viewpoint_far_shore(z, _vp_centre)) + _rng.randf_range(4.0, 90.0)
		if _height_above_water(z, out) < 0.4:
			continue
		var tint: Color = (_pal["prop_a"] as Color).darkened(0.12 + _rng.randf() * 0.32).lerp(Color("506872"), 0.15)
		var species: int = Flora.CONIFER if _rng.randf() < 0.8 else Flora.BROADLEAF
		_tree(species, z, _vp_side * out, _rng.randf_range(11.0, 23.0), tint, true)
	for _i in 3:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var out: float = float(_path.viewpoint_far_shore(z, _vp_centre)) + _rng.randf_range(10.0, 70.0)
		if _height_above_water(z, out) < 1.0:
			continue
		var s := _rng.randf_range(5.0, 13.0)
		_blob(
			z,
			_vp_side * out,
			Vector3(s * 1.6, s, s * 1.4),
			Color("586663").lerp(Color("71808a"), _rng.randf() * 0.28),
			0.0,
			false,
			true
		)


## Three ranges going back into the haze. Each is a folded crest rather than a
## row of cones: overlapping cones show every one of their outlines and read as
## a bag of pyramids, which is what the old overlook put across the water.
## A fourth, low, dark layer sits closest: hills on the far bank rather than
## mountains behind it. Three layers all read as "far away" together, and a view
## made only of far away has no depth in it — the near one is what the eye
## measures the rest against.
## `snow` is the fraction of a layer's own height the snowline sits at, and it
## used to sit low enough that most of every mountain came out white. A range
## with snow halfway down it has no mass: it reads as cloud, and four layers of
## cloud behind a pale lake is the whole reason this view had nothing in it. Only
## the peaks are capped now, and the rock under them is dark enough to be rock.
## `haze` mixes each layer's colour toward the sky before it is ever lit, and it
## used to carry the whole aerial perspective on its own — the far layer's albedo
## came out at 0.65 and the sun then multiplied it to 1.2, so the mountains
## clipped to white and the range that should recede furthest was the brightest
## thing in the frame. Distance is the engine's fog to draw. This only tints.
const RANGE_LAYERS := [
	{"lateral": 900.0, "height": 58.0, "spread": 38.0, "width": 104.0, "haze": 0.0, "snow": 2.0, "peak": -210.0},
	{"lateral": 1120.0, "height": 102.0, "spread": 52.0, "width": 132.0, "haze": 0.13, "snow": 2.0, "peak": 245.0},
	{"lateral": 1370.0, "height": 166.0, "spread": 66.0, "width": 172.0, "haze": 0.29, "snow": 0.90, "peak": -145.0},
	{"lateral": 1640.0, "height": 228.0, "spread": 78.0, "width": 214.0, "haze": 0.47, "snow": 0.82, "peak": 130.0},
]
const RANGE_STEP := 10.0  # enough facets for folded crests without a dense mesh


func _build_view_range() -> void:
	var z0 := float(chunk_index) * LENGTH
	var b := LowPoly.new()
	# Blue, not grey. Distance reads as blue because the air between is blue, and
	# a range mixed from neutral slate comes out the colour of concrete however
	# dark it is made — which reads as a wall behind the lake rather than as
	# something twenty minutes' ride away.
	var haze := Color("526e82")
	var rock := Color("182f43")
	if theme == Env.COAST:
		rock = Color("20394e")
	elif theme == Env.COUNTRY:
		rock = Color("213847")
	# Not white. This is an albedo, and the sun multiplies it: snow painted at
	# full white renders past 1.0 and clips, which put the least important part of
	# the view — the tops of the furthest mountains — in charge of the frame.
	var snow := Color("cbbfa9")
	var base_y := _vp_water_y - 4.0
	for index in RANGE_LAYERS.size():
		var layer: Dictionary = RANGE_LAYERS[index]
		var phase: float = float(posmod(hash(Vector2i(index, int(_path.world_seed))), 1000)) * 0.00628
		var fade: float = layer["haze"]
		var body: Color = rock.darkened(0.16 - float(index) * 0.05).lerp(haze, fade)
		var foot: Color = rock.darkened(0.34).lerp(haze, fade * 0.85)
		var cap: Color = snow.lerp(haze, fade * 0.7)
		var steps := int(LENGTH / RANGE_STEP)
		for i in steps:
			var za := z0 + RANGE_STEP * float(i)
			var zb := za + RANGE_STEP
			_range_face(
				b,
				za,
				zb,
				_range_sample(za, layer, phase),
				_range_sample(zb, layer, phase),
				layer,
				base_y,
				body,
				foot,
				cap
			)
	var mesh: MeshInstance3D = b.commit_to(self, "ViewpointRange")
	if mesh:
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# The skyline never culls: blinking a mountain range out at the prop
		# distance would be the most obvious pop in the game.
		mesh.visibility_range_end = 0.0


func _range_sample(z: float, layer: Dictionary, phase: float) -> Vector2:
	## x = crest height above the base, y = how far out the crest line runs.
	## Broad swells establish a calm silhouette; one asymmetric summit per layer
	## gives the eye somewhere to land.  The previous equal-weight high-frequency
	## sines repeatedly crashed from maximum height to the twelve-metre clamp and
	## produced a saw blade of isolated triangular walls.
	var local: float = z - _vp_centre
	var peak_distance: float = (local - float(layer["peak"])) / 150.0
	var summit: float = exp(-peak_distance * peak_distance)
	var shoulder: float = exp(-pow((local + float(layer["peak"]) * 0.55) / 260.0, 2.0))
	var n := (
		0.34
		+ 0.14 * sin(local * 0.0091 + phase)
		+ 0.08 * sin(local * 0.0183 + phase * 1.7)
		+ 0.34 * summit
		+ 0.16 * shoulder
	)
	var height: float = float(layer["height"]) * clampf(n, 0.18, 1.0)
	var out: float = float(layer["lateral"]) + float(layer["spread"]) * sin(local * 0.0068 + phase * 1.6)
	return Vector2(maxf(height, 12.0), out)


func _range_face(
	b: LowPoly,
	za: float,
	zb: float,
	a: Vector2,
	c: Vector2,
	layer: Dictionary,
	base_y: float,
	body: Color,
	foot: Color,
	cap: Color
) -> void:
	var width: float = layer["width"]
	var snowline: float = float(layer["height"]) * float(layer["snow"])
	var crest_a := _far_point(za, _vp_side * a.y, base_y + a.x)
	var crest_b := _far_point(zb, _vp_side * c.y, base_y + c.x)
	var front_a := _far_point(za, _vp_side * (a.y - width), base_y)
	var front_b := _far_point(zb, _vp_side * (c.y - width), base_y)
	var back_a := _far_point(za, _vp_side * (a.y + width), base_y)
	var back_b := _far_point(zb, _vp_side * (c.y + width), base_y)
	var top_a: Color = body.lerp(cap, smoothstep(snowline, snowline + 18.0, a.x))
	var top_b: Color = body.lerp(cap, smoothstep(snowline, snowline + 18.0, c.x))
	# Winding is written for a range on the rider's right. Mirrored, the same
	# vertex order faces away, so the pair order flips with the side.
	if _vp_side > 0.0:
		b.add_quad_shaded(front_a, crest_a, crest_b, front_b, foot, top_a, top_b, foot)
		b.add_quad_shaded(crest_a, back_a, back_b, crest_b, top_a, foot, foot, top_b)
	else:
		b.add_quad_shaded(front_b, crest_b, crest_a, front_a, foot, top_b, top_a, foot)
		b.add_quad_shaded(crest_b, back_b, back_a, crest_a, top_b, foot, foot, top_a)


func _platform_lateral(out: float) -> float:
	## Lateral of a point `out` metres from the platform's own centreline.
	return _vp_side * (RoadPathGD.SPUR_OUT + out)


func _set_piece_platform() -> void:
	## The destination. Everything is placed from the overlook centre on ground
	## the path has already levelled, so nothing here needs a fudge height.
	var centre := _vp_centre
	var side := _vp_side
	# Out on the terrace, clear of anything the bike can reach.
	var edge: float = RoadPathGD.PLATFORM_HALF_WIDTH + 6.2
	var stone: Color = (_pal["prop_c"] as Color).lerp(Color("8d8b84"), 0.45)
	var timber := Color("6d4f38")

	# The edge is a kerb and an open post-and-rail, not a parapet.
	#
	# That is a sight-line decision before it is a scenic one. A waist-high wall
	# two metres in front of a seated rider blocks everything more than five
	# degrees below the horizon, which is the entire lake: the first version of
	# this platform had one, and sitting on the bench showed nothing but the far
	# shore and some sky.
	#
	# The rail itself is the spur's barrier, which runs out along the terrace and
	# back — see _build_spur_barrier(). A second fence built here, from boxes
	# spaced along the route, is where most of the gaps in the platform edge came
	# from: seventy metres off the centreline, two metres of route is nearer three
	# metres of terrace, so every box fell short of the next.
	_build_platform_kerbs(stone)

	# Benches square on to the water, close enough to the edge that the terrace
	# floor does not crop the water out either.
	for offset in RoadPathGD.PLATFORM_BENCH_Z:
		_viewpoint_bench(centre + float(offset), side, RoadPathGD.PLATFORM_BENCH_OUT)
	_viewpoint_board(centre + 14.0, side, RoadPathGD.PLATFORM_HALF_WIDTH + 1.6, timber)
	_viewpoint_telescope(centre - 0.2, side, edge - 1.4)
	_cube(centre + 17.5, _platform_lateral(RoadPathGD.PLATFORM_HALF_WIDTH + 1.4), Vector3(0.62, 0.92, 0.62), timber.darkened(0.2), 0.0, 0.0, true)
	_cube(centre + 17.5, _platform_lateral(RoadPathGD.PLATFORM_HALF_WIDTH + 1.4), Vector3(0.76, 0.1, 0.76), timber.lightened(0.15), 0.0, 0.92, true)

	# Three tiny amber bollards make the terrace feel cared for after sunset and
	# give the foreground a warm depth layer against blue water.  Only the outer
	# two own real lights (the per-chunk cap); all three keep their emissive lens.
	for offset in [-19.0, 0.0, 19.0]:
		var lamp_z: float = centre + offset
		var lamp_out: float = edge - 0.65
		var lamp_lateral: float = _platform_lateral(lamp_out)
		_cube(lamp_z, lamp_lateral, Vector3(0.12, 0.62, 0.12), Color("343b3a"), 0.0, 0.0, true)
		_lamp(lamp_z, lamp_lateral, Vector3(0.22, 0.18, 0.22), LAMP_WARM, 0.56, true)
		if absf(offset) > 1.0:
			_glow_light(lamp_z, lamp_lateral, 0.68, LAMP_LIGHT, 7.5, 0.72)

	# Trees along the back of the platform, screening the carriageway the rider
	# came off so the place feels away from it.
	var reach: float = RoadPathGD.PLATFORM_HALF_LENGTH + 8.0
	for _i in 9:
		var z := centre + _rng.randf_range(-reach, reach)
		_tree(
			Flora.CONIFER,
			z,
			_platform_lateral(-RoadPathGD.PLATFORM_HALF_WIDTH - _rng.randf_range(3.0, 14.0)),
			_rng.randf_range(6.0, 12.0),
			(_pal["prop_a"] as Color).darkened(_rng.randf() * 0.25),
			true
		)

	# Boulders and scrub between the kerb and the lip. Without them the terrace
	# is a clean grey band running the length of the frame, and a clean band is
	# what makes a built place read as a car park rather than as a headland
	# somebody put a bench on.
	for _i in 11:
		var z := centre + _rng.randf_range(-reach, reach)
		var out: float = (
			RoadPathGD.PLATFORM_HALF_WIDTH + _rng.randf_range(1.4, 5.6)
			if _rng.randf() < 0.62
			else -RoadPathGD.PLATFORM_HALF_WIDTH - _rng.randf_range(1.0, 4.0)
		)
		# Keep the foreground beside each bench clean. A perfectly reasonable
		# two-metre boulder becomes half the frame when it is one metre from the
		# seated camera, turning the reward view into a close-up of a rock.
		var near_seat := false
		for offset in RoadPathGD.PLATFORM_BENCH_Z:
			near_seat = near_seat or absf(z - (centre + float(offset))) < 10.0
		if out > 0.0 and near_seat:
			continue
		var s := _rng.randf_range(0.7, 2.1)
		if _rng.randf() < 0.45:
			_prism(
				z,
				_platform_lateral(out),
				Vector3(s * 1.5, s * 0.9, s * 1.4),
				_face_color().darkened(_rng.randf() * 0.2),
				0.0,
				true
			)
		else:
			_blob(
				z,
				_platform_lateral(out),
				Vector3(s * 1.7, s * 0.6, s * 1.5),
				(_pal["verge"] as Color).darkened(_rng.randf() * 0.28),
				0.0,
				true,
				true
			)


func _build_platform_kerbs(stone: Color) -> void:
	## The two lines that make the platform read as a built place: a kerb along
	## the front of the parking, and one along the lip of the terrace.
	##
	## Both are ribbon geometry for the same reason the barrier is. They sit
	## seventy metres off the route, where the platform's own length and the
	## route's disagree by half a metre every two metres, and a run of boxes
	## stepped along z came out as a dashed line of blocks.
	var b := LowPoly.new()
	var top: Color = stone.lightened(0.3)
	var lip: Color = stone.darkened(0.06)
	var step := 1.5
	var half: float = RoadPathGD.PLATFORM_HALF_LENGTH
	var z := _vp_centre - half
	while z < _vp_centre + half:
		var next: float = minf(z + step, _vp_centre + half)
		_kerb_run(b, z, next, RoadPathGD.PLATFORM_HALF_WIDTH + 0.35, 0.5, 0.14, top)
		_kerb_run(b, z, next, RoadPathGD.PLATFORM_HALF_WIDTH + 6.2, 0.54, 0.16, lip)
		z = next
	var mesh: MeshInstance3D = b.commit_to(self, "PlatformKerbs")
	if mesh:
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _kerb_run(b: LowPoly, za: float, zb: float, out: float, width: float, height: float, color: Color) -> void:
	## One length of kerb between two points on its own line: a top face and the
	## face that shows toward the parking.
	var la: float = _platform_lateral(out - width * 0.5)
	var lb: float = _platform_lateral(out + width * 0.5)
	var inner: float = minf(la, lb)
	var outer: float = maxf(la, lb)
	b.add_quad(
		_p(za, inner, -height), _p(za, outer, -height), _p(zb, outer, -height), _p(zb, inner, -height), color
	)
	var near: float = inner if _vp_side > 0.0 else outer
	b.add_quad(
		_p(za, near, 0.0), _p(zb, near, 0.0), _p(zb, near, -height), _p(za, near, -height), color.darkened(0.12)
	)


func _viewpoint_bench(z: float, side: float, out: float) -> void:
	## Slatted timber bench square on to the water, on legs, with a back. The
	## facing matters: a bench parallel to the road at a viewpoint is a joke.
	var timber := Color("795b3f")
	var frame: Color = (_pal["rail"] as Color).darkened(0.45)
	var lateral := _platform_lateral(out)
	for leg in [-0.72, 0.72]:
		_cube(z + leg, lateral - side * 0.5, Vector3(0.12, 0.44, 0.12), frame, 0.0, 0.0, true)
		_cube(z + leg, lateral + side * 0.5, Vector3(0.12, 0.44, 0.12), frame, 0.0, 0.0, true)
	for slat in [-0.42, -0.14, 0.14, 0.42]:
		_cube(z, lateral + side * slat, Vector3(0.26, 0.07, 1.9), timber.darkened(_rng.randf() * 0.12), 0.0, 0.44, true)
	# Backrest on the road side, so you sit looking out over the water.
	for post_z in [z - 0.72, z + 0.72]:
		_cube(post_z, lateral - side * 0.46, Vector3(0.1, 0.52, 0.1), frame, 0.0, 0.44, true)
	for rail in [0.62, 0.86]:
		_cube(z, lateral - side * 0.46, Vector3(0.09, 0.16, 1.9), timber, 0.0, 0.3 + rail, true)


func _viewpoint_board(z: float, side: float, out: float, timber: Color) -> void:
	## Angled interpretation panel on two legs — the thing every real overlook
	## has, naming what you are looking at.
	var lateral := _platform_lateral(out)
	for leg in [-0.85, 0.85]:
		_cube(z + leg, lateral, Vector3(0.12, 1.06, 0.12), timber.darkened(0.25), 0.0, 0.0, true)
	_cube(z, lateral, Vector3(0.18, 0.1, 2.1), timber.darkened(0.1), 0.0, 1.06, true)
	# The panel leans back toward the reader; flat on its legs it would show only
	# its edge from the saddle.
	var flat: Basis = _path.frame_flat_at(z)
	var base: Vector3 = _terrain_surface_at(z, lateral) - _origin + Vector3(0, 1.16, 0)
	var lean := Basis(flat.z, side * deg_to_rad(36.0))
	_cubes.append(Transform3D(lean * Basis(flat.x * 0.78, flat.y * 0.07, flat.z * 2.0), base))
	_cube_cols.append(Color("d9d6c8"))
	_cubes.append(Transform3D(lean * Basis(flat.x * 0.5, flat.y * 0.075, flat.z * 1.2), base))
	_cube_cols.append(Color("3f6a72"))


func _viewpoint_telescope(z: float, side: float, out: float) -> void:
	## Coin viewer on a post, aimed across the water. Small, but it is the prop
	## that tells the rider this place is meant to be looked *from*.
	var body: Color = (_pal["rail"] as Color).darkened(0.15)
	var lateral := _platform_lateral(out)
	_cube(z, lateral, Vector3(0.16, 1.3, 0.16), body.darkened(0.35), 0.0, 0.0, true)
	_cube(z, lateral, Vector3(0.42, 0.16, 0.42), body.darkened(0.2), 0.0, 1.3, true)
	# Barrel across the road axis, tipped down toward the water.
	var flat: Basis = _path.frame_flat_at(z)
	var base: Vector3 = _terrain_surface_at(z, lateral) - _origin + Vector3(0, 1.52, 0)
	var barrel := Basis(flat.z, side * deg_to_rad(-18.0)) * Basis(flat.x * 1.1, flat.y * 0.21, flat.z * 0.21)
	_cubes.append(Transform3D(barrel, base + flat.x * side * 0.25))
	_cube_cols.append(Color("2f3339"))


func _build_viewpoint_sign(z: float, side: float, advance: bool) -> void:
	## A brown tourist board over a blue parking board — the pair a rider
	## recognises at 180 km/h. The advance sign stands 150 m before the junction
	## with a distance plate; the second marks the junction itself.
	var lateral := side * (HALF_WIDTH + 2.6)
	var blue := Color("1769aa")
	var brown := Color("6b4630")
	var white := Color("f5f7f2")
	_cube(z, lateral, Vector3(0.18, 4.2, 0.18), Color("626a70"), 0.0, 0.0, true)
	_cube(z, lateral, Vector3(2.5, 1.15, 0.16), brown, 0.0, 3.2, true)
	_cube(z, lateral, Vector3(2.2, 1.5, 0.18), blue, 0.0, 1.7, true)
	_sign_label(z, lateral, "150 m" if advance else "P", 2.45, 0.0075 if advance else 0.0095, white)
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
	z_a: float, z_b: float, lateral: float, width: float, height: float, color: Color, lift: float
) -> void:
	## Join exact ground endpoints so rails remain continuous through grades,
	## curves and streamed chunk boundaries.
	##
	## Posts already go through `_cube()`'s road-footprint check. Rails used to
	## bypass it, so a country fence lost its posts at an overlook but left two
	## floating beams running straight through the spur road. Check the complete
	## segment before emitting either rail.
	var middle := (z_a + z_b) * 0.5
	if not _footprint_is_clear(middle, lateral, width * 0.5, absf(z_b - z_a) * 0.5):
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
			return {
				"road": ROAD_TARMAC,
				"stripe": Color("fff4cc"),
				"shoulder": Color("8f846d"),
				"curb": Color("a2957f"),
				"verge": Color("aa9b68"),
				"ground": Color("bca56f"),
				"ground_alt": Color("987d58"),
				"rail": Color("d8cfc0"),
				"prop_a": Color("39715b"),
				"prop_b": Color("948b7c"),
				"prop_c": Color("7d766c"),
				"accent": Color("277b89"),
				"glow": Color(2.6, 2.2, 1.4),
			}
		Env.MOUNTAIN:
			return {
				"road": ROAD_TARMAC,
				"stripe": Color("e6ddb8"),
				"shoulder": Color("64666a"),
				"curb": Color("6e6a64"),
				"verge": Color("68704a"),
				"ground": Color("555f48"),
				"ground_alt": Color("394b45"),
				"rail": Color("9aa0a4"),
				"prop_a": Color("2b5140"),
				"prop_b": Color("654436"),
				"prop_c": Color("656a72"),
				"accent": Color("d45a36"),
				"glow": Color(2.4, 1.8, 1.2),
			}
		Env.COUNTRY:
			return {
				"road": ROAD_TARMAC,
				"stripe": Color("efe6bc"),
				"shoulder": Color("817764"),
				"curb": Color("857a66"),
				"verge": Color("8b873d"),
				"ground": Color("9c8842"),
				"ground_alt": Color("6f7139"),
				"rail": Color("b9ac8e"),
				"prop_a": Color("425e32"),
				"prop_b": Color("a74e32"),
				"prop_c": Color("c7a85f"),
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
