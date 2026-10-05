extends Node3D
## One 40 m section of world: road ribbon + themed scenery.
##
## Everything static in a chunk collapses into five nodes: one MeshInstance3D for
## the ribbon (tarmac + markings) and three MultiMeshInstance3Ds for props. The
## old version allocated a BoxMesh *and* a StandardMaterial3D per box, so nothing
## batched and a chunk cost hundreds of draw calls.

const LowPoly := preload("res://scripts/low_poly.gd")
const RoadPathGD := preload("res://scripts/road_path.gd")
const RangeMaterial := preload("res://scripts/range_material.gd")
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


## Authored lookout kit. Every piece is optional: with a file missing, the
## procedural terrace stands in for it, so a half-finished kit never leaves an
## overlook without a floor. Kit convention: origin on the walking surface, +X
## toward the view, +Z along the route.
const LOOKOUT_DECK := "res://scenes/lookout_deck.tscn"
const LOOKOUT_RAIL := "res://scenes/lookout_rail.tscn"
const LOOKOUT_BALCONY := "res://scenes/lookout_balcony.tscn"
const LOOKOUT_PIER := "res://scenes/lookout_pier.tscn"
const LOOKOUT_STOP := "res://scenes/lookout_stop.tscn"
const LOOKOUT_BAYS := "res://scenes/lookout_bays.tscn"
const LOOKOUT_TREE := "res://scenes/lookout_tree.tscn"
const LOOKOUT_PINE := "res://scenes/lookout_pine.tscn"
## The deck stands one kerb above the parking tarmac.
const TERRACE_FLOOR := 0.12
## Deck depth from the platform edge, and the rail line on its outer lip.
const TERRACE_DEPTH := 6.6
const TERRACE_RAIL_OUT := 6.45
const TERRACE_PITCH := 4.0
## The kit's bay paint is authored on the carriageway plane, but the spur's own
## surfacing lies 60 mm proud of it (`_build_spur_ribbon`). Set at zero the paint
## sat under the tarmac and vanished; this lands it 2 mm over the surface, just
## under the 72 mm the procedural bay lines used.
const BAYS_LIFT := 0.062
## Kit trees are authored ten metres tall.
const LOOKOUT_TREE_HEIGHT := 10.0

static var _lookout_scenes: Dictionary = {}


static func _lookout_scene(path: String) -> PackedScene:
	## Loaded once per run; null while the kit has not shipped that piece.
	if not _lookout_scenes.has(path):
		_lookout_scenes[path] = (load(path) as PackedScene) if ResourceLoader.exists(path) else null
	return _lookout_scenes[path]


static func _rock_scene(prefer_a: bool) -> PackedScene:
	_ensure_rocks()
	if prefer_a:
		return _rock_a if _rock_a else _rock_b
	return _rock_b if _rock_b else _rock_a


enum Env { CITY, FOREST, COAST, MOUNTAIN, COUNTRY }

const LENGTH := 40.0
const STEPS := 10  # 4 m cross-sections stay smooth on broad grades with fewer CPU-side samples
const RIBBON_STEPS_PER_FRAME := 1
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
## Bushes packed onto the first few metres of verge. Indexed by Env. Split across
## frames while streaming — planting all of them at once was a 35–90 ms hitch.
const VERGE_BUSH_COUNT := [8, 34, 18, 26, 32]
const VERGE_BUSH_BATCH := 4
## Hard cap on GLB instances per chunk. The Kenney kit is suburban, so it stocks
## the countryside and villages; the city builds its own frontage.
const MAX_IMPORTED_ASSETS_PER_CHUNK := 4
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
	[8.7, 0.18, "curb"],  # curb outer face
	[11.8, 0.82, "verge"],
	[15.5, 0.95, "ground"],
	[22.0, 0.5, "ground"],
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
## PINE is the timberline tree: a high, wind-shaped crown on a clean stem. It
## replaced a leafless snag, which from the saddle read as a burnt forest.
enum Flora { BROADLEAF, CONIFER, BIRCH, PALM, PINE, CYPRESS }

## Bark colours. Wood is never the same green-brown twice, and a birch stand is
## recognisable at 200 m purely from the pale trunks.
## Pale bark is deliberately grey rather than white: at 150 m a true birch white
## stops reading as a tree and starts reading as scaffolding stuck in the field.
const BARK := Color("3f3026")
const BARK_PALE := Color("a8a79a")
const BARK_PALM := Color("7d6a4e")

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
static var _water_material_sea: ShaderMaterial
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


static var _water_sky: Color = Color(0.10, 0.11, 0.12)
static var _water_sky_high: Color = Color(0.08, 0.10, 0.14)


static func set_water_sky(c: Color, high: Color = Color(0.08, 0.10, 0.14)) -> void:
	## main.gd pushes the mood's horizon colour (and the sky above it) in here;
	## the water materials are built lazily and shared across every chunk, so the
	## values are cached on the script and applied to whichever sheets exist.
	_water_sky = c
	_water_sky_high = high
	# The tarmac reflects the same sky at a grazing angle.
	LowPoly.road_material().set_shader_parameter("sky_sheen", c)
	for mat in [_water_material, _water_material_sea]:
		if mat:
			_apply_water_sky(mat)


static func _apply_water_sky(mat: ShaderMaterial) -> void:
	mat.set_shader_parameter("sky_mirror", _water_sky)
	mat.set_shader_parameter("sky_high", _water_sky_high)


static func water_material() -> ShaderMaterial:
	## Lake chop is quieter than the shader defaults. At overlook distance the
	## 18 cm default waves read as corduroy stripes across the basin.
	if _water_material == null:
		_water_material = ShaderMaterial.new()
		_water_material.shader = WATER_SHADER
		_water_material.set_shader_parameter("wave_height", 0.055)
		_water_material.set_shader_parameter("wave_speed", 0.42)
		_water_material.set_shader_parameter("wave_scale", 0.55)
		_water_material.set_shader_parameter("shimmer_amount", 0.55)
		_apply_water_sky(_water_material)
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
		# Open sea under a daylight sky is a deep blue, not a mirror of the haze:
		# at the lake's floor the whole coast view went a pale milky grey.
		_water_material_sea.set_shader_parameter("mirror_floor", 0.16)
		_apply_water_sky(_water_material_sea)
	return _water_material_sea


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
	rotor_mesh()
	beacon_material()
	water_material()
	water_material_sea()
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
var _ledges: Array[Transform3D] = []
var _ledge_cols: Array[Color] = []
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
var _normal_samples: Dictionary = {}
## Overlook this chunk overlaps, resolved once in _configure(). Every chunk in
## the world would otherwise pay the deck and basin queries per ribbon vertex.
var _vp_centre: float = 0.0
var _vp_side: float = 0.0
var _vp_water_y: float = 0.0
## Deterministic per-overlook phase for the landscape's shaping sines. Derived
## from the centre and the world seed rather than from `_rng`, because every
## chunk across the basin has to agree on the same shoreline and skyline — an
## RNG draw would give each of the twenty chunks a different one.
var _vista_basis: Basis = Basis.IDENTITY
var _vista_origin: Vector3 = Vector3.ZERO
var _vp_phase: float = 0.0
## Height of the authored deck over the tarmac, or zero while the procedural
## flags are in use. Set by `_build_belvedere` before any furniture goes down.
var _terrace_floor: float = 0.0
var _on_spur: bool = false
var _on_lake: bool = false
var _owns_platform: bool = false
var _vp_theme: int = Env.COUNTRY
## -1 unknown, else bit0=highway visible, bit1=scenic visible.
var _corridor_flags: int = -1


func setup(index: int, theme_id: int, include_scenic: bool = true, include_highway: bool = true) -> void:
	_configure(index, theme_id)
	_build_ribbon()
	if include_highway:
		_build_highway_props()
	if include_scenic and _on_spur:
		_build_scenic_props()
	elif _on_spur and include_highway:
		_build_scenic_stub()


func setup_ribbon(index: int, theme_id: int) -> void:
	## Sync tarmac only. Used when the bike is about to enter a missing chunk —
	## sliced builds still leave a hole for a couple of frames at top speed.
	_configure(index, theme_id)
	_build_ribbon()
	_dress_shoulder_immediate()


func setup_ribbon_fast(index: int, theme_id: int) -> void:
	## Emergency surface under the wheels. Terrain and planting stream later;
	## constructing a refined cliff here used to block a whole frame for 150 ms.
	_configure(index, theme_id)
	var road := LowPoly.new()
	var hard := LowPoly.new()
	var z0: float = float(index) * LENGTH
	var step: float = LENGTH / float(STEPS)
	for i in STEPS:
		var za: float = z0 + float(i) * step
		var zb: float = za + step
		road.add_quad_uv(_p(za, -HALF_WIDTH, 0.0), _p(za, HALF_WIDTH, 0.0),
			_p(zb, HALF_WIDTH, 0.0), _p(zb, -HALF_WIDTH, 0.0), _pal["road"],
			Vector2(-HALF_WIDTH, za), Vector2(HALF_WIDTH, za), Vector2(HALF_WIDTH, zb), Vector2(-HALF_WIDTH, zb))
	_build_markings(hard, z0)
	_commit_hard_ribbon(hard)
	_commit_road_ribbon(road)
	_commit_spur_meshes(z0)
	set_meta("ribbon_ready", false)


func setup_incremental(index: int, theme_id: int) -> void:
	await setup_ribbon_incremental(index, theme_id)
	if not is_instance_valid(self) or not is_inside_tree():
		return
	await setup_props_incremental()


func setup_ribbon_incremental(index: int, theme_id: int) -> void:
	## Runtime streaming must not consume an entire render frame. The chunk is far
	## beyond the camera when queued, so build its ribbon in small invisible slices.
	_configure(index, theme_id)
	var builders := _new_ribbon_builders()
	var hard: LowPoly = builders[0]
	var road: LowPoly = builders[1]
	var soft_left: LowPoly = builders[2]
	var soft_right: LowPoly = builders[3]
	var z0: float = float(chunk_index) * LENGTH
	# Spur ribbons are denser (deck/terrace mixes). One cross-section per frame
	# keeps the climb inside a frame; two at a time was still a hitch, four was ~40 ms.
	var steps_per: int = RIBBON_STEPS_PER_FRAME
	var band_count: int = _view_bands().size()
	const BANDS_PER_FRAME := 8
	var slice_started: int = Time.get_ticks_usec()
	for first_step in range(0, STEPS, steps_per):
		for first_band in range(0, band_count, BANDS_PER_FRAME):
			_build_ribbon_rows(hard, road, soft_left, soft_right, z0, first_step, mini(first_step + steps_per, STEPS), first_band, mini(first_band + BANDS_PER_FRAME, band_count))
			if Time.get_ticks_usec() - slice_started >= 6000:
				if not await _keep_streaming():
					return
				slice_started = Time.get_ticks_usec()
	if not await _keep_streaming():
		return
	await _finish_ribbon_incremental(hard, road, soft_left, soft_right, z0)
	if not await _keep_streaming():
		return
	await _dress_shoulder_incremental()


func setup_props_incremental() -> void:
	await _build_props_incremental()


func _dress_shoulder_immediate() -> void:
	## Grass, hedge and reflectors land with the ribbon so the curb never sits as
	## a blank brown slab while trees are still queued. Full theme scenery still
	## streams. Spur and lake chunks still dress the main carriageway — the slip
	## road and the water are kept clear by `_footprint_is_clear`.
	if bool(get_meta("shoulder_done", false)):
		return
	var from_index := get_child_count()
	_build_reflectors()
	_grass_verge()
	_hedge_verge()
	_publish_shoulder(from_index)


func _dress_shoulder_incremental() -> void:
	if bool(get_meta("shoulder_done", false)):
		return
	var from_index := get_child_count()
	_build_reflectors()
	if not await _keep_streaming():
		return
	_grass_verge()
	if not await _keep_streaming():
		return
	_hedge_verge()
	if not await _keep_streaming():
		return
	_publish_shoulder(from_index)


func _publish_shoulder(from_index: int) -> void:
	_commit_mm(_cubes, _cube_cols, unit_cube(), LowPoly.solid_material(), "Cubes", true)
	_cubes.clear()
	_cube_cols.clear()
	_commit_mm(_lamps, _lamp_cols, unit_cube(), LowPoly.glow_material(), "Lamps", false)
	_lamps.clear()
	_lamp_cols.clear()
	_commit_mm(_grass, _grass_cols, grass_tuft(), LowPoly.foliage_material(), "Grass", false)
	_grass.clear()
	_grass_cols.clear()
	_commit_mm(_leaves, _leaf_cols, unit_sphere(), LowPoly.foliage_material(), "Foliage", false)
	_leaves.clear()
	_leaf_cols.clear()
	set_meta("shoulder_done", true)
	set_meta("reflectors_done", true)
	set_meta("grass_done", true)
	set_meta("hedge_done", true)
	_tag_new_children(from_index, "highway")


func _build_props_incremental() -> void:
	## Highway dress first so the main road keeps its trees even while a scenic
	## spur peels off. Scenic meshes publish in a second pass and can be hidden
	## independently once the rider commits to one corridor.
	if bool(get_meta("highway_requested", true)) and not bool(get_meta("highway_done", false)):
		await _build_highway_props_incremental()
		if not is_instance_valid(self) or not is_inside_tree():
			return
	if not _on_spur:
		return
	if bool(get_meta("scenic_requested", false)):
		await _build_scenic_props_incremental()
		if is_instance_valid(self):
			set_meta("scenic_done", true)
		return
	await _build_scenic_stub_incremental()


func _build_highway_props_incremental() -> void:
	if bool(get_meta("highway_done", false)):
		return
	var highway_from := get_child_count()
	await _build_furniture_incremental()
	if not await _keep_streaming():
		return
	_build_approach_signs()
	if _on_spur:
		# Junction boards live on the highway verge so they stay readable when the
		# climb itself is culled.
		_build_junction()
		if not await _keep_streaming():
			return
		_build_highway_spur_screen()
		if not await _keep_streaming():
			return
	if _on_lake:
		await _plant_inland_carriageway_incremental()
	else:
		await _build_ordinary_theme_scenery_incremental()
	if not await _keep_streaming():
		return
	if not _on_lake:
		await _build_distant_scenery_incremental()
		if not await _keep_streaming():
			return
	if not _on_spur:
		_build_set_piece()
		if not await _keep_streaming():
			return
	await _commit_props_incremental()
	_tag_new_children(highway_from, "highway")
	set_meta("highway_done", true)


func _build_scenic_props_incremental() -> void:
	if not _on_spur or bool(get_meta("scenic_done", false)):
		return
	var scenic_marks := _prop_marks()
	var scenic_from := get_child_count()
	# Three woodland stations — denser tunnel so the climb does not read as
	# sparse pop-in once the dress window is ahead of the camera.
	var first := 2 if bool(get_meta("stub_done", false)) else 0
	var count := 1 if bool(get_meta("stub_done", false)) else 3
	# Water sheet first so the basin exists as soon as the rider commits; woodland
	# and the far skirt can trail by a few frames without a hole in the view.
	if _on_lake and _owns_platform:
		await _build_lake_water_incremental()
		if not await _keep_streaming():
			return
	# Then the platform, before any of the basin. It is the place the rider
	# stops at, and it used to come last: ~500 frames behind the range, far
	# ground and shore, so a fast arrival parked on a bare terrace while the
	# benches were still queued. Its batched extras (bench plinths, the bin,
	# planting and the backstop trees) still publish with the pass's one commit
	# below, so this adds no MultiMesh and no draw call.
	if _owns_platform:
		if not await _set_piece_platform_incremental():
			return
	_build_spur_woodland(first, count)
	if not await _keep_streaming():
		return
	if _on_lake and _owns_platform:
		# The platform chunk owns the complete basin; nearby chunks only carry the spur. Dressing can stay near
		# the bench; cutting the range off at 240 m left a blue water strip
		# hanging over the clear colour on both sides of every seated view.
		await _build_far_ground_incremental()
		if not await _keep_streaming():
			return
		await _build_view_range_incremental()
		if _vista_chunk():
			await _build_far_shore_incremental()
			if not await _keep_streaming():
				return
			await _build_far_cliffs_incremental()
			if not await _keep_streaming():
				return
			await _build_coast_headland_incremental()
			if not await _keep_streaming():
				return
			if not await _build_lake_edges_incremental():
				return
			_build_view_frame()
			if not await _keep_streaming():
				return
			_dress_vista()
			if not await _keep_streaming():
				return
			_build_vista_landmarks()
			if not await _keep_streaming():
				return
	_build_spur_furniture()
	if not await _keep_streaming():
		return
	await _commit_props_incremental(scenic_marks)
	_tag_new_children(scenic_from, "scenic")
	set_meta("scenic_done", true)


func _vista_chunk() -> bool:
	## Incremental callers gate shared basin work to the owner; setup/tests still need
	## to build a single requested chunk's authored vista props.
	return _on_lake


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
	_resolve_viewpoint()
	_vista_basis = _path.frame_flat_at(_vp_centre)
	_vista_origin = _path.center_at(_vp_centre)


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
	_build_highway_props()
	if _on_spur:
		_build_scenic_props()


func _build_highway_props() -> void:
	var highway_from := get_child_count()
	_build_furniture()
	if _on_lake:
		_plant_inland_carriageway()
	else:
		_build_ordinary_theme_scenery()
	if not _on_lake:
		_build_distant_scenery()
	_build_approach_signs()
	if _on_spur:
		_build_junction()
		_build_highway_spur_screen()
	else:
		_build_set_piece()
	_commit_props()
	_tag_new_children(highway_from, "highway")
	set_meta("highway_done", true)


func _build_scenic_props() -> void:
	if not _on_spur or bool(get_meta("scenic_done", false)):
		return
	var scenic_marks := _prop_marks()
	var scenic_from := get_child_count()
	# Same order as the streamed pass: the platform first.
	if _owns_platform:
		_set_piece_platform()
	if bool(get_meta("stub_done", false)):
		_build_spur_woodland(2, 3)
	else:
		_build_spur_woodland()
	_build_viewpoint_landscape()
	_build_spur_furniture()
	_commit_props(scenic_marks)
	_tag_new_children(scenic_from, "scenic")
	set_meta("scenic_done", true)


func ensure_scenic_dress() -> void:
	## Late scenic pass for a chunk that was streamed as highway-only.
	if not _on_spur or bool(get_meta("scenic_done", false)):
		return
	if bool(get_meta("scenic_building", false)):
		return
	set_meta("scenic_requested", true)
	set_meta("scenic_building", true)
	await _build_scenic_props_incremental()
	if is_instance_valid(self):
		set_meta("scenic_done", true)
		set_meta("scenic_building", false)
		set_meta("scenic_queued", false)


func _wants_junction_stub() -> bool:
	## Woodland at the gore so the exit is not a hole while the unused climb
	## and lake stay unbuilt.
	if not _on_spur or _path == null:
		return false
	var z := float(chunk_index) * LENGTH + LENGTH * 0.5
	var divergence: float = float(_path.spur_divergence(z))
	return divergence >= 0.08 and divergence < RoadPathGD.CORRIDOR_COMMIT


func _build_scenic_stub() -> void:
	if not _on_spur or bool(get_meta("scenic_done", false)) or bool(get_meta("stub_done", false)):
		return
	if not _wants_junction_stub():
		return
	var marks := _prop_marks()
	var from_index := get_child_count()
	_build_spur_woodland(0, 2)
	_commit_props(marks)
	_tag_new_children(from_index, "scenic")
	set_meta("stub_done", true)


func _build_scenic_stub_incremental() -> void:
	if not _on_spur or bool(get_meta("scenic_done", false)) or bool(get_meta("stub_done", false)):
		return
	if not _wants_junction_stub():
		return
	var marks := _prop_marks()
	var from_index := get_child_count()
	_build_spur_woodland(0, 2)
	if not await _keep_streaming():
		return
	await _commit_props_incremental(marks)
	_tag_new_children(from_index, "scenic")
	set_meta("stub_done", true)


func ensure_highway_dress() -> void:
	## Late highway pass for a chunk that was streamed as scenic-only.
	if bool(get_meta("highway_done", false)):
		return
	if bool(get_meta("highway_building", false)):
		return
	set_meta("highway_requested", true)
	set_meta("highway_building", true)
	await _build_highway_props_incremental()
	if is_instance_valid(self):
		set_meta("highway_done", true)
		set_meta("highway_building", false)
		set_meta("highway_queued", false)


func _build_theme_scenery() -> void:
	# Profiler entry: plant both corridors. Runtime `_build_props` publishes them
	# as separate passes so the unused path can be hidden.
	if _on_spur:
		_build_spur_woodland()
	if _on_lake:
		_plant_inland_carriageway()
	else:
		_build_ordinary_theme_scenery()


func _build_ordinary_theme_scenery() -> void:
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


func _build_ordinary_theme_scenery_incremental() -> void:
	## Theme dress stays visually identical; forest and mountain yield between
	## stands so fifty trees are not one hitch.
	match theme:
		Env.CITY:
			_scenery_city()
		Env.FOREST:
			await _scenery_forest_incremental()
		Env.COAST:
			_scenery_coast()
		Env.MOUNTAIN:
			await _scenery_mountain_incremental()
		Env.COUNTRY:
			_scenery_country()
	if theme != Env.FOREST and theme != Env.MOUNTAIN and not await _keep_streaming():
		return


func _plant_inland_carriageway() -> void:
	## Lake chunks skip the full biome so the bench stays a picture. The inland
	## verge of the main road still wants a stand of trees so it does not go bare
	## for the length of the basin if the rider stays on the highway.
	var z0: float = float(chunk_index) * LENGTH
	var inland: float = -_vp_side if _vp_side != 0.0 else -1.0
	var tint: Color = (_pal["prop_a"] as Color).darkened(_rng.randf() * 0.2)
	for _i in 22:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var lx: float = inland * (HALF_WIDTH + 3.5 + _rng.randf_range(0.0, 22.0))
		var species: int = (
			Flora.CONIFER if theme == Env.FOREST or theme == Env.MOUNTAIN else Flora.BROADLEAF
		)
		var height := _rng.randf_range(5.5, 11.5)
		if theme == Env.COAST:
			var s := _rng.randf_range(1.6, 3.2)
			_blob(
				z,
				lx,
				Vector3(s * 1.8, s * 0.8, s * 1.5),
				tint.lerp(_pal["ground_alt"], _rng.randf() * 0.4),
				0.0,
				true
			)
			continue
		_tree(species, z, lx, height, tint)


func _plant_inland_carriageway_incremental() -> void:
	## Same stand as `_plant_inland_carriageway`, eight trees then a frame so a
	## lake-highway chunk does not plant twenty-two trunks in one hitch.
	var z0: float = float(chunk_index) * LENGTH
	var inland: float = -_vp_side if _vp_side != 0.0 else -1.0
	var tint: Color = (_pal["prop_a"] as Color).darkened(_rng.randf() * 0.2)
	for i in 22:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var lx: float = inland * (HALF_WIDTH + 3.5 + _rng.randf_range(0.0, 22.0))
		var species: int = (
			Flora.CONIFER if theme == Env.FOREST or theme == Env.MOUNTAIN else Flora.BROADLEAF
		)
		var height := _rng.randf_range(5.5, 11.5)
		if theme == Env.COAST:
			var s := _rng.randf_range(1.6, 3.2)
			_blob(
				z,
				lx,
				Vector3(s * 1.8, s * 0.8, s * 1.5),
				tint.lerp(_pal["ground_alt"], _rng.randf() * 0.4),
				0.0,
				true
			)
		else:
			_tree(species, z, lx, height, tint)
		if i % 8 == 7 and not await _keep_streaming():
			return


func _build_spur_woodland(first_station: int = 0, station_count: int = 5) -> void:
	## Planting along the climb. The spur geometry is the same everywhere; what
	## grows beside it follows the biome of this stretch, so a coastal headland
	## is not ridden through a pine tunnel.
	var z0: float = float(chunk_index) * LENGTH
	for station in range(first_station, mini(first_station + station_count, 5)):
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
			# Near row only on most stations. Outer row is rare — Multimesh cost.
			for row in 2:
				if row == 1 and (station % 2 == 1 or _rng.randf() > 0.22):
					continue
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
						# No palms/cypress on the climb — thin needles read as sticks at
						# roadside speed. Big Sur is scrub, rock and marram.
						var s := _rng.randf_range(1.6, 3.6)
						_blob(
							jitter_z,
							lateral,
							Vector3(s * 1.9, s * 0.75, s * 1.6),
							Color("9a8868").lerp(Color("6a8070"), _rng.randf()),
							0.0,
							false,
							true
						)
						if row == 0 and _rng.randf() < 0.55:
							var bush := _rng.randf_range(1.2, 2.4)
							_blob(
								jitter_z + _rng.randf_range(-1.2, 1.2),
								lateral + road_side * _rng.randf_range(0.6, 2.2),
								Vector3(bush * 2.0, bush * 0.85, bush * 1.7),
								Color("3a5c44").lerp(Color("6a7a58"), _rng.randf()),
								0.0,
								true,
								true
							)
					Env.MOUNTAIN:
						var height: float = _rng.randf_range(8.0, 14.0) * lerpf(0.70, 1.0, reveal)
						var species: int = Flora.CONIFER if _rng.randf() < 0.78 + towards_summit * 0.15 else Flora.PINE
						_tree(species, jitter_z, lateral, height, Color("243830").lerp(Color("4a5640"), _rng.randf() * 0.35), true)
						if _rng.randf() < 0.4:
							var rock_s := _rng.randf_range(1.2, 2.8)
							_blob(
								jitter_z,
								lateral + road_side * _rng.randf_range(1.0, 3.0),
								Vector3(rock_s * 1.6, rock_s * 0.9, rock_s * 1.4),
								Color("7a7468").darkened(_rng.randf() * 0.2),
								0.0,
								false,
								true
							)
					_:
						var height: float = _rng.randf_range(11.0, 17.5) * lerpf(0.70, 1.0, reveal)
						if _vp_theme == Env.FOREST:
							height *= 1.08
						var tint: Color = Color("2a4634").lerp(Color("4a6840"), _rng.randf() * 0.42)
						var conifer_odds := 0.22 + towards_summit * 0.55
						if _vp_theme == Env.FOREST:
							conifer_odds = 0.42 + towards_summit * 0.35
						var species: int = Flora.CONIFER if _rng.randf() < conifer_odds else Flora.BROADLEAF
						_tree(species, jitter_z, lateral, height, tint.darkened(float(row) * 0.14), true)
			if _vp_theme == Env.COAST:
				continue
			if _rng.randf() > 0.72:
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
	if _on_lake and lateral * _vp_side > 0.0:
		var flatten: float = smoothstep(210.0, 400.0, absf(lateral))
		if flatten > 0.0:
			var vista: Vector3 = _far_point(z, lateral, point.y + _origin.y)
			point = point.lerp(vista, flatten)
	_point_samples[point_key] = point
	return point


func _ground_normal(z: float, lateral: float, drop: float) -> Vector3:
	## The terrain ribbons shade from normals sampled off the same surface they
	## draw, not from averaged face normals. A generated normal at a chunk's
	## first or last row only ever sees the quads inside that chunk, so every
	## LENGTH metres the shading steps — a faint corduroy that fills the whole
	## headland at the grazing angle the seat looks down it. A normal taken from
	## the surface itself is the same on both sides of the seam.
	var key := Vector3(z, lateral, drop)
	if _normal_samples.has(key):
		return _normal_samples[key]
	const EPS := 1.6
	var p0 := _p(z, lateral, drop)
	var n := (_p(z, lateral + EPS, drop) - p0).cross(_p(z + EPS, lateral, drop) - p0)
	var up: Vector3 = _path.frame_flat_at(z).y
	if n.length_squared() < 1e-10:
		n = up
	elif n.dot(up) < 0.0:
		n = -n
	n = n.normalized()
	_normal_samples[key] = n
	return n


# ---------------------------------------------------------------- road ribbon


func _ground_color(lateral: float, z: float) -> Color:
	## Smooth function of position, sampled per vertex — a per-quad colour would
	## stop index() merging vertices and smooth shading would never kick in.
	var mix: float = 0.5 + 0.5 * sin(lateral * 0.055 + z * 0.038) * sin(lateral * 0.017 - z * 0.021)
	# A second, slower grain so the midfield is patchwork instead of one wash —
	# the blank tan plane past the first trees in the rider's peripheral view.
	var patch: float = 0.5 + 0.5 * sin(lateral * 0.021 + z * 0.013) * sin(absf(lateral) * 0.033 - z * 0.009)
	mix = lerpf(mix, patch, 0.45)
	# Scenic embankments need a second, slower grain so cut banks read as rock
	# shelves instead of one blended wash from curb to horizon.
	if _on_spur:
		var bank: float = 0.5 + 0.5 * sin(lateral * 0.028 + z * 0.011) * sin(absf(lateral) * 0.09 - z * 0.007)
		mix = lerpf(mix, bank, 0.55)
	var color: Color = (_pal["ground"] as Color).lerp(_pal["ground_alt"], mix * 0.95)
	# A coast headland's top is machair and heath, not the open sand of the
	# beach palette — two hundred metres of pale `c9ae74` tapering to a point
	# reads as a dune slab, not a clifftop.
	if (
		_on_lake
		and _vp_theme == Env.COAST
		and lateral * _vp_side > 0.0
		and absf(lateral) < float(_path.headland_crest(z)) + 4.0
	):
		color = color.lerp(Color("6b754f"), 0.62)
	# Near the carriageway lean toward verge green so the soft shoulder meets
	# the hard curb without a painted seam.
	var near: float = 1.0 - smoothstep(HALF_WIDTH + 2.0, HALF_WIDTH + 18.0, absf(lateral))
	if near > 0.0:
		color = color.lerp(_pal["verge"] as Color, near * 0.35)
	if _on_spur:
		color = color.lerp(_embankment_color(lateral, z), _embankment_mix(lateral, z))
		color = color.lerp(_deck_color(z, lateral), _deck_mix(z, lateral))
		color = color.lerp(_terrace_color(), _terrace_mix(z, lateral))
	if _on_lake:
		color = color.lerp(_face_color(), _face_mix(z, lateral))
		color = color.lerp(_shore_color(), _shore_mix(z, lateral))
		color = color.lerp(_wash_color(), _wash_mix(z, lateral))
	return color


func _shoulder_color(lateral: float, z: float, band: String) -> Color:
	## Soft verge / near-ground colour. Gravel grain on the curb lip, grass further
	## out — so the strip between tarmac and guardrail is never a flat slab.
	if band == "ground":
		return _ground_color(lateral, z)
	var grain: float = 0.5 + 0.5 * sin(lateral * 0.14 + z * 0.07) * sin(lateral * 0.05 - z * 0.03)
	var gravel: Color = (_pal["shoulder"] as Color).darkened(0.08 + grain * 0.1)
	var grass: Color = (_pal["verge"] as Color).lerp(_pal["prop_a"] as Color, grain * 0.35)
	var out: float = absf(lateral) - HALF_WIDTH
	var t: float = smoothstep(0.2, 3.2, out)
	var color: Color = gravel.lerp(grass, t)
	if _on_spur:
		color = color.lerp(_deck_color(z, lateral), _deck_mix(z, lateral) * 0.85)
	return color


func _embankment_mix(lateral: float, z: float) -> float:
	## Rockier cut on the outer bank of a climbing spur, soft fill on the inside.
	## Without this the whole climb is one ground colour and the ribbon reads as a
	## painted strip rather than a road carved into a hillside.
	if not _on_spur:
		return 0.0
	var centre: float = _vp_side * float(_path.spur_offset(z))
	var half: float = float(_path.spur_half_width(z))
	var out: float = absf(lateral) - absf(centre) - half
	if out < 1.0 or out > 28.0:
		return 0.0
	# Strongest on the steep outer face, fading into ordinary ground.
	var band: float = smoothstep(1.2, 4.0, out) * (1.0 - smoothstep(16.0, 28.0, out))
	var grain: float = 0.45 + 0.55 * sin(z * 0.07 + out * 0.11) * sin(z * 0.023 - out * 0.05)
	return band * grain


func _embankment_color(lateral: float, z: float) -> Color:
	## Biome-specific cut-bank stone so coast sand, mountain scree and country
	## clay each read as a different hillside from the same spur geometry.
	var grain: float = 0.5 + 0.5 * sin(lateral * 0.09 + z * 0.04)
	match _vp_theme if _on_spur else theme:
		Env.COAST:
			return Color("b8a078").lerp(Color("8a9078"), grain * 0.45)
		Env.MOUNTAIN:
			return Color("6e6860").lerp(Color("4a5248"), grain * 0.5)
		Env.FOREST:
			return Color("5a5848").lerp(Color("3e4a38"), grain * 0.4)
		Env.COUNTRY:
			return Color("9a7e4c").lerp(Color("6a6840"), grain * 0.45)
	return (_pal["shoulder"] as Color).darkened(0.1 + grain * 0.08)


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
	var top := float(_path.headland_crest(z)) - 6.0
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
	# The rock paint belongs to the steep face, not to the level made ground the
	# terrace stands on — the lip shelf shares the face's lateral range, and
	# painted flat it reads as a pale concrete apron hanging off the parapet.
	return band * (0.3 + 0.7 * grain) * (1.0 - float(_path.spur_deck_blend(z, lateral)))


func _face_color() -> Color:
	## Stone, from the same family as the range across the water, so the headland
	## reads as belonging to the same country as its own skyline. Tinting the
	## theme's foliage colour toward grey instead just gives greyish grass.
	match theme:
		Env.MOUNTAIN:
			return Color("a8adb4")
		Env.COAST:
			# Grey-brown crag, the same family as the scarp rock — the old sand
			# tone over a hundred metres of benched drop read as a dune, not a
			# sea cliff.
			return Color("756e5c")
		Env.FOREST:
			return Color("857f6c")
	return Color("b0a585")


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
	if lateral * _vp_side <= 0.0 or absf(lateral) < float(_path.headland_crest(z)):
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


func _wash_mix(z: float, lateral: float) -> float:
	## A drier, brighter gravel wash sitting just above `_shore_mix`'s damp
	## shingle — the line of pale stones a lake leaves on the last metre of bank.
	## Runs a little wider than the damp band so the waterline reads as a shore,
	## not as a razor edge between grass and water.
	if _vp_theme == Env.COAST:
		return 0.0
	if lateral * _vp_side <= 0.0 or absf(lateral) < float(_path.headland_crest(z)):
		return 0.0
	var here: float = float(_path.height_at(z)) - float(_path.terrain_drop(lateral, z)) - _vp_water_y
	if here < 0.9 or here > 3.2:
		return 0.0
	var grain: float = 0.6 + 0.4 * sin(z * 0.09 + lateral * 0.05) * sin(z * 0.031 - lateral * 0.021)
	return smoothstep(0.9, 1.5, here) * (1.0 - smoothstep(2.4, 3.2, here)) * grain


func _wash_color() -> Color:
	## Sun-dried gravel — light enough to read as the tide line, still a stone
	## colour so it does not turn into a chalk outline around the lake.
	match _vp_theme:
		Env.MOUNTAIN:
			return Color("8f8878")
		Env.FOREST:
			return Color("8a8272")
	return Color("948a74")


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
	soft_left.explicit_normals = true
	soft_right.explicit_normals = true
	return [hard, road, soft_left, soft_right]


func _build_ribbon_rows(
	hard: LowPoly,
	road: LowPoly,
	soft_left: LowPoly,
	soft_right: LowPoly,
	z0: float,
	first_step: int,
	end_step: int,
	first_band: int = 0,
	end_band: int = -1
) -> void:
	var step := LENGTH / float(STEPS)
	var bands := _view_bands()

	for i in range(first_step, end_step):
		var za := z0 + float(i) * step
		var zb := za + step
		for band_index in range(first_band, bands.size() if end_band < 0 else end_band):
			var band: Array = bands[band_index]
			for segment: Vector4 in _terrain_segments(za, zb, band):
				var l0: float = segment.x
				var l1: float = segment.y
				var l2: float = segment.z
				var l3: float = segment.w
				var drop_a := _band_drop(za, l0, _band_interpolated_drop(band, l0))
				var drop_b := _band_drop(za, l1, _band_interpolated_drop(band, l1))
				var drop_c := _band_drop(zb, l3, _band_interpolated_drop(band, l3))
				var drop_d := _band_drop(zb, l2, _band_interpolated_drop(band, l2))
				var pa := _p(za, l0, drop_a)
				var pb := _p(za, l1, drop_b)
				var pc := _p(zb, l3, drop_c)
				var pd := _p(zb, l2, drop_d)
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
						Vector2(l3, zb),
						Vector2(l2, zb)
					)
				elif band[4] == "ground" or band[4] == "verge":
					# Verge used to be a flat hard quad in the palette colour — the blank
					# brown strip between the white line and the guardrail in every dusk
					# shot. Soft-shade it with the same ground grain so the shoulder
					# reads as grass/gravel even before Multimesh tufts stream in.
					var soft := soft_left if (l0 + l1) < 0.0 else soft_right
					soft.add_quad_shaded_n(
						pa,
						pb,
						pc,
						pd,
						_shoulder_color(l0, za, band[4]),
						_shoulder_color(l1, za, band[4]),
						_shoulder_color(l3, zb, band[4]),
						_shoulder_color(l2, zb, band[4]),
						_ground_normal(za, l0, drop_a),
						_ground_normal(za, l1, drop_b),
						_ground_normal(zb, l3, drop_c),
						_ground_normal(zb, l2, drop_d)
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

func _band_interpolated_drop(band: Array, lateral: float) -> float:
	var width: float = float(band[2]) - float(band[0])
	if absf(width) < 0.001:
		return float(band[1])
	return lerpf(float(band[1]), float(band[3]), (lateral - float(band[0])) / width)


func _terrain_segments(za: float, zb: float, band: Array) -> Array[Vector4]:
	var lo: float = float(band[0])
	var hi: float = float(band[2])
	if not _on_spur or band[4] not in ["ground", "verge"]:
		return [Vector4(lo, hi, lo, hi)]
	var sa: Vector2 = _spur_span(za)
	var sb: Vector2 = _spur_span(zb)
	if sa == Vector2.ZERO and sb == Vector2.ZERO:
		return [Vector4(lo, hi, lo, hi)]
	if sa == Vector2.ZERO:
		sa = Vector2(HALF_WIDTH, HALF_WIDTH) * _vp_side
	if sb == Vector2.ZERO:
		sb = Vector2(HALF_WIDTH, HALF_WIDTH) * _vp_side
	var result: Array[Vector4] = []
	var left_a: float = clampf(sa.x, lo, hi)
	var left_b: float = clampf(sb.x, lo, hi)
	if left_a > lo + 0.001 or left_b > lo + 0.001:
		result.append(Vector4(lo, left_a, lo, left_b))
	var right_a: float = clampf(sa.y, lo, hi)
	var right_b: float = clampf(sb.y, lo, hi)
	if right_a < hi - 0.001 or right_b < hi - 0.001:
		result.append(Vector4(right_a, hi, right_b, hi))
	return result


func _finish_ribbon(
	hard: LowPoly, road: LowPoly, soft_left: LowPoly, soft_right: LowPoly, z0: float
) -> void:
	_prepare_ribbon(hard, road, z0)
	_commit_spur_meshes(z0)
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
	_build_markings(hard, z0)
	if not await _keep_streaming():
		return
	if _on_spur:
		_build_decel_lane(hard, z0)
		_build_gore_hatch(hard, z0)
		if not await _keep_streaming():
			return
		_commit_spur_meshes(z0)
		if not await _keep_streaming():
			return
	# Open-coast sea sheet is for the highway ride. On the scenic spur it sits
	# behind woodland and lake meshes and only adds streaming cost.
	if theme == Env.COAST and not _on_spur:
		_build_sea(hard, z0)
		if not await _keep_streaming():
			return
	_commit_hard_ribbon(hard)
	if not await _keep_streaming():
		return
	_commit_road_ribbon(road)
	if not await _keep_streaming():
		return
	_commit_terrain_ribbon(soft_left, "Terrain")
	if not await _keep_streaming():
		return
	_commit_terrain_ribbon(soft_right, "TerrainRight")
	_clear_ribbon_samples()


func _prepare_ribbon(hard: LowPoly, road: LowPoly, z0: float) -> void:
	_build_markings(hard, z0)
	if _on_spur:
		# Junction paint stays on the highway ribbon so the exit is still readable
		# after the unused climb is culled.
		_build_decel_lane(hard, z0)
		_build_gore_hatch(hard, z0)
	if theme == Env.COAST and not _on_spur:
		_build_sea(hard, z0)


func _commit_spur_meshes(z0: float) -> void:
	## Spur tarmac and the drop barrier are their own meshes, tagged scenic, so
	## staying on the carriageway can hide the unused climb. Mixing them into
	## RoadSurface left a fenced empty road hanging over the verge.
	if not _on_spur or get_node_or_null("SpurSurface") != null:
		return
	var spur_hard := LowPoly.new()
	var spur_road := LowPoly.new()
	_build_spur_ribbon(spur_hard, spur_road, z0, 0, STEPS, false)
	_build_platform_bays(spur_hard, z0)
	_build_spur_barrier(spur_hard, z0)
	var from_index := get_child_count()
	var details: MeshInstance3D = spur_hard.commit_to(self, "SpurDetails")
	if details:
		details.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		details.set_meta("ribbon", true)
	var surface: MeshInstance3D = spur_road.commit_to(self, "SpurSurface")
	if surface:
		surface.material_override = _road_material()
		surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		surface.set_meta("ribbon", true)
	_tag_new_children(from_index, "scenic")


func _commit_hard_ribbon(hard: LowPoly) -> void:
	var previous: Node = get_node_or_null("RoadDetails")
	if previous != null:
		previous.free()
	var hard_mesh: MeshInstance3D = hard.commit_to(self, "RoadDetails")
	if hard_mesh:
		# Markings and curb faces should stay crisp and matte; their vertex colours
		# carry the reflective/painted distinction without extra materials.
		hard_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		hard_mesh.set_meta("corridor", "highway")
		hard_mesh.set_meta("ribbon", true)
		_corridor_flags = -1


func _commit_road_ribbon(road: LowPoly) -> void:
	var previous: Node = get_node_or_null("RoadSurface")
	if previous != null:
		previous.free()
	var road_mesh: MeshInstance3D = road.commit_to(self, "RoadSurface")
	if road_mesh:
		road_mesh.material_override = _road_material()
		road_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		road_mesh.set_meta("corridor", "highway")
		road_mesh.set_meta("ribbon", true)
		_corridor_flags = -1


func _commit_terrain_ribbon(soft: LowPoly, node_name: String) -> void:
	var terrain_mesh: MeshInstance3D = soft.commit_to(self, node_name)
	if terrain_mesh:
		terrain_mesh.material_override = LowPoly.terrain_material()
		# Flat ground casting onto itself buys nothing and costs a shadow pass.
		terrain_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _clear_ribbon_samples() -> void:
	_road_samples.clear()
	_point_samples.clear()
	_normal_samples.clear()


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
## Out to the top of the far bank. The old 150 m bound left the shelf lip, the
## whole headland face and the start of the far shore inside single ~110 m
## quads — which is why the drop read as one smooth green curtain and the
## terrace lip could never draw a clean edge.
const VIEW_REFINE_OUTER := 320.0
const VIEW_REFINE_STEP := 7.0


func _view_bands() -> Array:
	## The road profile, subdivided across the drop — and only on the view side of
	## chunks that have a view, so no ordinary stretch of road pays for it.
	if not _on_lake:
		return _bands()
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
	if _on_lake or _on_spur:
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
	var forward := Vector3(frame.z.x, 0.0, frame.z.z)
	if forward.length_squared() < 0.0001:
		forward = Vector3.FORWARD
	else:
		forward = forward.normalized()
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


func _ground_scatter_allowed(z: float, lateral: float, clearance: float = 0.6) -> bool:
	## Field grass and similar unguarded scatter. `_blob` now rejects tarmac even
	## when forced; grass tufts are appended directly and have to ask themselves.
	return not _on_tarmac(z, lateral, clearance) and not _viewpoint_reserves_sightline(z, lateral)


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
	var f: Basis = _path.frame_flat_at(z)
	return _path.ground_at(z, lateral) - f.y * _profile_drop_at(lateral, z)


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
	## Sit on the road's own up, not world Y. World-up boxes on a grade bury the
	## uphill face in the tarmac and hover downhill — the glitch along every climb.
	var half_lateral := absf(cos(yaw)) * size.x * 0.5 + absf(sin(yaw)) * size.z * 0.5
	var half_depth := absf(sin(yaw)) * size.x * 0.5 + absf(cos(yaw)) * size.z * 0.5
	if not allow_road_overlap and not _footprint_is_clear(z, lateral, half_lateral, half_depth):
		return
	var flat: Basis = _path.frame_flat_at(z)
	var frame := Basis(flat.x, flat.y, flat.z).rotated(flat.y, yaw)
	var scaled := Basis(frame.x * size.x, frame.y * size.y, frame.z * size.z)
	var base: Vector3 = _ground_base_for_footprint(z, lateral, half_lateral, half_depth, follow_terrain) - _origin
	_cubes.append(Transform3D(scaled, base + flat.y * (lift + size.y * 0.5)))
	_cube_cols.append(color)


func _deck_cube(
	z: float, lateral: float, size: Vector3, color: Color, yaw: float = 0.0, lift: float = 0.0
) -> void:
	## Sit a box on the spur deck, along the road's own up. World-Y placement is
	## what left the benches hovering whenever the headland was pitched.
	lift += _terrace_floor_at(z, lateral)
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
	lift += _terrace_floor_at(z, lateral)
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
	lift += _terrace_floor_at(z, lateral)
	var flat: Basis = _path.frame_flat_at(z)
	var scaled := Basis(flat.x * size.x, flat.y * size.y, flat.z * size.z)
	_lamps.append(Transform3D(scaled, _p(z, lateral, -(lift + size.y * 0.5))))
	_lamp_cols.append(color)


func _deck_light(z: float, lateral: float, lift: float, color: Color, radius: float, energy: float) -> void:
	if _light_count >= MAX_LIGHTS_PER_CHUNK:
		return
	var light := OmniLight3D.new()
	# Same deck allowance as the lamp it sits in, or the light hangs below its glass.
	light.position = _p(z, lateral, -(lift + _terrace_floor_at(z, lateral)))
	light.light_color = color
	light.light_energy = energy
	light.omni_range = radius
	light.omni_attenuation = 1.5
	light.shadow_enabled = false
	light.light_specular = 0.0
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
	var flat: Basis = _path.frame_flat_at(z)
	var frame := Basis(flat.x, flat.y, flat.z).rotated(flat.y, yaw)
	var scaled := Basis(frame.x * size.x, frame.y * size.y, frame.z * size.z)
	var base: Vector3 = _ground_base_for_footprint(z, lateral, half_lateral, half_depth, follow_terrain) - _origin
	_arch.append(Transform3D(scaled, base + flat.y * (lift + size.y * 0.5)))
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
	# Forced planting still cannot sit on tarmac. Vista rocks use forced to stand
	# in reserved ground; the slip road is not reserved, and coast/mountain midfield
	# used forced to skip the nine-sample query.
	if _on_tarmac(z, lateral, maxf(radius, 0.8)):
		return
	if not forced and not _footprint_is_clear(z, lateral, radius, radius):
		return
	var base: Vector3 = _ground_base_for_footprint(z, lateral, radius, radius, follow_terrain) - _origin + Vector3(0, lift, 0)
	var basis := Basis(Vector3.UP, _rng.randf_range(0.0, TAU)).scaled(size)
	var up: Vector3 = _path.frame_flat_at(z).y if follow_terrain else Vector3.UP
	var xform := Transform3D(basis, base + up * (size.y * 0.42))
	# Planting is measured against the analytic surface, but the waterline
	# checks run on the ribbon's chord — a leafy clump that slips between the
	# two lands in the lake, standing in open water like litter. Rocks are
	# allowed to sit in the shallows; foliage is not.
	if leafy and _on_lake and xform.origin.y + _origin.y < _vp_water_y - 0.4:
		return
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
	if _on_tarmac(z, lateral, foot + PROP_ROAD_CLEARANCE):
		return
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
		Flora.PINE:
			_grow_pine(frame, height, color)
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
	# A quarter of the height clear, not two fifths. Seen from a bike or a bench
	# — always from below — the longer stem was a pole with a dark lid on it.
	var trunk_h: float = height * _rng.randf_range(0.24, 0.32)
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

	# The crown keeps its old volume rather than growing into the freed stem:
	# grown, it was the prime suspect for a ~0.6 ms leaf-fill loss on the forest road.
	var crown_h: float = (height - fork.y) * _rng.randf_range(0.88, 0.98)
	_canopy(frame, fork + Vector3(lean.x * 0.3, -crown_h * 0.13, lean.z * 0.3), width, crown_h, color)


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
		# Leafed from two fifths of the way up, not three fifths. With the small
		# high crown, three pale stems and a tuft read as bare white sticks.
		var top := Vector3(cos(a) * out, tall * 0.6, sin(a) * out)
		_limb(frame, Vector3.ZERO, top, tall * 0.05, BARK_PALE.darkened(_rng.randf() * 0.3))
		# Old crown size, seated lower: leafed from the same point without the
		# extra leaf fill a bigger crown cost.
		var width: float = tall * _rng.randf_range(0.42, 0.56)
		_canopy(frame, top - Vector3(0, tall * 0.16, 0), width, tall * 0.5, color.lightened(_rng.randf() * 0.12))


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


func _grow_pine(frame: Transform3D, height: float, color: Color) -> void:
	## Mountain pine: a clean stem carrying a high, flat-topped crown and one
	## lower bough mass swung off to the side. Round masses, so it can stand in
	## the seated frame where a spruce apex reads as a spike, and dressed all the
	## way up, so the pass reads as wind-shaped timberline instead of the stand
	## of leafless snags it used to be. Four instances against a snag's dozen.
	# Warm upper bark, the one thing that tells a pine from a spruce at range.
	var bark: Color = BARK.lerp(BARK_PALM, 0.35).lightened(_rng.randf() * 0.1)
	var stem_h: float = height * _rng.randf_range(0.5, 0.6)
	var thickness: float = height * _rng.randf_range(0.05, 0.065)
	var lean := Vector3(_rng.randf_range(-0.07, 0.07), 0.0, _rng.randf_range(-0.07, 0.07)) * height
	var top := lean + Vector3(0, stem_h, 0)
	_limb(frame, Vector3.ZERO, top, thickness, bark)
	var width: float = height * _rng.randf_range(0.5, 0.66)
	var crown_h: float = (height - stem_h) * _rng.randf_range(0.9, 1.05)
	# Seated down over the stem head, so no bare fork shows between wood and leaf.
	_canopy(frame, top - Vector3(0, crown_h * 0.22, 0), width, crown_h, color)
	# The lower mass is the wind: one side only, a shade darker in the crown's
	# own shadow, with a bough running out to it so it is not a floating ball.
	var a: float = _rng.randf_range(0.0, TAU)
	var reach: float = width * _rng.randf_range(0.28, 0.4)
	var bough := top + Vector3(cos(a) * reach, -crown_h * _rng.randf_range(0.35, 0.5), sin(a) * reach)
	_limb(frame, top - Vector3(0, crown_h * 0.45, 0), bough, thickness * 0.45, bark.darkened(0.1))
	_canopy(frame, bough - Vector3(0, crown_h * 0.15, 0), width * 0.55, crown_h * 0.5, color.darkened(0.08))


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
	light.light_specular = 0.0
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
	var flat: Basis = _path.frame_flat_at(z)
	var scaled := Basis(flat.x * size.x, flat.y * size.y, flat.z * size.z)
	var base: Vector3 = _ground_base_for_footprint(z, lateral, half_lateral, half_depth) - _origin
	_lamps.append(Transform3D(scaled, base + flat.y * (lift + size.y * 0.5)))
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


func _vista_rock(z: float, lateral: float, scale: float, lift: float = 0.0, in_water: bool = false, freeboard: float = -1.0) -> void:
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
	if not in_water and ground.y + lift < _vp_water_y + 0.8:
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
	if in_water and freeboard >= 0.0:
		# Measure transformed imported geometry; do not assume asset pivot/height.
		var top: float = -INF
		var bottom: float = INF
		var meshes: Array[Node] = instance.find_children("*", "MeshInstance3D", true, false)
		if instance is MeshInstance3D:
			meshes.push_front(instance)
		for mesh_node: Node in meshes:
			var mesh_instance: MeshInstance3D = mesh_node as MeshInstance3D
			var local_frame: Transform3D = Transform3D.IDENTITY
			var ancestor: Node3D = mesh_instance
			while ancestor != instance:
				local_frame = ancestor.transform * local_frame
				ancestor = ancestor.get_parent() as Node3D
			var bounds: AABB = mesh_instance.get_aabb()
			for corner: int in 8:
				var vertex: Vector3 = bounds.position + bounds.size * Vector3(float(corner & 1), float((corner >> 1) & 1), float((corner >> 2) & 1))
				var transformed_y: float = (instance.basis * (local_frame * vertex)).y
				top = maxf(top, transformed_y)
				bottom = minf(bottom, transformed_y)
		if is_finite(top) and is_finite(bottom):
			# A stack must reach the water even when its imported mesh is squat.
			# Preserve the intended crown height and bury at least 18% of its span.
			var mesh_height: float = maxf(top - bottom, 0.01)
			var stretch: float = maxf(1.0, freeboard / (mesh_height * 0.82))
			instance.scale.y *= stretch
			top *= stretch
			bottom *= stretch
			var rooted_freeboard: float = minf(freeboard, (top - bottom) * 0.82)
			instance.position.y = _vp_water_y - _origin.y + rooted_freeboard - top
	add_child(instance)


func _dress_imported_rock(node: Node, mat: StandardMaterial3D) -> void:
	if node is GeometryInstance3D:
		var geo := node as GeometryInstance3D
		geo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		geo.material_override = mat
		LowPoly.cheap_draw(geo)
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


func apply_corridor(on_scenic: bool, committed: bool, drop_unused: bool = false) -> void:
	## Hide the unused path once the rider has committed. Junctions keep both
	## corridors drawn so the brown signs and the exit stay readable. Once
	## committed, runtime streaming also frees the unused meshes so they stop
	## occupying RAM and draw lists.
	if not _on_spur:
		return
	var show_highway := not on_scenic or not committed
	var show_scenic := on_scenic or not committed
	var flags := (1 if show_highway else 0) | (2 if show_scenic else 0)
	if flags == _corridor_flags:
		return
	_corridor_flags = flags
	var drop_highway := drop_unused and not show_highway
	var drop_scenic := drop_unused and not show_scenic
	var doomed: Array[Node] = []
	for child in get_children():
		if not child.has_meta("corridor"):
			continue
		var tag := str(child.get_meta("corridor"))
		var show := true
		if tag == "highway":
			show = show_highway
		elif tag == "scenic":
			show = show_scenic
		else:
			continue
		if not show and not child.has_meta("ribbon") and ((tag == "highway" and drop_highway) or (tag == "scenic" and drop_scenic)):
			doomed.append(child)
			continue
		child.visible = show
		child.process_mode = (
			Node.PROCESS_MODE_INHERIT if show else Node.PROCESS_MODE_DISABLED
		)
	for node in doomed:
		if is_instance_valid(node):
			node.free()
	if drop_highway:
		set_meta("highway_done", false)
		set_meta("highway_queued", false)
	if drop_scenic:
		set_meta("scenic_done", false)
		set_meta("stub_done", false)
		set_meta("scenic_queued", false)


func _tag_new_children(from_index: int, corridor: String) -> void:
	if not _on_spur:
		return
	_corridor_flags = -1
	for i in range(from_index, get_child_count()):
		get_child(i).set_meta("corridor", corridor)


func _prop_marks() -> Dictionary:
	return {
		"cubes": _cubes.size(),
		"arch": _arch.size(),
		"prisms": _prisms.size(),
		"blobs": _blobs.size(),
		"leaves": _leaves.size(),
		"trunks": _trunks.size(),
		"crowns": _crowns.size(),
		"conifers": _conifers.size(),
		"fronds": _fronds.size(),
		"ridges": _ridges.size(),
		"ledges": _ledges.size(),
		"grass": _grass.size(),
		"hay": _hay.size(),
		"lamps": _lamps.size(),
	}


func _commit_mm_range(
	xforms: Array[Transform3D],
	cols: Array[Color],
	start: int,
	mesh: Mesh,
	mat: Material,
	node_name: String,
	shadows: bool
) -> void:
	if start >= xforms.size():
		return
	if start <= 0:
		_commit_mm(xforms, cols, mesh, mat, node_name, shadows)
		return
	var slice_x: Array[Transform3D] = []
	var slice_c: Array[Color] = []
	slice_x.assign(xforms.slice(start))
	slice_c.assign(cols.slice(start))
	_commit_mm(slice_x, slice_c, mesh, mat, node_name, shadows)


func _commit_props(from: Dictionary = {}) -> void:
	_commit_mm_range(_cubes, _cube_cols, int(from.get("cubes", 0)), unit_cube(), LowPoly.solid_material(), "Cubes", true)
	_commit_mm_range(_arch, _arch_cols, int(from.get("arch", 0)), unit_box_sharp(), LowPoly.solid_material(), "Architecture", true)
	_commit_mm_range(_prisms, _prism_cols, int(from.get("prisms", 0)), unit_cone(), LowPoly.solid_material(), "Cones", true)
	_commit_mm_range(_blobs, _blob_cols, int(from.get("blobs", 0)), unit_sphere(), LowPoly.solid_material(), "Rocks", false)
	_commit_mm_range(_leaves, _leaf_cols, int(from.get("leaves", 0)), unit_sphere(), LowPoly.foliage_material(), "Foliage", false)
	_commit_mm_range(_trunks, _trunk_cols, int(from.get("trunks", 0)), unit_trunk(), LowPoly.solid_material(), "Trunks", true)
	_commit_mm_range(_crowns, _crown_cols, int(from.get("crowns", 0)), unit_crown(), LowPoly.foliage_material(), "Crowns", false)
	_commit_mm_range(_conifers, _conifer_cols, int(from.get("conifers", 0)), unit_conifer(), LowPoly.foliage_material(), "Conifers", false)
	_commit_mm_range(_fronds, _frond_cols, int(from.get("fronds", 0)), unit_frond(), LowPoly.foliage_material(), "Fronds", false)
	_commit_mm_range(_ridges, _ridge_cols, int(from.get("ridges", 0)), unit_ridge(), LowPoly.solid_material(), "Ridges", false)
	_commit_mm_range(_ledges, _ledge_cols, int(from.get("ledges", 0)), unit_box_sharp(), LowPoly.solid_material(), "FaceLedges", false)
	_commit_mm_range(_grass, _grass_cols, int(from.get("grass", 0)), grass_tuft(), LowPoly.foliage_material(), "Grass", false)
	_commit_mm_range(_hay, _hay_cols, int(from.get("hay", 0)), unit_hay_bale(), LowPoly.solid_material(), "HayBales", false)
	_commit_mm_range(_lamps, _lamp_cols, int(from.get("lamps", 0)), unit_cube(), LowPoly.glow_material(), "Lamps", false)


func _commit_props_incremental(from: Dictionary = {}) -> void:
	## Publish non-empty buckets only, a few per frame. Empty awaits used to burn
	## a dozen frames on a skinny spur chunk that had nothing to upload.
	var published := 0
	const PER_FRAME := 1
	if int(from.get("cubes", 0)) < _cubes.size():
		_commit_mm_range(_cubes, _cube_cols, int(from.get("cubes", 0)), unit_cube(), LowPoly.solid_material(), "Cubes", true)
		published += 1
		if published % PER_FRAME == 0 and not await _keep_streaming():
			return
	if int(from.get("arch", 0)) < _arch.size():
		_commit_mm_range(_arch, _arch_cols, int(from.get("arch", 0)), unit_box_sharp(), LowPoly.solid_material(), "Architecture", true)
		published += 1
		if published % PER_FRAME == 0 and not await _keep_streaming():
			return
	if int(from.get("prisms", 0)) < _prisms.size():
		_commit_mm_range(_prisms, _prism_cols, int(from.get("prisms", 0)), unit_cone(), LowPoly.solid_material(), "Cones", true)
		published += 1
		if published % PER_FRAME == 0 and not await _keep_streaming():
			return
	if int(from.get("blobs", 0)) < _blobs.size():
		_commit_mm_range(_blobs, _blob_cols, int(from.get("blobs", 0)), unit_sphere(), LowPoly.solid_material(), "Rocks", false)
		published += 1
		if published % PER_FRAME == 0 and not await _keep_streaming():
			return
	if int(from.get("leaves", 0)) < _leaves.size():
		_commit_mm_range(_leaves, _leaf_cols, int(from.get("leaves", 0)), unit_sphere(), LowPoly.foliage_material(), "Foliage", false)
		published += 1
		if published % PER_FRAME == 0 and not await _keep_streaming():
			return
	if int(from.get("trunks", 0)) < _trunks.size():
		_commit_mm_range(_trunks, _trunk_cols, int(from.get("trunks", 0)), unit_trunk(), LowPoly.solid_material(), "Trunks", true)
		published += 1
		if published % PER_FRAME == 0 and not await _keep_streaming():
			return
	if int(from.get("crowns", 0)) < _crowns.size():
		_commit_mm_range(_crowns, _crown_cols, int(from.get("crowns", 0)), unit_crown(), LowPoly.foliage_material(), "Crowns", false)
		published += 1
		if published % PER_FRAME == 0 and not await _keep_streaming():
			return
	if int(from.get("conifers", 0)) < _conifers.size():
		_commit_mm_range(_conifers, _conifer_cols, int(from.get("conifers", 0)), unit_conifer(), LowPoly.foliage_material(), "Conifers", false)
		published += 1
		if published % PER_FRAME == 0 and not await _keep_streaming():
			return
	if int(from.get("fronds", 0)) < _fronds.size():
		_commit_mm_range(_fronds, _frond_cols, int(from.get("fronds", 0)), unit_frond(), LowPoly.foliage_material(), "Fronds", false)
		published += 1
		if published % PER_FRAME == 0 and not await _keep_streaming():
			return
	if int(from.get("ridges", 0)) < _ridges.size():
		_commit_mm_range(_ridges, _ridge_cols, int(from.get("ridges", 0)), unit_ridge(), LowPoly.solid_material(), "Ridges", false)
		published += 1
		if published % PER_FRAME == 0 and not await _keep_streaming():
			return
	if int(from.get("ledges", 0)) < _ledges.size():
		_commit_mm_range(_ledges, _ledge_cols, int(from.get("ledges", 0)), unit_box_sharp(), LowPoly.solid_material(), "FaceLedges", false)
		published += 1
		if published % PER_FRAME == 0 and not await _keep_streaming():
			return
	if int(from.get("grass", 0)) < _grass.size():
		_commit_mm_range(_grass, _grass_cols, int(from.get("grass", 0)), grass_tuft(), LowPoly.foliage_material(), "Grass", false)
		published += 1
		if published % PER_FRAME == 0 and not await _keep_streaming():
			return
	if int(from.get("hay", 0)) < _hay.size():
		_commit_mm_range(_hay, _hay_cols, int(from.get("hay", 0)), unit_hay_bale(), LowPoly.solid_material(), "HayBales", false)
		published += 1
		if published % PER_FRAME == 0 and not await _keep_streaming():
			return
	if int(from.get("lamps", 0)) < _lamps.size():
		_commit_mm_range(_lamps, _lamp_cols, int(from.get("lamps", 0)), unit_cube(), LowPoly.glow_material(), "Lamps", false)


func _commit_mm(
	xforms: Array[Transform3D], cols: Array[Color], mesh: Mesh, mat: Material, node_name: String, shadows: bool
) -> void:
	if xforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	LowPoly.fill_multimesh(mm, xforms, cols)
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
	elif node_name == "Grass" or node_name == "HayBales":
		mmi.visibility_range_end = 140.0
	elif _on_lake and node_name in ["Conifers", "Cubes", "Architecture", "Rocks", "Trunks", "Crowns", "Foliage", "FaceLedges"]:
		# The far shore and the stacks sit a kilometre out. The old 720 m window
		# popped the trees off the opposite bank while the rider was still looking.
		mmi.visibility_range_end = 1800.0
	else:
		mmi.visibility_range_end = 200.0 if node_name == "Architecture" else 160.0
	if not shadows or _on_lake:
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	LowPoly.cheap_draw(mmi)
	add_child(mmi)


# ------------------------------------------------------------ shared furniture


func _build_furniture() -> void:
	## Reflector posts on both shoulders. Cheap, and the strobe of them going past
	## is most of what sells speed at 200 km/h. Amber and small: a white cube of
	## glow on every post read as floating litter. The scenic climb used to skip
	## this entire pass, which is why the main road beside the brown signs was a
	## bare ribbon for three kilometres.
	_build_reflectors()
	_verge_planting()
	if theme_carries_power_line(theme) and not _on_lake:
		_power_line()
	_build_guardrail()


func _build_furniture_incremental() -> void:
	## These stages used to land together in one 5–11 ms frame. Keeping the same
	## furniture while yielding between independent buckets removes that recurring
	## CPU spike each time a country chunk streams in.
	# Reflectors + grass already landed with the ribbon on the highway.
	if not bool(get_meta("shoulder_done", false)):
		_build_reflectors()
		if not await _keep_streaming():
			return
	var bushes_left: int = int(VERGE_BUSH_COUNT[theme])
	while bushes_left > 0:
		var n: int = mini(VERGE_BUSH_BATCH, bushes_left)
		_verge_plant_bushes(n)
		bushes_left -= n
		if not await _keep_streaming():
			return
	_grass_verge()
	_hedge_verge()
	_verge_plant_fringe(-1.0)
	if not await _keep_streaming():
		return
	_verge_plant_fringe(1.0)
	if not await _keep_streaming():
		return
	if theme_carries_power_line(theme) and not _on_lake:
		_power_line()
		if not await _keep_streaming():
			return
	await _build_guardrail_incremental()


func _build_reflectors() -> void:
	if bool(get_meta("reflectors_done", false)):
		return
	var z0: float = float(chunk_index) * LENGTH
	var z := z0
	while z < z0 + LENGTH - 0.01:
		for side in [-1.0, 1.0]:
			var lx: float = side * (HALF_WIDTH + 1.5)
			_cube(z, lx, Vector3(0.1, 1.0, 0.1), _pal["curb"].lightened(0.25))
			_cube(z, lx, Vector3(0.14, 0.16, 0.11), _pal["curb"].darkened(0.35), 0.0, 0.8)
			_lamp(z, lx, Vector3(0.11, 0.09, 0.045), REFLECTOR, 0.86)
		z += 10.0
	set_meta("reflectors_done", true)


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
		_cube(zz, side * (HALF_WIDTH + 1.15), Vector3(0.2, 1.08, 0.2), _pal["rail"])
		_terrain_beam(zz, zz + 2.8, side * (HALF_WIDTH + 1.15), 0.12, 0.14, _pal["rail"], 0.92)
		_terrain_beam(zz, zz + 2.8, side * (HALF_WIDTH + 1.15), 0.12, 0.14, _pal["rail"], 0.52)
		zz += 2.8


func _build_guardrail_incremental() -> void:
	var z0: float = float(chunk_index) * LENGTH
	var curv: float = _path.curvature_at(z0 + LENGTH * 0.5)
	var side_for_curve: float = -signf(curv) if absf(curv) > 0.0018 else 0.0
	if _on_lake:
		side_for_curve = _vp_side
	if side_for_curve == 0.0 and theme != Env.MOUNTAIN and theme != Env.COAST:
		return
	var side: float = side_for_curve if side_for_curve != 0.0 else 1.0
	var zz := z0
	var n := 0
	while zz < z0 + LENGTH - 0.01:
		_cube(zz, side * (HALF_WIDTH + 1.15), Vector3(0.2, 1.08, 0.2), _pal["rail"])
		_terrain_beam(zz, zz + 2.8, side * (HALF_WIDTH + 1.15), 0.12, 0.14, _pal["rail"], 0.92)
		_terrain_beam(zz, zz + 2.8, side * (HALF_WIDTH + 1.15), 0.12, 0.14, _pal["rail"], 0.52)
		zz += 2.8
		n += 1
		if n % 2 == 0 and not await _keep_streaming():
			return


func _grass_verge() -> void:
	## Blades along the first few metres of verge. This is the band that moves
	## fastest past the rider, so it is where wind reads at all — thirty metres out
	## the sway is invisible and the tufts are wasted.
	if bool(get_meta("grass_done", false)):
		return
	var z0: float = float(chunk_index) * LENGTH
	var base: Color = _pal["verge"]
	for _i in 72:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var side: float = 1.0 if _rng.randf() < 0.5 else -1.0
		# Packed against the curb, thinning outward.
		var lx: float = side * (HALF_WIDTH + 1.15 + pow(_rng.randf(), 1.6) * 7.5)
		if _on_tarmac(z, lx, 0.6) or ((_on_lake or _on_spur) and _viewpoint_reserves_sightline(z, lx)):
			continue
		var height := _rng.randf_range(0.55, 1.18)
		var flat: Basis = _path.frame_flat_at(z)
		var xform := Transform3D(
			Basis(flat.x, flat.y, flat.z).rotated(flat.y, _rng.randf_range(0.0, TAU)).scaled(
				Vector3(_rng.randf_range(0.65, 1.15), height, _rng.randf_range(0.65, 1.15))
			),
			_terrain_surface_at(z, lx) - _origin - flat.y * 0.04
		)
		_grass.append(xform)
		_grass_cols.append((base as Color).lerp(_pal["prop_a"], _rng.randf() * 0.5).darkened(_rng.randf() * 0.25))
	set_meta("grass_done", true)


func _hedge_verge() -> void:
	## A continuous low hedge along the first few metres of curb. Looking sideways
	## from the saddle, this is the entire near field — grass tufts alone read as
	## a painted stripe.
	if bool(get_meta("hedge_done", false)):
		return
	if theme == Env.CITY:
		set_meta("hedge_done", true)
		return
	var z0: float = float(chunk_index) * LENGTH
	for side in [-1.0, 1.0]:
		var hz := z0 + _rng.randf_range(0.0, 1.1)
		while hz < z0 + LENGTH:
			var lx: float = side * (HALF_WIDTH + 2.05 + _rng.randf_range(0.0, 2.6))
			# Forced blobs skip `_footprint_is_clear`; without a tarmac test they grow
			# on the slip road the moment spur chunks start dressing the verge again.
			if ((_on_lake or _on_spur) and _viewpoint_reserves_sightline(hz, lx)) or _on_tarmac(hz, lx, 1.2):
				hz += 2.0
				continue
			var h := _rng.randf_range(1.15, 2.05)
			var w := _rng.randf_range(1.55, 2.55)
			var col: Color = (_pal["prop_a"] as Color).lerp(_pal["verge"], _rng.randf() * 0.5).darkened(
				_rng.randf() * 0.18
			)
			if theme == Env.COAST:
				h *= 0.58
				col = (_pal["prop_a"] as Color).lerp(_pal["ground_alt"], _rng.randf() * 0.5)
			_blob(hz, lx, Vector3(w, h, w * 0.78), col, 0.0, true, true)
			if _rng.randf() < 0.28:
				var s := _rng.randf_range(0.4, 0.9)
				_cube(
					hz + 0.35,
					side * (HALF_WIDTH + 1.65 + _rng.randf() * 1.5),
					Vector3(s * 1.35, s * 0.72, s * 1.1),
					(_pal["prop_c"] as Color).darkened(_rng.randf() * 0.22)
				)
			hz += _rng.randf_range(1.65, 2.45)
	set_meta("hedge_done", true)


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
	# The wire sits at a fixed 15.5 m. Right at the junction tips the formation
	# has not reached that far yet, but the pole still lands on the gore and the
	# made ground the slip road is opening onto — the telegraph pole that used
	# to stand in the middle of the mouth. For the whole detour window, the
	# spur's side is closed to poles out to a little past the wire, not only
	# where the formation has already grown to.
	return absf(lateral) <= maxf(outer + 3.0, HALF_WIDTH + 9.0)


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
		# Arms run across the road, not along world X — on a climbing curve that
		# mismatch left the cables floating beside the poles.
		var foot: Vector3 = _terrain_surface_at(z, lx) - _origin
		var head: float = arm_height.call(z)
		var along: Vector3 = _road_across(z)
		var fwd := Vector3(-along.z, 0.0, along.x)
		_cubes.append(Transform3D(Basis.IDENTITY.scaled(Vector3(0.34, head, 0.34)), foot + Vector3(0, head * 0.5, 0)))
		_cube_cols.append(pole_color)
		_cubes.append(Transform3D(Basis(along * 2.1, Vector3.UP * 0.15, fwd * 0.15), foot + Vector3(0, head - 0.35, 0)))
		_cube_cols.append(pole_color)
		for index in 3:
			_cubes.append(
				Transform3D(
					Basis.IDENTITY.scaled(Vector3(0.13, 0.22, 0.13)),
					foot + along * ((float(index) - 1.0) * 0.85) + Vector3(0, head - 0.18, 0)
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


func _road_across(z: float) -> Vector3:
	## Horizontal right of the road, for poles that stay gravity-up. Flattened so
	## a banked or climbing stretch does not tilt the crossarm into the sky.
	var along := Vector3(_path.frame_flat_at(z).x.x, 0.0, _path.frame_flat_at(z).x.z)
	if along.length_squared() < 1e-8:
		return Vector3.RIGHT
	return along.normalized()


func _cable_point(
	z: float, span_start: float, t: float, cable_index: int, lateral: float, arm_height: Callable
) -> Vector3:
	var foot: Vector3 = _terrain_surface_at(z, lateral) - _origin
	var top: float = lerpf(float(arm_height.call(span_start)), float(arm_height.call(span_start + 24.0)), t)
	var sag: float = sin(t * PI) * 0.72
	return (
		foot
		+ _road_across(z) * ((float(cable_index) - 1.0) * 0.85)
		+ Vector3(0.0, top - 0.18 - sag, 0.0)
	)


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
	_verge_plant_bushes(int(VERGE_BUSH_COUNT[theme]))
	_grass_verge()
	_hedge_verge()
	_verge_plant_fringe(0.0)


func _verge_plant_bushes(count: int) -> void:
	var z0: float = float(chunk_index) * LENGTH
	# City verge is concrete-grey; planting it that colour reads as rubble.
	var base: Color = Color("2c4a33") if theme == Env.CITY else _pal["prop_a"]
	var alt: Color = Color("3d5c3c") if theme == Env.CITY else _pal["verge"]
	for _i in count:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var side: float = 1.0 if _rng.randf() < 0.5 else -1.0
		# Sparser the further out, so the near verge stays the dense, fast-moving band.
		var lx: float = side * (HALF_WIDTH + 2.0 + pow(_rng.randf(), 1.35) * 16.0)
		var s := _rng.randf_range(0.7, 2.15)
		var col: Color = (base as Color).lerp(alt, _rng.randf() * 0.7).darkened(_rng.randf() * 0.22)
		_blob(z, lx, Vector3(s * 1.6, s * _rng.randf_range(0.85, 1.45), s * 1.5), col, 0.0, true)


func _verge_plant_fringe(side_filter: float) -> void:
	## Low grass fringe right against the curb — reads as a soft edge to the tarmac.
	if theme == Env.CITY:
		return
	var z0: float = float(chunk_index) * LENGTH
	var gz := z0 + _rng.randf_range(0.0, 2.0)
	while gz < z0 + LENGTH:
		for side in [-1.0, 1.0]:
			if side_filter != 0.0 and not is_equal_approx(side, side_filter):
				continue
			var s := _rng.randf_range(0.35, 0.7)
			_blob(
				gz,
				side * (HALF_WIDTH + 1.9 + _rng.randf_range(0.0, 0.9)),
				Vector3(s * 2.2, s * 0.7, s * 1.4),
				(_pal["verge"] as Color).darkened(_rng.randf() * 0.3),
				0.0,
				true
			)
		gz += _rng.randf_range(2.0, 3.6)


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


func _scenery_forest_incremental() -> void:
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
			if not await _keep_streaming():
				return
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
		if not await _keep_streaming():
			return


func _scenery_coast() -> void:
	var z0: float = float(chunk_index) * LENGTH
	# Weathered stone for every rock here. These used the fencing colour, and a
	# pointed prism in warm `b8895a` under a dusk key is a traffic cone.
	var stone := Color("8a8274")
	# The inland bank. Eight low cool-grey blobs on warm sand used to leave this
	# side a flat, colourless strip — the one dull quarter of the coast ride. It is
	# a rugged rocky shoulder now: rocks that vary warm against cool and tall
	# against low so the dusk light has edges to catch, imported boulders for real
	# silhouette, and dune scrub in green and marram breaking the sand with colour.
	for _i in 10:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var lx := -(HALF_WIDTH + 8.0 + _rng.randf_range(0.0, 58.0))
		var roll := _rng.randf()
		if roll < 0.38:
			var rock: PackedScene = _rock_scene(_rng.randf() < 0.5)
			var s := _rng.randf_range(1.7, 4.2)
			if rock:
				_asset_prop(rock, z, lx, s * 1.7, s * 0.9, -_rng.randf_range(0.0, 2.0))
			else:
				_prism(z, lx, Vector3(s * 1.8, s * 1.4, s * 1.8), stone, -_rng.randf_range(0.0, 2.0))
		elif roll < 0.68:
			# Tall angular stack, warm stone, for the skyline edge the land side lacked.
			var w := _rng.randf_range(3.0, 6.5)
			_prism(z, lx, Vector3(w, _rng.randf_range(3.4, 7.2), w * 0.8), (stone as Color).darkened(_rng.randf() * 0.32))
		else:
			# Rounded boulder, warm/cool mixed so no two catch the light the same.
			var w := _rng.randf_range(4.0, 9.0)
			_blob(z, lx, Vector3(w, _rng.randf_range(2.4, 4.8), w * 0.75), (_pal["prop_b"] as Color).lerp(stone, _rng.randf() * 0.6))
	# Marram and scrub on the sand — without this the land bank is bare tint.
	for _i in 10:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var lx := -(HALF_WIDTH + 5.0 + _rng.randf_range(0.0, 64.0))
		var w := _rng.randf_range(1.5, 3.4)
		var h := _rng.randf_range(0.8, 1.6)
		# Bedded a fifth of its height into the sand and nearer the scrub tone, so
		# it grows out of the dune instead of lying on it as a dark disc.
		_blob(
			z,
			lx,
			Vector3(w, h, w * 0.9),
			(_pal["ground_alt"] as Color).lerp(_pal["prop_a"], _rng.randf() * 0.6).darkened(_rng.randf() * 0.14),
			-h * 0.2,
			true
		)
	# Sea-side curb: scrub and rock only. Palms/cypress read as thin sticks at
	# highway speed and fight the open Big Sur skyline.
	for _i in 9:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var lx := HALF_WIDTH + 2.4 + _rng.randf_range(0.0, 18.0)
		var w := _rng.randf_range(1.4, 3.2)
		if _rng.randf() < 0.55:
			_blob(
				z,
				lx,
				Vector3(w * 1.8, w * 1.0, w * 1.5),
				(_pal["ground_alt"] as Color).lerp(_pal["prop_a"], _rng.randf() * 0.6).darkened(_rng.randf() * 0.14),
				-w * 0.18,
				true,
				true
			)
		else:
			var s := _rng.randf_range(1.1, 2.6)
			_blob(
				z,
				lx,
				Vector3(s * 1.6, s * 0.9, s * 1.4),
				(stone as Color).darkened(_rng.randf() * 0.22),
				0.0,
				false,
				true
			)
	for _i in 8:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var lx := HALF_WIDTH + 14.0 + _rng.randf_range(0.0, 90.0)
		var s := _rng.randf_range(1.2, 4.5)
		if _rng.randf() < 0.65:
			var rock: PackedScene = _rock_scene(false)
			if rock:
				_asset_prop(rock, z, lx, s * 1.9, s * 0.95, -_rng.randf_range(0.0, 6.0))
			else:
				_prism(z, lx, Vector3(s * 1.8, s, s * 1.8), stone, -_rng.randf_range(0.0, 6.0))
		else:
			_prism(z, lx, Vector3(s * 1.8, s, s * 1.8), stone, -_rng.randf_range(0.0, 6.0))


func _scenery_mountain() -> void:
	var z0: float = float(chunk_index) * LENGTH
	for side in [-1.0, 1.0]:
		# Dark montane conifer, thinning into wind-shaped pine on the exposed ground.
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
				_tree(Flora.PINE, z, lx, h * 0.75, tint.lightened(0.06))
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
		# Midfield scrub and talus so the strip between roadside pines and the
		# distant ridges is not a blank tinted plane.
		for _i in 10:
			var z := z0 + _rng.randf_range(0.0, LENGTH)
			var lx: float = side * (HALF_WIDTH + 12.0 + _rng.randf_range(0.0, 55.0))
			var s := _rng.randf_range(1.2, 3.4)
			if _rng.randf() < 0.55:
				_blob(
					z,
					lx,
					Vector3(s * 1.8, s * 0.7, s * 1.5),
					(_pal["prop_a"] as Color).lerp(_pal["ground_alt"], _rng.randf()).darkened(_rng.randf() * 0.2),
					0.0,
					true,
					true
				)
			else:
				_blob(
					z,
					lx,
					Vector3(s * 1.5, s * 0.9, s * 1.3),
					(_pal["prop_c"] as Color).darkened(_rng.randf() * 0.25),
					0.0,
					false,
					true
				)
	# Grass over the open ground between the trees and hills, so the slopes
	# read as turf rather than a bare tinted plane between the planting.
	for _i in 55:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var side: float = 1.0 if _rng.randf() < 0.5 else -1.0
		var lx: float = side * (HALF_WIDTH + 6.0 + pow(_rng.randf(), 1.4) * 70.0)
		if not _ground_scatter_allowed(z, lx):
			continue
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


func _scenery_mountain_incremental() -> void:
	_scenery_mountain()
	if not await _keep_streaming():
		return


func _scenery_country() -> void:
	## Rolling farmland: hedged fields running off over the hills, post-and-rail
	## along the verge, broadleaf trees and hay bales. No buildings — this route
	## is meant to feel like nobody lives out here.
	var z0: float = float(chunk_index) * LENGTH

	# Post-and-rail fence hugging both verges. The scenic-side verge is the
	# exit: a field fence there is the unused climb's barrier seen from below.
	var fz := z0
	var fseg := 0
	while fz < z0 + LENGTH - 0.01:
		for side in [-1.0, 1.0]:
			if _on_spur and is_equal_approx(side, _vp_side):
				continue
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
		if not _ground_scatter_allowed(z, lx):
			continue
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
	if _on_lake:
		# The overlook authors its own range, far shore and headland. Extra ridge
		# blobs here only fight that composition and cost streaming frames.
		return
	for side in [-1.0, 1.0]:
		_build_distant_scenery_side(side)


func _build_distant_scenery_incremental() -> void:
	if _on_lake:
		return
	for side in [-1.0, 1.0]:
		_build_distant_scenery_side(side)
		if not await _keep_streaming():
			return


func _build_distant_scenery_side(side: float) -> void:
	const BANDS := [
		{"lateral": [175.0, 235.0], "width": [110.0, 195.0], "height": [16.0, 30.0], "fade": 0.22, "count": 3},
		{"lateral": [275.0, 350.0], "width": [185.0, 305.0], "height": [26.0, 46.0], "fade": 0.48, "count": 2},
	]
	var z0 := float(chunk_index) * LENGTH
	var haze := Color("899aa2")
	if theme == Env.COAST and side < 0.0:
		return
	if _on_lake and side == _vp_side:
		return
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
		LowPoly.cheap_draw(mesh)
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


func _build_spur_ribbon(
	hard: LowPoly,
	road: LowPoly,
	z0: float,
	first_step: int = 0,
	step_count: int = STEPS,
	finish: bool = true
) -> void:
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
	for i in range(first_step, mini(first_step + step_count, STEPS)):
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
		# The same tarmac as the carriageway it leaves, to the vertex. The spur
		# used to be laid a fifth lighter and the platform warmer again, so the
		# junction drew a seam straight across the road and the climb read as a
		# second, cheaper road bolted on. The car park is told apart by its bay
		# paint and its parapet, not by a different surface.
		var surface: Color = _pal["road"]
		road.add_quad_uv(
			_p(za, span_a.x, -PROUD),
			_p(za, span_a.y, -PROUD),
			_p(zb, span_b.y, -PROUD),
			_p(zb, span_b.x, -PROUD),
			surface,
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
	if finish:
		_finish_spur_ribbon(hard, z0)


func _finish_spur_ribbon(hard: LowPoly, z0: float) -> void:
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


## Gore marking: a solid border down each side, thin chevrons between them.
const GORE_LINE := 0.15  # half width of the two border lines
const GORE_BAR := 0.22  # half width of a chevron, measured along the route
const GORE_PITCH := 4.0  # route metres from one chevron to the next
const GORE_SLANT := 0.85  # chevron run along the route per metre of gap


func _build_gore_hatch(hard: LowPoly, z0: float) -> void:
	## Painted chevrons in the gore, so the fork is a mark on the road rather than
	## a sudden extra lane of tarmac. Only while the gap is wide enough to hold
	## paint and narrow enough to still read as a junction.
	##
	## Drawn the way a gore is actually painted: a border line along each edge
	## and thin diagonal bars between. It used to be solid bars the full width of
	## the gap, 2.8 m long with 2.8 m between — up to eleven metres of bright
	## paint at a time, which from the saddle read as slabs spilling over the
	## red kerb and across both road edges rather than as a marking.
	const PROUD := 0.07
	var stripe: Color = _pal["stripe"]
	var step := LENGTH / float(STEPS)
	for i in STEPS:
		var za := z0 + float(i) * step
		var zb := za + step
		if not (_gore_marked(za) and _gore_marked(zb)):
			continue
		var inner: float = _gore_inner()
		var out_a: float = _gore_outer(za)
		var out_b: float = _gore_outer(zb)
		var w: float = GORE_LINE * 2.0
		_road_paint(
			hard,
			[Vector2(za, inner), Vector2(za, inner + w), Vector2(zb, inner + w), Vector2(zb, inner)],
			-PROUD,
			stripe
		)
		_road_paint(
			hard,
			[Vector2(za, out_a - w), Vector2(za, out_a), Vector2(zb, out_b), Vector2(zb, out_b - w)],
			-PROUD,
			stripe
		)
	# Chevrons belong to the chunk their leading end falls in, on a route-wide
	# pitch, so a bar crossing a chunk seam is drawn once and never cut.
	var first: int = int(ceil(z0 / GORE_PITCH))
	var last: int = int(floor((z0 + LENGTH - 0.001) / GORE_PITCH))
	for k in range(first, last + 1):
		var zc: float = float(k) * GORE_PITCH
		if not _gore_marked(zc):
			continue
		var inner: float = _gore_inner() + GORE_LINE * 2.0
		var gap: float = _gore_outer(zc) - inner - GORE_LINE * 2.0
		if gap < 0.6:
			continue
		# Leaning back toward the traffic, as a gore's chevrons do.
		var zt: float = zc + gap * GORE_SLANT
		if not _gore_marked(zt):
			continue
		var outer: float = _gore_outer(zt) - GORE_LINE * 2.0
		_road_paint(
			hard,
			[
				Vector2(zc - GORE_BAR, inner),
				Vector2(zt - GORE_BAR, outer),
				Vector2(zt + GORE_BAR, outer),
				Vector2(zc + GORE_BAR, inner),
			],
			-PROUD,
			stripe
		)


func _gore_marked(z: float) -> bool:
	var gap: float = float(_path.spur_gap(z))
	return gap >= 1.6 and gap <= 11.0


func _gore_inner() -> float:
	## Unsigned lateral of the gore's carriageway-side edge.
	return HALF_WIDTH + 0.35


func _gore_outer(z: float) -> float:
	## Unsigned lateral of the gore's spur-side edge.
	return float(_path.spur_offset(z)) - float(_path.spur_half_width(z)) - 0.35


func _road_paint(hard: LowPoly, corners: Array[Vector2], drop: float, color: Color) -> void:
	## A painted quad on the road. Corners are (route z, unsigned lateral) in
	## order around the quad; they are mirrored to the overlook's side and the
	## quad is wound face-up whichever side that is.
	var q: Array[Vector3] = []
	for c in corners:
		q.append(_p(c.x, _vp_side * c.y, drop))
	if (q[2] - q[0]).cross(q[1] - q[0]).y < 0.0:
		hard.add_quad(q[0], q[3], q[2], q[1], color)
	else:
		hard.add_quad(q[0], q[1], q[2], q[3], color)


func _build_spur_barrier(hard: LowPoly, z0: float) -> void:
	## A low stone wall along the drop, built as one continuous ribbon.
	##
	## It used to be a beam a half-metre off the deck on posts spaced every four
	## metres — close up an armco barrier, from the road or the water a hairline
	## floating above the grass, because posts that thin stop drawing at fifty
	## metres. A wall has no underside to read as air: its foot is buried in the
	## made ground it stands on, so it is grounded from every distance.
	##
	## Each segment spans two points on the wall's own line, so consecutive
	## segments share their end faces exactly and it closes up; both neighbours
	## evaluate the same pure function at a chunk seam, so it closes there too.
	## Tall enough to lean on along the climb, and sunk to a kerb where the
	## platform takes over — the belvedere owns the parapet there.
	const FOOT := -0.24  # buried in the made ground — a wall stands, a beam floats
	const RAIL_FOOT := -0.10  # ...on the platform approach it sinks to a flush kerb
	const HEAD := 0.86  # waist height: a drystone wall, not a crash barrier
	const VIEW_HEAD := 0.22
	const THICK := 0.17  # half section, taken across the line — a third of a metre
	var stone: Color = _pal["rail"].lerp(_face_color(), 0.45)
	var step := LENGTH / float(STEPS)
	for i in STEPS:
		var za := z0 + float(i) * step
		var zb := za + step
		# Nothing at the very mouth of the junction: there is no drop to guard
		# there and a wall would be standing in the road.
		if float(_path.spur_half_width(za)) < 2.2 or float(_path.spur_half_width(zb)) < 2.2:
			continue
		# The platform owns a stone parapet; a second wall here would sit on top of
		# the belvedere and read as scaffolding.
		if float(_path.platform_blend(za)) > 0.55 and float(_path.platform_blend(zb)) > 0.55:
			continue
		var la: float = _vp_side * _spur_barrier_out(za)
		var lb: float = _vp_side * _spur_barrier_out(zb)
		var foot_a: float = lerpf(FOOT, RAIL_FOOT, float(_path.platform_blend(za)))
		var foot_b: float = lerpf(FOOT, RAIL_FOOT, float(_path.platform_blend(zb)))
		var platform_mix: float = maxf(float(_path.platform_blend(za)), float(_path.platform_blend(zb)))
		var segment_stone: Color = stone.lerp(Color("455356"), platform_mix * 0.82)
		var head_a: float = lerpf(HEAD, VIEW_HEAD, float(_path.platform_blend(za)))
		var head_b: float = lerpf(HEAD, VIEW_HEAD, float(_path.platform_blend(zb)))
		var a_top := _p(za, la, -head_a)
		var b_top := _p(zb, lb, -head_b)
		var a_foot := _p(za, la, -foot_a)
		var b_foot := _p(zb, lb, -foot_b)
		var out: Vector3 = (_p(za, la + 1.0, -head_a) - a_top).normalized() * THICK
		hard.add_quad(a_foot - out, b_foot - out, b_top - out, a_top - out, segment_stone.lightened(0.1))
		hard.add_quad(b_foot + out, a_foot + out, a_top + out, b_top + out, segment_stone.darkened(0.14))
		hard.add_quad(a_top - out, b_top - out, b_top + out, a_top + out, segment_stone)


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
	if _lookout_scene(LOOKOUT_BAYS) != null:
		return
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
			_deck_cube(z, inner, Vector3(0.1, 0.95, 0.1), rail.lightened(0.2), _spur_yaw(z), 0.0)
			_deck_lamp(z, inner, Vector3(0.1, 0.09, 0.05), REFLECTOR, 0.8)
		z += 3.0


func _build_highway_spur_screen() -> void:
	## Trees between the carriageway and the unused climb. Once the scenic
	## corridor is culled, this is what the bottom road looks at instead of a
	## fenced empty spur.
	if not _on_spur:
		return
	var z0: float = float(chunk_index) * LENGTH
	for station in 5:
		var z: float = z0 + 4.0 + float(station) * 7.2
		if z >= z0 + LENGTH:
			continue
		var divergence: float = float(_path.spur_divergence(z))
		if divergence < 0.10:
			continue
		var half: float = float(_path.spur_half_width(z))
		if half < 2.4:
			continue
		var inner: float = _vp_side * (float(_path.spur_offset(z)) - half - 4.2)
		if absf(inner) <= HALF_WIDTH + 2.4:
			continue
		if _on_tarmac(z, inner, 1.6):
			continue
		var height: float = _rng.randf_range(9.0, 15.0)
		var species: int = Flora.PINE if _vp_theme == Env.MOUNTAIN else Flora.BROADLEAF
		if _vp_theme == Env.FOREST:
			species = Flora.CONIFER if _rng.randf() < 0.3 else Flora.BROADLEAF
		if _vp_theme == Env.COAST:
			var s := _rng.randf_range(1.8, 3.4)
			_blob(
				z,
				inner,
				Vector3(s * 1.8, s * 0.8, s * 1.5),
				Color("6a8070").lerp(Color("9a8868"), _rng.randf()),
				0.0,
				true,
				true
			)
			continue
		_tree(species, z, inner, height, Color("2a4634").lerp(Color("4a6840"), _rng.randf() * 0.35), true)


func _build_approach_signs() -> void:
	## Both boards stand on the main-road verge *before* the extra lane exists, so
	## the rider is not asked to read a sign standing in the tarmac they just
	## opened. The far one is a distance plate; the near one is the P.
	##
	## Run by every chunk, not only spur chunks. The boards sit 90 and 240 m
	## ahead of the mouth, which puts them in chunks outside the spur span; built
	## from `_build_junction`, which only spur chunks run, neither ever appeared.
	var z0 := float(chunk_index) * LENGTH
	var entry := _vp_centre - RoadPathGD.SPUR_HALF_SPAN
	for pair in [[entry - 240.0, true], [entry - 90.0, false]]:
		var at: float = float(pair[0])
		if at >= z0 and at < z0 + LENGTH:
			_build_viewpoint_sign(at, _vp_side, bool(pair[1]))


func _build_junction() -> void:
	## Where the spur leaves and rejoins the carriageway: the sign, a hatched
	## gore, and a chevron board at the nose. This is the whole invitation — if
	## it is not legible at 180 km/h the rider never takes the detour.
	# The approach boards are `_build_approach_signs`: they stand outside the
	# spur span, so a spur chunk never holds them.
	var z0 := float(chunk_index) * LENGTH
	# Chevron board at the nose of the gore — where the gore is actually wide
	# enough to stand a board in. Placed at a fixed distance into the mouth it
	# stood on tarmac the rider is invited to ride across, and they rode through
	# it every time.
	var nose := _spur_nose()
	if nose >= z0 and nose < z0 + LENGTH:
		var lateral: float = _vp_side * (float(_path.spur_offset(nose)) - float(_path.spur_half_width(nose)) - 1.8)
		var yaw := _spur_yaw(nose) * 0.5  # splits the angle between the two roads
		_deck_cube(nose, lateral, Vector3(0.18, 1.7, 0.18), Color("626a70"), yaw, 0.0)
		_deck_cube(nose, lateral, Vector3(2.3, 1.05, 0.16), Color("f0b33b"), yaw, 1.7)
		_deck_cube(nose, lateral, Vector3(2.3, 0.14, 0.18), Color("2b2f36"), yaw, 2.2)


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
	## Sync path used by setup() / tests. Runtime streaming uses the owner-only path.
	if not _on_lake:
		return
	_build_lake_water()
	_build_far_ground()
	_build_view_range()
	if not _vista_chunk():
		return
	_build_far_shore()
	_build_far_cliffs()
	_build_coast_headland()
	_build_lake_edges()
	_build_view_frame()
	_dress_vista()
	_build_vista_landmarks()


## The three stages of an overlook's landscape, in the order the eye reads them.
## Kept as named stages because the streaming path builds them one per frame and
## has to be able to reach exactly the same set of work.
func _build_lake_basin() -> void:
	_build_lake_water()
	_build_far_ground()


func _build_lake_distance() -> void:
	_build_view_range()
	_build_far_shore()
	_build_far_cliffs()
	_build_coast_headland()


func _build_lake_dressing() -> void:
	_build_lake_edges()
	_build_view_frame()
	_dress_vista()
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
	[34.0, 28.0, 26.0], [39.0, 40.0, 32.0], [36.0, 52.0, 29.0],
	[43.0, 34.0, 24.0], [41.0, 60.0, 31.0], [45.0, 48.0, 27.0],
	[33.0, 68.0, 34.0], [47.0, 42.0, 25.0], [38.0, 78.0, 30.0],
	[44.0, 56.0, 28.0],
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
	var z0 := _vp_centre - 120.0
	var view_span: float = 240.0
	var hand: float = (
		1.0
		if posmod(hash(Vector2i(int(round(_vp_centre)), int(_path.world_seed) ^ 0x5f3a)), 2) == 0
		else -1.0
	)
	# Where the eye actually is, so the angles below mean what they say.
	var eye_out: float = float(_path.spur_offset(_vp_centre)) + RoadPathGD.PLATFORM_BENCH_OUT
	# All ten specs, not the first four. The stand was cut to four on the
	# reasoning that one side of a ninety-four-degree frame is plenty, and it is:
	# the problem was never the angle spread but the *count*. Four trees at
	# thirty-three to forty-three degrees leave the outer fifth of the picture
	# bare, and a frame is a pair of verticals with something between them, not
	# one vertical and a lot of sky. Ten at a spread of thirty-three to
	# forty-seven degrees puts mass in both outer thirds and leaves the middle
	# third of the axis clear, which is the composition: edges and a gate.
	#
	# Heights are graded outward, larger away from the axis, because that is the
	# only arrangement in which the near elements read as near. A stand of equal
	# heights at increasing angle is a hedge.
	var ranked := FRAME_CLUMP.duplicate()
	ranked.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	for spec in ranked:
		var angle: float = deg_to_rad(float(spec[0]))
		var out: float = float(spec[1])
		# Jittered off the overlook's own phase so the ten specs do not read as
		# ten trees planted on a surveyor's arc.
		var wobble: float = sin(_vp_phase + float(spec[1]) * 0.11)
		var z: float = _vp_centre + hand * (out * tan(angle) + wobble * 7.0)
		if z < z0 or z >= z0 + view_span:
			continue
		var lateral: float = _vp_side * (eye_out + out + wobble * 5.0)
		if _on_tarmac(z, lateral, 1.6):
			continue
		# Never below the waterline: the stand sits on the face of the headland,
		# and past the near shore it would be standing in the lake. The check
		# runs on the rendered chord — near the toe it sits metres off the
		# analytic surface, which is where the drowned saplings came from.
		if _height_above_water(z, absf(lateral)) < 3.0 or not _face_above_water(z, absf(lateral), 1.5):
			continue
		# Taller toward the edge of the lens. Two trees at the same height on
		# opposite sides of a wide frame are a pair of fence posts; graded, they
		# are the two sides of something.
		var edge: float = smoothstep(28.0, 46.0, float(spec[0]))
		var height: float = float(spec[2]) * (0.86 + 0.22 * absf(wobble)) * (0.8 + 0.55 * edge)
		# Round masses, not needles: conifer apices at this size were the spikes
		# standing in the corner of every seated frame. Broadleaf for the wooded
		# overlooks, round-crowned pine on the pass where nothing broadleaf grows.
		var species: int = Flora.BROADLEAF
		# Dark enough to frame, light enough that dusk fill still models them —
		# pure `14261f` under a low key landed as black cutouts.
		var tint := Color("26402f")
		if _vp_theme == Env.MOUNTAIN:
			species = Flora.PINE
			height *= 0.72
			tint = Color("27392f")
		else:
			height *= 1.25 if _vp_theme == Env.FOREST else 0.72
			if _vp_theme == Env.FOREST and absf(wobble) > 0.6:
				tint = Color("20382a")
		_tree(species, z, lateral, height, tint, true, _face_ground_lift(z, absf(lateral)))
		# The second value. A tree with the sun low and dead ahead is a black
		# shape with a lit edge along its top, and in a single tone it collapses
		# into the silhouette: which is what turned the four-tree stand into the
		# flat black shapes at the bottom of the country frame. One lighter
		# crown, offset toward the sun, puts the edge back.
		if _rng.randf() < 0.7:
			_blob(
				z + hand * _rng.randf_range(1.5, 5.0),
				lateral + _vp_side * _rng.randf_range(1.0, 3.5),
				Vector3(height * 0.3, height * 0.16, height * 0.28),
				tint.lightened(0.34),
				height * 0.86 + _face_ground_lift(z, absf(lateral)),
				true,
				true
			)
	# Talus at the foot of the stand, tying it to the slope. Without this the
	# trees read as posts stuck into a smooth hillside.
	if _vp_theme != Env.MOUNTAIN:
		return
	for spec in FRAME_CLUMP:
		var angle: float = deg_to_rad(float(spec[0]) * 0.92)
		var out: float = float(spec[1]) * 1.06
		var z: float = _vp_centre + hand * out * tan(angle)
		if z < z0 or z >= z0 + view_span:
			continue
		var lateral: float = _vp_side * (eye_out + out)
		if _height_above_water(z, absf(lateral)) < 3.0:
			continue
		_vista_rock(z, lateral, _rng.randf_range(5.5, 11.0), -1.2)
		# Pale scree above and behind each block, so the mountain stand is not a
		# row of dark lumps on a dark slope. This is the only biome whose framing
		# stand is allowed two values on the rock as well as on the wood.
		if _rng.randf() < 0.6:
			_blob(
				z - hand * _rng.randf_range(3.0, 9.0),
				lateral + _vp_side * _rng.randf_range(2.0, 6.0),
				Vector3(9.0, 1.6, 7.0),
				Color("7d8890"),
				1.2 + _face_ground_lift(z, absf(lateral)),
				false,
				true
			)


func _dress_vista() -> void:
	## Each overlook is a different place. Shared basin, then a dedicated pass
	## that pours the biome: Art of Rally / Firewatch country, Big Sur coast,
	## Mononoke gorge, Glen Coe tarn. Kenney rocks are the only imported mass.
	##
	## The first three stages are shared because the seated frame's dead band is
	## shared: whatever the biome, the bottom third of that picture is a lake with
	## nothing standing in it. The shoreline's value ladder, then the far bank's
	## three registers, then the one diagonal the composition is allowed — and
	## then the biome pass, which layers its own identity over the top of them.
	## Mass in the water is not here: it belongs with the other shore dressing, in
	## `_build_lake_edges`, where its streaming twin already lives.
	_build_far_bank_bands()
	_build_far_bank_ground()
	_build_vista_accent()
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
	var z0 := _vp_centre - LENGTH * 0.5
	for _i in 22:
		var z: float = _vp_centre + _rng.randf_range(-RoadPathGD.LAKE_SPAN, RoadPathGD.LAKE_SPAN)
		if absf(z - _vp_centre) < 18.0:
			continue
		var out: float = float(_path.viewpoint_far_shore(z, _vp_centre)) + _rng.randf_range(8.0, 55.0)
		if maxf(_far_bank_rise(z, out), _far_ground_y(z, out) - _vp_water_y) < 6.0:
			continue
		_tree(
			Flora.CONIFER if _rng.randf() < 0.45 else Flora.BROADLEAF,
			z,
			_vp_side * out,
			_rng.randf_range(18.0, 34.0),
			Color("1a3024").lerp(Color("2c4a38"), _rng.randf()),
			true,
			_far_bank_lift(z, out) if _far_bank_rise(z, out) >= 0.0 else _far_ground_lift(z, out)
		)
	for _i in 12:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var out: float = float(_path.headland_crest(z)) + 8.0 + _rng.randf_range(0.0, 40.0)
		if _height_above_water(z, out) < 10.0 or not _face_above_water(z, out, 2.0):
			continue
		if float(_path.spur_deck_blend(z, _vp_side * out)) > 0.1:
			continue
		_tree(
			Flora.CONIFER if _rng.randf() < 0.4 else Flora.BROADLEAF,
			z,
			_vp_side * out,
			_rng.randf_range(14.0, 24.0),
			Color("243c30"),
			true,
			_face_ground_lift(z, out)
		)
	for _i in 8:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var out: float = float(_path.viewpoint_near_shore(z)) + _rng.randf_range(-6.0, 14.0)
		if not _face_above_water(z, out, -1.5):
			continue
		_vista_rock(
			z, _vp_side * out, _rng.randf_range(2.4, 5.5),
			_rng.randf_range(-0.4, 0.8) + _face_ground_lift(z, out)
		)
	# A near cedar rank gives the forest overlook a readable frame instead of a
	# bare hillside. It is deliberately sparse: trunks, water and a clear gap.
	for _i in 10:
		var z := _vp_centre + _rng.randf_range(-LENGTH * 0.5, LENGTH * 0.5)
		var out: float = float(_path.viewpoint_near_shore(z)) + _rng.randf_range(28.0, 72.0)
		if not _face_above_water(z, out, 2.0):
			continue
		_tree(
			Flora.CONIFER if _rng.randf() < 0.72 else Flora.BROADLEAF,
			z,
			_vp_side * out,
			_rng.randf_range(16.0, 28.0),
			Color("183a2a").lerp(Color("2f6544"), _rng.randf() * 0.6),
			true
		)


func _dress_vista_coast() -> void:
	## Big Sur: open water, cliffed drop, headland rocks and marram — no trees.
	var z0 := _vp_centre - LENGTH * 0.5
	for _i in 8:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		# Hug the foot of the cliff face. Scattered twenty metres out they read
		# as pebbles floating in open water; bunched at the waterline they are
		# the talus the sea works against.
		var out: float = float(_path.headland_crest(z)) + 2.0 + _rng.randf_range(0.0, 12.0)
		if float(_path.spur_deck_blend(z, _vp_side * out)) > 0.12:
			continue
		if _height_above_water(z, out) < 4.0 or not _face_above_water(z, out, 1.5):
			continue
		_vista_rock(
			z, _vp_side * out, _rng.randf_range(3.5, 8.5),
			_rng.randf_range(-0.4, 0.2) + _face_ground_lift(z, out)
		)
	# Heath and marram on the flat top — a bare crest a hundred and seventy
	# metres wide reads as paving from the bench. Squashed low clumps held back
	# from the lip and the kerb; nothing tall enough to interrupt the sea.
	for _i in 14:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var out: float = (
			float(_path.spur_offset(z)) + RoadPathGD.PLATFORM_HALF_WIDTH + 7.0 + _rng.randf_range(0.0, 100.0)
		)
		if out > float(_path.headland_crest(z)) - 10.0:
			continue
		if float(_path.spur_deck_blend(z, _vp_side * out)) > 0.1:
			continue
		var s := _rng.randf_range(0.9, 2.4)
		_blob(
			z,
			_vp_side * out,
			Vector3(s * 1.7, s * 0.42, s * 1.4),
			Color("5a6448").lerp(Color("8a8a5c"), _rng.randf()),
			_face_ground_lift(z, out),
			true,
			true
		)
	for _i in 6:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var out: float = float(_path.headland_crest(z)) + 3.0 + _rng.randf_range(0.0, 18.0)
		if float(_path.spur_deck_blend(z, _vp_side * out)) > 0.12:
			continue
		if _height_above_water(z, out) < 3.0 or not _face_above_water(z, out, 1.0):
			continue
		var s: float = _rng.randf_range(1.4, 3.0)
		_blob(
			z,
			_vp_side * out,
			Vector3(s * 2.0, s * 0.8, s * 1.6),
			Color("3a5c44").lerp(Color("6a7a58"), _rng.randf()),
			_face_ground_lift(z, out),
			true,
			true
		)


func _dress_vista_mountain() -> void:
	## Glen Coe from the pass: a small tarn, scree to the water, peaks that
	## actually fill the sky. Talus, snags, a few dwarf pines on the folds —
	## not a forest, but not a quarry either.
	var z0 := _vp_centre - LENGTH * 0.5
	for _i in 16:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var out: float = float(_path.headland_crest(z)) + 4.0 + _rng.randf_range(0.0, 80.0)
		if float(_path.spur_deck_blend(z, _vp_side * out)) > 0.12:
			continue
		if _height_above_water(z, out) < 3.0 or not _face_above_water(z, out, 1.2):
			continue
		_vista_rock(
			z, _vp_side * out, _rng.randf_range(2.4, 8.5),
			_rng.randf_range(-0.5, 0.5) + _face_ground_lift(z, out)
		)
	for _i in 14:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var out: float = float(_path.headland_crest(z)) + 8.0 + _rng.randf_range(0.0, 64.0)
		if _height_above_water(z, out) < 4.0 or not _face_above_water(z, out, 1.5):
			continue
		if float(_path.spur_deck_blend(z, _vp_side * out)) > 0.1:
			continue
		var s: float = _rng.randf_range(1.6, 3.8)
		_blob(
			z,
			_vp_side * out,
			Vector3(s * 1.8, s * 0.9, s * 1.5),
			Color("5a5348").lerp(Color("3a3834"), _rng.randf()),
			_face_ground_lift(z, out),
			false,
			true
		)
	for _i in 8:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var out: float = float(_path.headland_crest(z)) + 6.0 + _rng.randf_range(0.0, 40.0)
		if _height_above_water(z, out) < 8.0 or not _face_above_water(z, out, 2.5):
			continue
		if float(_path.spur_deck_blend(z, _vp_side * out)) > 0.1:
			continue
		_tree(
			Flora.CONIFER,
			z,
			_vp_side * out,
			_rng.randf_range(12.0, 19.0),
			Color("2c4036"),
			true,
			_face_ground_lift(z, out)
		)
	# Six bounded stands leave the central col open; each has a different depth.
	for group: int in 6:
		var flank: float = -1.0 if group < 3 else 1.0
		var band: int = group % 3
		var group_z: float = _vp_centre + flank * (155.0 + float(band) * 175.0)
		var depth: float = 38.0 + float((band + group / 3) % 3) * 105.0
		for tree_index: int in 8:
			var z: float = group_z + _rng.randf_range(-65.0, 65.0)
			var out: float = float(_path.viewpoint_far_shore(z, _vp_centre)) + depth + _rng.randf_range(-20.0, 30.0)
			var bank_rise: float = _far_bank_rise(z, out)
			var lift: float = _far_bank_lift(z, out) if bank_rise >= 0.0 else _far_ground_lift(z, out)
			_tree(Flora.CONIFER, z, _vp_side * out, _rng.randf_range(12.0, 24.0), Color("263d32").lightened(_rng.randf() * 0.13), true, lift)
		for rock_index: int in 3:
			var z: float = group_z + _rng.randf_range(-72.0, 72.0)
			var out: float = float(_path.viewpoint_far_shore(z, _vp_centre)) + depth + _rng.randf_range(-18.0, 38.0)
			var lift: float = _far_bank_lift(z, out) if _far_bank_rise(z, out) >= 0.0 else _far_ground_lift(z, out)
			_vista_rock(z, _vp_side * out, _rng.randf_range(4.0, 9.0), lift)


func _dress_vista_country() -> void:
	## Wastwater / Art of Rally Wales: dark water, a sun path, screes, a pass
	## between fells you look *through*. Heather on the near face, Kenney
	## boulders as talus, trees only on the side folds.
	var z0 := _vp_centre - LENGTH * 0.5
	for _i in 11:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var out: float = float(_path.headland_crest(z)) + 5.0 + _rng.randf_range(0.0, 55.0)
		if float(_path.spur_deck_blend(z, _vp_side * out)) > 0.12:
			continue
		if _height_above_water(z, out) < 3.0 or not _face_above_water(z, out, 1.5):
			continue
		_vista_rock(
			z, _vp_side * out, _rng.randf_range(2.2, 5.8),
			_rng.randf_range(-0.4, 0.5) + _face_ground_lift(z, out)
		)
	for _i in 18:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var out: float = float(_path.headland_crest(z)) + 10.0 + _rng.randf_range(0.0, 48.0)
		if _height_above_water(z, out) < 8.0 or not _face_above_water(z, out, 2.0):
			continue
		if float(_path.spur_deck_blend(z, _vp_side * out)) > 0.1:
			continue
		_blob(
			z,
			_vp_side * out,
			Vector3(_rng.randf_range(1.4, 2.8), _rng.randf_range(0.5, 1.0), _rng.randf_range(1.2, 2.2)),
			Color("3a4a30").lerp(Color("5a4638"), _rng.randf()),
			_face_ground_lift(z, out),
			true,
			true
		)
	for _i in 14:
		var z: float = _vp_centre + _rng.randf_range(-RoadPathGD.LAKE_SPAN, RoadPathGD.LAKE_SPAN)
		if absf(z - _vp_centre) < 55.0:
			continue
		var out: float = float(_path.viewpoint_far_shore(z, _vp_centre)) + _rng.randf_range(16.0, 70.0)
		if maxf(_far_bank_rise(z, out), _far_ground_y(z, out) - _vp_water_y) < 6.0:
			continue
		_tree(
			Flora.CONIFER if _rng.randf() < 0.35 else Flora.BROADLEAF,
			z,
			_vp_side * out,
			_rng.randf_range(10.0, 20.0),
			Color("1a3026"),
			true,
			_far_bank_lift(z, out) if _far_bank_rise(z, out) >= 0.0 else _far_ground_lift(z, out)
		)


func _chunk_covers(z: float) -> bool:
	var z0 := float(chunk_index) * LENGTH
	return z >= z0 and z < z0 + LENGTH


func _build_coast_headland() -> void:
	## The drop under the rail: a compact rock skin around the headland nose.
	if _vp_theme != Env.COAST:
		return
	var z0 := _vp_centre - 100.0
	var z_span: float = 200.0
	var b := LowPoly.new()
	var rock := Color("8a8072")
	var scarp := Color("5a5448")
	var turf := Color("4a5844")
	var built := false
	var t := z0
	while t < z0 + z_span - 0.4:
		var t1: float = minf(t + 10.0, z0 + z_span)
		if _add_coast_scarp(b, t, t1, rock, scarp, turf):
			built = true
		t = t1
	if not built:
		return
	var mesh: MeshInstance3D = b.commit_to(self, "ViewpointHeadland")
	if mesh:
		mesh.material_override = LowPoly.terrain_material()
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mesh.visibility_range_end = 0.0


func _build_coast_headland_incremental() -> void:
	if _vp_theme != Env.COAST:
		return
	var z0 := _vp_centre - 100.0
	var z_span: float = 200.0
	var b := LowPoly.new()
	var rock := Color("8a8072")
	var scarp := Color("5a5448")
	var turf := Color("4a5844")
	var built := false
	var t := z0
	while t < z0 + z_span - 0.4:
		var t1: float = minf(t + 10.0, z0 + z_span)
		if _add_coast_scarp(b, t, t1, rock, scarp, turf):
			built = true
		t = t1
		if not await _keep_streaming():
			return
	if not built:
		return
	if not await _keep_streaming():
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
	var lip_out_a: float = float(_path.headland_crest(za)) + 4.0
	var lip_out_b: float = float(_path.headland_crest(zb)) + 4.0
	var near_a: float = float(_path.viewpoint_near_shore(za)) - 8.0
	var near_b: float = float(_path.viewpoint_near_shore(zb)) - 8.0
	if _face_chord_point(za, lip_out_a).y + _origin.y < _vp_water_y + 8.0:
		return false
	# A skin over the brow of the face that follows the ribbon's own rendered
	# chord — the benches are cut into the terrain now, and a flat sheet over
	# them is a glass pane floating off the slope. It only covers the steep
	# run under the lip, where the mesh is too coarse to hold a cliff edge;
	# below that the benched face and the rock paint carry the drop.
	var steps := 5
	var rowa: Array[Vector3] = []
	var rowb: Array[Vector3] = []
	for i in range(steps + 1):
		var f := float(i) / float(steps) * 0.45
		rowa.append(_face_chord_point(za, lerpf(lip_out_a, near_a, f)))
		rowb.append(_face_chord_point(zb, lerpf(lip_out_b, near_b, f)))
	var flat: Basis = _path.frame_flat_at(za)
	var cols: Array[Color] = []
	for i in range(steps + 1):
		var f := float(i) / float(steps)
		cols.append(turf.lerp(rock, smoothstep(0.0, 0.7, f)).lerp(scarp, smoothstep(0.7, 1.0, f) * 0.5))
	for i in range(steps):
		var a0: Vector3 = rowa[i]
		var a1: Vector3 = rowa[i + 1]
		var b0: Vector3 = rowb[i]
		var b1: Vector3 = rowb[i + 1]
		var n := (b0 - a0).cross(a1 - a0).normalized()
		if n.dot(flat.x * _vp_side) < 0.0:
			n = -n
		var proud := n * 0.35
		if _vp_side > 0.0:
			b.add_quad_shaded(a1 + proud, a0 + proud, b0 + proud, b1 + proud, cols[i + 1], cols[i], cols[i], cols[i + 1])
		else:
			b.add_quad_shaded(a0 + proud, a1 + proud, b1 + proud, b0 + proud, cols[i], cols[i + 1], cols[i + 1], cols[i])
	return true


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
	# The platform owner emits authored landmarks for the whole overlook, so the
	# cairn no longer depends on a neighbour chunk being alive.
	var z: float = _vp_centre + 150.0
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
	var z0 := _vp_centre - 200.0
	var z_span: float = 400.0
	var stone := Color("8a8478").darkened(0.08)
	var cap := stone.lightened(0.12)
	var built := false
	for i in 10:
		var za: float = _vp_centre + 140.0 + float(i) * 4.0
		var zb: float = za + 4.0
		if zb < z0 or za >= z0 + z_span:
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
	## Three unequal natural remnants occupy the seaward third of the view.
	## Measured mesh tops set their freeboard independently of asset pivots.
	var z: float = _vp_centre - 95.0
	var near: float = float(_path.viewpoint_near_shore(z))
	var lat: float = _vp_side * (near + 150.0)
	var specs: Array[Array] = [
		[0.0, 0.0, 56.0, 46.0],
		[12.0, 10.0, 38.0, 28.0],
		[-9.0, -6.0, 27.0, 17.0],
	]
	for spec in specs:
		var rz: float = z + float(spec[0])
		var rock_lat: float = lat + _vp_side * float(spec[1])
		_vista_rock(rz, rock_lat, float(spec[2]), 0.0, true, float(spec[3]))
		_surf_collar(rz, rock_lat, float(spec[2]) * 0.22)
	var marker := Node3D.new()
	marker.name = "ViewpointCypress"
	add_child(marker)


func _abs_cube(z: float, lateral: float, y: float, size: Vector3, color: Color, yaw: float = 0.0) -> void:
	## A box standing at an absolute height, world-up — for things built on the
	## water, where the ground under them is a sea bed tens of metres down.
	_cubes.append(Transform3D(Basis(Vector3.UP, yaw).scaled(size), _far_point(z, lateral, y + size.y * 0.5)))
	_cube_cols.append(color)


func _abs_cone(z: float, lateral: float, y: float, size: Vector3, color: Color) -> void:
	_prisms.append(Transform3D(Basis.IDENTITY.scaled(size), _far_point(z, lateral, y)))
	_prism_cols.append(color)


func _vista_lighthouse() -> void:
	## A light on the point. Big Sur has the stacks; what it does not have is a
	## reason for the eye to stop, and a banded tower on its own islet is the
	## oldest one there is. Built on a masonry plinth from the waterline so its
	## height is authored, not whatever the top of a boulder mesh happens to be.
	var z: float = _vp_centre - 95.0
	var near: float = float(_path.viewpoint_near_shore(z))
	var lat: float = _vp_side * (near + 150.0)
	var water: float = _vp_water_y
	var bed := _height_above_water(z, absf(lat))
	# The islet: a ring of rock round a plinth.
	for k in 5:
		var a: float = TAU * float(k) / 5.0 + 0.4
		var rz: float = z + cos(a) * 7.5
		var rl: float = lat + _vp_side * sin(a) * 7.5
		_vista_rock(rz, rl, _rng.randf_range(9.0, 13.0), -_height_above_water(rz, absf(rl)) - 3.2, true)
	_vista_rock(z, lat, 15.0, -bed - 4.5, true)
	var stone := Color("8c8478")
	_abs_cube(z, lat, water - 3.0, Vector3(8.5, 9.5, 8.5), stone.darkened(0.12), 0.3)
	_abs_cube(z, lat, water + 6.5, Vector3(9.6, 0.5, 9.6), stone.lightened(0.08), 0.3)
	# Keeper's cottage on the plinth, whitewashed with a slate roof.
	_abs_cube(z + 2.2, lat - _vp_side * 1.6, water + 7.0, Vector3(3.4, 2.4, 4.2), Color("e8e2d6"), 0.3)
	_abs_cube(z + 2.2, lat - _vp_side * 1.6, water + 9.4, Vector3(3.8, 0.35, 4.6), Color("3c4450"), 0.3)
	# The tower: tapering drums in red and white bands.
	var y: float = water + 7.0
	const DRUMS := 8
	for i in DRUMS:
		var t: float = float(i) / float(DRUMS)
		var w: float = lerpf(4.6, 3.1, t)
		var h: float = 3.5
		var band: Color = Color("f2efe8") if i % 2 == 0 else Color("b8332c")
		_abs_cube(z, lat, y, Vector3(w, h, w), band, 0.3 + float(i) * 0.785)
		_abs_cube(z, lat, y, Vector3(w, h, w), band.darkened(0.04), 0.3 + float(i) * 0.785 + 0.39)
		y += h
	# Gallery, lantern room, dome.
	_abs_cube(z, lat, y, Vector3(4.8, 0.4, 4.8), Color("2c3034"), 0.3)
	_abs_cube(z, lat, y + 0.4, Vector3(4.6, 1.0, 0.1), Color("2c3034"), 0.3)
	_abs_cube(z, lat, y + 0.4, Vector3(0.1, 1.0, 4.6), Color("2c3034"), 0.3)
	_lamps.append(Transform3D(Basis.IDENTITY.scaled(Vector3(2.0, 2.5, 2.0)), _far_point(z, lat, y + 0.4 + 1.25)))
	_lamp_cols.append(Color(2.6, 2.1, 1.3))
	for c in 4:
		var a2: float = TAU * float(c) / 4.0 + 0.3
		_abs_cube(z + cos(a2) * 1.05, lat + sin(a2) * 1.05, y + 0.4, Vector3(0.14, 2.5, 0.14), Color("2c3034"))
	_abs_cone(z, lat, y + 2.9, Vector3(2.9, 2.0, 2.9), Color("b8332c"))
	_abs_cube(z, lat, y + 4.8, Vector3(0.14, 1.0, 0.14), Color("2c3034"))
	# Surf breaking round the islet.
	_surf_collar(z, lat, 13.0)


func _surf_collar(z: float, lateral: float, radius: float) -> void:
	## White water where swell meets rock: a broken ring of flat foam at the
	## waterline. It is what puts a rock *in* the sea rather than on it.
	var count: int = clampi(int(radius * 0.6), 5, 10)
	for k in count:
		var a: float = TAU * float(k) / float(count) + _rng.randf_range(-0.2, 0.2)
		var r: float = radius * _rng.randf_range(0.85, 1.15)
		var fz: float = z + cos(a) * r
		var fl: float = lateral + _vp_side * sin(a) * r
		var s: float = _rng.randf_range(1.5, 3.0) * clampf(radius / 8.0, 0.45, 1.2)
		var foam := Color("8eaaa9").lerp(Color("597e80"), _rng.randf() * 0.6)
		# Long along the ring, thin across it and nearly flat: lace, not pebbles.
		_blobs.append(
			Transform3D(
				Basis(Vector3.UP, a + PI * 0.5).scaled(Vector3(s * 2.4, 0.07, s * 0.8)),
				_far_point(fz, fl, _vp_water_y + 0.02)
			)
		)
		_blob_cols.append(foam)


func _vista_sails() -> void:
	## Two boats standing off the coast: scale for a sea that otherwise has
	## none, and the only thing in the view that is somewhere on purpose.
	var near: float = float(_path.viewpoint_near_shore(_vp_centre))
	for spec in [[70.0, 260.0, 0.6], [-160.0, 420.0, -1.1]]:
		var z: float = _vp_centre + float(spec[0])
		var lat: float = _vp_side * (near + float(spec[1]))
		var yaw: float = float(spec[2])
		var water: float = _vp_water_y
		_abs_cube(z, lat, water - 0.2, Vector3(1.6, 0.9, 5.2), Color("f4f1ea"), yaw)
		_abs_cube(z, lat, water + 0.7, Vector3(1.3, 0.12, 4.6), Color("8a6a4c"), yaw)
		_abs_cube(z, lat, water + 0.8, Vector3(0.14, 7.5, 0.14), Color("3a3a3c"), yaw)
		# Mainsail and jib, thin boards trimmed to the wind.
		var fwd := Vector3(sin(yaw), 0.0, cos(yaw))
		_cubes.append(
			Transform3D(
				Basis(Vector3.UP, yaw + 0.25).scaled(Vector3(0.06, 6.2, 2.6)),
				_far_point(z - fwd.z * 1.3, lat - fwd.x * 1.3, water + 4.4)
			)
		)
		_cube_cols.append(Color("fbf8f0"))
		_cubes.append(
			Transform3D(
				Basis(Vector3.UP, yaw - 0.2).scaled(Vector3(0.05, 4.6, 1.6)),
				_far_point(z + fwd.z * 1.2, lat + fwd.x * 1.2, water + 3.4)
			)
		)
		_cube_cols.append(Color("efe8da"))
		_surf_collar(z, lat, 3.0)


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
	## The landscape has one frame. Applying the road's yaw at each distant
	## vertex folds a kilometre-wide water sheet whenever the access road bends.
	var p: Vector3 = _vista_origin + _vista_basis.z * (z - _vp_centre) + _vista_basis.x * lateral
	p.y = y
	return p - _origin

func _build_lake_water() -> void:
	if not _owns_platform:
		return
	## One continuous sheet owned by the platform chunk, rather than one overlapping
	## sheet per streamed chunk. Extra Z resolution keeps the shoreline readable.
	const ZS := 24
	var zs: int = 24
	var ls: int = 12
	# Start well inside the near shore so the sheet's inner edge stays buried.
	var inner: float = float(_path.viewpoint_near_shore(_vp_centre)) - 140.0
	var outer: float = float(_path.viewpoint_far_shore(_vp_centre, _vp_centre)) + (
		980.0 if _vp_theme == Env.COAST else 520.0
	)
	var z0 := _vp_centre - RANGE_REACH * 2.0
	var z_span: float = RANGE_REACH * 4.0
	var surface := _water_color()
	var b := LowPoly.new()
	b.smooth = true
	for i in zs:
		var za := z0 + z_span * float(i) / float(zs)
		var zb := z0 + z_span * float(i + 1) / float(zs)
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
	# One endless floor under the detailed sheets, owned by the platform chunk.
	# The sea only gets its striped sheet inside the lake window; past it the
	# water simply stops and the eye meets the sky dome's dark floor — at dusk
	# that is a black wall under a burning horizon. A second plane a handspan
	# lower fills every gap the window leaves; where the sheets exist they hide
	# it, and where the coast road crosses it the ground stands over it.
	if _vp_theme == Env.COAST and _owns_platform:
		var hb := LowPoly.new()
		var hy := _vp_water_y - 0.25
		var zc := _vp_centre
		var shore_in := minf(_vp_side * 60.0, _vp_side * 12000.0)
		var out_far := maxf(_vp_side * 60.0, _vp_side * 12000.0)
		var rim := float(_path.viewpoint_far_shore(zc, zc)) + 980.0
		var deep := _water_shade(surface, rim, zc)
		# Sampled out in open water. At 120 m it sat inside the near shore's foam
		# hem, so the whole horizon sheet took half the foam colour and stood
		# beside the lake sheet as a pale slab with a hard diagonal edge.
		var hemi := _water_shade(surface, float(_path.viewpoint_near_shore(zc)) + 240.0, zc)
		hb.add_quad_shaded(
			_far_point(zc - 12000.0, shore_in, hy),
			_far_point(zc - 12000.0, out_far, hy),
			_far_point(zc + 12000.0, out_far, hy),
			_far_point(zc + 12000.0, shore_in, hy),
			hemi, deep, deep, hemi
		)
		var hmesh: MeshInstance3D = hb.commit_to(self, "ViewpointSeaHorizon")
		if hmesh:
			hmesh.material_override = water_material_sea()
			hmesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _build_lake_water_incremental() -> void:
	if not _owns_platform:
		return
	## Same continuous sheet as `_build_lake_water`, one Z strip per frame, then commit.
	const ZS := 24
	var zs: int = 24
	var ls: int = 12
	var inner: float = float(_path.viewpoint_near_shore(_vp_centre)) - 140.0
	var outer: float = float(_path.viewpoint_far_shore(_vp_centre, _vp_centre)) + (
		980.0 if _vp_theme == Env.COAST else 520.0
	)
	var z0 := _vp_centre - RANGE_REACH * 2.0
	var z_span: float = RANGE_REACH * 4.0
	var surface := _water_color()
	var b := LowPoly.new()
	b.smooth = true
	for i in zs:
		var za := z0 + z_span * float(i) / float(zs)
		var zb := z0 + z_span * float(i + 1) / float(zs)
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
		if i % 2 == 1 and not await _keep_streaming():
			return
	var mesh: MeshInstance3D = b.commit_to(self, "ViewpointLake")
	if mesh:
		mesh.material_override = water_material_sea() if _vp_theme == Env.COAST else water_material()
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if _vp_theme == Env.COAST and _owns_platform:
		var hb := LowPoly.new()
		var hy := _vp_water_y - 0.25
		var zc := _vp_centre
		var shore_in := minf(_vp_side * 60.0, _vp_side * 12000.0)
		var out_far := maxf(_vp_side * 60.0, _vp_side * 12000.0)
		var rim := float(_path.viewpoint_far_shore(zc, zc)) + 980.0
		var deep := _water_shade(surface, rim, zc)
		# Sampled out in open water. At 120 m it sat inside the near shore's foam
		# hem, so the whole horizon sheet took half the foam colour and stood
		# beside the lake sheet as a pale slab with a hard diagonal edge.
		var hemi := _water_shade(surface, float(_path.viewpoint_near_shore(zc)) + 240.0, zc)
		hb.add_quad_shaded(
			_far_point(zc - 12000.0, shore_in, hy),
			_far_point(zc - 12000.0, out_far, hy),
			_far_point(zc + 12000.0, out_far, hy),
			_far_point(zc + 12000.0, shore_in, hy),
			hemi, deep, deep, hemi
		)
		var hmesh: MeshInstance3D = hb.commit_to(self, "ViewpointSeaHorizon")
		if hmesh:
			hmesh.material_override = water_material_sea()
			hmesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


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
	# A pale hem where the sheet meets the shore — the line that tells the eye
	# where water starts. Lakes get a faint wet edge; the sea gets a foam
	# fringe, and the far plane lifts toward the sky so the horizon dissolves
	# instead of ending in a seam.
	var near: float = float(_path.viewpoint_near_shore(z))
	var hem: float = 1.0 - smoothstep(near + 1.0, near + 26.0, out)
	if _vp_theme == Env.COAST:
		color = color.lerp(Color("cfe0da"), hem * 0.5)
		var far: float = float(_path.viewpoint_far_shore(z, _vp_centre))
		return color.lightened(0.12 * smoothstep(far + 250.0, far + 900.0, out))
	color = color.lerp(surface.lightened(0.34), hem * 0.22)
	# Very broad horizontal variations catch the sky as painted planes. Kept
	# below four percent so the water gains facets without becoming stripy.
	return color.lightened((0.5 + 0.5 * sin(out * 0.043 + z * 0.018)) * 0.035)


func _build_far_ground() -> void:
	if _vp_theme == Env.COAST:
		return
	## One basin skirt owned by the platform chunk, spanning the complete seated vista.
	var z0 := _vp_centre - RANGE_REACH * 2.0
	var z_span: float = RANGE_REACH * 4.0
	var b := LowPoly.new()
	# Smoothed within each field. Hard facets split every quad along its
	# diagonal into a lit and an unlit half, and across the valley floor that
	# read as a fan of bright triangles radiating from the col.
	b.smooth = true
	var color := Color("435c4a")
	match _vp_theme:
		Env.COAST:
			color = Color("6b7b78")
		Env.FOREST:
			color = Color("244632")
		Env.MOUNTAIN:
			# Alpine meadow, not slate. Blue-grey past the far bank read as a
			# second lake, and the bank between them as a dam.
			color = Color("4b5950")
		Env.COUNTRY:
			color = Color("536535")
	var inner: float = float(_path.viewpoint_far_shore(_vp_centre, _vp_centre)) + 50.0
	var outer: float = inner + 720.0
	# 180 m across by 10 m along is a sliver, and a sliver split into two hard-
	# normalled triangles shades as a herringbone rather than as a fold. Finer
	# across the slope — where the height actually changes — squares the quads up
	# enough that each one reads as a plane.
	const FAR_ZS := 64
	const FAR_LS := 8
	for i in FAR_ZS:
		var za := z0 + z_span * float(i) / float(FAR_ZS)
		var zb := z0 + z_span * float(i + 1) / float(FAR_ZS)
		var shift_a: float = _vp_side * (float(_path.viewpoint_far_shore(za, _vp_centre)) - float(_path.viewpoint_far_shore(_vp_centre, _vp_centre)))
		var shift_b: float = _vp_side * (float(_path.viewpoint_far_shore(zb, _vp_centre)) - float(_path.viewpoint_far_shore(_vp_centre, _vp_centre)))
		for j in FAR_LS:
			var out_a: float = lerpf(inner, outer, float(j) / float(FAR_LS))
			var out_b: float = lerpf(inner, outer, float(j + 1) / float(FAR_LS))
			var lat_a := _vp_side * out_a
			var lat_b := _vp_side * out_b
			if lat_a > lat_b:
				var swap := lat_a
				lat_a = lat_b
				lat_b = swap
			var ya0: float = _far_ground_y(za, absf(lat_a + shift_a))
			var ya1: float = _far_ground_y(za, absf(lat_b + shift_a))
			var yb1: float = _far_ground_y(zb, absf(lat_b + shift_b))
			var yb0: float = _far_ground_y(zb, absf(lat_a + shift_b))
			# Keep a floor through the pass. Skipping any quad whose corners sat
			# near the water punched a black triangle in the one place the eye
			# looks — and on the coast it deleted the whole skirt. Six centimetres
			# over the surface, though: at +0.8 the clamped corners hung in the
			# air over the shoreline as a pale slab.
			var floor_y: float = _vp_water_y + (0.06 if _vp_theme == Env.COAST else 2.2)
			ya0 = maxf(ya0, floor_y)
			ya1 = maxf(ya1, floor_y)
			yb1 = maxf(yb1, floor_y)
			yb0 = maxf(yb0, floor_y)
			var patch := _far_field_color(color, i, j)
			_range_quad_lit(
				b,
				_far_point(za, lat_a + shift_a, ya0),
				_far_point(za, lat_b + shift_a, ya1),
				_far_point(zb, lat_b + shift_b, yb1),
				_far_point(zb, lat_a + shift_b, yb0),
				patch,
				patch,
				patch,
				patch
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
		if _vp_theme == Env.COUNTRY or _vp_theme == Env.MOUNTAIN or _vp_theme == Env.FOREST:
			# _range_quad_lit already shades these slopes. Preserve their local
			# palette under the warm sunset while retaining normal distance fog.
			var far_material: StandardMaterial3D = LowPoly.terrain_material().duplicate() as StandardMaterial3D
			far_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mesh.material_override = far_material
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mesh.visibility_range_end = 0.0


func _far_field_color(color: Color, zi: int, li: int) -> Color:
	## Broad authored parcels and alpine depth bands retain each valley's palette.
	##
	## The mountain ladder is doing more work than it looks. This mesh is drawn
	## unshaded for mountain and country, so its vertex colour *is* the surface:
	## there is no lighting left to break up a tone, and eight value steps spread
	## over seven hundred and twenty metres arrived on screen as one flat
	## grey-mauve wedge filling a fifth of the seated frame. The near end is
	## therefore pulled well down — it has to sit under the cliff face's new dark
	## — and the far end lifted, and a slow patch grain is run along the route so
	## the eight columns do not read as eight bands either.
	if _vp_theme == Env.MOUNTAIN:
		var depth: float = clampf(float(li) / 7.0, 0.0, 1.0)
		# The ramp finishes inside the first four columns rather than the last
		# three. The seated frame only ever sees the inner half of this mesh — the
		# outer columns are behind the ranges — so a ladder spread evenly over all
		# eight put four nearly identical dark steps in the only part of it anybody
		# can see, which is the flat wedge all over again.
		var moss: Color = Color("2f3d37").lerp(Color("7f8d8f"), smoothstep(0.0, 0.62, depth))
		var patch: float = 0.5 + 0.5 * sin(float(zi) * 0.37 + float(li) * 1.9)
		return moss.darkened(0.10 * patch * (1.0 - 0.4 * depth))
	if _vp_theme == Env.FOREST:
		## Woodland as a mosaic of stands instead of one wash. Lit, this sheet
		## took the dusk key at a graze and came out mauve-brown under green
		## ranges — a bare valley in a forest. Unshaded, the vertex colour is the
		## surface, so the stands carry their own value: mostly dark mixed
		## canopy, lighter broadleaf and clearings, and one parcel in six on the
		## turn. Muted olive for that one, not gold; a saturated yellow parcel
		## under the warm key is the jaundice this replaces.
		const STANDS := [
			Color("2c4733"), Color("33523a"), Color("3e5c3b"), Color("2a4232"), Color("475c39"), Color("585a38")
		]
		var stand: int = posmod(hash(Vector2i(chunk_index * 37 + zi / 5, (li / 2) * 13 + 7)), STANDS.size())
		var tone: Color = STANDS[stand]
		var grain: float = 0.5 + 0.5 * sin(float(zi) * 0.41 + float(li) * 1.7)
		var reach: float = smoothstep(0.0, 1.0, clampf(float(li) / 7.0, 0.0, 1.0))
		return tone.darkened(0.08 * grain).lerp(Color("5d6f6a"), 0.28 * reach)
	if _vp_theme != Env.COUNTRY:
		return color
	# Each parcel retains the established six-by-two cell footprint.
	var field_z: int = zi / 6
	var field_out: int = li / 2
	var fh: int = posmod(hash(Vector2i(chunk_index * 31 + field_z, field_out * 17)), 4)
	if fh == 0:
		return Color("456c36")
	if fh == 1:
		return Color("9a8547")
	if fh == 2:
		return Color("668343")
	return Color("365d38")


func _build_far_ground_incremental() -> void:
	if _vp_theme == Env.COAST:
		return
	## Same basin skirt as `_build_far_ground`, spread across the complete seated vista.
	var z0 := _vp_centre - RANGE_REACH * 2.0
	var z_span: float = RANGE_REACH * 4.0
	var b := LowPoly.new()
	b.smooth = true
	var color := Color("435c4a")
	match _vp_theme:
		Env.COAST:
			color = Color("6b7b78")
		Env.FOREST:
			color = Color("244632")
		Env.MOUNTAIN:
			# Alpine meadow, not slate. Blue-grey past the far bank read as a
			# second lake, and the bank between them as a dam.
			color = Color("4b5950")
		Env.COUNTRY:
			color = Color("536535")
	var inner: float = float(_path.viewpoint_far_shore(_vp_centre, _vp_centre)) + 50.0
	var outer: float = inner + 720.0
	const FAR_ZS := 64
	const FAR_LS := 8
	for i in FAR_ZS:
		var za := z0 + z_span * float(i) / float(FAR_ZS)
		var zb := z0 + z_span * float(i + 1) / float(FAR_ZS)
		var shift_a: float = _vp_side * (float(_path.viewpoint_far_shore(za, _vp_centre)) - float(_path.viewpoint_far_shore(_vp_centre, _vp_centre)))
		var shift_b: float = _vp_side * (float(_path.viewpoint_far_shore(zb, _vp_centre)) - float(_path.viewpoint_far_shore(_vp_centre, _vp_centre)))
		for j in FAR_LS:
			var out_a: float = lerpf(inner, outer, float(j) / float(FAR_LS))
			var out_b: float = lerpf(inner, outer, float(j + 1) / float(FAR_LS))
			var lat_a := _vp_side * out_a
			var lat_b := _vp_side * out_b
			if lat_a > lat_b:
				var swap := lat_a
				lat_a = lat_b
				lat_b = swap
			var ya0: float = _far_ground_y(za, absf(lat_a + shift_a))
			var ya1: float = _far_ground_y(za, absf(lat_b + shift_a))
			var yb1: float = _far_ground_y(zb, absf(lat_b + shift_b))
			var yb0: float = _far_ground_y(zb, absf(lat_a + shift_b))
			# Same floor as the sync path: close over the water so no black hole
			# opens in the pass, but flush with the surface so it does not hover.
			var floor_y: float = _vp_water_y + (0.06 if _vp_theme == Env.COAST else 2.2)
			ya0 = maxf(ya0, floor_y)
			ya1 = maxf(ya1, floor_y)
			yb1 = maxf(yb1, floor_y)
			yb0 = maxf(yb0, floor_y)
			var patch := _far_field_color(color, i, j)
			_range_quad_lit(
				b,
				_far_point(za, lat_a + shift_a, ya0),
				_far_point(za, lat_b + shift_a, ya1),
				_far_point(zb, lat_b + shift_b, yb1),
				_far_point(zb, lat_a + shift_b, yb0),
				patch,
				patch,
				patch,
				patch
			)
		if not await _keep_streaming():
			return
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
		if _vp_theme == Env.COUNTRY or _vp_theme == Env.MOUNTAIN or _vp_theme == Env.FOREST:
			# _range_quad_lit already shades these slopes. Preserve their local
			# palette under the warm sunset while retaining normal distance fog.
			var far_material: StandardMaterial3D = LowPoly.terrain_material().duplicate() as StandardMaterial3D
			far_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mesh.material_override = far_material
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mesh.visibility_range_end = 0.0


func _far_ground_y(z: float, out: float) -> float:
	## Rises under the side peaks and stays down in the col, so the pass is sky
	## rather than a sunlit table. Coast barely rises: the sea is the view.
	var far: float = float(_path.viewpoint_far_shore(z, _vp_centre))
	var bank: float = 24.0
	var col: float = 1.0 - 0.88 * exp(-pow((z - _vp_centre) / 300.0, 2.0))
	match _vp_theme:
		Env.FOREST:
			bank = 48.0
			col = 1.0 - 0.18 * exp(-pow((z - _vp_centre) / 220.0, 2.0))
		Env.COAST:
			bank = 16.0
			col = 0.20 + 0.16 * (1.0 - exp(-pow((z - _vp_centre) / 400.0, 2.0)))
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
	return maxf(_vp_water_y + (rise + roll) * col, _vp_water_y + 2.2)


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
	##
	## The last two stages are the opposite of that: they are the only things in
	## the overlook that are placed *for* the seated camera, because the bench's
	## bottom third is a hundred and forty metres of open lake and a mirror has
	## no incident in it. See `_build_shore_strip` and `_build_basin_rocks`.
	##
	## The last stage is the opposite of all that: the only dressing in the
	## overlook placed *for* the seated camera rather than for the ground. With
	## the bench ninety metres over the water the headland drops out of shot and
	## the bottom third of the picture is bare lake, and a mirror with nothing
	## standing in it has no incident anywhere in it. See `_build_basin_rocks`.
	##
	## Owned once, by whichever chunk holds the platform, so this runs a single
	## time per overlook however many chunks the basin spans.
	_build_lake_edge_boulders()
	_build_face_scree()
	_build_face_ledges()
	_build_lake_reeds()
	_build_basin_rocks()


func _build_lake_edges_incremental() -> bool:
	## Same dressing as `_build_lake_edges`, one Z strip per frame, then commit.
	_build_lake_edge_boulders()
	if not await _keep_streaming():
		return false
	var fan_count := SCREE_FANS if _vp_theme == Env.COAST else (SCREE_FANS * 2 if _vp_theme == Env.MOUNTAIN else SCREE_FANS)
	var z0 := _vp_centre - LENGTH * 0.5
	var face_run: float = maxf(
		float(_path.viewpoint_near_shore(_vp_centre)) - float(_path.headland_crest(_vp_centre)) - 8.0, 24.0
	)
	for _fan in fan_count:
		_build_face_scree_fan(z0, face_run)
		if not await _keep_streaming():
			return false
	_build_face_ledges()
	if not await _keep_streaming():
		return false
	_build_lake_reeds()
	if not await _keep_streaming():
		return false
	return await _build_basin_rocks_incremental()


func _build_lake_edge_boulders() -> void:
	var z0 := _vp_centre - LENGTH * 0.5
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
				# thing there is that says the water has a depth. The face lift is
				# the same correction the rest of the shore dressing gets — the
				# rendered chord stands over the analytic surface on this profile.
				-s * _rng.randf_range(0.0, 0.45) + _face_ground_lift(z, out),
				false,
				true
			)


func _build_lake_reeds() -> void:
	# Reeds, where reeds actually grow. A mountain tarn sits above the line where
	# anything roots in its margins, and a sea cliff has surf at the bottom of it
	# — on both, these were half a dozen saturated green chips lying flat on a
	# dark bank, reading as litter rather than as planting.
	if _vp_theme == Env.MOUNTAIN or _vp_theme == Env.COAST:
		return
	var z0 := _vp_centre - LENGTH * 0.5
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


# ------------------------------------------------- the seated frame's mid-ground
#
# Everything above this line dresses ground a rider sees from a bike. Everything
# below dresses the one place in the game where the camera is deliberately
# parked and held still, and where the composition is the whole point.
#
# The measurement that governs all of it: with the bench at eighty to a hundred
# metres over the water and the lens tilted three and a half degrees down, the
# headland falls out of shot almost immediately. Projected through the real seat
# transform, the crest line — the very lip the rider is sitting on — lands below
# row 2000 of a 720-row frame, and the ground four hundred metres out lands in
# the middle of it. So the bottom third of every seated overlook is not a slope
# at all. It is lake.
#
# Which is the actual finding, and it is the opposite of the received wisdom that
# the near face needs more rocks on it. Rocks on the near face are worth having —
# they carry the standing view and the run up the spur — but they cannot fix this
# frame, because a seated rider never sees them. What the seated rider sees is a
# hundred and forty metres of open water to the bottom edge of the picture, and a
# mirror with nothing standing in it has no incident anywhere in it. Per-row
# luminance contrast in the baseline fell from 13 out of 255 at y=460 to 2.2 at
# y=660, which is what an empty plane of water looks like from ninety metres up.
#
# The coast already solved this and nobody noticed: its skerries, stacks and surf
# are the only reason that frame holds any contrast at all below y=460, and it is
# the sparsest of the four biomes by every count the code keeps. The answer is
# mass standing in the water, and the rest of this section is that answer for the
# three biomes that have none.


func _basin_stone() -> Array[Color]:
	## The two values a mass standing in the basin is painted in: its body, and
	## the lighter value its crown catches.
	##
	## Two values, never one, and the reason is the light rather than the
	## material. The sun is low and dead ahead, so a mass in the water is lit on
	## its far shoulder and black everywhere the eye can see the near side of it.
	## Painted in a single value it does not read as a rock with a lit edge; it
	## reads as a hole cut in the water, which is what the near-black blobs at the
	## bottom of the country frame were.
	match _vp_theme:
		Env.FOREST:
			# Waterlogged wood and river boulders, a shade off the lake itself.
			# The lake is the darkest thing in this palette and the masses have to
			# sit against it, not in front of it: the crowns do all the separating.
			return [Color("1d241d"), Color("77835f")]
		Env.COAST:
			return [Color("39404a"), Color("a2a8ac")]
		Env.MOUNTAIN:
			# A tarn is glacial rock and nothing else, and this is the only place
			# in the mountain frame where a light value is available: there is no
			# sunlit ground behind it to compete with, so the bodies go pale and
			# the hard silhouette against dark water does the rest.
			#
			# That was read as permission for near-white, and c8ced4 is near-white:
			# 0.61 linear luminance against a body of 0.16, in a frame whose
			# brightest real surface is the sky at 0.52. Measured off the dusk
			# capture, that crown was the only thing in the mountain picture
			# brighter than the sun behind it, and repeated down the waterline it
			# read as a string of pearls rather than as talus.
			#
			# The crown now sits just under the shore strip's own pale (a8aeb0,
			# see `_shore_band_tone`), so the one light accent by the water stays
			# the shore, and the body has come *up* a step to meet it: four stops
			# of body-to-crown contrast was the other half of the same problem.
			# Two values is a limit, not a target — a mass in a tarn still has to
			# separate from water measured at 0.02 linear, and that it now does
			# with 3x its body's value rather than 4x.
			return [Color("5e6365"), Color("9aa0a2")]
	return [Color("4a463c"), Color("ab9f80")]


func _water_ball(
	z: float, out: float, size: Vector3, body: Color, crown: Color, freeboard: float
) -> void:
	## One mass standing in the lake, lifted until exactly `freeboard` metres of
	## it clear the surface.
	##
	## The basin bed runs from a metre under the surface at the shore to twelve in
	## the middle, so everything placed on it is drowned — which is why the older
	## skerry work had to lift by hand. The lift is measured off the sampled
	## terrain rather than the analytic profile, because the two disagree by
	## metres exactly where the bed falls away, and a ball that clears the water
	## at the shore is two metres under it in the middle.
	##
	## `crown` is the second value: a smaller, lighter mass sitting on the
	## up-sun shoulder. Without it a ball in flat water is a silhouette, and a
	## silhouette on water is a hole.
	var ground: float = _terrain_surface_at(z, _vp_side * out).y
	var lift: float = _vp_water_y + freeboard - size.y * 0.92 - ground
	_blobs.append(
		Transform3D(
			Basis(Vector3.UP, _rng.randf_range(0.0, TAU)).scaled(size),
			_far_point(z, _vp_side * out, ground + lift)
		)
	)
	_blob_cols.append(body)
	if crown.is_equal_approx(Color(0.0, 0.0, 0.0, 0.0)):
		return
	var cap: Vector3 = size * Vector3(0.52, 0.34, 0.5)
	_blobs.append(
		Transform3D(
			Basis(Vector3.UP, _rng.randf_range(0.0, TAU)).scaled(cap),
			_far_point(z, _vp_side * (out + size.z * 0.22), ground + lift + size.y * 0.72)
		)
	)
	_blob_cols.append(crown)


func _water_slab(
	z: float, out: float, size: Vector3, yaw: float, body: Color, freeboard: float
) -> void:
	## A hard-edged slab standing out of the lake. Same lift arithmetic as
	## `_water_ball`, but into the sharp box bucket: at this distance a boulder
	## with a smooth silhouette and a boulder with a faceted one are not the same
	## object, and the mountain frame is the one place that has to be told apart
	## from the rock behind it.
	var ground: float = _terrain_surface_at(z, _vp_side * out).y
	var lift: float = _vp_water_y + freeboard - size.y * 0.5 - ground
	_ledges.append(
		Transform3D(
			Basis(Vector3.UP, yaw).scaled(size),
			_far_point(z, _vp_side * out, ground + lift)
		)
	)
	_ledge_cols.append(body)


func _basin_site(kind: int) -> Vector4:
	## One place in the lake worth putting mass in: z offset from the overlook
	## centre, distance out from the carriageway, size, and freeboard.
	##
	## `z` is pushed away from the centre on purpose. The frame is ninety-four
	## degrees across, so its outer thirds are the only place a near mass can sit
	## without standing in the middle of the view — which is the whole difference
	## between a frame and an obstruction, and the reason the country overlook had
	## three black shapes along the bottom edge where it should have had a view.
	var off: float = _vp_centre
	var bench: float = float(_path.spur_offset(off)) + RoadPathGD.PLATFORM_BENCH_OUT
	# Out to one side, never square on: the third of the frame nearest the lens
	# axis is where a foreground mass does the most damage and the least good.
	var side := 1.0 if _rng.randf() < 0.5 else -1.0
	var dz: float = side * _rng.randf_range(55.0, 300.0)
	var far: float = float(_path.viewpoint_far_shore(off + dz, off))
	var near: float = float(_path.viewpoint_near_shore(off + dz))
	var lat: float = _rng.randf_range(0.0, 1.0)
	var out: float = 0.0
	var size: float = 0.0
	var free: float = 0.0
	match _vp_theme:
		Env.FOREST:
			# A flooded valley floor: half-sunk trunks and the boulders the
			# torrent left, in clumps, low. Nothing here stands proud enough to
			# interrupt the treelines above it.
			out = far - lerpf(8.0, 30.0, lat)
			size = _rng.randf_range(4.5, 13.0)
			free = _rng.randf_range(1.2, 4.0) if kind != 1 else _rng.randf_range(0.3, 1.1)
			if kind == 2:
				size *= 1.7
				free = _rng.randf_range(5.0, 9.5)
		Env.COAST:
			# Sparsest of the four and meant to be: the sea horizon is the subject
			# and a reef field across it would be gravel on glass. Two low teeth
			# well out past the stacks, off to one side.
			out = lerpf(far - 120.0, far + 60.0, lat)
			size = _rng.randf_range(5.0, 11.0)
			free = _rng.randf_range(1.6, 4.5)
		Env.MOUNTAIN:
			# A moraine-drowned tarn. The densest of the four and the only one
			# allowed big pale crags: a glacier leaves rock standing out of its
			# own meltwater, and that silhouette is the biome.
			out = far - lerpf(6.0, 24.0, lat)
			size = _rng.randf_range(3.5, 9.0) if kind != 1 else _rng.randf_range(2.0, 5.5)
			free = _rng.randf_range(0.8, 3.0) if kind != 1 else _rng.randf_range(0.2, 0.8)
			if kind == 2:
				size = _rng.randf_range(11.0, 19.0)
				free = _rng.randf_range(7.0, 14.0)
		_:
			# A glacial lake with a delta in it: shingle bars and the odd
			# boulder, low and warm, laid out so the eye reads a shoreline.
			out = far - lerpf(6.0, 18.0, lat)
			size = _rng.randf_range(5.0, 14.0) if kind != 1 else _rng.randf_range(3.0, 8.0)
			free = _rng.randf_range(1.0, 3.5) if kind != 1 else _rng.randf_range(0.2, 0.9)
			if kind == 2:
				size *= 1.6
				free = _rng.randf_range(4.5, 8.0)
	return Vector4(off + dz, out, size, free)


func _build_basin_rocks() -> void:
	## Mass standing in the lake, which is the entire bottom third of the seated
	## frame. See the section header: this is the only thing in the overlook that
	## can break a mirror.
	##
	## Site count is per biome on purpose, not per seed: the coast is the
	## reference frame and it holds its contrast on two dozen objects, so a biome
	## whose whole subject is rock can afford three times that and still be under
	## a hundred instances of an instanced sphere.
	var stone := _basin_stone()
	var body: Color = stone[0]
	var crown: Color = stone[1]
	var groups: int = 0
	var per_group: int = 0
	match _vp_theme:
		Env.FOREST:
			groups = 3
			per_group = 1
		Env.COAST:
			groups = 0
			per_group = 0
		Env.MOUNTAIN:
			groups = 5
			per_group = 1
		_:
			groups = 2
			per_group = 1
	# A handful of hero crags, and only for the biomes whose subject is rock.
	var heroes: int = 1 if _vp_theme == Env.MOUNTAIN else 0
	for group in groups:
		# Clumped, not sprinkled: a boulder field is a field because the ice
		# dropped it in lines, and an even scatter at one size reads as litter.
		var head := _basin_site(0)
		var count: int = per_group + _rng.randi_range(0, 1)
		for i in count:
			var site := _basin_site(1)
			site.x = head.x + _rng.randf_range(-26.0, 26.0)
			site.y = clampf(head.y + _rng.randf_range(-34.0, 34.0), site.y, 1.0e9)
			# Graded away from the clump head, the way talus grades down a fan.
			site.z *= lerpf(1.0, 0.45, float(i) / float(maxi(count, 1)))
			_vista_rock(site.x, _vp_side * site.y, site.z, 0.0, true, site.w)
	for i in heroes:
		var site: Vector4 = _basin_site(2)
		_vista_rock(site.x, _vp_side * site.y, site.z, 0.0, true, site.w)

func _build_basin_rocks_incremental() -> bool:
	## Same mass in the water as `_build_basin_rocks`, a clump per frame.
	##
	## Yielding inside a clump rather than between groups is deliberate: a clump is
	## the compositional unit, and a frame that publishes half of one leaves a
	## lone rock standing in open water, which is worse than the empty plane it
	## was meant to fix.
	var stone := _basin_stone()
	var body: Color = stone[0]
	var crown: Color = stone[1]
	var groups: int = 0
	var per_group: int = 0
	match _vp_theme:
		Env.FOREST:
			groups = 3
			per_group = 1
		Env.COAST:
			groups = 0
			per_group = 0
		Env.MOUNTAIN:
			groups = 5
			per_group = 1
		_:
			groups = 2
			per_group = 1
	for group in groups:
		var head := _basin_site(0)
		var count: int = per_group + _rng.randi_range(0, 1)
		for i in count:
			var site := _basin_site(1)
			site.x = head.x + _rng.randf_range(-26.0, 26.0)
			site.y = clampf(head.y + _rng.randf_range(-34.0, 34.0), site.y, 1.0e9)
			site.z *= lerpf(1.0, 0.45, float(i) / float(maxi(count, 1)))
			_vista_rock(site.x, _vp_side * site.y, site.z, 0.0, true, site.w)
		if not await _keep_streaming():
			return false
	var heroes: int = 1 if _vp_theme == Env.MOUNTAIN else 0
	for i in heroes:
		var site: Vector4 = _basin_site(2)
		_vista_rock(site.x, _vp_side * site.y, site.z, 0.0, true, site.w)

	return await _keep_streaming()


func _shore_band_tone() -> Array[Color]:
	## Wet stone and dry shingle, for the strip laid along the water's edge.
	##
	## Three values where there was one: the lake, the wet band the edge darkens
	## to, and the dry shingle above it. The brief called for a pale strip to
	## separate two near-identical luma steps, and the honest version of that is a
	## three-step ladder rather than a painted line — one bright band across a
	## shoreline that already has three of them would read as a decal.
	match _vp_theme:
		Env.FOREST:
			return [Color("4e5a4a"), Color("9aa088")]
		Env.COAST:
			return [Color("5d5a52"), Color("c8c0ac")]
		Env.MOUNTAIN:
			return [Color("5a5f62"), Color("a8aeb0")]
	return [Color("5e5442"), Color("b6a888")]


func _build_shore_strip() -> void:
	## Shingle along the far waterline — the one edge in the frame the eye is
	## actually looking for.
	##
	## The far bank is the only shoreline a seated rider can see: the near one is
	## under the lens's bottom edge, as the section header explains. So the strip
	## follows `viewpoint_far_shore` and not the near curve, which is where the
	## obvious reading of "a strip along the water" would have put it and where it
	## would have been invisible.
	##
	## The coast is excluded entirely. Its far shore is a kilometre out and barely
	## rises, so a band there would be a hairline drawn on the sea horizon — and
	## the sea horizon is the one line in that frame which is already doing its
	## job perfectly well.
	if _vp_theme == Env.COAST:
		return
	var tone := _shore_band_tone()
	var z := _vp_centre - RoadPathGD.LAKE_SPAN * 0.8
	var step := 11.0
	while z < _vp_centre + RoadPathGD.LAKE_SPAN * 0.8:
		var line: float = float(_path.viewpoint_far_shore(z, _vp_centre))
		# Broken, not ruled. A continuous band along a wobbling shore is the one
		# thing that reads as a decal rather than as ground, so the strip is laid
		# in overlapping runs with the width and the inset both varying, and the
		# gaps fall where the bank is steepest and the beach would be narrowest.
		if _rng.randf() > 0.82:
			z += step
			continue
		var len: float = _rng.randf_range(14.0, 30.0)
		var wide: float = _rng.randf_range(4.0, 8.0)
		var inset: float = _rng.randf_range(-2.5, 1.0)
		var yaw: float = _rng.randf_range(-0.06, 0.06)
		_ledges.append(
			Transform3D(
				Basis(Vector3.UP, yaw).scaled(Vector3(wide, 0.55, len)),
				_far_point(z, _vp_side * (line - 4.5 + inset), _vp_water_y + 0.28)
			)
		)
		_ledge_cols.append(tone[1])
		# The wet band, one step darker and a little further out. Without it the
		# pale strip floats on the water with nothing between, and what reads is a
		# decal laid over a lake rather than a shore.
		_ledges.append(
			Transform3D(
				Basis(Vector3.UP, yaw).scaled(Vector3(wide * 0.7, 0.35, len * 0.9)),
				_far_point(z, _vp_side * (line - 8.5 + inset), _vp_water_y + 0.16)
			)
		)
		_ledge_cols.append(tone[0])
		z += step * 0.5


func _far_ground_lift(z: float, out: float) -> float:
	## Lift that stands something on the drawn skirt beyond the far bank.
	##
	## The analytic ground under that mesh is marsh at water level for its whole
	## width and then climbs somewhere else entirely, so anything grounded on it
	## either drowns or stands behind the crest where the bench cannot see it. The
	## same correction `_far_bank_lift` makes, for the mesh past the cliff.
	return _far_ground_y(z, out) - _terrain_surface_at(z, _vp_side * out).y


func _build_far_bank_bands() -> void:
	## Three receding value bands on the far bank.
	##
	## The country overlook already does this and it is the best thing in the
	## baseline frames: three horizontal steps in value, each lighter than the one
	## in front of it, laid at increasing distance. It is not perspective and it
	## is not fog — it is three flat tones in three horizontal registers, and the
	## eye reads depth off the ordering alone. Every other baseline band in the
	## game is a single tone spread over a distance, which is why they all decay
	## to nothing by y=660.
	##
	## So this is the same device, built for the two biomes whose far bank is
	## currently one unbroken ramp. Forest gets woodland in three values; mountain
	## gets broken rock in three values. Both are one instance per band per
	## ten metres of shoreline, which is the same density the country bank runs at.
	# Alpine geology comes from the connected cliff and sparse natural talus.
	# Three rows of sphere proxies read as boulder wallpaper from the bench.
	if _vp_theme != Env.FOREST:
		return
	var z := _vp_centre - 400.0
	var band := 0
	# near-black, dark olive, mid olive-grey. Ordered light-to-dark going away is
	# wrong and is the whole trick: the far band is the palest, because that is
	# what distance does to a value.
	var forest_tones: Array[Color] = [Color("16261e"), Color("2c4634"), Color("556d55")]
	var rock_tones: Array[Color] = [Color("3a3f42"), Color("5f686c"), Color("8b9498")]
	# The three ranks: one on the bank itself, then two out on the skirt behind
	# it, each far enough back that the rank in front of it stands against it.
	var ranks: Array[float] = [16.0, 82.0, 178.0]
	while z < _vp_centre + 400.0:
		if sin((z - _vp_centre) * 0.021 + _vp_phase) < -0.18:
			z += 9.0
			continue
		for rank in 3:
			var shore: float = float(_path.viewpoint_far_shore(z, _vp_centre))
			var out: float = shore + ranks[rank] + _rng.randf_range(-14.0, 14.0)
			var zz: float = z + _rng.randf_range(-5.0, 5.0)
			if _vp_theme == Env.FOREST:
				var tall: float = _rng.randf_range(9.0, 17.0) - float(rank) * 1.4
				_tree(
					Flora.CONIFER if _rng.randf() < 0.55 else Flora.BROADLEAF,
					zz,
					_vp_side * out,
					tall,
					forest_tones[rank],
					true,
					_far_ground_lift(zz, out)
				)
			else:
				var s: float = _rng.randf_range(5.0, 13.0) + float(rank) * 3.0
				_blob(
					zz,
					_vp_side * out,
					Vector3(s * 1.5, s * 0.9, s * 1.3),
					rock_tones[rank],
					_far_ground_lift(zz, out),
					false,
					true,
					false
				)
		z += 9.0
		band += 1


func _far_bank_ground_tone() -> Array[Color]:
	## Near-shore and inland values for the ground forms standing on the far bank.
	## Two steps, because the job is a ladder and not a pair of accents: the near
	## end reads as ground catching the low sun over the shoulder of the bank, the
	## far end as the shadowed hollows behind it.
	##
	## Cool, and only a step above the field they stand on. The first attempt at
	## this laddered the other way — a pale apron right behind the shoreline — and
	## under a `ff9e62` key a pale warm albedo is a salmon one, so the apron came
	## out as a row of pink pancakes lying on the bank: the pearl effect wearing a
	## different hat. These are rock and scrub in the shade of a hill. They have to
	## separate from the ground they sit on without competing with the water.
	match _vp_theme:
		Env.FOREST:
			return [Color("515e48"), Color("212c22")]
		Env.MOUNTAIN:
			return [Color("586160"), Color("2a3133")]
		Env.COUNTRY:
			return [Color("605e42"), Color("2e3424")]
	return [Color("434c3d"), Color("242a21")]


func _build_far_bank_ground() -> void:
	## Low masses on the ground between the shoreline and the treeline.
	##
	## No incremental twin, and that is deliberate: this is called from
	## `_dress_vista`, which the sync builder and the streaming path already
	## share, so there is nothing to keep in step. The stages that carry twins
	## are the ones that build meshes across frames; this only appends instances
	## to buckets the commit pass already owns.
	##
	## The band it fills is the dead one. `_build_far_ground` lays a skirt of
	## eight-by-sixty-four quads from fifty metres behind the shore strip out to
	## seven hundred and seventy, and for mountain and country that mesh is drawn
	## unshaded — the vertex colour *is* the surface. A pass with nothing on it
	## arrived as one flat grey-mauve wedge across the middle fifth of the
	## seated frame, in mountain, in forest and in country. Vertex colour alone
	## cannot fix that: eight value steps spread over seven hundred metres are
	## one tone at this distance. The ground needs things standing on it.
	##
	## Clumped, graded and gappy, because the obvious version of this was tried
	## and undone. Evenly sized lumps at even intervals along the waterline, all
	## in one value, read as a string of pearls — beads on a wire, not ground —
	## and no amount of count fixes that, because the defect is the *regularity*.
	## So: a head per clump with a spread that widens and a size that falls off
	## with distance from it, each clump carrying its own value, the sizes running
	## wide and low so they read as risers and swells rather than as spheres, and
	## bare ground left between the clumps. The gaps are the point; they are what
	## tells the eye the clumps are ground rather than a row.
	##
	## The coast is left alone. Its far shore is a kilometre out and barely
	## rises, so there is no band to fill — only a sea horizon, which is already
	## doing its job and must not be given gravel.
	if _vp_theme == Env.COAST:
		return
	var tone := _far_bank_ground_tone()
	var pale: Color = tone[0]
	var dark: Color = tone[1]
	var z0 := _vp_centre - RoadPathGD.LAKE_SPAN
	var z_span: float = RoadPathGD.LAKE_SPAN * 2.0
	# The inner edge sits just behind the cliff wall's own back edge so nothing
	# pokes through the shoreline strip, and the outer edge stops well short of
	# the ranges so the mid-ground is filled without crowding the skyline.
	const NEAR_OFFSET := 52.0
	const FAR_OFFSET := 330.0
	var groups: int = 14 if _vp_theme == Env.MOUNTAIN else (12 if _vp_theme == Env.FOREST else 11)
	for group in groups:
		# One clump per slot along the route, jittered so the slots do not read
		# as slots. An even row of clumps is the pearl effect wearing a hat.
		var head_z: float = (
			z0 + (float(group) + 0.5) / float(groups) * z_span + _rng.randf_range(-0.62, 0.62) * z_span / float(groups)
		)
		# Square-rooted, so the clumps spread up the bank instead of all queueing
		# against the waterline where they would draw a second shoreline.
		var head_out: float = (
			float(_path.viewpoint_far_shore(head_z, _vp_centre))
			+ lerpf(NEAR_OFFSET, FAR_OFFSET, sqrt(_rng.randf()))
		)
		# Big and wide at the head, shrinking outward, and one clump in four gets
		# no head at all — just the debris around where one would have been.
		var head_scale: float = 0.0 if _rng.randf() < 0.24 else _rng.randf_range(0.8, 1.5)
		var members: int = _rng.randi_range(5, 9)
		for i in members:
			var run: float = float(i) / float(members)
			var z: float = head_z + _rng.randf_range(-1.0, 1.0) * (16.0 + run * 44.0)
			var out: float = head_out + _rng.randf_range(-1.0, 1.0) * (7.0 + run * 40.0)
			if out < float(_path.viewpoint_far_shore(z, _vp_centre)) + NEAR_OFFSET * 0.7:
				continue
			if _far_ground_y(z, out) < _vp_water_y + 2.5:
				continue
			# Two sizes in every clump and a third of them small. Size variety is
			# the strongest thing against the pearl reading there is: nothing in a
			# real talus field is the same size as its neighbour twice running, and
			# a field of identically sized lumps has no scale in it at all.
			var fine: bool = _rng.randf() < 0.34
			var s: float = (_rng.randf_range(3.5, 6.5) if fine else _rng.randf_range(11.0, 23.0))
			s *= head_scale / (1.0 + run * 1.2)
			# Value runs a step lighter at the waterline and darkens inland —
			# distance lifting a tone is the one depth cue this band has left once
			# the sun is down — and then every member takes its own drop, because a
			# clump whose stones all match each other is the other half of the
			# regularity that makes a scatter read as beads.
			var depth: float = clampf((out - head_out + FAR_OFFSET) / FAR_OFFSET, 0.0, 1.0)
			var col: Color = pale.lerp(dark, clampf(depth, 0.0, 1.0)).darkened(_rng.randf() * 0.30)
			# One in five is left pale. The band needs a top value as well as a
			# bottom one or it is still one tone, and a lit face here is a warm
			# face — a handful of them reads as scree catching the last of the sun,
			# where a whole apron of them read as salmon laid on a bank.
			if _rng.randf() < 0.2:
				col = pale.lightened(_rng.randf() * 0.14)
			# Big enough to be ground and low enough not to be a skyline: height is
			# a third of the width, so a member overlaps its neighbours in plan and
			# the clump closes into one mass instead of a row of separate lumps.
			# Two in five are laid as faceted slabs rather than swells — every form
			# on this bank round, and every form the same roundness, is a texture
			# tiled with one stamp.
			if _rng.randf() < 0.4:
				_ledges.append(
					Transform3D(
						Basis(Vector3.UP, _rng.randf_range(0.0, TAU)).scaled(
							Vector3(s * 2.0, s * 0.62, s * 1.6)
						),
						_far_point(z, _vp_side * out, _far_ground_y(z, out) - s * 0.24)
					)
				)
				_ledge_cols.append(col)
				continue
			_blob(
				z,
				_vp_side * out,
				Vector3(s * 1.9, s * 0.72, s * 1.55),
				col,
				_far_ground_lift(z, out),
				false,
				true,
				false
			)


func _build_vista_accent() -> void:
	## One bright diagonal per overlook.
	##
	## Every band in these frames is horizontal — treelines, banks, shorelines,
	## the water's own edge — which is exactly why they read as stripes rather
	## than as places. A single diagonal running out of the near foreground and
	## away across the middle distance is the cheapest thing in the file that
	## breaks the stripes, and one per overlook is enough: two would be a
	## crossroads.
	##
	## What each biome spends its one diagonal on is the thing it is actually
	## about. Mountain gets a snow gully down the face of the far bank, because
	## the alternative is more horizontal rock. Country gets a hedgerow running
	## down to the water, because country is fields seen edge-on. Coast gets a
	## headland spur entering from the lower left, which is the only thing that
	## can be added to that frame without touching the sea horizon. Forest gets a
	## gravel spit, because a flooded valley floor has bars in it and a wood has
	## no diagonals.
	var stone := _basin_stone()
	match _vp_theme:
		Env.MOUNTAIN:
			# A snow-filled gully down the bank, running from high on the fell to
			# the waterline. Built on the drawn far bank rather than the analytic
			# one, for the reason `_far_ground_lift` exists.
			var z0: float = _vp_centre + _rng.randf_range(-160.0, -60.0)
			var side := 1.0 if _rng.randf() < 0.5 else -1.0
			var start_out: float = float(_path.viewpoint_far_shore(z0, _vp_centre)) + 46.0
			for i in 9:
				var t: float = float(i) / 8.0
				var zz: float = z0 + side * t * 190.0
				var shore: float = float(_path.viewpoint_far_shore(zz, _vp_centre))
				var out: float = lerpf(start_out, shore - 2.0, t)
				var rise := _far_bank_rise(zz, out)
				if rise < 1.0:
					continue
				var w: float = lerpf(3.0, 15.0, t)
				_ledges.append(
					Transform3D(
						Basis(Vector3.UP, lerpf(0.34, 0.10, t) * side).scaled(
							Vector3(w, 0.5, 26.0 - t * 8.0)
						),
						_far_point(zz, _vp_side * out, _vp_water_y + rise - 0.35)
					)
				)
				_ledge_cols.append(Color("dfe6ec").lerp(Color("9aa2a4"), t * 0.5))
		Env.COUNTRY:
			# A hedgerow running down the near face into the water. Fields read as
			# fields because of their boundaries, and from ninety metres up the only
			# boundary that crosses the frame at an angle is one that runs away from
			# the viewer.
			var z0: float = _vp_centre + _rng.randf_range(-200.0, -120.0)
			var side2 := 1.0 if _rng.randf() < 0.5 else -1.0
			for i in 14:
				var t: float = float(i) / 13.0
				var zz: float = z0 + side2 * t * 260.0
				var near: float = float(_path.viewpoint_near_shore(zz))
				var out: float = lerpf(float(_path.headland_crest(zz)) - 4.0, near + 26.0, t)
				var s: float = lerpf(3.2, 8.5, t)
				var ground: float = _terrain_surface_at(zz, _vp_side * out).y
				if ground < _vp_water_y + 0.5:
					continue
				_blob(
					zz,
					_vp_side * out,
					Vector3(s * 1.6, s * 0.9, s * 4.5),
					Color("22341f").lerp(Color("3d5233"), _rng.randf() * 0.5),
					_face_ground_lift(zz, out),
					true,
					true
				)
		Env.COAST:
			# The natural stack group carries this composition.
			pass
		_:
			# The forest peninsula provides a continuous natural diagonal.
			pass


const SCREE_FANS := 3
const SCREE_PER_FAN := 8


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
	var z0 := _vp_centre - LENGTH * 0.5
	var face_run: float = maxf(
		float(_path.viewpoint_near_shore(_vp_centre)) - float(_path.headland_crest(_vp_centre)) - 8.0, 24.0
	)
	for _fan in (SCREE_FANS if _vp_theme == Env.COAST else (SCREE_FANS * 2 if _vp_theme == Env.MOUNTAIN else SCREE_FANS)):
		_build_face_scree_fan(z0, face_run)


func _build_face_scree_fan(z0: float, face_run: float) -> void:
	# Source of the fan: a point high on the face, in this chunk.
	var head_z: float = z0 + _rng.randf_range(0.0, LENGTH)
	var head_out: float = float(_path.headland_crest(head_z)) + 3.0 + _rng.randf_range(0.0, face_run * 0.35)
	var spread: float = _rng.randf_range(9.0, 22.0)
	for _i in SCREE_PER_FAN:
		# Fall line, biased downslope, spreading as it goes.
		var run: float = _rng.randf() * _rng.randf()  # bunched near the head
		var out: float = head_out + run * (face_run - (head_out - float(_path.headland_crest(z0))))
		var z: float = head_z + _rng.randf_range(-1.0, 1.0) * spread * (0.35 + run)
		var above := _height_above_water(z, out)
		if above < 1.0 or not _face_above_water(z, out, 0.6) or float(_path.spur_deck_blend(z, _vp_side * out)) > 0.15:
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
			_face_ground_lift(z, out),
			false,
			true
		)


func _face_chord_point(z: float, out: float) -> Vector3:
	## The surface the terrain ribbon actually *draws* at this spot on the
	## headland face: the straight chord between the mesh's own lateral edge
	## vertices. The analytic surface and the rendered strip sit metres apart on
	## this profile — dressing placed on the analytic one ends up underneath the
	## drawn slope, which is what buried every earlier attempt at face detail.
	var side := _vp_side
	for band in _view_bands():
		var e0: float = float(band[0])
		var e1: float = float(band[2])
		var u0 := e0 * side
		var u1 := e1 * side
		var lo := minf(u0, u1)
		var hi := maxf(u0, u1)
		if out < lo or out > hi or hi - lo < 0.01:
			continue
		var pa := _p(z, e0, _band_drop(z, e0, float(band[1])))
		var pb := _p(z, e1, _band_drop(z, e1, float(band[3])))
		return pa.lerp(pb, (out - u0) / (u1 - u0))
	return _p(z, side * out, 0.0)


func _face_ground_lift(z: float, out: float) -> float:
	## How far the rendered chord stands above the analytic surface at this
	## spot on the face — the lift anything planted on the drop needs to sit on
	## the drawn ground. On the headland profile the mesh's straight chords
	## bridge metres over the carved surface, and a tree grounded analytically
	## there was buried to its crown, which is what the dead-stick saplings
	## poking out of the face were. A small negative allowance stays so a stone
	## on a convex spot beds in rather than floats.
	var chord_y := _face_chord_point(z, out).y + _origin.y
	var ground_y := _terrain_surface_at(z, _vp_side * out).y
	return clampf(chord_y - ground_y, -0.4, 9.0)


func _face_above_water(z: float, out: float, margin: float) -> bool:
	## The waterline test the face dressing wants, taken on the rendered chord
	## rather than the analytic surface. Near the toe the two disagree by
	## metres, and a prop that clears the water on paper can still come out
	## standing in the lake.
	return _face_chord_point(z, out).y + _origin.y > _vp_water_y + margin


func _face_ledge(z: float, out: float, size: Vector3, color: Color) -> void:
	## One slab of bedded rock breaking out of the headland face. A sharp box,
	## not a boulder: its upper face lies in the slope plane, so what shows is a
	## pale bedding edge a metre proud of the face, not a plank lying on a
	## hillside. The long axis runs along the contour so a broken line of them
	## is a stratum.
	##
	## Placement is on the ribbon's rendered chord — the analytic surface sits
	## metres under the mesh on this profile, and anything planted on it ends
	## up buried.
	var flat: Basis = _path.frame_flat_at(z)
	var point := _face_chord_point(z, out)
	var down_slope := (_face_chord_point(z, out + 2.5) - point).normalized()
	var normal := down_slope.cross(flat.z).normalized()
	if normal.dot(flat.x * _vp_side) < 0.0:
		normal = -normal
	# Frame lying in the face plane: local x runs along the contour (the long
	# axis, so a run reads as a stratum), local y out of the face, local z down
	# the slope — plus a small roll so runs never align into a ruled line.
	var bx := flat.z.cross(normal).normalized()
	var bz := normal.cross(bx).normalized()
	var frame := Basis(bx, normal, bz).rotated(normal, _rng.randf_range(-0.10, 0.10))
	var scaled := Basis(frame.x * size.z, frame.y * size.y, frame.z * size.x)
	_ledges.append(Transform3D(scaled, point + normal * (size.y * 0.55)))
	_ledge_cols.append(color)


func _build_face_ledges() -> void:
	## Broken lines of rock shelves at the stratum boundaries — the crisp edge
	## the vertex-colour bands cannot draw at seven-metre vertex spacing. The
	## eye reads geology from the lit top edge of a shelf against the shadowed
	## seam under it; a smooth gradient, however wide the values swing, is a
	## dune. The coast's headland is a sand scarp rather than bedded rock, so
	## it keeps none.
	if _vp_theme == Env.COAST:
		return
	var z0 := float(chunk_index) * LENGTH
	# Three runs sit at fractions down the face, so the built ledges and the
	# benched profile describe the same geology: a broken brow just under the
	# lip, a long pale shelf mid-face, and a second shelf where the dark seam
	# gives way to the talus. The lip moves along the route now that the top
	# tapers, so the runs measure off the crest at each z, not a constant.
	for run in [0.16, 0.42, 0.66]:
		var z := z0 + _rng.randf_range(0.0, 6.0)
		while z < z0 + LENGTH - 4.0:
			var near: float = float(_path.viewpoint_near_shore(z))
			var top := float(_path.headland_crest(z)) - 6.0
			var out: float = top + (run + _rng.randf_range(-0.05, 0.05)) * (near - top)
			var above := _height_above_water(z, out)
			if above < 4.0 or not _face_above_water(z, out, 2.5) or float(_path.spur_deck_blend(z, _vp_side * out)) > 0.15:
				z += _rng.randf_range(4.0, 8.0)
				continue
			var slab := Vector3(
				_rng.randf_range(2.6, 4.4),
				_rng.randf_range(0.9, 1.7),
				_rng.randf_range(8.0, 15.0)
			)
			var tone := Color("8a8072").lerp(Color("6a6258"), _rng.randf())
			if _vp_theme == Env.MOUNTAIN:
				tone = Color("8a9096").lerp(Color("5c6268"), _rng.randf())
			elif _vp_theme == Env.FOREST:
				tone = Color("8d8271").lerp(Color("655c4e"), _rng.randf())
			elif _vp_theme == Env.COUNTRY:
				tone = Color("9a8c74").lerp(Color("6f6350"), _rng.randf())
			_face_ledge(z, out, slab, tone)
			z += slab.z * _rng.randf_range(0.72, 0.95) + _rng.randf_range(2.0, 7.0)


func _far_cliff_tone() -> Array[Color]:
	## Scarp, waterline and lip for the far-shore cliff wall. One definition, read
	## by both `_build_far_cliffs` and its streaming twin, because the pair used
	## to be written out twice and a palette duplicated by hand is exactly the
	## thing that ends up with the sync lookoff and the streamed lookoff
	## disagreeing about what colour a shoreline is.
	##
	## The visual job here is to *be a shoreline and nothing else*. These three
	## quads run the whole width of every seated frame, they are the flattest
	## surfaces in it, and the dusk sun rakes straight into them — so whatever
	## albedo they carry arrives multiplied by the entire key, which is `ff9e62`
	## at 5.5. Nothing else in the frame gets that much of a single hue.
	##
	## That is why they were the loudest thing in the picture. Warm-dark stone
	## under a saturated orange key does not arrive as warm-dark stone: `52463a`
	## measured off the dusk mountain capture came out at (190, 103, 63) — sat
	## 0.68, the most saturated surface in a frame whose actual subject is a
	## lake, with a near-fluorescent strip round it in the other biomes. The eye
	## went to the edge of the water instead of into it.
	##
	## So all three come down and go cool: damp rock in the shadow of its own
	## bank, a step apart rather than three, with the waterline step darkest. The
	## band still separates lake from land, but it does it on hue — rust against
	## blue — instead of on value, which is all a lit surface under this key can
	## offer. The band is meant to be found, not stopped at.
	##
	## Cool is doing as much work here as dark, and not only because it sits
	## opposite the key. It also un-breaks the land: the far bank behind it is
	## warm, and a cool edge against warm ground is what tells the eye which of
	## the two is nearer.
	## The one thing albedo cannot serve here is both moods at once. These are lit
	## surfaces, so one albedo answers to the whole key in every mood: the values
	## that make the band quiet under the dusk key are the values that leave it a
	## black void under the much stronger night fill (3.6 at 64 degrees against
	## dusk's 0.52), and the values that keep a moonlit shoreline read at night
	## measured 0.30 linear luminance in the dusk capture. Chasing both would mean
	## giving Defect 1 straight back. What is left here is the compromise — a band
	## that still has a value, and a shoreline that is carried at night by the
	## bank's own silhouette and the water's edge rather than by a pale beach.
	match _vp_theme:
		Env.FOREST:
			return [Color("1b231d"), Color("141b16"), Color("35433a")]
		Env.MOUNTAIN:
			return [Color("282e32"), Color("1f2528"), Color("474f52")]
		Env.COUNTRY:
			# Ochre rather than grey, and still the darkest land in the frame: the
			# composition rests on warm land against cool water, and it rests on
			# the *water* being the subject, so this stays a value and not a hue.
			return [Color("3d382c"), Color("2e2c24"), Color("5a543e")]
	return [Color("28261f"), Color("21201b"), Color("3c372c")]


func _build_far_cliffs() -> void:
	## Continuous far-shore scree with a pass in the middle of the view, owned once.
	if _vp_theme == Env.COAST:
		return
	var z0 := _vp_centre - RoadPathGD.LAKE_SPAN
	var z_span: float = RoadPathGD.LAKE_SPAN * 2.0
	var b := LowPoly.new()
	var tone := _far_cliff_tone()
	var face: Color = tone[0]
	var wet: Color = tone[1]
	var lip: Color = tone[2]
	var rises := _far_cliff_rises()
	var pass_rise: float = rises.x
	var fell_rise: float = rises.y
	var built := false
	var t := z0
	while t < z0 + z_span - 0.4:
		var t1: float = minf(t + 13.0, z0 + z_span)
		_cliff_span(b, t, t1, _far_scree_rise(t, pass_rise, fell_rise), _far_scree_rise(t1, pass_rise, fell_rise), face, wet, lip)
		built = true
		t = t1
	if not built:
		return
	var mesh: MeshInstance3D = b.commit_to(self, "ViewpointCliffs")
	if mesh:
		mesh.material_override = LowPoly.terrain_material()
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mesh.visibility_range_end = 0.0


func _build_far_cliffs_incremental() -> void:
	if _vp_theme == Env.COAST:
		return
	var z0 := _vp_centre - RoadPathGD.LAKE_SPAN
	var z_span: float = RoadPathGD.LAKE_SPAN * 2.0
	var b := LowPoly.new()
	var tone := _far_cliff_tone()
	var face: Color = tone[0]
	var wet: Color = tone[1]
	var lip: Color = tone[2]
	var rises := _far_cliff_rises()
	var pass_rise: float = rises.x
	var fell_rise: float = rises.y
	var built := false
	var t := z0
	while t < z0 + z_span - 0.4:
		var t1: float = minf(t + 13.0, z0 + z_span)
		_cliff_span(b, t, t1, _far_scree_rise(t, pass_rise, fell_rise), _far_scree_rise(t1, pass_rise, fell_rise), face, wet, lip)
		built = true
		t = t1
		if not await _keep_streaming():
			return
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
	# Keep the far bank as a framing lip, not a vertical wall in the seated lens.
	return maxf(base * (1.0 + fold), pass_rise * 0.5) * 0.72


func _cliff_span(
	b: LowPoly,
	za: float,
	zb: float,
	h_a: float,
	h_b: float,
	face: Color,
	wet: Color,
	lip: Color
) -> void:
	# Broken along the route before anything else happens to it. A shoreline drawn
	# at one value for a kilometre is a stripe, and a stripe across the middle of
	# a lake is a decal however well its value is chosen; what makes a bank read
	# as a bank is that it goes into shadow somewhere and comes back out. The
	# function is a pure function of the route position and the overlook's own
	# phase rather than an RNG draw, so the sync wall and the streamed wall break
	# in exactly the same places.
	var weather: float = 0.5 + 0.5 * sin(za * 0.0231 + _vp_phase) * sin(za * 0.0082 - _vp_phase * 1.7)
	face = face.darkened(0.30 * (1.0 - weather))
	wet = wet.darkened(0.24 * (1.0 - weather))
	lip = lip.darkened(0.26 * (1.0 - weather))
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
	var scarp := wet
	var crown := lip
	var ledge_col := face
	if _vp_theme == Env.MOUNTAIN:
		# Alpine turf where the bank is low — ochre rock along the pass read as a
		# dam laid across the lake — bare rock higher, and real snowfields on
		# the summits at either end. The ledge takes snow only on the highest
		# spans, so the scarp under it stays rock and the peaks keep their form.
		var h: float = maxf(h_a, h_b)
		crown = Color("4f5d3e").lerp(lip, smoothstep(24.0, 70.0, h))
		crown = crown.lerp(Color("eef2f6"), smoothstep(60.0, 115.0, h) * 0.92)
		ledge_col = face.lerp(Color("dfe6ec"), smoothstep(95.0, 150.0, h) * 0.6)
	if _vp_side > 0.0:
		b.add_quad_shaded(water_a, ledge_a, ledge_b, water_b, scarp, ledge_col, ledge_col, scarp)
		b.add_quad_shaded(ledge_a, crown_a, crown_b, ledge_b, ledge_col, crown, crown, ledge_col)
		b.add_quad_shaded(crown_a, back_a, back_b, crown_b, crown, scarp, scarp, crown)
	else:
		b.add_quad_shaded(water_b, ledge_b, ledge_a, water_a, scarp, ledge_col, ledge_col, scarp)
		b.add_quad_shaded(ledge_b, crown_b, crown_a, ledge_a, ledge_col, crown, crown, ledge_col)
		b.add_quad_shaded(crown_b, back_b, back_a, crown_a, crown, scarp, scarp, crown)


func _build_far_shore() -> void:
	## Banks well above the water, distributed across the complete owner basin.
	var z0 := _vp_centre - RoadPathGD.LAKE_SPAN
	var z_span: float = RoadPathGD.LAKE_SPAN * 2.0
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
			var z := z0 + _rng.randf_range(0.0, z_span)
			if absf(z - _vp_centre) < keep_out:
				continue
			var out: float = float(_path.viewpoint_far_shore(z, _vp_centre)) + _rng.randf_range(8.0, 40.0)
			if _far_bank_rise(z, out) < min_height:
				continue
			var tint := Color("162820").lerp(Color("24362c"), _rng.randf() * 0.3)
			var species: int = Flora.BROADLEAF if _vp_theme == Env.COUNTRY else Flora.CONIFER
			if _vp_theme == Env.FOREST and _rng.randf() < 0.5:
				species = Flora.BROADLEAF
			elif _vp_theme == Env.MOUNTAIN and _rng.randf() < 0.55:
				species = Flora.PINE
			var tall: float = _rng.randf_range(16.0, 28.0) if _vp_theme == Env.FOREST else (
				_rng.randf_range(7.0, 13.0) if _vp_theme == Env.MOUNTAIN else _rng.randf_range(10.0, 16.0)
			)
			_tree(species, z, _vp_side * out, tall, tint, true, _far_bank_lift(z, out))
	if _vp_theme == Env.FOREST:
		# A close-set rank right on the bank, so the far side reads as woodland
		# to the water — a treeline, not speckle on a fell. Mixed crowns keep it
		# from reading as a wall of spikes.
		#
		# Stepped to seven metres and grown taller than it used to be. At eleven
		# the crowns did not touch and the rank read as scattered dots on a green
		# ramp, which is the thing this whole pass exists to stop being.
		var tz := z0 + 4.0
		while tz < z0 + z_span:
			if absf(tz - _vp_centre) > 34.0 and sin((tz - _vp_centre) * 0.018 + _vp_phase) > -0.28:
				var tout: float = float(_path.viewpoint_far_shore(tz, _vp_centre)) + _rng.randf_range(8.0, 30.0)
				if _far_bank_rise(tz, tout) >= 2.5:
					_tree(
						Flora.CONIFER if _rng.randf() < 0.6 else Flora.BROADLEAF,
						tz,
						_vp_side * tout,
						_rng.randf_range(13.0, 24.0),
						Color("14261e").lerp(Color("1e332a"), _rng.randf()),
						true,
						_far_bank_lift(tz, tout)
					)
			tz += 7.0
	_build_far_shore_groves()
	for _i in (14 if _vp_theme == Env.MOUNTAIN else 7):
		var z := z0 + _rng.randf_range(0.0, z_span)
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


func _build_far_shore_groves() -> void:
	if _vp_theme not in [Env.FOREST, Env.COUNTRY]:
		return
	var packed: PackedScene = load("res://scenes/lookout_grove.tscn")
	var count: int = 13 if _vp_theme == Env.FOREST else 5
	for i in count:
		var u: float = (float(i) + 0.5 + 0.35 * sin(float(i) * 2.7 + _vp_phase)) / float(count)
		var z: float = _vp_centre + lerpf(-1000.0, 1000.0, u)
		var depth: float = 140.0 + 45.0 * sin(float(i) * 2.7)
		if _vp_theme == Env.FOREST:
			# Interleave lower woodland, middle slopes and distant stands.
			depth = [105.0, 280.0, 480.0][i % 3] + 35.0 * sin(float(i) * 2.7)
		var out: float = float(_path.viewpoint_far_shore(z, _vp_centre)) + depth
		var grove: Node3D = packed.instantiate()
		grove.name = "LookoutGrove_%d" % i
		var flat: Basis = _path.frame_flat_at(_vp_centre)
		var grove_scale: float = (0.65 if _vp_theme == Env.COUNTRY else 1.0) * lerpf(0.65, 1.0, 0.5 + 0.5 * sin(float(i) * 1.9 + _vp_phase))
		var base_y: float = _far_ground_y(z, out) - 1.0
		# Every grove turned its own way. Thirteen copies of one stand at one
		# heading were the same ring of trees stamped down the valley.
		var turn := Basis(Vector3.UP, fposmod(float(i) * 2.39996 + _vp_phase, TAU))
		grove.transform = Transform3D((flat * turn).scaled(Vector3.ONE * grove_scale), _far_point(z, _vp_side * out, base_y))
		# Conform each reused model to this site's terrain without sharing mutable
		# transforms with another grove. Trunk/crown pairs keep identical bases.
		for part in grove.get_children():
			if part is MultiMeshInstance3D:
				part.multimesh = part.multimesh.duplicate()
				for tree_index in part.multimesh.instance_count:
					var tree_transform: Transform3D = part.multimesh.get_instance_transform(tree_index)
					var turned: Vector3 = turn * tree_transform.origin
					var tree_z: float = z + turned.z * grove_scale
					var tree_out: float = out + _vp_side * turned.x * grove_scale
					tree_transform.origin.y += (_far_ground_y(tree_z, tree_out) - base_y) / grove_scale
					part.multimesh.set_instance_transform(tree_index, tree_transform)
		add_child(grove)


func _far_cliff_rises() -> Vector2:
	## Pass and fell height of the far-shore scree, per biome. Shared by the mesh
	## and everything planted on it, so the two cannot disagree.
	match _vp_theme:
		Env.FOREST:
			return Vector2(36.0, 88.0)
		Env.MOUNTAIN:
			return Vector2(18.0, 168.0)
		Env.COUNTRY:
			return Vector2(22.0, 72.0)
	return Vector2(10.0, 58.0)


func _far_bank_rise(z: float, out: float) -> float:
	## Height above the water of the *drawn* far bank — the ViewpointCliffs
	## profile — at this distance out, or -1 off it. The analytic terrain under
	## that mesh is marsh at water level for the first twenty metres and climbs
	## somewhere else entirely, so trees grounded on it either drowned or stood
	## behind the crest where the bench cannot see them.
	var rises := _far_cliff_rises()
	var h: float = _far_scree_rise(z, rises.x, rises.y)
	var d: float = out - float(_path.viewpoint_far_shore(z, _vp_centre))
	if d < -3.0 or d > 48.0:
		return -1.0
	if d < 6.0:
		return h * 0.58 * (d + 3.0) / 9.0
	if d < 22.0:
		return h * lerpf(0.58, 1.0, (d - 6.0) / 16.0)
	return h * lerpf(1.0, 0.42, (d - 22.0) / 26.0)


func _far_bank_lift(z: float, out: float) -> float:
	## `_tree` lift that stands a tree on the drawn far bank, bedded in a little
	## so a trunk on the slope does not show daylight under its downhill side.
	var bank_y: float = _vp_water_y + _far_bank_rise(z, out) - 0.4
	return bank_y - _terrain_surface_at(z, _vp_side * out).y


func _build_far_shore_incremental() -> void:
	var z0 := _vp_centre - RoadPathGD.LAKE_SPAN
	var z_span: float = RoadPathGD.LAKE_SPAN * 2.0
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
		for i in tree_count:
			var z := z0 + _rng.randf_range(0.0, z_span)
			if absf(z - _vp_centre) < keep_out:
				continue
			var out: float = float(_path.viewpoint_far_shore(z, _vp_centre)) + _rng.randf_range(8.0, 40.0)
			if _far_bank_rise(z, out) < min_height:
				continue
			var tint := Color("162820").lerp(Color("24362c"), _rng.randf() * 0.3)
			var species: int = Flora.BROADLEAF if _vp_theme == Env.COUNTRY else Flora.CONIFER
			if _vp_theme == Env.FOREST and _rng.randf() < 0.5:
				species = Flora.BROADLEAF
			elif _vp_theme == Env.MOUNTAIN and _rng.randf() < 0.55:
				species = Flora.PINE
			var tall: float = _rng.randf_range(16.0, 28.0) if _vp_theme == Env.FOREST else (
				_rng.randf_range(7.0, 13.0) if _vp_theme == Env.MOUNTAIN else _rng.randf_range(10.0, 16.0)
			)
			_tree(species, z, _vp_side * out, tall, tint, true, _far_bank_lift(z, out))
			if i % 8 == 7 and not await _keep_streaming():
				return
		if not await _keep_streaming():
			return
		if _vp_theme == Env.FOREST:
			# Same close-set bank rank as the sync path.
			var tz := z0 + 4.0
			while tz < z0 + z_span:
				if absf(tz - _vp_centre) > 34.0 and sin((tz - _vp_centre) * 0.018 + _vp_phase) > -0.28:
					var tout: float = float(_path.viewpoint_far_shore(tz, _vp_centre)) + _rng.randf_range(8.0, 30.0)
					if _far_bank_rise(tz, tout) >= 2.5:
						_tree(
							Flora.CONIFER if _rng.randf() < 0.6 else Flora.BROADLEAF,
							tz,
							_vp_side * tout,
							_rng.randf_range(13.0, 24.0),
							Color("14261e").lerp(Color("1e332a"), _rng.randf()),
							true,
							_far_bank_lift(tz, tout)
						)
				tz += 7.0
			if not await _keep_streaming():
				return
	_build_far_shore_groves()
	if not await _keep_streaming():
		return
	for i in (14 if _vp_theme == Env.MOUNTAIN else 7):
		var z := z0 + _rng.randf_range(0.0, z_span)
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
## the engine's aerial perspective, which the riding fog already carries.
## `left` and `right` are where this layer's two shoulders stand, as an offset
## along the route from the centre of the view. They are not decoration: the
## composition is a col you look *through*, and a col is only legible if it has
## a defined summit on either side of it. Leaving the shoulders to the general
## run of tents meant whether the pass read at all came down to which way the
## per-layer phase happened to fall, and on most seeds it did not read.
##
## Every layer, backslope included, stands inside the riding clip
## (HorizonMountains.CLIP_FAR) from the bench. The skyline ring carries the
## distance beyond that, and the camera never changes its clip on arrival — so
## the view you ride up to is the view you sit down in. Haze follows distance
## on the same scale as the ring's layers, so the two interleave as one range.
const RANGE_LAYERS := [
	{"lateral": 900.0, "height": 220.0, "spread": 55.0, "width": 420.0, "haze": 0.02, "pass_width": 440.0, "left": -320.0, "right": 460.0, "cliff": false},
	{"lateral": 1300.0, "height": 280.0, "spread": 65.0, "width": 520.0, "haze": 0.10, "pass_width": 500.0, "left": -460.0, "right": 280.0, "cliff": false},
	{"lateral": 1700.0, "height": 340.0, "spread": 75.0, "width": 620.0, "haze": 0.24, "pass_width": 560.0, "left": -380.0, "right": 460.0, "cliff": false},
	{"lateral": 2100.0, "height": 400.0, "spread": 85.0, "width": 740.0, "haze": 0.40, "pass_width": 620.0, "left": -470.0, "right": 320.0, "cliff": false},
]
## Target facet size along the crest. Twenty was still fine enough to read as
## corduroy under a raking dusk key — twenty-eight gives flanks big enough to
## take a definite side of the light. The step is a *target*: strips are sized
## so they tile the chunk exactly. `int(LENGTH / 28)` left a 12 m remainder in
## every lake chunk, and from the bench the skyline was a row of stripes.
const RANGE_STEP := 28.0
## Columns per strip. The mesh is sampled finer than the strip so the crest
## keeps its notches; the strip itself still tiles the chunk exactly.
const RANGE_SUBSTEP := 2


static func range_strip_count() -> int:
	return maxi(1, int(round(LENGTH / RANGE_STEP)))


static func range_strip_length() -> float:
	return LENGTH / float(range_strip_count())


func _build_view_range() -> void:
	## Coast keeps only the far headlands: water and sky in the near field, a
	## Big Sur peninsula on the horizon. Forest/mountain/country get the lot.
	var ctx := _view_range_context()
	var b := LowPoly.new()
	b.explicit_normals = true
	for index in range(int(ctx["first_layer"]), int(ctx["last_layer"])):
		_append_view_range_layer(b, index, ctx)
	_finish_view_range(b)


func _build_view_range_incremental() -> void:
	var ctx := _view_range_context()
	var b := LowPoly.new()
	b.explicit_normals = true
	const COLUMNS_PER_FRAME := 12
	for index in range(int(ctx["first_layer"]), int(ctx["last_layer"])):
		var data: Dictionary = _new_view_range_layer(index, ctx)
		var columns: int = int(data["steps"]) + 1
		for first in range(0, columns, COLUMNS_PER_FRAME):
			_sample_view_range_columns(data, first, mini(first + COLUMNS_PER_FRAME, columns))
			if not await _keep_streaming():
				return
		for first in range(0, columns, COLUMNS_PER_FRAME):
			_shade_view_range_columns(data, first, mini(first + COLUMNS_PER_FRAME, columns))
			if not await _keep_streaming():
				return
		for first in range(0, columns - 1, COLUMNS_PER_FRAME):
			_emit_view_range_columns(b, data, first, mini(first + COLUMNS_PER_FRAME, columns - 1))
			if not await _keep_streaming():
				return
	_finish_view_range(b)


func _view_range_context() -> Dictionary:
	var first_layer := 0
	var height_mul := 1.15
	var lateral_mul := 1.0
	if _vp_theme == Env.COAST:
		first_layer = 0
		# Headlands, not sandbars. At 0.42 the islands were khaki slabs lying on
		# the sea; with the cliffed profile they stand up as white-faced points.
		height_mul = 0.70
		lateral_mul = 0.95
	# Heights are what the view is *for*. From a bench eighty metres over the
	# water a 250 m summit a kilometre out stands nine degrees above the eye —
	# a row of hills. The mountain overlook has to look up at its peaks.
	elif _vp_theme == Env.FOREST:
		height_mul = 1.10
		lateral_mul = 0.88
	elif _vp_theme == Env.MOUNTAIN:
		height_mul = 1.85
		lateral_mul = 1.08
	elif _vp_theme == Env.COUNTRY:
		height_mul = 0.46
		lateral_mul = 1.02
	var range_span: float = RANGE_REACH * 2.0
	var range_steps: int = maxi(1, int(ceil(range_span / RANGE_STEP)))
	return {
		"z0": _vp_centre - RANGE_REACH,
		"steps": range_steps,
		"step": range_span / float(range_steps),
		"base_y": _vp_water_y - 4.0,
		"first_layer": first_layer,
		"last_layer": 2 if _vp_theme == Env.COAST else RANGE_LAYERS.size(),
		"height_mul": height_mul,
		"lateral_mul": lateral_mul,
	}


func _append_view_range_layer(b: LowPoly, index: int, ctx: Dictionary) -> void:
	var data: Dictionary = _new_view_range_layer(index, ctx)
	_sample_view_range_columns(data, 0, int(data["steps"]) + 1)
	_shade_view_range_columns(data, 0, int(data["steps"]) + 1)
	_emit_view_range_columns(b, data, 0, int(data["steps"]))


func _new_view_range_layer(index: int, ctx: Dictionary) -> Dictionary:
	var z0: float = float(ctx["z0"])
	var height_mul: float = float(ctx["height_mul"])
	var lateral_mul: float = float(ctx["lateral_mul"])
	var base_y: float = float(ctx["base_y"])
	var layer: Dictionary = RANGE_LAYERS[index]
	var phase: float = float(posmod(hash(Vector2i(index, int(_path.world_seed))), 1000)) * 0.00628
	var fade: float = layer["haze"]
	## Twice as many columns as strips: the crest is the only edge the eye
	## follows at this range, and a 28 m chord cut every notch into a straight.
	var substeps: int = RANGE_SUBSTEP if index < 2 else 1
	var steps: int = int(ctx.get("steps", range_strip_count())) * substeps
	var step: float = float(ctx.get("step", range_strip_length())) / float(substeps)
	var stack: float = 1.0
	if _vp_theme == Env.MOUNTAIN:
		stack = 1.0 + 0.14 * float(index)
	elif _vp_theme == Env.COUNTRY:
		stack = 1.0 - 0.10 * float(index)
	var top: float = maxf(float(layer["height"]) * height_mul * stack, 1.0)
	var profile := _range_profile()
	var cols: Array[PackedVector3Array] = []
	var norms: Array[PackedVector3Array] = []
	var tones: Array[PackedColorArray] = []
	return {"z0": z0, "height_mul": height_mul, "lateral_mul": lateral_mul,
		"base_y": base_y, "layer": layer, "phase": phase, "fade": fade,
		"steps": steps, "step": step, "stack": stack, "top": top,
		"profile": profile, "index": index, "cols": cols, "norms": norms, "tones": tones,
		"crest_h": PackedFloat32Array()}


func _sample_view_range_columns(data: Dictionary, first: int, end: int) -> void:
	var cols: Array[PackedVector3Array] = data["cols"]
	var crest_h: PackedFloat32Array = data["crest_h"]
	for i in range(first, end):
		var z: float = float(data["z0"]) + float(data["step"]) * float(i)
		var sample: Vector2 = _range_sample(z, data["layer"], float(data["phase"]), int(data["index"]))
		sample.x *= float(data["height_mul"]) * float(data["stack"])
		sample.y *= float(data["lateral_mul"])
		cols.append(_range_column(z, sample, data["layer"], float(data["base_y"]), float(data["phase"]), data["profile"]))
		crest_h.append(sample.x)
	data["crest_h"] = crest_h


func _shade_view_range_columns(data: Dictionary, first: int, end: int) -> void:
	var cols: Array[PackedVector3Array] = data["cols"]
	var norms: Array[PackedVector3Array] = data["norms"]
	var tones: Array[PackedColorArray] = data["tones"]
	for i in range(first, end):
		var ns := PackedVector3Array()
		var cs := PackedColorArray()
		var z: float = float(data["z0"]) + float(data["step"]) * float(i)
		for k in cols[i].size():
			ns.append(_range_normal(cols, i, k))
			var lift: float = clampf((cols[i][k].y - float(data["base_y"])) / float(data["top"]), 0.0, 1.0)
			var grit: float = 0.5 + 0.5 * sin(z * 0.031 + float(k) * 2.3 + float(data["phase"]) * 3.1)
			cs.append(Color(0.0, grit, lift, float(data["fade"])))
		norms.append(ns)
		tones.append(cs)


func _emit_view_range_columns(b: LowPoly, data: Dictionary, first: int, end: int) -> void:
	var cols: Array[PackedVector3Array] = data["cols"]
	var norms: Array[PackedVector3Array] = data["norms"]
	var tones: Array[PackedColorArray] = data["tones"]
	var crest_h: PackedFloat32Array = data["crest_h"]
	for i in range(first, end):
		if crest_h[i] < 0.5 and crest_h[i + 1] < 0.5:
			continue
		var ca: PackedVector3Array = cols[i]
		var cb: PackedVector3Array = cols[i + 1]
		for k in ca.size() - 1:
			_range_quad_n(b, [ca[k], ca[k + 1], cb[k + 1], cb[k]],
				[tones[i][k], tones[i][k + 1], tones[i + 1][k + 1], tones[i + 1][k]],
				[norms[i][k], norms[i][k + 1], norms[i + 1][k + 1], norms[i + 1][k]])


## Rows up the lake face of a range: `g` is the inset from the crest line as a
## fraction of the layer's width, `f` the fraction of crest height. The last row
## is the crest; one more row behind it falls to the foot of the backslope.
## Alpine faces are concave — steep under the crest, easing into scree — a fell
## is convex, and a coastal headland is a sea cliff with turf on top.
func _range_profile() -> Dictionary:
	match _vp_theme:
		Env.COUNTRY:
			return {"g": [0.55, 0.38, 0.23, 0.10, 0.0], "f": [0.0, 0.34, 0.64, 0.88, 1.0], "back": 1.05}
		Env.COAST:
			return {"g": [0.08, 0.06, 0.04, 0.018, 0.0], "f": [0.0, 0.40, 0.74, 0.93, 1.0], "back": 1.35}
	return {
		"g": [0.70, 0.50, 0.34, 0.21, 0.11, 0.04, 0.0],
		"f": [0.0, 0.14, 0.32, 0.51, 0.69, 0.86, 1.0],
		"back": 1.12,
	}


func _range_column(
	z: float, sample: Vector2, layer: Dictionary, base_y: float, phase: float, profile: Dictionary
) -> PackedVector3Array:
	## Ribs and gullies: every interior row wanders on its own frequency, by at
	## most a fraction of the room between it and its neighbours, so the face
	## folds without ever folding back through itself. Frequencies are in route
	## metres, so a chunk seam cannot tear the face.
	var width: float = layer["width"]
	var gs: Array = profile["g"]
	var fs: Array = profile["f"]
	var last: int = gs.size() - 1
	var body: float = clampf(sample.x / maxf(float(layer["height"]), 1.0), 0.0, 1.0)
	var pts := PackedVector3Array()
	for k in gs.size():
		var g: float = gs[k]
		var f: float = fs[k]
		if k > 0 and k < last:
			var room_g: float = minf(float(gs[k - 1]) - g, g - float(gs[k + 1]))
			var room_f: float = minf(f - float(fs[k - 1]), float(fs[k + 1]) - f)
			var kf := float(k)
			g += room_g * 0.42 * sin(z * (0.019 + 0.007 * kf) + phase * (1.7 + 0.9 * kf))
			f += room_f * 0.55 * sin(z * (0.027 + 0.009 * kf) + phase * (2.3 + 1.3 * kf)) * body
		pts.append(_far_point(z, _vp_side * (sample.y - width * g), base_y + sample.x * f))
	pts.append(_far_point(z, _vp_side * (sample.y + width * float(profile["back"])), base_y))
	return pts


func _range_normal(cols: Array[PackedVector3Array], i: int, k: int) -> Vector3:
	## Central differences over the grid. The range is a height field over the
	## route and the lateral, so the right side of the surface is the one that
	## faces up.
	var col: PackedVector3Array = cols[i]
	var along: Vector3 = cols[mini(i + 1, cols.size() - 1)][k] - cols[maxi(i - 1, 0)][k]
	var up: Vector3 = col[mini(k + 1, col.size() - 1)] - col[maxi(k - 1, 0)]
	var n := along.cross(up)
	if n.length_squared() < 1e-8:
		return Vector3.UP
	n = n.normalized()
	return -n if n.y < 0.0 else n


func _range_quad_n(b: LowPoly, q: Array, c: Array, n: Array) -> void:
	# Winding is written for a range on the rider's right. Mirrored, the same
	# vertex order faces away, so the pair order flips with the side.
	if _vp_side > 0.0:
		b.add_quad_shaded_n(q[0], q[1], q[2], q[3], c[0], c[1], c[2], c[3], n[0], n[1], n[2], n[3])
	else:
		b.add_quad_shaded_n(q[3], q[2], q[1], q[0], c[3], c[2], c[1], c[0], n[3], n[2], n[1], n[0])


func _finish_view_range(b: LowPoly) -> void:
	var z0 := _vp_centre - RANGE_REACH
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
		# Painted like the ride's own skyline rather than lit as terrain: see
		# range_material.gd for why the overlooks stopped being clay.
		mesh.material_override = RangeMaterial.overlook(_vp_theme)
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# The skyline never culls: blinking a mountain range out at the prop
		# distance would be the most obvious pop in the game.
		mesh.visibility_range_end = 0.0


## How far along the route the skyline is actually built. The range is drawn by
## the same chunks that carry the lake, so it exists over this half-window and
## nowhere else — and a crest still at full height when the mesh runs out is a
## vertical wall standing in the sky. Everything below is distributed inside this
## window and tapered to nothing at the edge of it.
const RANGE_REACH := 1800.0
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
	var sharpness := 0.86
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
			# Concave flanks and a horn on top. At 0.96 every massif was a
			# straight-sided pyramid — the lone witch's hat on the left of the view.
			#
			# 1.3 only traded the pyramid for the hat. `pow(t, 1.3)` is flat at the
			# foot and steepest at the summit, which is the definition of a witch's
			# hat: on a hero standing alone it read as a dark cone planted in front
			# of the range. A mountain wants most of its height change in the
			# middle of the flank, so the exponent comes down to just past vertical
			# and the heroes get wider below — `inner_k`/`outer_k` are what set how
			# much ground a summit stands on, and at 0.48/0.34 a hero had almost
			# none.
			sharpness = 0.78
			other = 0.62
			sag0 = 0.68
			jag_a = 0.08
			jag_b = 0.05
			inner_k = 0.62
			outer_k = 0.46
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
			sharpness = 0.42
			other = 0.62
			sag0 = 0.82
			jag_a = 0.01
			jag_b = 0.008
			inner_k = 1.05
			outer_k = 0.85
			extra = 0
			floor_h = 0.02
		Env.FOREST:
			# Below linear, so the shoulders swell: at 0.88 every summit was a
			# straight-sided cone, which wooded hills never are.
			sharpness = 0.70
			other = 0.74
			sag0 = 0.40
			inner_k = 0.58
			outer_k = 0.24
			jag_a = 0.09
			jag_b = 0.05
			foothill_lo = 0.34
			foothill_span = 0.18
			floor_h = 0.05
	var crest := floor_h
	if _vp_theme == Env.MOUNTAIN or _vp_theme == Env.FOREST:
		# A companion summit on the outer shoulder of each hero, so neither
		# stands alone as a symmetric spike. Always outboard: the col between
		# the two heroes is the composition and stays open.
		for k in 2:
			var side: float = -1.0 if k == 0 else 1.0
			var hero_at: float = left_at if k == 0 else right_at
			var hero_peak: float = 1.0 if (k == 0) == left_hero else other
			var horn_at: float = hero_at + side * (120.0 + 30.0 * sin(phase * 1.7 + float(k) * 2.3))
			crest = maxf(crest, _range_massif(local, horn_at, 160.0, 280.0, hero_peak * 0.74, sharpness))
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
	if _vp_theme == Env.MOUNTAIN:
		# The crest's own teeth — gendarmes and notches a few columns wide — so
		# an arête reads as broken rock against the sky, not a ruled line.
		crest += (0.07 * sin(local * 0.083 + phase * 2.9) + 0.05 * absf(sin(local * 0.151 + phase * 4.1))) * flank_weight
	var sag_depth: float = sag0 + float(depth) * 0.14
	var sag_width: float = pass_w * (1.0 + float(depth) * 0.55)
	var saddle: float = 1.0 - sag_depth * exp(-pow(local / sag_width, 2.0))
	var ends: float = 1.0 - smoothstep(RANGE_REACH * 0.72, RANGE_REACH, absf(local))
	var height: float = float(layer["height"]) * clampf(crest * saddle, 0.0, 1.0) * ends
	var out: float = float(layer["lateral"]) + float(layer["spread"]) * sin(local * 0.0074 + phase * 1.4)
	return Vector2(height, out)


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
	## A ground quad with a baked dusk rake. The range faces the lake and the
	## sun sits along the route, so a Lambert-only hillside arrived as one value
	## — a silhouette. Raking it here is what gives a lit slope and a shaded one.
	##
	## Ground always faces up, whichever side of the road the basin is on and
	## whichever order the caller walked its corners in. Borrowing the range's
	## side-flipped winding here flipped it twice — callers already sort their
	## laterals — so on one side of the road the whole valley floor was a back
	## face: culled, and the lake sheet under it showed through as a second lake.
	var n := (q2 - q0).cross(q1 - q0)
	if n.length_squared() < 1e-12:
		return
	if n.y < 0.0:
		var qs := q1
		q1 = q3
		q3 = qs
		var cs := c1
		c1 = c3
		c3 = cs
		n = -n
	n = n.normalized()
	var sun := Vector3(0.22, 0.18, 1.0).normalized()
	var t := smoothstep(0.12, 0.88, clampf(n.dot(sun) * 0.5 + 0.5, 0.0, 1.0))
	var sky := clampf(n.y, 0.0, 1.0) * 0.18
	# Soft raking, not a hard terminator. A 0.42 shade jump per facet is what
	# turned the dusk ranges into corduroy — each strip a different value.
	#
	# Lightening is a lerp to white, and the scene light still falls on these
	# faces afterwards. At 0.22 key + 0.18 sky + 0.10 fill a sunlit slope was
	# half white before the sun touched it, and the whole basin read as a pale
	# sand table at midday. The rake stays; the bleach goes.
	var shade := 0.2 * (1.0 - t)
	var key := 0.1 * t + sky * 0.35 + 0.02
	b.add_quad_shaded(
		q0,
		q1,
		q2,
		q3,
		c0 * (0.82 + key - shade),
		c1 * (0.82 + key - shade),
		c2 * (0.82 + key - shade),
		c3 * (0.82 + key - shade)
	)


func _platform_lateral(out: float, z: float = -1.0e12) -> float:
	## Lateral of a point `out` metres from the spur centreline at z.
	if z < -1.0e11:
		z = _vp_centre
	return _vp_side * (float(_path.spur_offset(z)) + out)


func _set_piece_platform() -> void:
	var rng := _platform_rng()
	_platform_step(rng, _build_belvedere)
	_platform_step(rng, _build_platform_furniture)
	_platform_step(rng, _build_platform_trees)
	_platform_step(rng, _build_platform_planting)


func _set_piece_platform_incremental() -> bool:
	var rng := _platform_rng()
	_platform_step(rng, _build_belvedere)
	if not await _keep_streaming():
		return false
	_platform_step(rng, _build_platform_furniture)
	if not await _keep_streaming():
		return false
	_platform_step(rng, _build_platform_trees)
	if not await _keep_streaming():
		return false
	_platform_step(rng, _build_platform_planting)
	return await _keep_streaming()


func _platform_rng() -> RandomNumberGenerator:
	## The platform draws from its own sequence, seeded from the overlook. It is
	## built first in the owner's scenic pass now, so the rider finds it standing
	## on arrival; on the chunk's shared generator that move would have re-rolled
	## every tree, rock and ridge built after it.
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(int(round(_vp_centre)), int(_path.world_seed), 0x51a7))
	return rng


func _platform_step(rng: RandomNumberGenerator, step: Callable) -> void:
	## One synchronous platform step on the platform's generator. Swapped only
	## across a call that never awaits, so nothing else can draw from it.
	var world_rng := _rng
	_rng = rng
	step.call()
	_rng = world_rng


func _build_platform_furniture() -> void:
	## The destination. Everything is placed from the overlook centre on ground
	## the path has already levelled, so nothing here needs a fudge height.
	var centre := _vp_centre
	var side := _vp_side
	# Out on the terrace, clear of anything the bike can reach.
	var edge: float = RoadPathGD.PLATFORM_HALF_WIDTH + 6.2
	var timber := Color("6d4f38")

	# Benches square on to the water, planted on the terrace rather than hovering
	# a world-up offset above a pitched deck.
	for offset in RoadPathGD.PLATFORM_BENCH_Z:
		_viewpoint_bench(centre + float(offset), side, RoadPathGD.PLATFORM_BENCH_OUT)
	_viewpoint_board(centre + 14.0, side, RoadPathGD.PLATFORM_HALF_WIDTH + 1.6, timber)
	# The kit's balcony carries its own coin viewer out over the drop.
	if _lookout_scene(LOOKOUT_BALCONY) == null:
		_viewpoint_telescope(centre - 0.2, side, edge - 1.4)
	# Painted bays and the brown board at the way in, when the kit has them.
	var bays: PackedScene = _lookout_scene(LOOKOUT_BAYS)
	if bays:
		for at in [-8.0, 8.0]:
			_place_lookout(bays, centre + at, RoadPathGD.PLATFORM_HALF_WIDTH, BAYS_LIFT, "LookoutBays_%d" % int(at))
	var stop: PackedScene = _lookout_scene(LOOKOUT_STOP)
	if stop:
		# One at the way in, and one a long stopping distance before it, so the
		# rider is told before the bays open rather than as they pass them.
		for pair in [[RoadPathGD.PLATFORM_HALF_LENGTH + 8.0, "LookoutStop"], [150.0, "LookoutStopAdvance"]]:
			var stop_z: float = centre - float(pair[0])
			var verge: float = float(_path.spur_half_width(stop_z)) + RoadPathGD.SPUR_SHOULDER + 1.4
			_place_lookout(stop, stop_z, -verge, 0.0, str(pair[1]))
	var bin_z := centre + 17.5
	var bin_lat: float = _platform_lateral(RoadPathGD.PLATFORM_HALF_WIDTH + 1.4, bin_z)
	_deck_cube(bin_z, bin_lat, Vector3(0.62, 0.92, 0.62), timber.darkened(0.2), 0.0, -0.04)
	_deck_cube(bin_z, bin_lat, Vector3(0.76, 0.1, 0.76), timber.lightened(0.15), 0.0, 0.88)

	# Promenade lanterns along the parking side of the walk: tall enough to read
	# as street furniture from the road, behind the benches so the seated view
	# never has a pole in it. Only the outer two own real lights (the per-chunk
	# cap); the middle one keeps its emissive glass.
	for offset in [-12.0, 0.0, 12.0]:
		_viewpoint_lantern(centre + offset, RoadPathGD.PLATFORM_HALF_WIDTH + 1.05, absf(offset) > 1.0)


func _viewpoint_lantern(z: float, out: float, lit: bool) -> void:
	var packed: PackedScene = load("res://scenes/lookout_bollard.tscn")
	var lamp: Node3D = packed.instantiate()
	var lateral := _platform_lateral(out, z)
	lamp.transform = Transform3D(_path.frame_flat_at(z), _p(z, lateral, -0.05 - _terrace_floor_at(z, lateral)))
	lamp.name = "LookoutLight_%d" % int(z)
	add_child(lamp)
	if lit:
		_deck_light(z, lateral, 0.81, Color("ffd399"), 5.0, 0.55)

func _build_platform_pergola() -> void:
	## A timber pergola over the far end of the walk, with a bench of its own and
	## blossom over the rafters. It is the silhouette that makes the terrace a
	## destination from the parking: an open frame, not a roof, so the lake still
	## shows through it. It stands clear of both seated benches.
	var timber := Color("5f432f")
	var stone := Color("8e8270")
	var bloom := Color("9a86c6") if _vp_theme != Env.COAST else _platform_bloom()
	var inner := RoadPathGD.PLATFORM_HALF_WIDTH + 1.15
	var outer := RoadPathGD.PLATFORM_HALF_WIDTH + 5.45
	var z_a := _vp_centre - 21.6
	var z_b := _vp_centre - 15.0
	var z_mid := (z_a + z_b) * 0.5
	var posts: Array[float] = [z_a, z_mid, z_b]
	const HEIGHT := 2.75
	for pz in posts:
		for out in [inner, outer]:
			var lat: float = _platform_lateral(out, pz)
			_deck_cube(pz, lat, Vector3(0.36, 0.3, 0.36), stone, 0.0, -0.04)
			_deck_cube(pz, lat, Vector3(0.2, HEIGHT - 0.26, 0.2), timber, 0.0, 0.26)
			# Climbers on every post, thicker at the foot.
			_deck_blob(pz, lat, Vector3(0.5, 0.7, 0.5), Color("35573a"), 0.2, true)
			_deck_blob(pz, lat, Vector3(0.36, 0.9, 0.36), Color("3f6443").darkened(_rng.randf() * 0.15), 1.1, true)
	# Beams along the walk, running a little past the end posts.
	var span: float = z_b - z_a + 1.0
	for out in [inner, outer]:
		_deck_cube(z_mid, _platform_lateral(out, z_mid), Vector3(0.16, 0.26, span), timber.darkened(0.08), 0.0, HEIGHT)
	# Rafters across, overhanging both beams.
	var width: float = outer - inner + 1.1
	var centre_out: float = (inner + outer) * 0.5
	var rz := z_a - 0.3
	while rz <= z_b + 0.31:
		_deck_cube(rz, _platform_lateral(centre_out, rz), Vector3(width, 0.18, 0.09), timber, 0.0, HEIGHT + 0.26)
		rz += 0.55
	# Blossom along the rafters and hanging racemes under them — wisteria where
	# it grows, sea thrift colour on the coast.
	for _i in 16:
		var bz: float = _rng.randf_range(z_a - 0.2, z_b + 0.2)
		var bo: float = _rng.randf_range(inner - 0.3, outer + 0.3)
		var s: float = _rng.randf_range(0.5, 0.9)
		var col: Color = Color("486c44").darkened(_rng.randf() * 0.2)
		if _rng.randf() < 0.55:
			col = bloom.lightened(_rng.randf() * 0.15)
		_deck_blob(bz, _platform_lateral(bo, bz), Vector3(s * 1.4, s * 0.55, s * 1.2), col, HEIGHT + 0.3, true)
	for _i in 14:
		var hz: float = _rng.randf_range(z_a, z_b)
		var ho: float = _rng.randf_range(inner + 0.2, outer - 0.2)
		var hl: float = _rng.randf_range(0.45, 0.8)
		_deck_blob(hz, _platform_lateral(ho, hz), Vector3(0.24, hl, 0.24), bloom.lightened(_rng.randf() * 0.2), HEIGHT + 0.2 - hl, true)
	# A bench under it, looking out between the posts.
	var bench_z := (z_a + z_mid) * 0.5
	var bench_lat := _platform_lateral(outer - 0.9, bench_z)
	_deck_cube(bench_z, bench_lat, Vector3(0.5, 0.12, 1.9), stone, 0.0, -0.04)
	for leg in [-0.7, 0.7]:
		_deck_cube(bench_z + leg, bench_lat, Vector3(0.44, 0.36, 0.1), Color("3a3d42"), 0.0, 0.08)
	for slat in [-0.14, 0.0, 0.14]:
		_deck_cube(bench_z, bench_lat + _vp_side * slat, Vector3(0.11, 0.06, 1.8), timber.lightened(0.12), 0.0, 0.44)
	# A trough of bloom between the far posts so the frame sits in a garden.
	var trough_z := (z_mid + z_b) * 0.5
	var trough_lat := _platform_lateral(outer - 0.7, trough_z)
	_deck_cube(trough_z, trough_lat, Vector3(0.6, 0.42, 1.6), Color("b8ac98"), 0.0, -0.04)
	_deck_blob(trough_z, trough_lat, Vector3(0.55, 0.4, 1.4), Color("4a6a46"), 0.34, true)
	for k in 3:
		_deck_blob(trough_z - 0.5 + float(k) * 0.5, trough_lat, Vector3(0.4, 0.3, 0.4), bloom.lightened(0.05 * float(k)), 0.52, true)


func _build_platform_trees() -> void:
	# Pines along the back of the platform, screening the carriageway.
	# Coast keeps the sky; mountain is a screen of wind-shaped pine; forest and
	# country keep the wooded backstop.
	var centre := _vp_centre
	var reach: float = RoadPathGD.PLATFORM_HALF_LENGTH + 8.0
	if _vp_theme != Env.COAST:
		for _i in (10 if _vp_theme == Env.FOREST else 7):
			var z := centre + _rng.randf_range(-reach, reach)
			var species: int = Flora.BROADLEAF
			if _vp_theme == Env.MOUNTAIN:
				species = Flora.PINE
			var back_lat: float = _platform_lateral(-RoadPathGD.PLATFORM_HALF_WIDTH - _rng.randf_range(2.0, 10.0), z)
			if _on_tarmac(z, back_lat, 1.4):
				continue
			_tree(
				species,
				z,
				back_lat,
				_rng.randf_range(8.0, 14.0),
				# Mid woodland green. The old near-black pair read as cut-outs even
				# at noon, from the one spot where the rider stands right under them.
				Color("2b4c35").lerp(Color("45683f"), _rng.randf()),
				true
			)
	# Two sentinel trees at the terrace ends — the silhouette that says this
	# is a belvedere and not a lay-by. They stand on the road side: planted
	# past the parapet they parked a dark canopy across the seated view.
	# Coast and mountain leave the view open.
	if _vp_theme == Env.FOREST or _vp_theme == Env.COUNTRY:
		for end in [-1.0, 1.0]:
			var cz: float = centre + end * (RoadPathGD.PLATFORM_HALF_LENGTH - 1.6)
			var sentinel_lat: float = _platform_lateral(-RoadPathGD.PLATFORM_HALF_WIDTH - 2.4, cz)
			if _on_tarmac(cz, sentinel_lat, 1.4):
				continue
			# The two trees nearest the bench are the kit's full-canopy model; the
			# backstop stays in the batched buckets, where a dozen more scene
			# instances would cost a draw call each for trees seen at forty metres.
			var sentinel: PackedScene = _lookout_scene(LOOKOUT_TREE)
			if sentinel:
				_lookout_tree(sentinel, cz, sentinel_lat, 11.0 + end * 0.8, "LookoutSentinel_%d" % int(end))
				continue
			_tree(
				Flora.BROADLEAF,
				cz,
				sentinel_lat,
				11.0 + end * 0.8,
				Color("2f4d36"),
				true
			)


func _lookout_tree(packed: PackedScene, z: float, lateral: float, height: float, node_name: String) -> void:
	## A kit tree grounded the way `_tree` grounds its own: footprint fitted to
	## the slope, then scaled from the kit's ten metres to the height asked for.
	var foot: float = clampf(height * 0.1, 0.35, 1.1)
	var base: Vector3 = _ground_base_for_footprint(z, lateral, foot, foot) - _origin
	var tree: Node3D = packed.instantiate()
	tree.transform = Transform3D(
		Basis(Vector3.UP, _rng.randf_range(0.0, TAU)).scaled(Vector3.ONE * height / LOOKOUT_TREE_HEIGHT), base
	)
	tree.name = node_name
	add_child(tree)


func _platform_bloom() -> Color:
	## What the biome would actually grow in a trough: anemone in shade, thrift
	## on the sea edge, heather on the pass, gorse in the hedgerow country.
	match _vp_theme:
		Env.FOREST:
			return Color("c8c0ac")
		Env.COAST:
			return Color("b86a72")
		Env.MOUNTAIN:
			return Color("8a6a94")
	return Color("c8a83c")


func _build_platform_planting() -> void:
	# A couple of stone planters at the ends, not a hedge across the view.
	var centre := _vp_centre
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
	# Troughs mid-terrace, flanking the centre, so the walk is a garden edge and
	# not only a place to stand the bike.
	var bloom := _platform_bloom()
	for offset in [-7.5, 7.5]:
		var pz: float = centre + offset
		var plat: float = _platform_lateral(RoadPathGD.PLATFORM_HALF_WIDTH + 1.7, pz)
		_deck_cube(pz, plat, Vector3(1.3, 0.4, 0.62), Color("b8ac98"), 0.0, -0.04)
		_deck_blob(pz, plat, Vector3(1.15, 0.4, 0.52), Color("4a6a46"), 0.34, true)
		_deck_blob(pz + 0.32, plat, Vector3(0.5, 0.3, 0.42), bloom, 0.5, true)
		_deck_blob(pz - 0.34, plat, Vector3(0.44, 0.26, 0.4), bloom.lightened(0.1), 0.46, true)
	# Boulders and scrub on the back of the platform, screening the road.
	var reach: float = RoadPathGD.PLATFORM_HALF_LENGTH + 8.0
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
	##
	## With the lookout kit present the deck, kerb and parapet are authored and
	## only the masonry under the lip stays procedural, because that is the part
	## that has to meet whatever ground the overlook was given.
	var deck: PackedScene = _lookout_scene(LOOKOUT_DECK)
	var rail: PackedScene = _lookout_scene(LOOKOUT_RAIL)
	var authored: bool = deck != null and rail != null
	_terrace_floor = TERRACE_FLOOR if authored else 0.0
	var b := LowPoly.new()
	var limestone := Color("737568")
	var mortar := Color("62685e")
	var shadow := Color("4f4a43")
	var step := 2.4
	var half: float = RoadPathGD.PLATFORM_HALF_LENGTH
	var z := _vp_centre - half
	while z < _vp_centre + half:
		var next: float = minf(z + step, _vp_centre + half)
		if not authored:
			_kerb_run(b, z, next, RoadPathGD.PLATFORM_HALF_WIDTH + 0.32, 0.46, 0.12, limestone.lightened(0.08))
			# Weathered flags, not fresh limestone: at full value the paving was the
			# brightest surface in the frame and the terrace read as a sand strip.
			_belvedere_pave(b, z, next, limestone.lerp(shadow, 0.34))
		_belvedere_wall(b, z, next, limestone, mortar, shadow)
		z = next
	_belvedere_ends(b, limestone, shadow)
	var mesh: MeshInstance3D = b.commit_to(self, "PlatformKerbs")
	if mesh:
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if authored:
		_build_authored_terrace(deck, rail)
		return
	# Short stone piers at the corners, so the parapet has something to end on.
	for end in [-1.0, 1.0]:
		var pz: float = _vp_centre + end * (half - 0.4)
		var lat: float = _platform_lateral(RoadPathGD.PLATFORM_HALF_WIDTH + 6.15, pz)
		_deck_cube(pz, lat, Vector3(0.48, 0.72, 0.48), limestone.darkened(0.06), 0.0, -0.04)
	# Piers along the cap — the staccato that turns a kerb line into a parapet.
	# Without them the wall reads as one unbroken rail and the terrace has no
	# scale against the water.
	var pier_z := _vp_centre - half + 3.6
	while pier_z < _vp_centre + half - 3.0:
		var lat: float = _platform_lateral(RoadPathGD.PLATFORM_HALF_WIDTH + 6.45, pier_z)
		_deck_cube(pier_z, lat, Vector3(0.52, 1.04, 0.52), limestone.darkened(0.05), 0.0, -0.02)
		_deck_cube(pier_z, lat, Vector3(0.72, 0.13, 0.72), limestone.lightened(0.10), 0.0, 1.02)
		# Stepped finial, so each pier ends in a shape and not a slab.
		pier_z += 7.7
	_build_belvedere_railing()


func _build_authored_terrace(deck: PackedScene, rail: PackedScene) -> void:
	## The kit's deck and rail in four-metre segments, each squared to the road
	## at its own station so the run follows the platform round its curve the way
	## the procedural flags did. The deck's skirt and the rail's shared end posts
	## cover the wedge that opens between neighbours on a bend.
	var balcony: PackedScene = _lookout_scene(LOOKOUT_BALCONY)
	var half: float = RoadPathGD.PLATFORM_HALF_LENGTH
	var rail_out: float = RoadPathGD.PLATFORM_HALF_WIDTH + TERRACE_RAIL_OUT
	var deck_zs: Array[float] = []
	var rail_zs: Array[float] = []
	var offset: float = -half + 1.0
	while offset <= half - 1.0 + 0.01:
		deck_zs.append(_vp_centre + offset)
		# The balcony takes the two rail bays either side of the axis.
		if balcony == null or absf(offset) > TERRACE_PITCH * 0.75:
			rail_zs.append(_vp_centre + offset)
		offset += TERRACE_PITCH
	_place_lookout_run(deck, deck_zs, RoadPathGD.PLATFORM_HALF_WIDTH, TERRACE_FLOOR, "LookoutDeck")
	_place_lookout_run(rail, rail_zs, rail_out, TERRACE_FLOOR, "LookoutRail")
	if balcony:
		_place_lookout(balcony, _vp_centre, rail_out, TERRACE_FLOOR, "LookoutBalcony")
	# A pier at each end of the run, so the rail stops on something.
	var pier: PackedScene = _lookout_scene(LOOKOUT_PIER)
	if pier:
		for end in [-1.0, 1.0]:
			_place_lookout(pier, _vp_centre + end * (half + 1.0), rail_out, TERRACE_FLOOR, "LookoutPier_%d" % int(end))


func _place_lookout_run(packed: PackedScene, zs: Array[float], out: float, lift: float, node_name: String) -> void:
	## A run of identical kit modules as one MultiMesh, so twelve deck segments
	## are one draw rather than twelve. A module that is not a single mesh falls
	## back to one scene instance per station.
	var proto: Node = packed.instantiate()
	var source: MeshInstance3D = null
	if proto.get_child_count() == 1:
		source = proto.get_child(0) as MeshInstance3D
	if source == null or source.mesh == null:
		proto.free()
		for z in zs:
			_place_lookout(packed, z, out, lift, "%s_%d" % [node_name, int(z - _vp_centre)])
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = source.mesh
	mm.instance_count = zs.size()
	for i in zs.size():
		var z: float = zs[i]
		var flat: Basis = _path.frame_flat_at(z)
		var station := Transform3D(
			Basis(flat.x * _vp_side, flat.y, flat.z * _vp_side), _p(z, _platform_lateral(out, z), -lift)
		)
		mm.set_instance_transform(i, station * source.transform)
	var run := MultiMeshInstance3D.new()
	run.name = node_name
	run.multimesh = mm
	run.material_override = source.material_override
	run.cast_shadow = source.cast_shadow
	add_child(run)
	proto.free()


func _place_lookout(packed: PackedScene, z: float, out: float, lift: float, node_name: String) -> Node3D:
	## One kit piece `out` metres from the spur centreline, turned with the
	## overlook's side exactly as the benches are.
	var piece: Node3D = packed.instantiate()
	var flat: Basis = _path.frame_flat_at(z)
	piece.transform = Transform3D(
		Basis(flat.x * _vp_side, flat.y, flat.z * _vp_side), _p(z, _platform_lateral(out, z), -lift)
	)
	piece.name = node_name
	add_child(piece)
	return piece


func _terrace_floor_at(z: float, lateral: float) -> float:
	## Deck height over the tarmac at this point, zero off the deck. Everything
	## that stands on the terrace goes up by this much, so the benches, planters
	## and lamps sit on the authored deck rather than five centimetres inside it.
	if _terrace_floor <= 0.0 or absf(z - _vp_centre) > RoadPathGD.PLATFORM_HALF_LENGTH + 1.0:
		return 0.0
	var out: float = lateral * _vp_side - float(_path.spur_offset(z)) - RoadPathGD.PLATFORM_HALF_WIDTH
	if out < -0.05 or out > TERRACE_DEPTH:
		return 0.0
	return _terrace_floor


func _build_belvedere_railing() -> void:
	## Wrought iron between the piers. A bare cap reads as a kerb from the
	## parking; balusters give the parapet a rhythm and the terrace a human scale
	## against the water. Top rail stays under 0.97 m: the seated eye sits half a
	## metre in from the cap, and anything taller lands across the bottom of the
	## view as a dark bar.
	var iron := Color("2c3033")
	var half: float = RoadPathGD.PLATFORM_HALF_LENGTH - 0.7
	var out: float = RoadPathGD.PLATFORM_HALF_WIDTH + 6.45
	const SEG := 1.2
	var z := _vp_centre - half
	while z < _vp_centre + half - 0.01:
		var mid: float = minf(z + SEG * 0.5, _vp_centre + half)
		var lat: float = _platform_lateral(out, mid)
		_deck_cube(mid, lat, Vector3(0.07, 0.05, SEG + 0.02), iron, 0.0, 0.91)
		_deck_cube(mid, lat, Vector3(0.05, 0.035, SEG + 0.02), iron, 0.0, 0.6)
		# Balusters, with every fourth one a heavier post and a knuckle on it.
		for i in 5:
			var bz: float = z + float(i) * SEG / 5.0
			var blat: float = _platform_lateral(out, bz)
			if i == 0:
				_deck_cube(bz, blat, Vector3(0.05, 0.44, 0.05), iron, 0.0, 0.52)
				_deck_cube(bz, blat, Vector3(0.09, 0.07, 0.09), iron.lightened(0.08), 0.0, 0.72)
			else:
				_deck_cube(bz, blat, Vector3(0.024, 0.4, 0.024), iron, 0.0, 0.54)
		z += SEG


func _belvedere_pave(b: LowPoly, za: float, zb: float, color: Color) -> void:
	## Stone deck from the parking kerb out to the parapet, laid as flagstones:
	## two courses across the walk, a hair of tonal drift per run, and a
	## shadowed joint at each course break and down the middle. One flat sheet
	## is what read as a poured apron from the bench.
	var inner := RoadPathGD.PLATFORM_HALF_WIDTH + 0.55
	var outer := RoadPathGD.PLATFORM_HALF_WIDTH + 6.05
	var mid := (inner + outer) * 0.5
	var drift := float(posmod(int(round(za / 2.4)), 4)) - 1.5
	var course := color.lightened(0.022 * drift)
	for pair in [[inner, mid, 0.0], [mid, outer, 0.045]]:
		var a0: float = _platform_lateral(float(pair[0]), za)
		var a1: float = _platform_lateral(float(pair[1]), za)
		var b0: float = _platform_lateral(float(pair[1]), zb)
		var b1: float = _platform_lateral(float(pair[0]), zb)
		b.add_quad(
			_p(za, minf(a0, a1), -0.05), _p(za, maxf(a0, a1), -0.05), _p(zb, maxf(b0, b1), -0.05), _p(zb, minf(b0, b1), -0.05), course.darkened(float(pair[2]))
		)
	# Joints sit a finger below the flags so they read as shadow, not paint.
	var j0: float = _platform_lateral(mid - 0.045, za)
	var j1: float = _platform_lateral(mid + 0.045, za)
	var k0: float = _platform_lateral(mid - 0.045, zb)
	var k1: float = _platform_lateral(mid + 0.045, zb)
	b.add_quad(
		_p(za, minf(j0, j1), -0.028), _p(za, maxf(j0, j1), -0.028), _p(zb, maxf(k0, k1), -0.028), _p(zb, minf(k0, k1), -0.028), course.darkened(0.24)
	)
	var e0: float = _platform_lateral(inner, zb)
	var e1: float = _platform_lateral(outer, zb)
	b.add_quad(
		_p(zb - 0.10, minf(e0, e1), -0.028), _p(zb - 0.10, maxf(e0, e1), -0.028), _p(zb, maxf(e0, e1), -0.028), _p(zb, minf(e0, e1), -0.028), course.darkened(0.24)
	)


func _belvedere_wall(b: LowPoly, za: float, zb: float, limestone: Color, mortar: Color, shadow: Color) -> void:
	## A masonry box under the lip, not a single face. A plane at the edge is
	## invisible from the parking and a white line from below; thickness is
	## what makes the terrace a place the benches can stand on.
	const LIP := 6.05
	const FACE := 6.85
	# Under the authored deck the cap comes down flush with it and becomes the
	# rail's footing; standing at its own height it would push up through the
	# deck's outer lip.
	var cap: float = _terrace_floor if _terrace_floor > 0.0 else 0.52
	# The terrace stands on a ledge of made ground now (PLATFORM_LIP_SHELF), so
	# the masonry only has to be a parapet that is buried in it — not a nine-metre
	# retaining wall reaching for a hillside that is no longer there. That depth
	# is what made the belvedere a box floating over the drop from across the
	# water.
	const WALL := 3.0
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
		_p(za, in_a, -cap), _p(za, out_a, -cap), _p(zb, out_b, -cap), _p(zb, in_b, -cap), limestone.lightened(0.12)
	)
	# Inner face, toward the parking.
	_wall_face(b, za, zb, lip_a, lip_b, 0.0, -cap, mortar)
	_wall_face(b, za, zb, face_a, face_b, -cap, 2.4, limestone)
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
	## ribbon that stops in mid-air. Same three metres as the wall face: the end
	## walls used to keep the old nine-metre reach and hung below the shelf as
	## two lit blades.
	var half: float = RoadPathGD.PLATFORM_HALF_LENGTH
	var inner := RoadPathGD.PLATFORM_HALF_WIDTH + 0.55
	var face := RoadPathGD.PLATFORM_HALF_WIDTH + 6.45
	for end in [-1.0, 1.0]:
		var z: float = _vp_centre + end * half
		var la: float = _platform_lateral(inner, z)
		var lb: float = _platform_lateral(face, z)
		var a := minf(la, lb)
		var c := maxf(la, lb)
		var top: float = _terrace_floor if _terrace_floor > 0.0 else 0.52
		b.add_quad(_p(z, a, -top), _p(z, c, -top), _p(z, c, 3.0), _p(z, a, 3.0), limestone.lerp(shadow, 0.35))


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
	var lateral := _platform_lateral(out, z)
	# The small plinth follows the path; the editable scene owns the model.
	_deck_cube(z, lateral, Vector3(0.86, 0.10, 2.2), Color("555b51"), 0.0, -0.04)
	var packed: PackedScene = load("res://scenes/lookout_bench.tscn")
	var bench: Node3D = packed.instantiate()
	var flat: Basis = _path.frame_flat_at(z)
	bench.transform = Transform3D(
		Basis(flat.x * side, flat.y, flat.z * side), _p(z, lateral, -0.07 - _terrace_floor_at(z, lateral))
	)
	bench.name = "LookoutBench_%d" % int(z)
	add_child(bench)

func _viewpoint_board(z: float, side: float, out: float, _timber: Color) -> void:
	var packed: PackedScene = load("res://scenes/lookout_board.tscn")
	var board: Node3D = packed.instantiate()
	var flat: Basis = _path.frame_flat_at(z)
	var lateral := _platform_lateral(out, z)
	board.transform = Transform3D(
		Basis(flat.x * side, flat.y, flat.z * side), _p(z, lateral, -0.05 - _terrace_floor_at(z, lateral))
	)
	board.name = "LookoutMap"
	add_child(board)

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
	var base: Vector3 = _p(z, lateral, -1.48 - _terrace_floor_at(z, lateral))
	var barrel := Basis(flat.z, side * deg_to_rad(-18.0)) * Basis(flat.x * 1.1, flat.y * 0.21, flat.z * 0.21)
	_cubes.append(Transform3D(barrel, base + flat.x * side * 0.25))
	_cube_cols.append(Color("2f3339"))


func _build_viewpoint_sign(z: float, side: float, advance: bool) -> void:
	## A brown tourist board over a blue parking board — the pair a rider
	## recognises at 180 km/h. The advance sign stands 240 m before the junction
	## with a distance plate; the second marks the start of the deceleration lane.
	var lateral := side * (HALF_WIDTH + 2.6)
	# The board at the mouth is the kit's VIEWPOINT/P sign, on this same anchor
	# and the footing `_sign_label` uses, so the exit is announced at the size the
	# parking is. The advance board stays procedural for its distance plate.
	var kit: PackedScene = null if advance else _lookout_scene(LOOKOUT_STOP)
	if kit:
		var flat: Basis = _path.frame_flat_at(z)
		var board: Node3D = kit.instantiate()
		board.transform = Transform3D(
			Basis(flat.x * side, flat.y, flat.z * side),
			_ground_base_for_footprint(z, lateral, 1.2, 0.09, true) - _origin
		)
		board.name = "LookoutApproachSign"
		add_child(board)
		return
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
		_ground_base_for_footprint(z, lateral, 1.2, 0.09, true) - _origin + frame.y * lift
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
	var a: Vector3 = _terrain_surface_at(z_a, lateral) + _path.frame_flat_at(z_a).y * lift
	var b: Vector3 = _terrain_surface_at(z_b, lateral) + _path.frame_flat_at(z_b).y * lift
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
				# Sand a step greyer and the scrub a step greener. Under the warm key
				# the old `c9ae74` came out as saturated yellow from curb to sea, and
				# every dark bush on it read as a hole cut in the ground.
				"verge": Color("84966a"),
				"ground": Color("ae9f7e"),  # open sand
				"ground_alt": Color("6f8a72"),  # scrub holding the dune
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
