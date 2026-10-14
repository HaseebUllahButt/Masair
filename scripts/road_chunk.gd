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
## Visuals layer reserved for the headland skin's own sky fill. The skin is the
## only surface on it: the day key leaves a face this steep in open shade, and
## the fix is light, not brighter paint — a weak cool directional aimed over
## the lake lifts the strata the albedo already draws, without touching the
## water, the range or the bank behind it.
const HEADLAND_FILL_LAYER := 1 << 19
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
## Per-frame CPU budget for streamed builds. Stage boundaries used to park for a
## whole frame each, so a dressed chunk cost ~40 frames regardless of how cheap
## the stages were — at a loaded 60 fps that is a full second per chunk and the
## props queue falls behind the bike, leaving bare roadside. Yielding only once
## the frame's slice is spent keeps the same per-frame ceiling while finishing a
## chunk in as many frames as its real cost needs.
const STREAM_SLICE_USEC := 4000
## How much one build slice may spend in a frame. The streamer drops it while
## the rider is seated: parked work has no deadline, so the same queue drains
## over more frames and leaves the lookout's frame time to the view instead.
static var slice_budget_usec: int = STREAM_SLICE_USEC
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
## Clear air over the rideable surface. The corridor is the carriageway and the
## scenic spur, each widened by its shoulder; a rider's head and eyes live in
## the first couple of metres above it, and the foliage shader swings every
## crown a few percent of its width besides.
##
## Two rules, both measured against the road surface under the plant: growth
## whose lowest reach sits under FOLIAGE_LOW_HEIGHT keeps
## FOLIAGE_LOW_CLEARANCE of air past the corridor edge, and nothing at all may
## cross the edge below FOLIAGE_OVERHANG_HEIGHT. A tree is still welcome right
## beside the road — only its crown has to clear it, not just its trunk.
const FOLIAGE_LOW_CLEARANCE := 1.5
const FOLIAGE_LOW_HEIGHT := 6.0
const FOLIAGE_OVERHANG_HEIGHT := 9.0
## foliage.gdshader displaces a vertex by sway_strength * lever * gust, lever
## being mesh-local height (~1 for a crown). Per metre of instance width that
## is ~6 cm of travel; 12% of the measured reach covers it with room to spare.
const FOLIAGE_SWAY := 0.12
## Bushes packed onto the first few metres of verge. Indexed by Env. Split across
## frames while streaming — planting all of them at once was a 35–90 ms hitch.
const VERGE_BUSH_COUNT := [8, 34, 18, 26, 16]
const VERGE_BUSH_BATCH := 1
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

## Country patchwork, shared by the ground colouring and the hedge planting so
## a painted boundary always has its grown boundary on the same line. Depth
## edges reuse the ground ribbon's own vertex laterals — the only places a
## per-vertex colour can draw a sharp line — and field lengths grow with
## distance the way real parcels do.
const FIELD_EDGES: Array[float] = [22.0, 47.0, 75.0, 125.0, 195.0, 305.0]
const FIELD_LENGTHS: Array[float] = [50.0, 72.0, 96.0, 126.0, 170.0, 220.0]
## How far each depth edge wanders along its run, so parcel lines meander like
## hedgerows instead of drafting a surveyor's grid.
const FIELD_WAVE: Array[float] = [2.0, 3.5, 5.0, 7.0, 9.0, 11.0]
## Length of one along-edge hedge decision; runs this long come and go rather
## than unbroken walls marching the whole biome.
const FIELD_RUN := 26.0

## What one parcel is growing. Grass dominates, as it should in English
## farmland; crop and cut hay are the accents, plough the rare dark note.
enum Field { GRAZED, PASTURE, CROP, MOWN, FALLOW }

## Roadside tree species. One shape — a ball on a stick — at every scale in every
## theme is what made a pine forest, an orchard and a fellside plantation all
## read as the same green lollipops going past.
## PINE is the timberline tree: a high, wind-shaped crown on a clean stem. It
## replaced a leafless snag, which from the saddle read as a burnt forest.
enum Flora { BROADLEAF, CONIFER, BIRCH, PINE }

## Length of one stand decision on the verge: the run of roadside a wood edge
## treats as a single stand — wooded or open, one species family, one height
## class — hashed off the world seed so a stand spanning a chunk boundary
## grows the same from both chunks, and gaps open between stands the way a
## real margin does instead of a metronome row of random specimens.
const STAND_CELL := 46.0

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
static var _unit_bush: ArrayMesh
static var _unit_boulder: ArrayMesh
static var _unit_trunk: ArrayMesh
static var _unit_crown: ArrayMesh
static var _unit_conifer: ArrayMesh
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
		b.index_flat = true
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


static func unit_bush() -> ArrayMesh:
	## Every shrub, hedge lump, flower head and canopy mass on the verge. The
	## smooth ball it replaced was the one bubble-plastic shape left among
	## faceted crowns, and squashed to a shrub's proportions it became a dark
	## lens lying on the grass — the "discs" that littered the valley from the
	## bench. A few faceted lobes give a lumpy silhouette that still reads as
	## leaf at any squash. Everything stays inside the unit sphere the corridor
	## sweep measures, so no swaying lobe can reach further than the ball did,
	## and the main lobe reaches the sphere's floor so nothing hovers.
	if _unit_bush == null:
		var b := LowPoly.new()
		b.index_flat = true
		b.channel = LowPoly.FOLIAGE
		# [x, y, z, radius, y-stretch, shade]: one body down to the ground, a
		# raised shoulder, two lower side lobes in their own shade.
		const LOBES := [
			[0.00, -0.04, 0.00, 0.44, 1.05, 0.90],
			[0.08, 0.20, -0.06, 0.24, 1.0, 1.10],
			[0.18, -0.14, 0.10, 0.23, 1.0, 0.76],
			[-0.18, -0.12, -0.14, 0.23, 1.0, 0.80],
		]
		var turn := 0.0
		for lobe in LOBES:
			var shade: float = lobe[5]
			b.add_sphere(
				Transform3D(
					Basis(Vector3.UP, turn).scaled(Vector3(1.0, lobe[4], 1.0)), Vector3(lobe[0], lobe[1], lobe[2])
				),
				lobe[3],
				6,
				4,
				Color(shade, shade, shade)
			)
			# Each lobe a different twist so their facets never line up.
			turn += 0.71
		_unit_bush = b.commit()
	return _unit_bush


static func unit_boulder() -> ArrayMesh:
	## Stones. A smooth ball read as an egg or a pebble at every size — the
	## outcrops, verge rocks and lake skerries were billiard balls in moss. One
	## faceted lump with an irregular radius per vertex reads as broken rock,
	## costs fewer triangles than the ball, and keeps its flat-ish top catching
	## the sky the way weathered stone does. Bottom stays at the unit floor so
	## the old bedding offsets still bury it the same.
	if _unit_boulder == null:
		var b := LowPoly.new()
		b.index_flat = true
		b.hull_origin = Vector3.ZERO
		const SEGS := 7
		const RINGS := [[-0.5, 0.0], [-0.34, 0.44], [-0.02, 0.5], [0.24, 0.42], [0.42, 0.22], [0.47, 0.0]]
		var grid: Array = []
		for r in RINGS.size():
			var level: Array = RINGS[r]
			var row: Array[Vector3] = []
			for i in SEGS:
				# Fixed hash, not the stream: one shared mesh, the same rock every
				# boot. Instances turn and squash it into a whole field of others.
				var h: float = fposmod(sin(float(i) * 12.9898 + float(r) * 78.233) * 43758.5453, 1.0)
				var a: float = TAU * (float(i) + (h - 0.5) * 0.35) / float(SEGS) + float(r) * 0.4
				var rad: float = float(level[1]) * lerpf(0.8, 1.0, h)
				row.append(Vector3(cos(a) * rad, float(level[0]) + (h - 0.5) * 0.05 * float(level[1] > 0.0), sin(a) * rad))
			grid.append(row)
		for r in RINGS.size() - 1:
			# Dark foot, lit shoulder, pale weathered top.
			var t: float = (float(r) + 0.5) / float(RINGS.size() - 1)
			var shade: float = lerpf(0.66, 1.08, t)
			for i in SEGS:
				var j: int = (i + 1) % SEGS
				var p00: Vector3 = grid[r][i]
				var p10: Vector3 = grid[r][j]
				var p01: Vector3 = grid[r + 1][i]
				var p11: Vector3 = grid[r + 1][j]
				if float(RINGS[r][1]) == 0.0:
					b.add_hull_tri(p00, p11, p01, Color(shade, shade, shade))
				elif float(RINGS[r + 1][1]) == 0.0:
					b.add_hull_tri(p00, p10, p01, Color(shade, shade, shade))
				else:
					b.add_hull_quad(p00, p10, p11, p01, Color(shade, shade, shade))
		_unit_boulder = b.commit()
	return _unit_boulder


static func unit_trunk() -> ArrayMesh:
	## Tapered, faceted trunk: root flare of radius 0.5 on Y=0, thin tip at Y=1.
	## Every woody part in the world is this one mesh under a different transform —
	## trunks, boughs, twigs, palm stems — so the whole forest is a single bucket.
	if _unit_trunk == null:
		var b := LowPoly.new()
		b.index_flat = true
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
		b.index_flat = true
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
		b.index_flat = true
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
	##
	## Lofted along its length, not extruded: the profile shrinks toward both
	## ends and pinches to the baseline, so the hill rounds off into the ground
	## instead of stopping at a flat vertical cap. Seen end-on from the saddle
	## that cap was a boxy gold slab — a wall of unbroken flat shading with a
	## dead straight top, unmistakably a set piece rather than a hillside.
	if _unit_ridge == null:
		var b := LowPoly.new()
		b.smooth = true
		b.hull_origin = Vector3(0.0, 0.22, 0.0)
		const PROFILE := [
			Vector3(-0.55, 0.0, 0.0), Vector3(-0.34, 0.40, 0.0), Vector3(-0.10, 0.62, 0.0),
			Vector3(0.16, 0.60, 0.0), Vector3(0.40, 0.32, 0.0), Vector3(0.55, 0.0, 0.0)
		]
		# Stations along the long axis and the fraction of the profile each
		# keeps. The two end rings sit at zero — a ground line, not a wall.
		const RING_Z := [-0.30, -0.165, 0.0, 0.165, 0.30]
		const RING_S := [0.0, 0.78, 1.0, 0.78, 0.0]
		var base_col := Color(0.64, 0.68, 0.60)
		var top_col := Color(0.90, 0.90, 0.86)
		var rings: Array[Array] = []
		for k in RING_Z.size():
			var ring: Array[Vector3] = []
			for p in PROFILE:
				ring.append(Vector3(p.x * RING_S[k], p.y * RING_S[k], RING_Z[k]))
			rings.append(ring)
		for k in rings.size() - 1:
			# The tapers bake in a little ground shadow the way the old cap did:
			# a hill's feet are darker than its shoulder.
			var shade: float = 0.16 * (1.0 - (RING_S[k] + RING_S[k + 1]) * 0.5)
			for i in PROFILE.size() - 1:
				var t: float = (float(i) + 0.5) / float(PROFILE.size() - 1)
				b.add_hull_quad(
					rings[k][i], rings[k][i + 1], rings[k + 1][i + 1], rings[k + 1][i],
					base_col.lerp(top_col, t).darkened(shade)
				)
		# Underside strip between the two baseline edges, so nothing shows
		# through if a ridge is ever seen from below.
		for k in rings.size() - 1:
			b.add_hull_quad(
				rings[k][0], rings[k][PROFILE.size() - 1],
				rings[k + 1][PROFILE.size() - 1], rings[k + 1][0],
				base_col.darkened(0.15)
			)
		_unit_ridge = b.commit()
	return _unit_ridge


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


static func set_water_sky(c: Color, high: Color = Color(0.08, 0.10, 0.14), sheen: Color = Color(0.03, 0.03, 0.03)) -> void:
	## main.gd pushes the mood's horizon colour (and the sky above it) in here;
	## the water materials are built lazily and shared across every chunk, so the
	## values are cached on the script and applied to whichever sheets exist.
	_water_sky = c
	_water_sky_high = high
	# The tarmac reflects the same sky at a grazing angle, at a much dimmer
	# share — the water is the mirror, the road only remembers it is wet.
	LowPoly.road_material().set_shader_parameter("sky_sheen", sheen)
	for mat in [_water_material]:
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
	unit_bush()
	unit_boulder()
	unit_trunk()
	unit_crown()
	unit_conifer()
	unit_ridge()
	grass_tuft()
	unit_hay_bale()
	rotor_mesh()
	beacon_material()
	water_material()
	_ensure_rocks()
	_bands()
	# The shared LowPoly channels — two of them (road, foliage) are ShaderMaterials
	# whose creation is part of the same cold init.
	LowPoly.solid_material()
	LowPoly.glow_material()
	LowPoly.road_material()
	LowPoly.terrain_material()
	LowPoly.field_material()
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
## Cubes that are allowed to move: hedgerows. They ride the foliage material so
## the shared gust field runs visibly down a field boundary instead of the line
## standing bolted while the grass around it ripples.
var _leaf_cubes: Array[Transform3D] = []
var _leaf_cube_cols: Array[Color] = []
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
## Wall-clock mark for the current streamed slice; `_keep_streaming` parks only
## once it is spent. Reset at each build entry so a queued job starts fresh.
var _slice_started_usec: int = 0
## Hitch tracing for tools/profile_scenic and friends: when set, every slice of
## incremental work longer than ~12 ms prints its caller and cost. Off in play.
static var hitch_trace: bool = false
var _resumed_usec: int = 0


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
	_resumed_usec = Time.get_ticks_usec()
	# The other build entry points set both clocks; without this the first
	# `_keep_streaming` measured against a stale slice start and yielded a whole
	# frame before the first row went down.
	_slice_started_usec = _resumed_usec
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
	# Two cross-section bands per call: the lake's view-refined bands are a
	# metre or two of verts each, and four at a time still overran the slice
	# to ~10 ms on the climb — a visible stutter arriving exactly where the
	# rider turns to look at the water.
	const BANDS_PER_FRAME := 1
	for first_step in range(0, STEPS, steps_per):
		for first_band in range(0, band_count, BANDS_PER_FRAME):
			_build_ribbon_rows(hard, road, soft_left, soft_right, z0, first_step, mini(first_step + steps_per, STEPS), first_band, mini(first_band + BANDS_PER_FRAME, band_count))
			if _slice_spent() and not await _keep_streaming():
				return
	if not await _keep_streaming():
		return
	await _finish_ribbon_incremental(hard, road, soft_left, soft_right, z0)
	if not await _keep_streaming():
		return
	await _dress_shoulder_incremental()


func setup_props_incremental() -> void:
	_slice_started_usec = Time.get_ticks_usec()
	_resumed_usec = _slice_started_usec
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
	# Liner trees land with the shoulder, after it: anywhere the rider can
	# already see grass, the side road can already show its trees. They are
	# tagged after the shoulder pass so they keep their scenic corridor.
	_build_scenic_stub()


func _dress_shoulder_incremental() -> void:
	if bool(get_meta("shoulder_done", false)):
		return
	var from_index := get_child_count()
	await _build_reflectors(true)
	if not await _keep_streaming():
		return
	await _grass_verge_incremental()
	if not await _keep_streaming():
		return
	await _hedge_verge_incremental()
	if not await _keep_streaming():
		return
	await _publish_shoulder_incremental(from_index)
	if not await _keep_streaming():
		return
	# Same order as the sync shoulder: liner last so the scenic tag sticks.
	await _build_scenic_stub_incremental()


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
	_commit_mm(_leaves, _leaf_cols, unit_bush(), LowPoly.foliage_material(), "Foliage", true)
	_leaves.clear()
	_leaf_cols.clear()
	_shoulder_published(from_index)


func _publish_shoulder_incremental(from_index: int) -> void:
	## Four MultiMesh commits used to land in one frame — each uploads a batch to
	## the renderer, so together they were a recurring ~40 ms spike while riding.
	_commit_mm(_cubes, _cube_cols, unit_cube(), LowPoly.solid_material(), "Cubes", true)
	_cubes.clear()
	_cube_cols.clear()
	if not await _keep_streaming():
		return
	_commit_mm(_lamps, _lamp_cols, unit_cube(), LowPoly.glow_material(), "Lamps", false)
	_lamps.clear()
	_lamp_cols.clear()
	if not await _keep_streaming():
		return
	_commit_mm(_grass, _grass_cols, grass_tuft(), LowPoly.foliage_material(), "Grass", false)
	_grass.clear()
	_grass_cols.clear()
	if not await _keep_streaming():
		return
	_commit_mm(_leaves, _leaf_cols, unit_bush(), LowPoly.foliage_material(), "Foliage", true)
	_leaves.clear()
	_leaf_cols.clear()
	_shoulder_published(from_index)


func _shoulder_published(from_index: int) -> void:
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
		await _build_highway_spur_screen(true)
		if not await _keep_streaming():
			return
	await _build_ordinary_theme_scenery_incremental()
	if not await _keep_streaming():
		return
	if _on_spur:
		await _build_basin_roadside(true)
		if not await _keep_streaming():
			return
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
	# All five woodland stations — the same coverage the synchronous pass
	# publishes. Chunks that already grew their liner row in the props stub
	# only run the fill phase here; the rest plant the whole stand. One
	# station per slice keeps the hitch profile the split bought.
	var phase := 2 if bool(get_meta("stub_done", false)) else 0
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
	# One woodland station per slice — each plants rows of trees through the
	# corridor clearance sweep, and all five at once was a ~20 ms lump.
	for i in 5:
		await _build_spur_woodland(i, 1, phase, _keep_streaming)
		if not is_inside_tree():
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
			await _build_headland_face_incremental()
			if not await _keep_streaming():
				return
			# The fill has to exist even when the skin emitted nothing —
			# terrain and ledges on this chunk already wear its layer.
			_headland_fill()
			if not await _build_lake_edges_incremental():
				return
			await _build_view_frame_incremental()
			if not await _keep_streaming():
				return
			await _dress_vista_incremental()
			if not await _keep_streaming():
				return
			_build_vista_landmarks()
			if not await _keep_streaming():
				return
	await _build_spur_furniture(true)
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
	if Time.get_ticks_usec() - _slice_started_usec < slice_budget_usec:
		return true
	if hitch_trace:
		var stack := get_stack()
		var site := "?"
		if stack.size() > 1:
			site = "%s:%d" % [str(stack[1].get("function", "?")), int(stack[1].get("line", 0))]
		set_meta("dbg_stage", site)
		if _resumed_usec > 0:
			var work := Time.get_ticks_usec() - _resumed_usec
			if work >= 12000:
				print("chunk %d slice %s: %.1f ms" % [chunk_index, site, float(work) / 1000.0])
	await get_tree().process_frame
	_slice_started_usec = Time.get_ticks_usec()
	_resumed_usec = _slice_started_usec
	return is_instance_valid(self) and is_inside_tree()


func _slice_spent() -> bool:
	## Whether this build slice has run long enough to be worth a frame. Loops
	## that yield on a fixed count drain the stream queues slower than the work
	## needs — the restart test's frame windows felt that before the bike did —
	## so small batches yield only once the slice is already past its budget.
	return Time.get_ticks_usec() - _resumed_usec > slice_budget_usec


func _configure(index: int, theme_id: int) -> void:
	_slice_started_usec = Time.get_ticks_usec()
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
	if _on_spur:
		# The drowned tail of the basin sinks past the lake span onto spur-only
		# chunks — the waterline test needs the level wherever shoreline can go.
		_vp_water_y = float(_path.viewpoint_water_y(_vp_centre))


func _build_props() -> void:
	_build_highway_props()
	if _on_spur:
		_build_scenic_props()


func _build_highway_props() -> void:
	var highway_from := get_child_count()
	_build_furniture()
	# Lake chunks dress like the rest of the biome too — the sightline reserve
	# keeps the seat's view open; skipping the theme pass outright was what left
	# a kilometre of roadside beside every basin reading as a mown green plain.
	_build_ordinary_theme_scenery()
	_build_basin_roadside()
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
		_build_spur_woodland(0, 5, 2)
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
	_slice_started_usec = Time.get_ticks_usec()
	set_meta("scenic_requested", true)
	set_meta("scenic_building", true)
	_resumed_usec = Time.get_ticks_usec()
	await _build_scenic_props_incremental()
	if is_instance_valid(self):
		set_meta("scenic_done", true)
		set_meta("scenic_building", false)
		set_meta("scenic_queued", false)


func _wants_junction_stub() -> bool:
	## Woodland liner with the props pass so the lane is never a bare ribbon
	## waiting on the scenic queue — at the gore it is what the exit looks like
	## before the rider commits, and for a rider who never commits it is the
	## only dressing the unused climb ever gets.
	if not _on_spur or _path == null:
		return false
	var z := float(chunk_index) * LENGTH + LENGTH * 0.5
	return float(_path.spur_divergence(z)) >= 0.08


func _build_scenic_stub() -> void:
	if not _on_spur or bool(get_meta("scenic_done", false)) or bool(get_meta("stub_done", false)):
		return
	if not _wants_junction_stub():
		return
	var marks := _prop_marks()
	var from_index := get_child_count()
	_build_spur_woodland(0, 5, 1)
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
	# One liner station per slice — all five at once ran every tree's corridor
	# sweep in a single 15–30 ms lump on every chunk of the climb.
	for i in 5:
		await _build_spur_woodland(i, 1, 1, _keep_streaming)
		if not is_inside_tree():
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
	_slice_started_usec = Time.get_ticks_usec()
	set_meta("highway_requested", true)
	set_meta("highway_building", true)
	_resumed_usec = Time.get_ticks_usec()
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
	_build_ordinary_theme_scenery()
	_build_basin_roadside()


func _build_ordinary_theme_scenery() -> void:
	match theme:
		Env.CITY:
			_scenery_city()
		Env.FOREST:
			_scenery_forest()
		Env.MOUNTAIN:
			_scenery_mountain()
		Env.COUNTRY:
			_scenery_country()


func _build_ordinary_theme_scenery_incremental() -> void:
	## Theme dress stays visually identical; forest and mountain yield between
	## stands so fifty trees are not one hitch. Country streams inside its own
	## passes now — its fences and hedgerows were the same lump by another name.
	match theme:
		Env.CITY:
			_scenery_city()
		Env.FOREST:
			await _scenery_forest_incremental()
		Env.MOUNTAIN:
			await _scenery_mountain_incremental()
		Env.COUNTRY:
			await _scenery_country(true)
	if theme != Env.FOREST and theme != Env.MOUNTAIN and not await _keep_streaming():
		return


func _plant_inland_carriageway() -> void:
	_inland_woods(Callable())


func _plant_inland_carriageway_incremental() -> void:
	## Same stand as `_plant_inland_carriageway`, a few trees then a frame so a
	## lake-highway chunk does not plant its wood edge in one hitch.
	_inland_woods(Callable(self, "_keep_streaming"))


func _inland_woods(pace: Callable) -> void:
	## Lake chunks skip the full biome so the bench stays a picture. The inland
	## verge of the main road still wants its stands so it does not go bare for
	## the length of the basin if the rider stays on the highway — planted in
	## cells like every other verge: wooded runs alternating with open ground,
	## each run one species and one height class.
	var z0: float = float(chunk_index) * LENGTH
	var inland: float = -_vp_side if _vp_side != 0.0 else -1.0
	var side_i := int(inland)
	var tint: Color = (_pal["prop_a"] as Color).darkened(_rng.randf() * 0.2)
	var cell_a := int(floor((z0 + _stand_phase(side_i)) / STAND_CELL))
	var cell_b := int(floor((z0 + LENGTH + _stand_phase(side_i)) / STAND_CELL))
	for cell in range(cell_a, cell_b + 1):
		var stand: Array = _stand_cell(side_i, (float(cell) + 0.5) * STAND_CELL - _stand_phase(side_i), theme)
		if not stand[0]:
			continue
		var lo := maxf(z0, float(cell) * STAND_CELL - _stand_phase(side_i))
		var hi := minf(z0 + LENGTH, float(cell + 1) * STAND_CELL - _stand_phase(side_i))
		for _m in _rng.randi_range(3, 6):
			var z := _rng.randf_range(lo, hi)
			var lx: float = inland * (HALF_WIDTH + 3.5 + _rng.randf_range(0.0, 22.0))
			var species: int = int(stand[1])
			if _rng.randf() < 0.12:
				species = _stand_accent(species)
			_tree(species, z, lx, _stand_member_height(stand, 0.84, 1.14), tint)
			if pace.is_valid() and _slice_spent() and not await pace.call():
				return


func _spur_tree(species: int, z: float, lateral: float, height: float, color: Color, escape: float = 0.0) -> void:
	## Woodland row planting with a hole-fill retry. `_tree` refuses a site that
	## cannot be slid clear of the corridor — on the spur that used to leave a
	## bare station every time a plant landed near a band edge. `escape` is the
	## signed direction that walks the retry away from the corridor, in the row's
	## own lateral direction wherever open ground continues that way; 0 only where
	## the gore between the two bands is genuinely tight, so a straddle can never
	## be walked onto either carriageway.
	var try_lateral := lateral
	for _retry in 3:
		# Walking outward must not walk into the lake: the view-side face is a
		# fall to the water, and a crown planted below the waterline stands in
		# the lake like litter.
		if _on_lake and _path.height_at(z) - _path.terrain_drop(try_lateral, z) < _vp_water_y + 0.8:
			return
		var before: int = _trunks.size() + _crowns.size() + _conifers.size()
		_tree(species, z, try_lateral, height, color, true)
		if _trunks.size() + _crowns.size() + _conifers.size() > before:
			return
		if escape == 0.0:
			return
		try_lateral += escape * 6.0


func _beside_terrace(z: float, lateral: float) -> bool:
	## The lane's verge planting runs on past the terrace on the view side, and
	## there the platform's half width puts the "verge" right at the benches: a
	## hedge mound three metres across stood a stride from the seat, filling
	## the frame the moment the rider turned their head. The terrace dresses
	## itself; the lane's verge stops at its ends.
	if _vp_side == 0.0 or absf(z - _vp_centre) >= RoadPathGD.PLATFORM_HALF_LENGTH + 4.0:
		return false
	# Outboard of the spur's own centreline: the parking side keeps its verge.
	return (lateral - _vp_side * float(_path.spur_offset(z))) * _vp_side > 0.0


func _build_spur_woodland(
	first_station: int = 0, station_count: int = 5, phase: int = 0, pace: Callable = Callable()
) -> void:
	## Planting along the climb. The spur geometry is the same everywhere; what
	## grows beside it follows the biome of this stretch, so a country rise is
	## not ridden through a pine tunnel.
	##
	## `phase` splits the work the streaming passes share. 1 plants only the
	## near row — the liner the props pass lays down early so the lane is never
	## bare ribbon waiting on the scenic queue. 2 is the fill the scenic pass
	## adds once the rider commits — the back row and the undergrowth. 0 is
	## both at once, for the synchronous setup/tests.
	var z0: float = float(chunk_index) * LENGTH
	for station in range(first_station, mini(first_station + station_count, 5)):
		var z: float = z0 + 3.2 + float(station) * 7.4
		if z >= z0 + LENGTH:
			continue
		var distance: float = absf(z - _vp_centre)
		var half: float = float(_path.spur_half_width(z))
		# The lane wants trees from the moment it is a lane. Gating on the
		# divergence (and on the widened half-width) used to leave the whole
		# deceleration stretch bald even though its outer verge was already
		# open ground; the corridor sweep itself keeps the gore and both bands
		# clear wherever the two roads still run cheek by jowl.
		if half < 1.6:
			continue
		# Once the gore is wide, an inner-side reject has a whole hillside to
		# step into; near the mouth it does not, and the wedge stays open.
		var wide_gore: bool = float(_path.spur_gap(z)) > 28.0
		for road_side in [-1.0, 1.0]:
			var view_side: bool = road_side == _vp_side
			# The one gap the lane keeps is the seated corridor itself: a hard
			# window around the terrace easing into occasional framed openings,
			# then the full row resumes well before the mouth of the climb. The
			# old reveal suppressed the view side for a quarter kilometre — the
			# bare upper climb — and the hillside between the roads is no
			# sightline at all.
			var corridor := 0.0
			if view_side and _vp_side != 0.0:
				corridor = 1.0 - smoothstep(
					RoadPathGD.PLATFORM_HALF_LENGTH + RoadPathGD.PLATFORM_TERRACE + 8.0,
					RoadPathGD.PLATFORM_HALF_LENGTH + RoadPathGD.PLATFORM_TERRACE + 92.0,
					distance
				)
			var crown_scale := lerpf(1.0, 0.60, corridor)
			# A rejected plant steps further out in the row's own direction —
			# away from the lane — wherever the ground continues that way.
			var escape: float = road_side if (view_side or wide_gore) else 0.0
			# The stand cell decides whether this stretch of verge is wooded at
			# all, and what grows on it: species, height class and tint are the
			# stand's, the members' only their own jitter — groups of five to
			# eight with open ground between, never a row of lone poles. The
			# near edge plants every station inside a cell; the back row fills
			# behind it on most.
			var stand: Array = _stand_cell(int(road_side), z, _vp_theme)
			for row in range(1 if phase == 2 else 0, 2):
				if row == 1 and _rng.randf() > 0.6:
					continue
				if view_side and corridor > 0.0 and _rng.randf() < corridor:
					continue
				if not stand[0]:
					continue
				var jitter_z: float = z + _rng.randf_range(-2.0, 2.0)
				# Sample the spur at the plant point, not the station. The apron
				# widens through the taper; a setback computed 2 m uphill lands
				# in the middle of the wider tarmac.
				var plant_half: float = float(_path.spur_half_width(jitter_z))
				var plant_centre: float = _vp_side * float(_path.spur_offset(jitter_z))
				var setback: float = plant_half + RoadPathGD.SPUR_SHOULDER + 2.8 + float(row) * 7.2
				var lateral: float = plant_centre + road_side * (setback + _rng.randf_range(-1.0, 2.3))
				if _on_tarmac(jitter_z, lateral, 1.4):
					continue
				var species: int = int(stand[1])
				if _rng.randf() < 0.10:
					species = _stand_accent(species)
				var height: float = _stand_member_height(stand, 0.84, 1.14) * crown_scale
				var tint: Color
				if _vp_theme == Env.MOUNTAIN:
					tint = Color("243830").lerp(
						Color("4a5640"), clampf(float(stand[3]) * 0.4 + _rng.randf() * 0.12, 0.0, 0.35)
					)
				else:
					tint = Color("2a4634").lerp(
						Color("4a6840"), clampf(float(stand[3]) * 0.5 + _rng.randf() * 0.12, 0.0, 0.42)
					)
				_spur_tree(species, jitter_z, lateral, height, tint.darkened(float(row) * 0.14), escape)
				if _vp_theme == Env.MOUNTAIN and _rng.randf() < 0.4:
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
				# A companion beside the near row knits the stand's front —
				# the sweep walks every fourth or fifth tree out of line and
				# single spacing made each walked tree a visible hole.
				if row == 0 and corridor < 0.5 and _rng.randf() < 0.5:
					var pair_z: float = jitter_z + _rng.randf_range(2.2, 3.6)
					var pair_half: float = float(_path.spur_half_width(pair_z))
					var pair_centre: float = _vp_side * float(_path.spur_offset(pair_z))
					var pair_lateral: float = pair_centre + road_side * (
						pair_half + RoadPathGD.SPUR_SHOULDER + _rng.randf_range(2.2, 4.4)
					)
					if not _on_tarmac(pair_z, pair_lateral, 1.4):
						var pair_height: float = _stand_member_height(stand, 0.8, 1.05) * crown_scale
						var pair_species: int = int(stand[1])
						if _rng.randf() < 0.22:
							pair_species = _stand_accent(pair_species)
						_spur_tree(
							pair_species, pair_z, pair_lateral, pair_height,
							Color("2e4c36").lerp(
								Color("52704a"), clampf(float(stand[3]) * 0.45 + _rng.randf() * 0.1, 0.0, 0.4)
							),
							escape
						)
				if pace.is_valid() and _slice_spent() and not await pace.call():
					return
			# Turf and tussock right at the lane edge, every side and every
			# phase — the narrow green verge the painted embankment used to
			# leave as a bare apron. It stays low and out of the foliage sweep,
			# so it survives where crowns may not lean, and inside the seated
			# corridor it only ever laps the terrace lip.
			for _t in 2:
				var turf_z: float = z + _rng.randf_range(-3.2, 3.2)
				var turf_half: float = float(_path.spur_half_width(turf_z))
				var turf_centre: float = _vp_side * float(_path.spur_offset(turf_z))
				var turf_lateral: float = turf_centre + road_side * (
					turf_half + RoadPathGD.SPUR_SHOULDER + _rng.randf_range(1.4, 3.8)
				)
				if _on_tarmac(turf_z, turf_lateral, 1.0):
					continue
				var turf_s := _rng.randf_range(0.9, 1.7)
				if _beside_terrace(turf_z, turf_lateral):
					continue
				_blob(
					turf_z,
					turf_lateral,
					Vector3(turf_s * 1.9, turf_s * _rng.randf_range(0.45, 0.7), turf_s * 1.5),
					(_pal["verge"] as Color).lerp(_pal["prop_a"] as Color, _rng.randf() * 0.5).darkened(_rng.randf() * 0.2),
					0.0,
					false,
					true
				)
			if _vp_theme == Env.COUNTRY:
				# The country climb is a hedged lane, not a plantation: a low
				# hawthorn-dark run right at the verge carries the hedgerow the
				# oaks stand behind. It stations every pass — a hedge that only
				# shows on some stations reads as scattered bushes.
				for _h in 2:
					var hedge_z: float = z + _rng.randf_range(-3.4, 3.4)
					var hedge_half: float = float(_path.spur_half_width(hedge_z))
					var hedge_centre: float = _vp_side * float(_path.spur_offset(hedge_z))
					var hedge_lateral: float = hedge_centre + road_side * (
						hedge_half + RoadPathGD.SPUR_SHOULDER + _rng.randf_range(1.7, 2.9)
					)
					if not _on_tarmac(hedge_z, hedge_lateral, 1.2) and not _beside_terrace(hedge_z, hedge_lateral):
						_blob(
							hedge_z,
							hedge_lateral,
							Vector3(_rng.randf_range(1.7, 2.7), _rng.randf_range(0.9, 1.6), _rng.randf_range(1.5, 2.3)),
							(_pal["prop_a"] as Color).lerp(_pal["verge"], _rng.randf_range(0.15, 0.55)).darkened(_rng.randf() * 0.18),
							0.0,
							true,
							true
						)
			if phase == 1:
				continue
			# The hillside between the carriageway and the spur is deliberately
			# unreserved ground — trees on it are what the climb is ridden
			# through, and the inward glance should meet a wood, not a meadow.
			if not view_side and wide_gore and stand[0] and _rng.randf() < 0.6:
				var mid_z: float = z + _rng.randf_range(-3.0, 3.0)
				var mid_centre: float = _vp_side * float(_path.spur_offset(mid_z))
				var mid_half: float = float(_path.spur_half_width(mid_z))
				var gap: float = float(_path.spur_gap(mid_z))
				var mid_reach: float = _rng.randf_range(15.0, maxf(minf(48.0, gap - 14.0), 15.5))
				var mid_lateral: float = mid_centre + road_side * (mid_half + mid_reach)
				# The shelf's interior wood is the verge stand's own deep
				# members — same family, looser about accents.
				var mid_species: int = int(stand[1])
				if _rng.randf() < 0.3:
					mid_species = _stand_accent(mid_species)
				_spur_tree(
					mid_species,
					mid_z,
					mid_lateral,
					_stand_member_height(stand, 0.9, 1.18),
					Color("2a4634").lerp(
						Color("4a6840"), clampf(float(stand[3]) * 0.5 + _rng.randf() * 0.12, 0.0, 0.42)
					).darkened(0.06),
					escape
				)
			# And the deep gore: once the shelf is really wide the reach cap
			# leaves a hundred metres of bare embankment, which is the flat dark
			# band the s1-z2500 climb shot reads as an unlit void. Scatter the
			# rest of the shelf — mostly crown masses and stones, cheap at this
			# range, with a few real trunks — so the inward glance meets a
			# working hillside, not a wall of paint.
			if not view_side and float(_path.spur_gap(z)) > 60.0 and _rng.randf() < 0.7:
				var deep_z: float = z + _rng.randf_range(-3.4, 3.4)
				var deep_centre: float = _vp_side * float(_path.spur_offset(deep_z))
				var deep_half: float = float(_path.spur_half_width(deep_z))
				var deep_gap: float = float(_path.spur_gap(deep_z))
				var deep_reach: float = _rng.randf_range(50.0, maxf(minf(deep_gap - 16.0, 130.0), 51.0))
				var deep_lateral: float = deep_centre + road_side * (deep_half + deep_reach)
				if not _on_tarmac(deep_z, deep_lateral, 2.0):
					var droll := _rng.randf()
					if droll < 0.55:
						var ds := _rng.randf_range(4.0, 8.0)
						_blob(
							deep_z,
							deep_lateral,
							Vector3(ds * 1.6, ds * _rng.randf_range(0.5, 0.85), ds * 1.3),
							Color("1c3628").lerp(Color("315e3e"), _rng.randf()).darkened(_rng.randf() * 0.2),
							0.0,
							true
						)
					elif droll < 0.85:
						# Deep shelf trunks are the verge stand's far members —
						# same family whether the cell calls itself wooded or not.
						var deep_species: int = (
							int(stand[1]) if stand[0]
							else (Flora.BROADLEAF if _vp_theme == Env.COUNTRY else Flora.CONIFER)
						)
						_tree(
							deep_species,
							deep_z,
							deep_lateral,
							_stand_member_height(stand, 0.75, 1.05),
							Color("1a3024").lerp(Color("3a5a44"), _rng.randf())
						)
					else:
						var rs := _rng.randf_range(1.8, 3.6)
						_blob(
							deep_z,
							deep_lateral,
							Vector3(rs * 1.7, rs * _rng.randf_range(0.7, 1.0), rs * 1.4),
							Color("6f6d64").darkened(_rng.randf() * 0.22),
							0.0,
							false
						)
			if _rng.randf() > 0.5:
				continue
			# The understory keeps the seated corridor too: a lane-edge sapling
			# here stood a metre from the bench and filled the whole view.
			if view_side and corridor > 0.0 and _rng.randf() < corridor:
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
			_spur_tree(
				under_species,
				under_z,
				under_lateral,
				_rng.randf_range(4.6, 7.4) * crown_scale,
				Color("4e6844").darkened(_rng.randf() * 0.2),
				escape
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
			if _vp_theme == Env.FOREST and _rng.randf() < 0.55:
				# Ferns and moss-bright clumps at the dripline — the undergrowth
				# layer a pine lane is missing without them.
				var fern_z: float = z + _rng.randf_range(-3.0, 3.0)
				var fern_half: float = float(_path.spur_half_width(fern_z))
				var fern_centre: float = _vp_side * float(_path.spur_offset(fern_z))
				var fern_lateral: float = fern_centre + road_side * (
					fern_half + RoadPathGD.SPUR_SHOULDER + _rng.randf_range(1.8, 3.8)
				)
				if not _on_tarmac(fern_z, fern_lateral, 1.0):
					var fern_s := _rng.randf_range(0.5, 1.0)
					_blob(
						fern_z,
						fern_lateral,
						Vector3(fern_s * 1.6, fern_s * 0.8, fern_s * 1.4),
						(_pal["prop_a"] as Color).lerp(_pal["verge"], 0.25 + _rng.randf() * 0.4),
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
			if pace.is_valid() and _slice_spent() and not await pace.call():
				return


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


var _ground_colors: Dictionary = {}


func _ground_color(lateral: float, z: float) -> Color:
	## Smooth function of position, sampled per vertex — a per-quad colour would
	## stop index() merging vertices and smooth shading would never kick in.
	## Ribbon vertices are shared by the quads on either side, so the lake-side
	## mixes underneath run at least twice per sample without this cache.
	var key := Vector2(lateral, z)
	var cached: Variant = _ground_colors.get(key)
	if cached != null:
		return cached
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
	if theme == Env.COUNTRY:
		# The worked land itself: hedged parcels painted onto the same cells the
		# hedge lines are grown from, so colour and geometry never disagree.
		color = _country_field_tint(lateral, z, color, mix)
	if theme == Env.FOREST and not _on_spur and not _on_lake:
		# Under the canopy the floor sits in shade. Past the planted edge the
		# ground sinks toward the wood's dark instead of staying lit pasture —
		# the old even lawn was half of why the forest read as a park.
		var shade: float = smoothstep(HALF_WIDTH + 14.0, HALF_WIDTH + 46.0, absf(lateral))
		color = color.lerp(color.darkened(0.32), shade)
	# Near the carriageway lean toward verge green so the soft shoulder meets
	# the hard curb without a painted seam. But verge is a yellow grass and the
	# first ground band is a sun-facing scarp: under the warm key it rendered as
	# a pink-gold sand apron beside the road. Leaning toward the deeper prop
	# green — and shading the scarp a touch — keeps the seam reading as meadow.
	var near: float = 1.0 - smoothstep(HALF_WIDTH + 2.0, HALF_WIDTH + 18.0, absf(lateral))
	if near > 0.0:
		var near_grass: Color = (_pal["verge"] as Color).lerp(_pal["prop_a"] as Color, 0.55)
		color = color.lerp(near_grass, near * 0.5).darkened(near * 0.07)
	if _on_spur:
		color = color.lerp(_embankment_color(lateral, z), _embankment_mix(lateral, z))
		color = color.lerp(_deck_color(z, lateral), _deck_mix(z, lateral))
		color = color.lerp(_terrace_color(), _terrace_mix(z, lateral))
	if _on_lake:
		var face := _face_mix(z, lateral)
		if face > 0.001:
			color = color.lerp(_face_color(z, lateral), face)
		color = color.lerp(_shore_color(), _shore_mix(z, lateral))
		color = color.lerp(_wash_color(), _wash_mix(z, lateral))
	_ground_colors[key] = color
	return color


func _curb_edge_color() -> Color:
	## The narrow shelf between tarmac and verge. The palette's pale concrete
	## reads as poured kerb in the city, but on rural roads this strip is dirt
	## and gravel — darker, and leaning a little toward the verge's green so the
	## surface sequence is tarmac, grit, grass rather than tarmac, beach, grass.
	return (_pal["curb"] as Color).lerp(_pal["prop_a"] as Color, 0.72).darkened(0.12)


func _shoulder_color(lateral: float, z: float, band: String) -> Color:
	## Soft verge / near-ground colour. Gravel grain on the curb lip, grass further
	## out — so the strip between tarmac and guardrail is never a flat slab.
	if band == "ground":
		return _ground_color(lateral, z)
	var grain: float = 0.5 + 0.5 * sin(lateral * 0.14 + z * 0.07) * sin(lateral * 0.05 - z * 0.03)
	var gravel: Color = (_pal["shoulder"] as Color).darkened(0.1 + grain * 0.12)
	var grass: Color = (_pal["verge"] as Color).lerp(_pal["prop_a"] as Color, grain * 0.35)
	var out: float = absf(lateral) - HALF_WIDTH
	# The verge band is a single quad: its two edge colours interpolate across
	# all 3.1 m, so the blend has to finish before the band's inner edge (0.7 m)
	# or gravel bleeds pink across the whole strip. The 0.7 m curb top already
	# carries the gravel lip.
	var t: float = smoothstep(0.05, 0.8, out)
	var color: Color = gravel.lerp(grass, t)
	if _on_spur:
		color = color.lerp(_deck_color(z, lateral), _deck_mix(z, lateral) * 0.85)
	return color


# ------------------------------------------------------------ country fields


func _field_edge_at(edge_i: int, z: float, side_i: int) -> float:
	## Where one depth boundary sits at this z. It wanders a few metres along
	## its run — differently on each side of the road — so parcel edges meander
	## the way hedgerows do instead of drafting a surveyor's grid.
	return FIELD_EDGES[edge_i] + sin(
		z * 0.013 + float(edge_i) * 1.9 + float(side_i) * 0.83
	) * FIELD_WAVE[edge_i]


var _field_edge_rows: Dictionary = {}  # Vector2(z, side) -> PackedFloat64Array
var _field_phases: Dictionary = {}  # Vector2i(side_i, band) -> float
var _field_cells: Dictionary = {}  # Vector3i(side_i, band, cell) -> [kind, hedged, lift, period]
var _field_runs: Dictionary = {}  # Vector3i(side_i, edge_i, zseg) -> bool

var _stand_phases: Dictionary = {}  # side_i -> float
var _stand_cells: Dictionary = {}  # Vector3i(side_i, cell, theme_id) -> [active, species, height, tint]


func _stand_phase(side_i: int) -> float:
	## Each side's stand grid slides along the route so the gaps in the two wood
	## edges never line up into a cross-section of bare road.
	var cached: Variant = _stand_phases.get(side_i)
	if cached != null:
		return cached
	var phase := (
		float(posmod(hash(Vector2i(side_i * 41, int(_path.world_seed) ^ 0x71b3)), 1000))
		* 0.001 * STAND_CELL
	)
	_stand_phases[side_i] = phase
	return phase


func _stand_cell(side_i: int, z: float, theme_id: int) -> Array:
	## One STAND_CELL metres of roadside, answered the way a real stand is:
	## [wooded at all, species family, stand height, tint roll]. Trees come and
	## go inside a cell; the stand's own decisions do not — which is what stops
	## the verge reading as individually random specimens on a metronome.
	var cell := int(floor((z + _stand_phase(side_i)) / STAND_CELL))
	var key := Vector3i(side_i, cell, theme_id)
	var cached: Variant = _stand_cells.get(key)
	if cached != null:
		return cached
	var seed := int(_path.world_seed)
	var h := func(salt: int) -> float:
		return float(posmod(hash(Vector3i(side_i * 173 + salt, cell, seed)), 1000)) * 0.001
	var roll: float = h.call(11)
	var species: int
	match theme_id:
		Env.MOUNTAIN:
			# Montane conifer stands with real pine blocs and the rare birch seam.
			species = Flora.CONIFER if roll < 0.7 else (Flora.PINE if roll < 0.94 else Flora.BIRCH)
		Env.COUNTRY:
			# Hedgerow oaks and beech, birch seams, the odd conifer shelterbelt.
			species = Flora.BROADLEAF if roll < 0.62 else (Flora.BIRCH if roll < 0.78 else Flora.CONIFER)
		_:
			# Forest: the conifer wall, broken by birch seams and pine blocs —
			# one species per stretch, shifting stand by stand, never per tree.
			species = Flora.CONIFER if roll < 0.68 else (Flora.BIRCH if roll < 0.78 else (Flora.PINE if roll < 0.93 else Flora.BROADLEAF))
	var hr: float = h.call(23)
	var height: float
	if theme_id == Env.MOUNTAIN:
		# Fellside timber runs shorter and tighter than the lowland stand.
		height = lerpf(7.0, 11.0, h.call(29)) if hr < 0.62 else lerpf(11.0, 15.0, h.call(29))
	elif hr < 0.66:
		# Canopy classes only — the cell decides mid or tall, never "dwarf":
		# whole cells of 4.5-7.5 m timber beside a tall stand were the 3-4x
		# toy-town spread at the road edge. The NORTHSTAR short layer lives in
		# single trees *inside* the stand (_stand_member_height), keeping the
		# ~60/30/10 population without a dwarf row in any frame.
		height = lerpf(8.5, 12.0, h.call(29))
	else:
		height = lerpf(12.5, 16.5, h.call(29))
	var info: Array = [h.call(0) < 0.64, species, height, h.call(37)]
	_stand_cells[key] = info
	return info


func _stand_accent(species: int) -> int:
	## The minority tree inside a stand: a conifer bloc carries the odd birch,
	## an oak line the odd holly-dark conifer. What a stand never carries is a
	## second random family per member.
	match species:
		Flora.CONIFER, Flora.PINE:
			return Flora.BIRCH
		Flora.BIRCH:
			return Flora.BROADLEAF
		_:
			return Flora.CONIFER


func _stand_member_height(stand: Array, lo: float, hi: float) -> float:
	## One member's height: the stand's canopy class with a small jitter —
	## except the odd understory tree (~one in nine), which is where the
	## NORTHSTAR short class lives. A short grown *inside* a stand reads as
	## the young layer of a real margin; a short grown as its own stand read
	## as toy town.
	var h := float(stand[2]) * _rng.randf_range(lo, hi)
	if _rng.randf() < 0.11:
		h = maxf(4.8, float(stand[2]) * _rng.randf_range(0.45, 0.62))
	return h


func _field_edges_at(z: float, side_i: int) -> PackedFloat64Array:
	## All six depth boundaries for one cross-section. A ribbon row's vertices
	## share z, so this runs six sine waves per row instead of per vertex.
	var key := Vector2(z, side_i)
	var cached: Variant = _field_edge_rows.get(key)
	if cached != null:
		return cached
	var edges := PackedFloat64Array()
	edges.resize(FIELD_EDGES.size())
	for i in FIELD_EDGES.size():
		edges[i] = _field_edge_at(i, z, side_i)
	_field_edge_rows[key] = edges
	return edges


func _field_phase(side_i: int, band: int) -> float:
	## Each depth band slides its own parcel grid, so the field ends on opposite
	## sides of the road never line up into avenues.
	var key := Vector2i(side_i, band)
	var cached: Variant = _field_phases.get(key)
	if cached != null:
		return cached
	var phase := (
		float(posmod(hash(Vector2i(side_i * 733 + band * 131, int(_path.world_seed))), 1000))
		* 0.001
		* FIELD_LENGTHS[band]
	)
	_field_phases[key] = phase
	return phase


func _field_cell(side_i: int, band: int, cell: int) -> Array:
	## [kind, road-end hedged, tone lift, crop row period] for one parcel —
	## every vertex in the cell asks the same four hashed questions.
	var key := Vector3i(side_i, band, cell)
	var cached: Variant = _field_cells.get(key)
	if cached != null:
		return cached
	var h := float(
		posmod(hash(Vector3i(side_i * 131 + band * 37, cell, int(_path.world_seed))), 1000)
	) * 0.001
	var kind := Field.FALLOW
	if h < 0.34:
		kind = Field.GRAZED
	elif h < 0.68:
		kind = Field.PASTURE
	elif h < 0.86:
		kind = Field.CROP
	elif h < 0.95:
		kind = Field.MOWN
	var info := [
		kind,
		posmod(
			hash(Vector3i(side_i * 197 + band * 41, cell, int(_path.world_seed) ^ 0x5a37)), 100
		)
		< 62,
		(float(posmod(hash(Vector3i(side_i * 17 + band * 5, cell, int(_path.world_seed))), 100)) - 50.0) * 0.0009,
		13.0 + float(posmod(hash(Vector2i(cell, band * 7 + side_i)), 100)) * 0.14,
	]
	_field_cells[key] = info
	return info


func _field_kind(side_i: int, band: int, cell: int) -> int:
	## What one parcel is growing, hashed off the world seed so the same map
	## answers the ground colour and the prop planting identically.
	return _field_cell(side_i, band, cell)[0]


func _field_hedged(side_i: int, band: int, cell: int) -> bool:
	## Whether a parcel's road-end boundary grows a hedge — roughly three in
	## five; the rest stay open grass with only a ditch line painted.
	return _field_cell(side_i, band, cell)[1]


func _field_hedge_run(side_i: int, edge_i: int, zseg: int) -> bool:
	## Whether one FIELD_RUN stretch of a depth boundary stands grown. Keyed the
	## same way the ground colour asks, so a dark boundary line always has its
	## hedge on it and a gap stays pale.
	var key := Vector3i(side_i, edge_i, zseg)
	var cached: Variant = _field_runs.get(key)
	if cached != null:
		return cached
	var run := posmod(
		hash(Vector3i(side_i * 89 + edge_i * 29, zseg, int(_path.world_seed) ^ 0x2e51)), 100
	) < 46
	_field_runs[key] = run
	return run


func _field_kind_at(side_i: int, out: float, z: float) -> int:
	## Which parcel a prop lands in, on the unwobbled edges — a bale asks
	## "which field am I in", not "where exactly is the hedge line". -1 past
	## the last field edge, where the plain wash takes over.
	var band := 0
	while band < FIELD_EDGES.size() and out >= FIELD_EDGES[band]:
		band += 1
	if band >= FIELD_LENGTHS.size():
		return -1
	var cell := int(floor((z + _field_phase(side_i, band)) / FIELD_LENGTHS[band]))
	return _field_kind(side_i, band, cell)


func _field_tone(kind: int, grain: float) -> Color:
	## A parcel's two-tone wash. All greens and damp earth — no golds: ripe corn
	## under the warm key is exactly the sandy slab this biome already lost once.
	match kind:
		Field.GRAZED:
			return Color("38542a").lerp(Color("44602f"), grain)
		Field.PASTURE:
			return Color("4a722d").lerp(Color("567f33"), grain)
		Field.CROP:
			return Color("527f30").lerp(Color("60893a"), grain)
		Field.MOWN:
			# Fresh-cut grass — the palest parcel on the sheet, but a sage green:
			# the straw colour lives on the bales, not on the ground.
			return Color("5e8148").lerp(Color("6d8e50"), grain)
		_:
			# Ploughed earth: damp loam, the darkest parcel on the sheet. Kept
			# green-grey on the red channel's wrong side — a warm brown bakes to
			# gold under the low sun and the whole parcel reads as sand.
			return Color("414931").lerp(Color("4c553c"), grain)


func _country_field_tint(lateral: float, z: float, base: Color, grain: float) -> Color:
	## Worked land painted onto the ground mesh. Everything is a pure function
	## of position, so neighbouring chunks shade the same parcels and the hedge
	## planting in _scenery_country reads the very same cells.
	var out := absf(lateral)
	if out < 15.5 or out > FIELD_EDGES[FIELD_EDGES.size() - 1]:
		return base
	var side_i := 1 if lateral > 0.0 else -1
	var edges := _field_edges_at(z, side_i)
	var band := 0
	while band < edges.size() and out >= edges[band]:
		band += 1
	if band >= edges.size():
		return base
	var edge_out := edges[band]
	var edge_in := 15.5 if band == 0 else edges[band - 1]
	# Shearing z by a slow wave of `out` tilts every field end a little off the
	# perpendicular — parcels that skew rather than stamp a grid.
	var shear := sin(out * 0.05 + float(band) * 1.7) * (2.0 + float(band) * 1.6)
	var len_i := FIELD_LENGTHS[band]
	var phase := _field_phase(side_i, band)
	var cell := int(floor((z + shear + phase) / len_i))
	var cell_a := float(cell) * len_i - phase - shear
	var cell_b := cell_a + len_i
	var info := _field_cell(side_i, band, cell)
	var kind: int = int(info[0])
	var tone := _field_tone(kind, grain)
	# Per-parcel lift, so two neighbouring pastures never sit the same green.
	# Modest: at ±0.08 the palest parcels washed to cream under the day key.
	tone = tone.lightened(float(info[2]))
	# Boundary shadow: a hedge casts a dark line on its own side of a parcel
	# edge — a grown one deeper, an open ditch a bare hint. The z ends belong
	# to whichever cell opens there; the depth edges break into FIELD_RUN
	# stretches so the lines come and go like real hedgerows.
	var shade := 0.0
	var d_a := z - cell_a
	var d_b := cell_b - z
	if d_a < d_b:
		shade = (1.0 - smoothstep(0.4, 4.5, d_a)) * (0.17 if bool(info[1]) else 0.05)
	else:
		var hedged_b: bool = bool((_field_cell(side_i, band, cell + 1))[1])
		shade = (1.0 - smoothstep(0.4, 4.5, d_b)) * (0.17 if hedged_b else 0.05)
	var zseg := int(floor(z / FIELD_RUN))
	if out - edge_in < edge_out - out:
		var hedged := band > 0 and _field_hedge_run(side_i, band - 1, zseg)
		shade = maxf(shade, (1.0 - smoothstep(0.4, 3.6, out - edge_in)) * (0.15 if hedged else 0.05))
	else:
		shade = maxf(shade, (1.0 - smoothstep(0.4, 3.6, edge_out - out)) * (0.15 if _field_hedge_run(side_i, band, zseg) else 0.05))
	tone = tone.lerp((_pal["prop_a"] as Color).darkened(0.18), minf(shade, 0.6))
	# Standing crop carries tramlines — faint rows crossing the parcel along the
	# one direction the vertex grid can draw, faded before they could zebra.
	if kind == Field.CROP:
		var row_vis := 1.0 - smoothstep(80.0, 150.0, out)
		if row_vis > 0.0:
			tone = tone.darkened((0.5 + 0.5 * sin(z * TAU / float(info[3]))) * 0.11 * row_vis)
	# Farther parcels keep their shapes but breathe toward the meadow wash —
	# aerial softening, so the distance is hazy farmland, not a checkerboard.
	tone = tone.lerp(base.lightened(0.03), smoothstep(150.0, 290.0, out) * 0.5)
	return base.lerp(tone, 0.88)


func _embankment_mix(lateral: float, z: float) -> float:
	## Rockier cut on the outer bank of a climbing spur, soft fill on the inside.
	## Without this the whole climb is one ground colour and the ribbon reads as a
	## painted strip rather than a road carved into a hillside.
	if not _on_spur:
		return 0.0
	var centre: float = _vp_side * float(_path.spur_offset(z))
	var half: float = float(_path.spur_half_width(z))
	var out: float = absf(lateral) - absf(centre) - half
	if out < 1.0 or out > 18.0:
		return 0.0
	# Strongest on the steep outer face, fading into ordinary ground — and kept
	# narrow: the climb is a grassed lane with a cut lip, not a twenty-metre
	# apron of bare bank.
	var band: float = smoothstep(1.0, 3.2, out) * (1.0 - smoothstep(9.0, 18.0, out))
	var grain: float = 0.45 + 0.55 * sin(z * 0.07 + out * 0.11) * sin(z * 0.023 - out * 0.05)
	return band * grain


func _embankment_color(lateral: float, z: float) -> Color:
	## Biome-specific cut-bank stone so mountain scree and country clay each
	## read as a different hillside from the same spur geometry.
	var grain: float = 0.5 + 0.5 * sin(lateral * 0.09 + z * 0.04)
	match _vp_theme if _on_spur else theme:
		Env.MOUNTAIN:
			return Color("565a52").lerp(Color("4a5248"), grain * 0.5)
		Env.FOREST:
			# 5a5848 lit to a golden scarp beside the spur; cooler keeps it on
			# the moss side of the cut bank. 4c5147 still warmed to bare dirt
			# where the bank catches the key — a moss-dark olive survives it.
			return Color("3f4a35").lerp(Color("33402c"), grain * 0.4)
		Env.COUNTRY:
			# Down from 9a7e4c twice now: at this brightness any warm albedo
			# goes gold under the key, and the whole outer bank read as sand.
			# Grassed-over bank greens now, darker toward the cut.
			return Color("44522f").lerp(Color("4d5c33"), grain * 0.45)
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
	# And it belongs to the drop, not to the hill the ridge becomes past the
	# end of the lake. Without this fade the whole tail kept its cliff paint
	# and stood on the horizon as a smooth pale dune — the same fake cone the
	# rock beds exist to kill. As the nose dives the paint recedes with it and
	# the tail goes back to being green hillside.
	var tail := 1.0 - smoothstep(
		RoadPathGD.LAKE_SPAN, RoadPathGD.LAKE_SPAN * 1.45, absf(z - _vp_centre)
	)
	# A face is rock only while it is a face. Where the basin tails off toward
	# the junction the same lateral band flattens into a drowned plain a metre
	# above the water, and rock paint over it read as a pale concrete apron a
	# hundred metres wide. Below a couple of metres of freeboard that ground is
	# marsh, not cliff — hand it to the shore and grass colours.
	var here: float = float(_path.height_at(z)) - float(_path.terrain_drop(lateral, z)) - _vp_water_y
	var freeboard := smoothstep(1.0, 4.5, here)
	# The rock paint belongs to the steep face, not to the level made ground the
	# terrace stands on — the lip shelf shares the face's lateral range, and
	# painted flat it reads as a pale concrete apron hanging off the parapet.
	return (
		band
		* (0.3 + 0.7 * grain)
		* (1.0 - float(_path.spur_deck_blend(z, lateral)))
		* tail
		* freeboard
	)


func _face_color(z: float = 0.0, lateral: float = 0.0) -> Color:
	## Stone, from the same family as the range across the water, so the headland
	## reads as belonging to the same country as its own skyline. Tinting the
	## theme's foliage colour toward grey instead just gives greyish grass.
	##
	## The face is banded into beds. A single stone tone over thirty metres of
	## drop is the smooth slab the scarp skin exists to fix, and vertex colour
	## does at bench height what a relief skin cannot do at a hundred metres:
	## the country's right-hand wall read as one glowing wedge precisely because
	## every vertex on it carried the same colour. Beds wander a little along
	## the shore, each keeps its own weathered tone, and the lower edge of each
	## darkens where the bed above throws it into shadow.
	var base := _face_base_color()
	if not _on_lake or lateral * _vp_side <= 0.0:
		return base
	var out := absf(lateral)
	var top := float(_path.headland_crest(z)) - 6.0
	var near := float(_path.viewpoint_near_shore(z))
	if out <= top or out >= near or near - top < 10.0:
		return base
	var t := (out - top) / (near - top)
	var beds := t * 7.0 + 0.7 * sin(z * 0.045)
	var frac := fposmod(beds, 1.0)
	var bed_id := int(floorf(beds))
	var weather := float(posmod(bed_id * 53 + int(floorf(z * 0.13)) * 17, 97)) / 97.0
	# A sawtooth, not bands: each bed shades from sunlit cap down to shadowed
	# foot, and the wrap from one bed to the next is a hard step in value.
	# Seven-metre vertex colour cannot draw a thin seam — it falls between the
	# samples — but it can draw a jump between two adjacent quads, and a row of
	# jumps is what reads as a stratum. The foot cools as it darkens: bed shade
	# is skylight, not less sun, and only a hue shift survives the warm key.
	# 0.52 crushed the bed feet to the same black the scarp used to render in
	# shade — a hard 0.40 keeps the value step without losing the surface.
	var shade := base.darkened(0.40).lerp(Color("454b52"), 0.35)
	var col := base.darkened(0.05).lerp(shade, frac)
	col = col.lerp(base.darkened(0.28), weather * 0.4)
	return col.lightened(0.08 * (1.0 - t))


func _face_base_color() -> Color:
	match theme:
		Env.MOUNTAIN:
			return Color("a8adb4")
		Env.FOREST:
			# 857f6c was the whole cream dune: a warm pale grey under the day key
			# renders as sand across the entire face. Country's fix applies here
			# too — G ahead of R so the key lands moss, a step deeper for the
			# forest's shaded-cedar read.
			return Color("46584a")
	# a39a80 rendered as orange clay — the sunlit bank face ringing the lake was
	# the sand strip's biggest offender. Neutral 7d7c72 still went ochre on the
	# bright hay ground under the warm key — the base has to start green for the
	# blend to land as a grassed bank instead of a sandstone one. The key's red
	# gain is roughly double its green, so killing the tan read is a hue job,
	# not a value job: keep the luminance, put G well ahead of R, and the lit
	# panels land as grey-olive stone instead of straw. 45574a tried to win on
	# darkness and read as a black slab.
	return Color("4a6350")


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
	## Worn grass at the road's edge, the same on every theme. The grain is long
	## and shallow on purpose: at a couple of metres of wavelength it read as
	## damage to the road rather than as texture on the ground beside it.
	var grain: float = 0.5 + 0.5 * sin(lateral * 0.11 + z * 0.055) * sin(lateral * 0.043 - z * 0.026)
	# Grey gravel kept arriving as sand: every neutral tried still renders tan
	# under the warm key, and a tan strip beside a country lane is beach, not
	# verge. Olive went the same way — the key doubles red against green, so a
	# mid olive lights up gold. The deep prop green is what the verge grass
	# already renders as beside it, so the strip lands as a close-cropped grass
	# edge and cannot read as sand at any temperature.
	return (_pal["verge"] as Color).lerp(_pal["prop_a"] as Color, 0.62 + grain * 0.28).darkened(0.10 + grain * 0.08)


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
	# Hug the shorelines, not the altitude: the height test alone paints every
	# drowned flat as shingle, and where the basin tails off toward the junction
	# the flats run for hundreds of metres — a pale concrete apron in plan.
	# Ground counts as a shore only while a real shoreline is a dozen metres
	# away; past that it is marshy verge and takes the grass colours.
	var out := absf(lateral)
	var near: float = float(_path.viewpoint_near_shore(z))
	var far: float = float(_path.viewpoint_far_shore(z, _vp_centre))
	var gap: float = minf(absf(out - near), absf(out - far))
	return (1.0 - smoothstep(6.0, 14.0, gap)) * (1.0 - smoothstep(0.1, 1.7, here))


func _shore_color() -> Color:
	## Damp shingle. Grey, not lightened shoulder — a lifted warm tone caught the
	## key light and ringed the lake in ochre, which read as a beach. A darker
	## grey-blue sits under the waterline sheen without breaking it.
	match _vp_theme:
		Env.MOUNTAIN:
			return Color("6a6e68")
		Env.FOREST:
			# Same damp moss shingle the country band uses — 666a62 was a pale
			# grey that caught the key and continued the sand ring into forest.
			return Color("3f4c42")
	# Country's grey still rendered as wet sand under the day key — the band
	# sits flat and takes the full warm light. Dark moss-green shingle instead.
	return Color("414a40")


func _wash_mix(z: float, lateral: float) -> float:
	## A drier, brighter gravel wash sitting just above `_shore_mix`'s damp
	## shingle — the line of pale stones a lake leaves on the last metre of bank.
	## Runs a little wider than the damp band so the waterline reads as a shore,
	## not as a razor edge between grass and water.
	if lateral * _vp_side <= 0.0 or absf(lateral) < float(_path.headland_crest(z)):
		return 0.0
	var here: float = float(_path.height_at(z)) - float(_path.terrain_drop(lateral, z)) - _vp_water_y
	if here < 0.9 or here > 3.2:
		return 0.0
	# Same shoreline hug as `_shore_mix`, a few metres wider for the dry band.
	var out := absf(lateral)
	var near: float = float(_path.viewpoint_near_shore(z))
	var far: float = float(_path.viewpoint_far_shore(z, _vp_centre))
	var gap: float = minf(absf(out - near), absf(out - far))
	if gap > 20.0:
		return 0.0
	var grain: float = 0.6 + 0.4 * sin(z * 0.09 + lateral * 0.05) * sin(z * 0.031 - lateral * 0.021)
	return (
		(1.0 - smoothstep(12.0, 20.0, gap))
		* smoothstep(0.9, 1.5, here)
		* (1.0 - smoothstep(2.4, 3.2, here))
		* grain
	)


func _wash_color() -> Color:
	## Sun-dried gravel — light enough to read as the tide line, still a stone
	## colour so it does not turn into a chalk outline around the lake. Greyed:
	## the old warm beige was the ochre ring at the waterline under day sun.
	match _vp_theme:
		Env.MOUNTAIN:
			return Color("7e7c72")
		Env.FOREST:
			return Color("4d5849")
	# Same problem a step further up the bank: 807b6e sun-dries straight to
	# straw. A green-grey gravel reads as the damp pasture edge it is.
	return Color("525b4c")


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
					if band[4] == "curb":
						# The curb top is a flat 0.7 m shelf: at handlebar height it
						# foreshortens into a broad strip beside the tarmac, and the
						# pale concrete tone kept rendering as sand under the warm
						# key. A dirt-and-gravel edge, part-way to the verge green,
						# is what a country road actually grows along its lip.
						band_color = _curb_edge_color()
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
	await _build_markings(hard, z0, true)
	if not await _keep_streaming():
		return
	if _on_spur:
		_build_decel_lane(hard, z0)
		_build_gore_paving(road, z0)
		_build_gore_hatch(hard, z0)
		if not await _keep_streaming():
			return
		await _commit_spur_meshes_incremental(z0)
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
		_build_gore_paving(road, z0)
		_build_gore_hatch(hard, z0)


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


func _commit_spur_meshes_incremental(z0: float) -> void:
	## Same meshes as `_commit_spur_meshes`, spread so the climb does not pay the
	## whole spur ribbon plus bays, barrier and two uploads in one frame. The
	## ribbon takes step ranges and draws no rng, so the slices are identical.
	if not _on_spur or get_node_or_null("SpurSurface") != null:
		return
	var spur_hard := LowPoly.new()
	var spur_road := LowPoly.new()
	for first in range(0, STEPS, 2):
		_build_spur_ribbon(spur_hard, spur_road, z0, first, mini(2, STEPS - first), false)
		if _slice_spent() and not await _keep_streaming():
			return
	await _build_platform_bays(spur_hard, z0, true)
	if not await _keep_streaming():
		return
	await _build_spur_barrier(spur_hard, z0, true)
	if not await _keep_streaming():
		return
	var from_index := get_child_count()
	var details: MeshInstance3D = spur_hard.commit_to(self, "SpurDetails")
	if details:
		details.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		details.set_meta("ribbon", true)
	if not await _keep_streaming():
		return
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
		terrain_mesh.material_override = LowPoly.field_material()
		# Flat ground casting onto itself buys nothing and costs a shadow pass.
		terrain_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if _on_lake:
			# The shaded face of the nose is this ribbon, not the scarp skin —
			# hiding ViewpointHeadland left the black slab untouched. It joins
			# the fill's cull mask so the headland's own sky light can reach it.
			terrain_mesh.layers = HEADLAND_FILL_LAYER


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


func _build_markings(b: LowPoly, z0: float, streamed: bool = false) -> void:
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
				_worn_stripe(stripe, za)
			)
			if i % 4 == 3 and streamed and _slice_spent() and not await _keep_streaming():
				return
		if streamed and _slice_spent() and not await _keep_streaming():
			return

	# Dashed lane dividers between the same-direction lanes. Phase comes from
	# world z, so dashes run unbroken across chunk seams.
	var lanes: int = _path.LANE_COUNT
	var dz := 0.5
	var z := z0
	var marks := 0
	while z < z0 + LENGTH - 0.001:
		if fposmod(z + dz * 0.5, DASH_PERIOD) < DASH_ON:
			var worn := _worn_stripe(stripe, z + dz * 0.5)
			for lane in range(1, lanes - 1):
				var lx: float = (_path.lane_x(lane - 1) + _path.lane_x(lane)) * 0.5
				b.add_quad(
					_p(z, lx - 0.09, -LIFT),
					_p(z, lx + 0.09, -LIFT),
					_p(z + dz, lx + 0.09, -LIFT),
					_p(z + dz, lx - 0.09, -LIFT),
					worn
				)
		z += dz
		marks += 1
		# ~80 dashes of path samples was the head of `_finish_ribbon` — the whole
		# stripe pass in one slice. Streamed builds get a boundary mid-run.
		if marks % 4 == 0 and streamed and _slice_spent() and not await _keep_streaming():
			return

	# The last boundary is not a lane line but the centre line of a two-way
	# road: the lane past it is the oncoming flow. Solid and slightly wider —
	# the only paint that says the far lane runs at the rider.
	var centre_lx: float = (_path.lane_x(lanes - 2) + _path.lane_x(lanes - 1)) * 0.5
	for i in STEPS:
		var za := z0 + float(i) * step
		var zb := za + step
		b.add_quad(
			_p(za, centre_lx - 0.13, -LIFT),
			_p(za, centre_lx + 0.13, -LIFT),
			_p(zb, centre_lx + 0.13, -LIFT),
			_p(zb, centre_lx - 0.13, -LIFT),
			_worn_stripe(stripe, za)
		)
		if i % 4 == 3 and streamed and _slice_spent() and not await _keep_streaming():
			return


func _worn_stripe(stripe: Color, z: float) -> Color:
	## Paint wears in stretches, not per metre — sun and plough take it off in
	## runs of tens of metres, and a per-quad speckle would read as noise rather
	## than age. Two slow overlapping sines give that drift; the swing stays
	## small enough that the freshest paint still reads as one line with the
	## faded runs.
	var wear := 0.90 + 0.07 * sin(z * 0.109 + 3.1) * sin(z * 0.031 + 1.4)
	return Color(stripe.r * wear, stripe.g * wear, stripe.b * wear)


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
	# The basin only exists on the view side — inland scatter skips the
	# waterline query and answers `viewpoint_reserves` directly below anyway.
	if lateral * _vp_side <= 0.0:
		return false
	# Below the waterline nothing random is allowed at all. `viewpoint_reserves`
	# covers the lake *bed* the set piece digs, but the water sheet reaches far
	# past it — out to the ranges — and the ordinary verge scatter was happily
	# planting bushes over the whole of it. That went unnoticed only while every
	# biome palette was the same low-chroma beige as the lake it was strewn
	# across; the moment the palettes got their hues back it read as confetti
	# floating on the water. The drowned tail past the lake's end asks the same
	# question on spur chunks: its sinking ground dips under the sheet too.
	if _path.height_at(z) - _path.terrain_drop(lateral, z) < _vp_water_y + 0.6:
		return true
	return bool(_path.viewpoint_reserves(z, lateral))


func _ground_scatter_allowed(z: float, lateral: float, clearance: float = 0.6) -> bool:
	## Field grass and similar unguarded scatter. `_blob` now rejects tarmac even
	## when forced; grass tufts are appended directly and have to ask themselves.
	return not _on_tarmac(z, lateral, clearance) and not _viewpoint_reserves_sightline(z, lateral)


var _corridor_frames: Dictionary = {}
var _band_env := Vector2.ZERO
var _band_env_ready := false


func _band_envelope() -> Vector2:
	## The outermost lateral any corridor band reaches anywhere over this
	## chunk, padded by the widest part span: a plant whose own station sits
	## beyond it stays beyond every band at every station the sweep could
	## visit, so it cannot touch the road and skips the sweep entirely. The
	## frames it walks are the shared corridor cache, so it costs a few
	## stations once per chunk rather than a sweep per plant. The sample step
	## and the padding match the sweep's own grid and the widest part span, so
	## a band edge the sweep could see can never reach past the envelope.
	if _band_env_ready:
		return _band_env
	var z0 := float(chunk_index) * LENGTH
	var lo := INF
	var hi := -INF
	var z := z0 - 20.0
	while z <= z0 + LENGTH + 20.0:
		for band: Vector2 in _corridor_frame(z)[2]:
			lo = minf(lo, band.x)
			hi = maxf(hi, band.y)
		z += 4.0
	_band_env = Vector2(lo, hi)
	_band_env_ready = true
	return _band_env


func _corridor_frame(z: float) -> Array:
	## [centre, right, bands, edge heights] for one station, cached on a
	## 1 m grid. Every
	## pushed plant sweeps the same stretch of route, so the path queries —
	## the expensive part of the corridor check — are paid once per station,
	## not once per plant part per station.
	var key := snappedf(z, 1.0)
	var cached: Variant = _corridor_frames.get(key)
	if cached != null:
		return cached
	var flat: Basis = _path.frame_flat_at(key)
	# The fourth slot lazily maps a band-edge lateral to that edge's road
	# height. Every part near a station clamps to the same two edge lats, so
	# the height query is paid once per edge rather than once per part.
	var frame := [_path.center_at(key), flat.x, _road_bands(key), {}]
	_corridor_frames[key] = frame
	return frame


func _road_bands(z: float) -> Array[Vector2]:
	## Rideable strips at this station, each widened by its shoulder: the main
	## carriageway and — on the climb to an overlook — the scenic spur, which is
	## the same tarmac to a rider even though it lives sixty metres out.
	var bands: Array[Vector2] = [
		Vector2(-HALF_WIDTH - RoadPathGD.SPUR_SHOULDER, HALF_WIDTH + RoadPathGD.SPUR_SHOULDER)
	]
	var spur: Vector2 = _path.spur_interval(z)
	if spur != Vector2.ZERO:
		bands.append(
			Vector2(spur.x - RoadPathGD.SPUR_SHOULDER, spur.y + RoadPathGD.SPUR_SHOULDER)
		)
	return bands


func _band_hit(z: float, slat: float, need: float) -> bool:
	## Whether a disc of half-width `need` at this lateral touches a corridor band.
	if absf(slat) <= HALF_WIDTH + RoadPathGD.SPUR_SHOULDER + need:
		return true
	var spur: Vector2 = _path.spur_interval(z)
	return (
		spur != Vector2.ZERO
		and slat >= spur.x - RoadPathGD.SPUR_SHOULDER - need
		and slat <= spur.y + RoadPathGD.SPUR_SHOULDER + need
	)


func _foliage_road_push(world_pos: Vector3, reach: float, bottom_y: float, sways: bool = true) -> float:
	## How far to slide a plant along the road's lateral axis so none of it dips
	## into the corridor: 0.0 when it already clears, a signed lateral delta to
	## add when a sideways move rescues it, and INF when nothing nearby does.
	##
	## `world_pos` is the centre of the part's horizontal extent, `reach` that
	## extent, and `bottom_y` the lowest point of the part in world space — the
	## margin a part owes depends on how far above the tarmac it hangs. Stations
	## are sampled across the part's own span because a crown on the inside of a
	## bend can reach the road well away from its trunk's station.
	var sway: float = reach * FOLIAGE_SWAY + 0.05 if sways else 0.0
	var need_max: float = reach + sway + FOLIAGE_LOW_CLEARANCE
	# The part is checked against the road across its own z-span plus the
	# corridor's wander: on the climb the spur sweeps several metres sideways
	# per station, so a part can reach the band well past its own footprint.
	# need_max already contains the part's extent; the constant only has to
	# cover how far a band edge can slide inside the sampled window.
	var span: float = need_max + 4.0
	# Cheap far-field exit: this is sampled per plant part, so most calls are a
	# hundred metres from the nearest band and should cost two path queries. The
	# slop covers the centreline's worst-case wander across the span
	# (curvature*span²/2 at the sharpest bend the path generates) plus the
	# spur's sideways sweep.
	var station0 := _corridor_frame(world_pos.z)
	var slat0: float = (world_pos - (station0[0] as Vector3)).dot(station0[1])
	# The chunk's band envelope bounds every band edge the sweep could visit —
	# but only inside the z span it was measured over. Verge planting hugs the
	# corridor's flank and mostly sits beyond it, so one compare answers those
	# instead of the station loop. Vista dressing is planted far outside the
	# owning chunk (the platform chunk builds the whole basin), so anything
	# beyond the covered span falls through to the real sweep.
	var z0 := float(chunk_index) * LENGTH
	if world_pos.z - span >= z0 - 20.0 and world_pos.z + span <= z0 + LENGTH + 20.0:
		var env := _band_envelope()
		var env_slack := need_max + 0.5 + span * span * 0.006
		if slat0 - env_slack > env.y or slat0 + env_slack < env.x:
			return 0.0
	var halo := need_max + 2.5 + span * span * 0.006
	var near_band := false
	for band: Vector2 in station0[2]:
		if slat0 + halo > band.x and slat0 - halo < band.y:
			near_band = true
	if not near_band:
		return 0.0
	# Stations every couple of metres across the part's own span: the band edges
	# swing on a bend, and a crown checked only at its trunk's station can still
	# reach the tarmac twenty metres along. Each station votes for the nearer
	# escape; a part caught between the carriageway and the spur at a junction
	# wants both at once, and there is no slide that fixes that — it is refused.
	# Stations every four metres across the part's span, halving the old sweep:
	# a part's lateral read in the station frame is smooth along z (a few
	# centimetres of curve sag between samples at the sharpest bend), and the
	# band edges slide at well under half a metre per station even at the gore.
	# What a coarser grid can miss is priced into the wider push slack below.
	var push_right := 0.0
	var push_left := 0.0
	var sz: float = world_pos.z - span
	while sz <= world_pos.z + span + 0.01:
		var station := _corridor_frame(sz)
		var slat: float = (world_pos - (station[0] as Vector3)).dot(station[1])
		for band: Vector2 in station[2]:
			# A station that is clear under the largest possible margin stays
			# clear under the real one — do not pay for a road-height sample
			# until the lateral test says the part is actually near the edge.
			# The edge can move between two stations four metres apart, so a part
			# only counts as clear with that drift in hand.
			if slat + need_max + 0.8 <= band.x or slat - need_max - 0.8 >= band.y:
				continue
			var edge_lat: float = clampf(slat, band.x, band.y)
			var road_y: float
			var edge_heights: Dictionary = station[3]
			if edge_lat == band.x or edge_lat == band.y:
				var cached_y: Variant = edge_heights.get(edge_lat)
				if cached_y == null:
					cached_y = (_path.point_at(sz, edge_lat) as Vector3).y
					edge_heights[edge_lat] = cached_y
				road_y = cached_y
			else:
				road_y = (_path.point_at(sz, edge_lat) as Vector3).y
			if bottom_y >= road_y + FOLIAGE_OVERHANG_HEIGHT:
				continue
			var margin := FOLIAGE_LOW_CLEARANCE if bottom_y < road_y + FOLIAGE_LOW_HEIGHT else 0.0
			var need: float = reach + sway + margin
			if slat + need + 0.8 <= band.x or slat - need - 0.8 >= band.y:
				continue
			# Escape through the nearer edge of the band, with enough slack that
			# the curve between two sampled stations cannot reopen the overlap —
			# on the sweeping spur the band itself slides a metre per station,
			# so the slack is wider than a sampling step can be wrong by.
			if slat >= (band.x + band.y) * 0.5:
				push_right = maxf(push_right, band.y + need + 2.0 - slat)
			else:
				push_left = minf(push_left, band.x - need - 2.0 - slat)
		sz += 4.0
	if push_right > 0.0 and push_left < 0.0:
		return INF
	var push: float = push_right if push_right > 0.0 else push_left
	if absf(push) > 60.0:
		return INF
	return push


func _xform_road_push(xform: Transform3D, mesh: Mesh, sways: bool = true) -> float:
	## Corridor check for one prepared instance transform: measure the mesh's
	## real horizontal reach and underside under this transform, then ask
	## `_foliage_road_push` how far sideways clears it. Every foliage bucket is
	## placed through this, so the regression test measures exactly what the
	## placement code measured.
	var aabb: AABB = mesh.get_aabb()
	var centre_local: Vector3 = aabb.get_center()
	var reach := 0.0
	var bottom := INF
	for corner in 8:
		var local: Vector3 = aabb.position + aabb.size * Vector3(
			float(corner & 1), float((corner >> 1) & 1), float((corner >> 2) & 1)
		)
		var off: Vector3 = xform.basis * (local - centre_local)
		reach = maxf(reach, Vector2(off.x, off.z).length())
		bottom = minf(bottom, (xform.basis * local).y)
	return _foliage_road_push(
		xform * centre_local + _origin, reach, bottom + xform.origin.y + _origin.y, sways
	)


func _planted_parts_road_push(marks: Dictionary) -> float:
	## Measure what the grow functions just appended — every limb and crown gets
	## its real horizontal reach and underside from the mesh bounds under its
	## transform — and answer the sideways shove that clears all of it off the
	## corridor, or INF if the tree cannot be saved by sliding.
	var push_right := 0.0
	var push_left := 0.0
	var buckets: Array = [
		[_trunks, unit_trunk(), false, int(marks["trunks"])],
		[_crowns, unit_crown(), true, int(marks["crowns"])],
		[_conifers, unit_conifer(), true, int(marks["conifers"])],
	]
	for entry: Array in buckets:
		var xforms: Array = entry[0]
		for i in range(int(entry[3]), xforms.size()):
			var d: float = _xform_road_push(xforms[i], entry[1], entry[2])
			if is_inf(d):
				return INF
			if d > 0.0:
				push_right = maxf(push_right, d)
			elif d < 0.0:
				push_left = minf(push_left, d)
	# A trunk voting left while its crown votes right is a tree straddling the
	# corridor; no single slide fixes that, so the whole planting is refused.
	if push_right > 0.0 and push_left < 0.0:
		return INF
	return push_right if push_right > 0.0 else push_left


func _rollback_planted_parts(marks: Dictionary) -> void:
	## Drop everything a rejected grow attempt appended. Half-keeping a shifted
	## tree would leave orphan boughs standing where the trunk used to be.
	_trunks.resize(int(marks["trunks"]))
	_trunk_cols.resize(int(marks["trunks"]))
	_crowns.resize(int(marks["crowns"]))
	_crown_cols.resize(int(marks["crowns"]))
	_conifers.resize(int(marks["conifers"]))
	_conifer_cols.resize(int(marks["conifers"]))


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


func _leaf_cube(
	z: float,
	lateral: float,
	size: Vector3,
	color: Color,
	yaw: float = 0.0,
	lift: float = 0.0,
	allow_road_overlap: bool = false,
	follow_terrain: bool = true
) -> void:
	## `_cube` into the wind bucket. Same placement rules, same corridor margin —
	## a hedge keeps its whole body, sway included, out of the rider's airspace.
	var half_lateral := absf(cos(yaw)) * size.x * 0.5 + absf(sin(yaw)) * size.z * 0.5
	var half_depth := absf(sin(yaw)) * size.x * 0.5 + absf(cos(yaw)) * size.z * 0.5
	if not allow_road_overlap and not _footprint_is_clear(z, lateral, half_lateral, half_depth):
		return
	var flat: Basis = _path.frame_flat_at(z)
	var frame := Basis(flat.x, flat.y, flat.z).rotated(flat.y, yaw)
	var scaled := Basis(frame.x * size.x, frame.y * size.y, frame.z * size.z)
	var base: Vector3 = _ground_base_for_footprint(z, lateral, half_lateral, half_depth, follow_terrain) - _origin
	_leaf_cubes.append(Transform3D(scaled, base + flat.y * (lift + size.y * 0.5)))
	_leaf_cube_cols.append(color)


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
	## `_deck_cube`, or it floats the moment the headland pitches. The leafy ones
	## also keep the corridor rule: a trough bloom leaning over the slip road
	## brushes a rider the same as a hedge does.
	for _attempt in 3:
		var rng_state: int = _rng.state
		var deck_lift: float = lift + _terrace_floor_at(z, lateral)
		var flat: Basis = _path.frame_flat_at(z)
		var frame := Basis(flat.x, flat.y, flat.z).rotated(flat.y, _rng.randf_range(0.0, TAU))
		var scaled := Basis(frame.x * size.x, frame.y * size.y, frame.z * size.z)
		var xform := Transform3D(scaled, _p(z, lateral, -(deck_lift + size.y * 0.42)))
		if leafy:
			var push := _xform_road_push(xform, unit_sphere(), true)
			if is_inf(push):
				return
			if push != 0.0:
				lateral += push
				_rng.state = rng_state
				continue
			_leaves.append(xform)
			_leaf_cols.append(color)
		else:
			_blobs.append(xform)
			_blob_cols.append(color)
		return


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
	for _attempt in 3:
		var rng_state: int = _rng.state
		# Forced planting still cannot sit on tarmac. Vista rocks use forced to
		# stand in reserved ground; the slip road is not reserved, and the
		# mountain midfield uses forced to skip the nine-sample query.
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
		if leafy and _on_spur and xform.origin.y + _origin.y < _vp_water_y - 0.4:
			return
		if leafy:
			# The corridor rule is about leaves, not stone: a hedge or bush keeps
			# its whole body — sway included — out of the rider's airspace, so it
			# slides out along the verge rather than clipping the shoulder. The
			# stream is rewound per retry so the shift moves the blob it measured.
			var push := _xform_road_push(xform, unit_sphere(), true)
			if is_inf(push):
				return
			if push != 0.0:
				lateral += push
				_rng.state = rng_state
				continue
		if leafy:
			_leaves.append(xform)
			_leaf_cols.append(color)
		else:
			_blobs.append(xform)
			_blob_cols.append(color)
		return


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
	## The trunk footprint decides, but the crown is checked too: the tree is
	## grown speculatively, every limb and crown is measured against the
	## corridor (bends included), and the whole tree is slid sideways until its
	## foliage clears the road — or given up on. A bough over the tarmac puts
	## leaves in the rider's face, which is the one thing a roadside tree may
	## never do.
	##
	## `forced` is for authored planting inside ground the overlook reserves — the
	## far shore of its lake is exactly the place the random pass must not touch
	## and the set piece must. `lift` raises the whole tree off the ground it was
	## sampled on, which is how anything gets planted on an island: the terrain
	## under one is the lake bed, several metres down. Forced still has to clear
	## the corridor — the spur woodland is authored planting right beside tarmac.
	##
	## Placement is settled by a single cylinder bound first, and only when the
	## corridor might still reach the tree does the exact path run: grown
	## speculatively, every limb and crown measured against the corridor (bends
	## included), the whole tree slid sideways until its foliage clears the
	## road — or given up on. A bough over the tarmac puts leaves in the rider's
	## face, which is the one thing a roadside tree may never do.
	var foot: float = clampf(height * 0.1, 0.35, 1.1)
	# A tree rooted well clear of every corridor band cannot swing a crown onto
	# the road from there; the deep-scenery majority skips the grow-measure-shift
	# dance entirely and pays only for its own shape.
	var corridor_near: bool = _band_hit(z, lateral, height * 0.95 + FOLIAGE_LOW_CLEARANCE + 11.0)
	for _attempt in 4:
		if _on_tarmac(z, lateral, foot + PROP_ROAD_CLEARANCE):
			return
		if not forced and not _footprint_is_clear(z, lateral, foot, foot):
			return
		# Rewind the stream on every retry: a shift must move the *same* tree it
		# measured, not roll a new shape whose crown lands somewhere unexpected.
		var rng_state: int = _rng.state
		var base: Vector3 = _ground_base_for_footprint(z, lateral, foot, foot) - _origin + Vector3(0.0, lift, 0.0)
		var measure := true
		if corridor_near:
			# One sweep for the whole tree before one per part: a cylinder at the
			# root, as wide as the widest crown this height can throw (the grow
			# functions keep every limb tip and crown edge inside ~0.7·height of
			# the trunk axis) and reaching below the ground line for the crown
			# that dips under its own fork. Where the bound clears, no real part
			# can reach the corridor and the grow-measure-shift dance below is
			# skipped. But the cylinder charges ~0.95·height of horizontal reach
			# to every tree — nearly twice a real crown's — so a nonzero bound
			# was sliding roadside planting another dozen metres off the verge
			# it was meant to line, and each retry walked it further still.
			# Only a *clear* bound may skip the per-part verdict now: anything
			# else is measured against the parts that actually grew, which is
			# also what lets a slimmer real tree stand where the cylinder could
			# not.
			var bound := _foliage_road_push(
				base + _origin, height * 0.95, base.y + _origin.y - height * 0.2, true
			)
			measure = bound != 0.0
		var frame := Transform3D(Basis(Vector3.UP, _rng.randf_range(0.0, TAU)), base)
		var marks := {
			"trunks": _trunks.size(), "crowns": _crowns.size(), "conifers": _conifers.size()
		}
		match species:
			Flora.CONIFER:
				_grow_conifer(frame, height, color)
			Flora.BIRCH:
				_grow_birch(frame, height, color)
			Flora.PINE:
				_grow_pine(frame, height, color)
			_:
				_grow_broadleaf(frame, height, color)
		if not corridor_near or not measure:
			return
		var push := _planted_parts_road_push(marks)
		if push == 0.0:
			return
		_rollback_planted_parts(marks)
		if is_inf(push):
			return
		lateral += push
		_rng.state = rng_state


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


func _grow_conifer(frame: Transform3D, height: float, color: Color) -> void:
	## Spruce: bare lower trunk, then skirts all the way to a point. The one shape
	## on the roadside that is allowed a sharp apex.
	var bark: Color = BARK.darkened(_rng.randf_range(0.1, 0.3))
	var skirt: float = height * _rng.randf_range(0.08, 0.16)
	_limb(frame, Vector3.ZERO, Vector3(0, height * 0.42, 0), height * 0.05, bark)
	# Two stepped tiers rather than one cone: a single apex-to-skirt cone
	# reads as a flat cardboard triangle beside the rounder broadleaf crowns
	# (fully 2D at dusk). A wide lower skirt under a narrower leader gives a
	# spruce silhouette and takes the light in two bands.
	var needle_h := height - skirt
	var lower_h := needle_h * _rng.randf_range(0.52, 0.6)
	var lower_w := height * _rng.randf_range(0.34, 0.46)
	var lower_basis := Basis(Vector3.UP, _rng.randf_range(0.0, TAU)).scaled(
		Vector3(lower_w, lower_h, lower_w * _rng.randf_range(0.88, 1.12))
	)
	_conifers.append(frame * Transform3D(lower_basis, Vector3(0, skirt, 0)))
	_conifer_cols.append(color.darkened(0.05))
	var upper_h := needle_h * _rng.randf_range(0.56, 0.66)
	var upper_w := lower_w * _rng.randf_range(0.58, 0.72)
	var upper_basis := Basis(Vector3.UP, _rng.randf_range(0.0, TAU)).scaled(
		Vector3(upper_w, upper_h, upper_w * _rng.randf_range(0.88, 1.12))
	)
	_conifers.append(frame * Transform3D(upper_basis, Vector3(0, height - upper_h, 0)))
	_conifer_cols.append(color)


func _grow_birch(frame: Transform3D, height: float, color: Color) -> void:
	## A clump of two or three pale stems from one root, each with a small high
	## crown. Slim and bright: the tree that breaks up a wall of dark conifer.
	# Mostly one stem, sometimes a pair. Three stems splayed out at up to 15
	# degrees planted in a whole birch stand read as a row of white fans.
	var stems: int = 1 if _rng.randf() < 0.55 else 2
	for i in stems:
		var a: float = TAU * float(i) / float(stems) + _rng.randf_range(-0.4, 0.4)
		var tall: float = height * _rng.randf_range(0.78, 1.0)
		var out: float = tall * _rng.randf_range(0.01, 0.06)
		# Leafed from two fifths of the way up, not three fifths. With the small
		# high crown, three pale stems and a tuft read as bare white sticks.
		var top := Vector3(cos(a) * out, tall * 0.6, sin(a) * out)
		# Still the palest bark on the verge, but a step off fluorescent —
		# bare bright stems among dark conifers were what read as white sticks.
		_limb(frame, Vector3.ZERO, top, tall * 0.05, BARK_PALE.darkened(0.18 + _rng.randf() * 0.22))
		# And a fuller crown carried further down the stem: leaf over most of
		# the tree is a birch's drift of green; a tuft on a wand is not.
		var width: float = tall * _rng.randf_range(0.48, 0.62)
		_canopy(frame, top - Vector3(0, tall * 0.22, 0), width, tall * _rng.randf_range(0.54, 0.62), color.lightened(_rng.randf() * 0.12))


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
	## an orange body, and dropped unaltered into a dusk basin they read as
	## painted confetti floating on the water — the most conspicuous thing in the
	## view, and the only object in it not built from the biome palette.
	match _vp_theme:
		Env.MOUNTAIN:
			return Color("4d4f48")
		Env.FOREST:
			return Color("3b4438")
	return Color("5f5747")


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
	face_road: bool = false,
	dress_mat: Material = null
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
	if dress_mat != null:
		_dress_imported_rock(instance, dress_mat)
	add_child(instance)
	_asset_count += 1


func apply_corridor(on_scenic: bool, committed: bool, drop_unused: bool = false) -> void:
	## Hide the unused path once the rider has committed. Junctions keep both
	## corridors drawn so the brown signs and the exit stay readable. Once
	## committed, runtime streaming also frees the unused meshes so they stop
	## occupying RAM and draw lists.
	if not _on_spur:
		return
	# The main road's roadside stays: its trees and hedges stand in plain view
	# of the side road a hundred-odd metres away, and culling them made the
	# woods beside the climb blink out the moment the rider took the exit.
	var show_highway := true
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
		var child := get_child(i)
		if child.has_meta("shared_corridor"):
			continue  # seen from both roads; see _spur_gate()
		child.set_meta("corridor", corridor)


func _prop_marks() -> Dictionary:
	return {
		"cubes": _cubes.size(),
		"leaf_cubes": _leaf_cubes.size(),
		"arch": _arch.size(),
		"prisms": _prisms.size(),
		"blobs": _blobs.size(),
		"leaves": _leaves.size(),
		"trunks": _trunks.size(),
		"crowns": _crowns.size(),
		"conifers": _conifers.size(),
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
	# Shadow casting is on for anything big enough to shade the road: crowns and
	# conifers carry their sway into the shadow pass for free, which is what
	# makes the low sun read as wind as well as light. Grass stays off — a
	# thousand blade-shadows a metre tall is noise, not shade.
	_commit_mm_range(_cubes, _cube_cols, int(from.get("cubes", 0)), unit_cube(), LowPoly.solid_material(), "Cubes", true)
	_commit_mm_range(_leaf_cubes, _leaf_cube_cols, int(from.get("leaf_cubes", 0)), unit_cube(), LowPoly.foliage_material(), "Hedges", true)
	_commit_mm_range(_arch, _arch_cols, int(from.get("arch", 0)), unit_box_sharp(), LowPoly.solid_material(), "Architecture", true)
	_commit_mm_range(_prisms, _prism_cols, int(from.get("prisms", 0)), unit_cone(), LowPoly.solid_material(), "Cones", true)
	_commit_mm_range(_blobs, _blob_cols, int(from.get("blobs", 0)), unit_boulder(), LowPoly.solid_material(), "Rocks", true)
	_commit_mm_range(_leaves, _leaf_cols, int(from.get("leaves", 0)), unit_bush(), LowPoly.foliage_material(), "Foliage", true)
	_commit_mm_range(_trunks, _trunk_cols, int(from.get("trunks", 0)), unit_trunk(), LowPoly.solid_material(), "Trunks", true)
	_commit_mm_range(_crowns, _crown_cols, int(from.get("crowns", 0)), unit_crown(), LowPoly.foliage_material(), "Crowns", true)
	_commit_mm_range(_conifers, _conifer_cols, int(from.get("conifers", 0)), unit_conifer(), LowPoly.foliage_material(), "Conifers", true)
	_commit_mm_range(_ridges, _ridge_cols, int(from.get("ridges", 0)), unit_ridge(), LowPoly.solid_material(), "Ridges", false)
	_commit_mm_range(_ledges, _ledge_cols, int(from.get("ledges", 0)), unit_box_sharp(), LowPoly.solid_material(), "FaceLedges", false)
	_commit_mm_range(_grass, _grass_cols, int(from.get("grass", 0)), grass_tuft(), LowPoly.foliage_material(), "Grass", false)
	_commit_mm_range(_hay, _hay_cols, int(from.get("hay", 0)), unit_hay_bale(), LowPoly.solid_material(), "HayBales", true)
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
	if int(from.get("leaf_cubes", 0)) < _leaf_cubes.size():
		_commit_mm_range(_leaf_cubes, _leaf_cube_cols, int(from.get("leaf_cubes", 0)), unit_cube(), LowPoly.foliage_material(), "Hedges", true)
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
		_commit_mm_range(_blobs, _blob_cols, int(from.get("blobs", 0)), unit_boulder(), LowPoly.solid_material(), "Rocks", true)
		published += 1
		if published % PER_FRAME == 0 and not await _keep_streaming():
			return
	if int(from.get("leaves", 0)) < _leaves.size():
		_commit_mm_range(_leaves, _leaf_cols, int(from.get("leaves", 0)), unit_bush(), LowPoly.foliage_material(), "Foliage", true)
		published += 1
		if published % PER_FRAME == 0 and not await _keep_streaming():
			return
	if int(from.get("trunks", 0)) < _trunks.size():
		_commit_mm_range(_trunks, _trunk_cols, int(from.get("trunks", 0)), unit_trunk(), LowPoly.solid_material(), "Trunks", true)
		published += 1
		if published % PER_FRAME == 0 and not await _keep_streaming():
			return
	if int(from.get("crowns", 0)) < _crowns.size():
		_commit_mm_range(_crowns, _crown_cols, int(from.get("crowns", 0)), unit_crown(), LowPoly.foliage_material(), "Crowns", true)
		published += 1
		if published % PER_FRAME == 0 and not await _keep_streaming():
			return
	if int(from.get("conifers", 0)) < _conifers.size():
		_commit_mm_range(_conifers, _conifer_cols, int(from.get("conifers", 0)), unit_conifer(), LowPoly.foliage_material(), "Conifers", true)
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
		_commit_mm_range(_hay, _hay_cols, int(from.get("hay", 0)), unit_hay_bale(), LowPoly.solid_material(), "HayBales", true)
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
	elif theme == Env.FOREST and node_name in ["Conifers", "Trunks", "Crowns", "Foliage", "Rocks"]:
		# The forest's back band and canopy wall sit 90–170 m off the centreline:
		# at the prop cull the deep wood would blink on as the rider closed in.
		mmi.visibility_range_end = 300.0
	else:
		mmi.visibility_range_end = 200.0 if node_name == "Architecture" else 160.0
	if not shadows or _on_lake or _shadow_pruned(node_name):
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if node_name == "FaceLedges":
		# Ledges sit on the same shaded face as the skin and terrain; without
		# the fill they stay jet against the lifted rock behind them.
		mmi.layers = HEADLAND_FILL_LAYER
	LowPoly.cheap_draw(mmi)
	add_child(mmi)


static var _shadow_prune: PackedStringArray = []


static func _shadow_pruned(node_name: String) -> bool:
	## Perf-sweep hook: SPLENDOR_SHADOW_NOCAST="Cones,HayBales" drops those
	## buckets from the sun's shadow pass, nothing else. Parsed once.
	if _shadow_prune.is_empty():
		var raw := OS.get_environment("SPLENDOR_SHADOW_NOCAST")
		if raw.is_empty():
			_shadow_prune = PackedStringArray(["__none__"])
		else:
			_shadow_prune = raw.split(",")
	return node_name in _shadow_prune


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
		await _build_reflectors(true)
		if not await _keep_streaming():
			return
	var bushes_left: int = int(VERGE_BUSH_COUNT[theme])
	while bushes_left > 0:
		var n: int = mini(VERGE_BUSH_BATCH, bushes_left)
		_verge_plant_bushes(n)
		bushes_left -= n
		if _slice_spent() and not await _keep_streaming():
			return
	# The clearance sweeps made each verge stage dearer, so they each get their
	# own frame the way they already do in `_dress_shoulder_incremental`: grass,
	# hedge and fringe back to back is a ~17 ms lump in the middle of a ride.
	await _grass_verge_incremental()
	if not await _keep_streaming():
		return
	await _hedge_verge_incremental()
	if not await _keep_streaming():
		return
	await _verge_flowers(true)
	if not await _keep_streaming():
		return
	await _verge_plant_fringe_incremental(-1.0)
	if not await _keep_streaming():
		return
	await _verge_plant_fringe_incremental(1.0)
	if not await _keep_streaming():
		return
	if theme_carries_power_line(theme) and not _on_lake:
		await _power_line(true)
		if not await _keep_streaming():
			return
	await _build_guardrail_incremental()


func _build_reflectors(streamed: bool = false) -> void:
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
		if streamed and _slice_spent() and not await _keep_streaming():
			return
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
	if side_for_curve == 0.0 and theme != Env.MOUNTAIN:
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
	if side_for_curve == 0.0 and theme != Env.MOUNTAIN:
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
		if n % 2 == 0 and _slice_spent() and not await _keep_streaming():
			return


func _grass_at(z: float, lateral: float, size: Vector3, color: Color) -> void:
	## One grass tuft, grounded on the terrain under it. Grass is foliage too —
	## it sways, and a blade at knee height still brushes a shoulder — so it
	## answers the corridor the way the trees do: measured under its own
	## transform and slid outward until it clears, not just kept off the tarmac
	## by a fixed strip.
	for _attempt in 3:
		if (
			_on_tarmac(z, lateral, FOLIAGE_LOW_CLEARANCE + 0.6)
			or ((_on_lake or _on_spur) and _viewpoint_reserves_sightline(z, lateral))
		):
			return
		var rng_state: int = _rng.state
		var flat: Basis = _path.frame_flat_at(z)
		var xform := Transform3D(
			Basis(flat.x, flat.y, flat.z).rotated(flat.y, _rng.randf_range(0.0, TAU)).scaled(size),
			_terrain_surface_at(z, lateral) - _origin - flat.y * 0.04
		)
		var push := _xform_road_push(xform, grass_tuft(), true)
		if is_inf(push):
			return
		if push != 0.0:
			lateral += push
			_rng.state = rng_state
			continue
		_grass.append(xform)
		_grass_cols.append(color)
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
		# Packed against the curb, thinning outward — but never inside the
		# corridor margin: a swaying blade over the shoulder still brushes the
		# rider's sleeve.
		var lx: float = _mow_lateral(z, side * (HALF_WIDTH + 2.2 + pow(_rng.randf(), 1.6) * 7.5))
		var height := _rng.randf_range(0.55, 1.18)
		var tuft := Vector3(_rng.randf_range(0.65, 1.15), height, _rng.randf_range(0.65, 1.15))
		_grass_at(
			z, lx, tuft,
			(base as Color).lerp(_pal["prop_a"], _rng.randf() * 0.5).darkened(_rng.randf() * 0.25)
		)
	set_meta("grass_done", true)


func _grass_verge_incremental() -> void:
	## Same tufts in the same order — each `_grass_at` sweeps the corridor mesh
	## for clearance, so all 72 in one frame was a ~15 ms block on the climb.
	if bool(get_meta("grass_done", false)):
		return
	var z0: float = float(chunk_index) * LENGTH
	var base: Color = _pal["verge"]
	for i in 72:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var side: float = 1.0 if _rng.randf() < 0.5 else -1.0
		var lx: float = _mow_lateral(z, side * (HALF_WIDTH + 2.2 + pow(_rng.randf(), 1.6) * 7.5))
		var height := _rng.randf_range(0.55, 1.18)
		var tuft := Vector3(_rng.randf_range(0.65, 1.15), height, _rng.randf_range(0.65, 1.15))
		_grass_at(
			z, lx, tuft,
			(base as Color).lerp(_pal["prop_a"], _rng.randf() * 0.5).darkened(_rng.randf() * 0.25)
		)
		if _slice_spent() and not await _keep_streaming():
			return
	set_meta("grass_done", true)


func _hedge_verge() -> void:
	## A low hedge along the first few metres of curb, grown in runs with real
	## gaps between them: hawthorn-dark for a stretch, lighter bramble next, then
	## a bare strip of verge where the grass runs on. A hedge that never breaks
	## reads as wallpaper at riding speed; the gaps are most of what makes it
	## countryside. In country the gap earns a field gate half the time.
	if bool(get_meta("hedge_done", false)):
		return
	if theme == Env.CITY:
		set_meta("hedge_done", true)
		return
	var z0: float = float(chunk_index) * LENGTH
	# In country the verge hedge is the field boundary proper — longer, deeper
	# runs of hawthorn green with fewer breaks, not a sprinkle of round bushes.
	var country := theme == Env.COUNTRY
	for side in [-1.0, 1.0]:
		var hz := z0 + _rng.randf_range(0.0, 1.1)
		while hz < z0 + LENGTH:
			if _rng.randf() < (0.13 if country else 0.17):
				var gap := _rng.randf_range(3.0, 8.0)
				if country and _rng.randf() < 0.5:
					_field_gate(hz + gap * 0.5, side)
				hz += gap
				continue
			var run_end := minf(
				hz + _rng.randf_range(10.0, 30.0) if country else hz + _rng.randf_range(7.0, 22.0),
				z0 + LENGTH
			)
			var run_col: Color = (_pal["prop_a"] as Color).lerp(
				_pal["verge"], _rng.randf_range(0.1, 0.4) if country else _rng.randf_range(0.15, 0.55)
			)
			var run_h := _rng.randf_range(1.3, 2.3) if country else _rng.randf_range(1.1, 2.1)
			while hz < run_end:
				var lx: float = _mow_lateral(hz, side * (HALF_WIDTH + 3.0 + _rng.randf_range(0.0, 2.6)))
				# Forced blobs skip `_footprint_is_clear`; without a tarmac test they grow
				# on the slip road the moment spur chunks start dressing the verge again.
				if ((_on_lake or _on_spur) and _viewpoint_reserves_sightline(hz, lx)) or _on_tarmac(hz, lx, 1.2):
					hz += 2.0
					continue
				var w := _rng.randf_range(1.8, 2.9) if country else _rng.randf_range(1.55, 2.55)
				_blob(
					hz, lx, Vector3(w, run_h * _rng.randf_range(0.82, 1.12), w * _rng.randf_range(0.85, 1.15) if country else w * 0.78),
					run_col.darkened(_rng.randf() * 0.18), 0.0, true, true
				)
				if _rng.randf() < 0.28:
					var s := _rng.randf_range(0.4, 0.9)
					# Bramble at the hedge foot, low and in the hedge's own shade.
					# It was a box — under the key a green box on the plain
					# material lands mustard, and a row of them along the fence
					# read as crates set out on the verge.
					_blob(
						hz + 0.35,
						_mow_lateral(hz, side * (HALF_WIDTH + 1.65 + _rng.randf() * 1.5)),
						Vector3(s * 1.5, s * 0.7, s * 1.3),
						run_col.darkened(_rng.randf_range(0.2, 0.34)),
						0.0,
						true
					)
				hz += _rng.randf_range(1.65, 2.45)
	set_meta("hedge_done", true)


func _field_gate(z: float, side: float) -> void:
	## A five-bar field gate stood in a hedge gap — one of the few roadside
	## details that says somebody works this land. It hangs on the fence line,
	## clear of the tarmac, and the beams answer the same corridor test the
	## guardrails do rather than floating over a spur junction.
	var lat: float = _mow_lateral(z, side * (HALF_WIDTH + 4.6))
	var wood: Color = (_pal["rail"] as Color).darkened(_rng.randf_range(0.05, 0.2))
	_cube(z - 1.7, lat, Vector3(0.24, 1.45, 0.24), wood.darkened(0.14))
	_cube(z + 1.7, lat, Vector3(0.18, 1.2, 0.18), wood)
	for r in 3:
		_terrain_beam(z - 1.7, z + 1.7, lat, 0.07, 0.09, wood, 0.36 + float(r) * 0.32)


func _hedge_verge_incremental() -> void:
	## Same hedgerow as `_hedge_verge` — identical rng draws, so a streamed verge
	## grows the same runs, gaps and gates — but every blob walks the corridor
	## clearance checks, and the whole strip measured up to ~35 ms on a scenic
	## chunk. A budget check inside the run loop lets the frame boundary land
	## mid-hedge instead of paying the whole verge in one slice.
	##
	## This twin had drifted: it missed the country field-boundary runs and
	## still laid the hay-gold clod boxes the sync path had dropped, and it is
	## the path a rider actually sees. Kept line for line with `_hedge_verge`.
	if bool(get_meta("hedge_done", false)):
		return
	if theme == Env.CITY:
		set_meta("hedge_done", true)
		return
	var z0: float = float(chunk_index) * LENGTH
	var country := theme == Env.COUNTRY
	for side in [-1.0, 1.0]:
		var hz := z0 + _rng.randf_range(0.0, 1.1)
		while hz < z0 + LENGTH:
			if _rng.randf() < (0.13 if country else 0.17):
				var gap := _rng.randf_range(3.0, 8.0)
				if country and _rng.randf() < 0.5:
					_field_gate(hz + gap * 0.5, side)
				hz += gap
				continue
			var run_end := minf(
				hz + _rng.randf_range(10.0, 30.0) if country else hz + _rng.randf_range(7.0, 22.0),
				z0 + LENGTH
			)
			var run_col: Color = (_pal["prop_a"] as Color).lerp(
				_pal["verge"], _rng.randf_range(0.1, 0.4) if country else _rng.randf_range(0.15, 0.55)
			)
			var run_h := _rng.randf_range(1.3, 2.3) if country else _rng.randf_range(1.1, 2.1)
			while hz < run_end:
				var lx: float = _mow_lateral(hz, side * (HALF_WIDTH + 3.0 + _rng.randf_range(0.0, 2.6)))
				# Forced blobs skip `_footprint_is_clear`; without a tarmac test they grow
				# on the slip road the moment spur chunks start dressing the verge again.
				if ((_on_lake or _on_spur) and _viewpoint_reserves_sightline(hz, lx)) or _on_tarmac(hz, lx, 1.2):
					hz += 2.0
					continue
				var w := _rng.randf_range(1.8, 2.9) if country else _rng.randf_range(1.55, 2.55)
				_blob(
					hz, lx, Vector3(w, run_h * _rng.randf_range(0.82, 1.12), w * _rng.randf_range(0.85, 1.15) if country else w * 0.78),
					run_col.darkened(_rng.randf() * 0.18), 0.0, true, true
				)
				if _rng.randf() < 0.28:
					var s := _rng.randf_range(0.4, 0.9)
					_blob(
						hz + 0.35,
						_mow_lateral(hz, side * (HALF_WIDTH + 1.65 + _rng.randf() * 1.5)),
						Vector3(s * 1.5, s * 0.7, s * 1.3),
						run_col.darkened(_rng.randf_range(0.2, 0.34)),
						0.0,
						true
					)
				hz += _rng.randf_range(1.65, 2.45)
				if _slice_spent() and not await _keep_streaming():
					return
	set_meta("hedge_done", true)


static func theme_carries_power_line(theme_id: int) -> bool:
	## Open country only. The wire is a landscape line, and the forest section is
	## the one that reads as untouched.
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


func _boundary_under_lane(z_a: float, z_b: float) -> bool:
	## Whether the verge's fence line stands inside the slip lane across this
	## segment. While the spur is still a lane bolted to the carriageway edge a
	## rail or wall at the verge lands in the deceleration lane; once the gore
	## opens, the verge is open ground and the boundary is wanted back.
	if not _on_spur:
		return false
	for z in [z_a, z_b]:
		if float(_path.spur_half_width(z)) > 0.0 and float(_path.spur_gap(z)) < 6.0:
			return true
	return false


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


func _power_line(streamed: bool = false) -> void:
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
		if streamed and _slice_spent() and not await _keep_streaming():
			return

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
		if streamed and _slice_spent() and not await _keep_streaming():
			return


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



func _junction_mow(z: float) -> float:
	## The unsigned lateral a junction's mown margin reaches. While the slip
	## road still shares the carriageway's formation the verge beside it is
	## kept short — a real exit lane is read against gravel and paint, not out
	## of a hedge. Zero away from a junction, where the verge belongs to the
	## trees again.
	if not _on_spur:
		return 0.0
	if float(_path.spur_divergence(z)) >= 0.55:
		return 0.0
	var spur: Vector2 = _path.spur_interval(z)
	if spur == Vector2.ZERO:
		return 0.0
	return maxf(absf(spur.x), absf(spur.y)) + RoadPathGD.SPUR_SHOULDER + 3.8


func _mow_lateral(z: float, lateral: float) -> float:
	## Keep verge planting outside the mown margin on the spur's side — the
	## bushes that used to crowd the exit lane's edge slid out to the verge
	## the mow leaves, keeping the same density a clean strip further out.
	var bound := _junction_mow(z)
	if bound <= 0.0 or lateral * _vp_side <= 0.0:
		return lateral
	return signf(lateral) * maxf(absf(lateral), bound)


func _verge_planting() -> void:
	## Rounded growth packed along the first few metres of verge, every theme.
	## This is the band the rider actually looks at, and it used to be a bare
	## coloured stripe between the curb and whatever was 20 m away.
	_verge_plant_bushes(int(VERGE_BUSH_COUNT[theme]))
	_grass_verge()
	_hedge_verge()
	_verge_flowers()
	_verge_plant_fringe(0.0)


func _verge_flowers(streamed: bool = false) -> void:
	## Patches of wildflowers in the grass band — the small bright notes that
	## keep a verge reading as a verge rather than an even green stripe. Poppy
	## red, daisy white, buttercup gold and the odd cornflower in the farmland;
	## foxglove pink and white under the trees. They go in the foliage bucket
	## like the grass they stand in, so they lean with the same wind.
	if theme == Env.CITY or theme == Env.MOUNTAIN:
		return
	if bool(get_meta("flowers_done", false)):
		return
	var blooms: Array[Color] = []
	if theme == Env.COUNTRY:
		blooms.assign([Color("d4492f"), Color("e9e3d2"), Color("e0b63f"), Color("7f7496")])
	else:
		blooms.assign([Color("b96e92"), Color("e3ddcc"), Color("d5c88e")])
	var z0: float = float(chunk_index) * LENGTH
	for _p in _rng.randi_range(1, 3):
		var patch_z := z0 + _rng.randf_range(0.0, LENGTH)
		var side: float = 1.0 if _rng.randf() < 0.5 else -1.0
		var patch_x: float = side * (HALF_WIDTH + _rng.randf_range(3.0, 6.5))
		var col: Color = blooms[_rng.randi() % blooms.size()]
		for _f in _rng.randi_range(8, 14):
			var s := _rng.randf_range(0.2, 0.38)
			_blob(
				patch_z + _rng.randf_range(-2.6, 2.6),
				_mow_lateral(patch_z, patch_x + _rng.randf_range(-1.5, 1.5)),
				Vector3(s * 1.5, s, s * 1.5),
				col.darkened(_rng.randf() * 0.15),
				0.0,
				true
			)
			if streamed and _slice_spent() and not await _keep_streaming():
				return
	set_meta("flowers_done", true)


func _verge_plant_bushes(count: int) -> void:
	var z0: float = float(chunk_index) * LENGTH
	# City verge is concrete-grey; planting it that colour reads as rubble.
	var base: Color = Color("2c4a33") if theme == Env.CITY else _pal["prop_a"]
	var alt: Color = Color("3d5c3c") if theme == Env.CITY else _pal["verge"]
	for _i in count:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var side: float = 1.0 if _rng.randf() < 0.5 else -1.0
		# Sparser the further out, so the near verge stays the dense, fast-moving band.
		var lx: float = _mow_lateral(z, side * (HALF_WIDTH + 3.0 + pow(_rng.randf(), 1.35) * 16.0))
		var s := _rng.randf_range(0.7, 2.15)
		if theme == Env.COUNTRY:
			# Fewer, longer, deeper — low scrub on the verge, not a scatter of
			# little round balls; the hedge runs carry the fine detail.
			s = _rng.randf_range(1.0, 2.6)
			var col: Color = (base as Color).lerp(alt, _rng.randf() * 0.3).darkened(_rng.randf() * 0.2)
			_blob(z, lx, Vector3(s * 1.5, s * _rng.randf_range(0.7, 1.05), s * 2.3), col, 0.0, true)
		else:
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
				_mow_lateral(gz, side * (HALF_WIDTH + 2.6 + _rng.randf_range(0.0, 0.9))),
				Vector3(s * 2.2, s * 0.7, s * 1.4),
				(_pal["verge"] as Color).darkened(_rng.randf() * 0.3),
				0.0,
				true
			)
		gz += _rng.randf_range(2.0, 3.6)


func _verge_plant_fringe_incremental(side_filter: float) -> void:
	## Same blobs in the same order; one full pass is ~25 forced blobs and their
	## corridor checks, a ~10 ms lump when a chunk's furniture lands mid-ride.
	if theme == Env.CITY:
		return
	var z0: float = float(chunk_index) * LENGTH
	var gz := z0 + _rng.randf_range(0.0, 2.0)
	var n := 0
	while gz < z0 + LENGTH:
		for side in [-1.0, 1.0]:
			if side_filter != 0.0 and not is_equal_approx(side, side_filter):
				continue
			var s := _rng.randf_range(0.35, 0.7)
			_blob(
				gz,
				_mow_lateral(gz, side * (HALF_WIDTH + 2.6 + _rng.randf_range(0.0, 0.9))),
				Vector3(s * 2.2, s * 0.7, s * 1.4),
				(_pal["verge"] as Color).darkened(_rng.randf() * 0.3),
				0.0,
				true
			)
		gz += _rng.randf_range(2.0, 3.6)
		n += 1
		if n % 2 == 0 and _slice_spent() and not await _keep_streaming():
			return


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
	## Each side also rolls a mood: mostly the usual mixed stands, sometimes a
	## wall of timber tight over the verge, sometimes the wood steps back and
	## leaves a glade of grass and saplings between the rider and the trees.
	##
	## Depth is what sells it: verge shrubs, then the planted stands, then a deep
	## band of taller, darker timber, then canopy masses under the fog line — a
	## wood that keeps going, not trees parked on a lawn.
	var z0: float = float(chunk_index) * LENGTH
	for side in [-1.0, 1.0]:
		var mood := _rng.randf()
		var stand_count := _forest_stand_count(mood)
		for _stand in stand_count:
			_forest_stand(z0, side, mood)
		_forest_back_band(z0, side, mood)
		_forest_verge(z0, side)
		_forest_floor(side)
	_forest_water(z0)


func _forest_stand_count(mood: float) -> int:
	if mood < 0.16:
		return 5
	if mood < 0.38:
		return 1 + int(_rng.randf() < 0.45)
	return 3


func _forest_stand(z0: float, side: float, mood: float, pace: Callable = Callable()) -> void:
	## One stand: same species, same tint family, one size range. Stands overlap
	## each other and the back band, which is what knits the wood edge together.
	## `pace` is the incremental build's slice budget: invalid on the one-shot
	## path, so both callers grow the same stand off the same stream.
	var stand_near := 5.0
	var stand_far := 49.0
	if mood < 0.16:
		stand_near = 4.0
		stand_far = 26.0
	elif mood < 0.38:
		stand_near = 19.0
		stand_far = 60.0
	var stand_z := z0 + _rng.randf_range(0.0, LENGTH)
	var stand_x: float = side * (HALF_WIDTH + _rng.randf_range(stand_near, stand_far))
	var roll := _rng.randf()
	var species: int = (
		Flora.CONIFER if roll < 0.5 else (Flora.BIRCH if roll < 0.68 else (Flora.PINE if roll < 0.78 else Flora.BROADLEAF))
	)
	var tint: Color = (_pal["prop_a"] as Color).lerp(_pal["prop_c"], _rng.randf() * 0.7)
	# Even-aged stands: most middling, some tall, the odd short thicket — a
	# height class per stand, not a ladder of random poles beside the road.
	var hr := _rng.randf()
	var tall: float
	if hr < 0.58:
		tall = _rng.randf_range(8.5, 12.0)
	elif hr < 0.88:
		tall = _rng.randf_range(12.5, 16.5)
	else:
		tall = _rng.randf_range(5.0, 8.0)
	if species == Flora.BIRCH or species == Flora.BROADLEAF:
		tall *= 0.8
	for _i in 7:
		var z := stand_z + _rng.randf_range(-12.0, 12.0)
		var lx: float = stand_x + _rng.randf_range(-12.0, 12.0)
		_tree(species, z, lx, tall * _rng.randf_range(0.82, 1.15), tint.darkened(_rng.randf() * 0.2))
		# Each `_tree` sweeps the corridor for clearance; a whole stand in one
		# slice was a ~20 ms block on forest chunks.
		if pace.is_valid() and _slice_spent() and not await pace.call():
			return
	# Undergrowth in the stand's lee — a wood is not trees on a lawn, and the
	# shaded gap between trunks and ground is where the eye finds the lie.
	for _i in _rng.randi_range(2, 4):
		var s := _rng.randf_range(1.4, 3.2)
		_blob(
			stand_z + _rng.randf_range(-9.0, 9.0),
			stand_x + _rng.randf_range(-8.0, 8.0),
			Vector3(s * 1.7, s * _rng.randf_range(0.45, 0.75), s * 1.5),
			tint.darkened(_rng.randf_range(0.15, 0.38)),
			0.0,
			true
		)
		if pace.is_valid() and _slice_spent() and not await pace.call():
			return


func _forest_back_band(z0: float, side: float, mood: float, pace: Callable = Callable()) -> void:
	## The deep wood. Behind the stands the forest keeps going — taller, darker
	## trunks and crowns out where the canopy shades the ground to black. Every
	## tree out here starts far enough past the corridor that `_tree` never pays
	## its clearance sweep, so the depth is nearly free.
	##
	## Glade moods hold the band back so the clearing stays open to the sky; a
	## wall mood pushes it right up behind the planted edge.
	var near := 38.0
	var far := 95.0
	var rows := 6
	var deep: Color = (_pal["prop_c"] as Color).lerp(Color("152e24"), 0.45)
	if mood < 0.16:
		near = 26.0
		far = 70.0
		rows = 7
	elif mood < 0.38:
		near = 62.0
		far = 130.0
		rows = 4
	for _i in rows:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var lx: float = side * (HALF_WIDTH + _rng.randf_range(near, far))
		# The back wall is the verge stand's own deep timber — same cell, same
		# family, one height class run up a size with depth. A scatter of
		# per-tree rolls out here was what stacked the odd lone giant against
		# the skyline.
		var stand: Array = _stand_cell(int(side), z, theme)
		var species: int = int(stand[1])
		var tall := _stand_member_height(stand, 1.05, 1.3)
		# Past ~80 m a grown tree is limbs the eye cannot pick out against the
		# canopy wall behind it: a trunk, boughs and tiered skirts a hundred
		# metres off is four to six instances where a single crown mass reads
		# the same. The far band plants that mass instead — same z, same tint,
		# a tenth of the vertex cost.
		if absf(lx) - HALF_WIDTH > 80.0:
			var w := tall * _rng.randf_range(0.38, 0.58)
			_blob(
				z,
				lx,
				Vector3(w, tall * _rng.randf_range(0.34, 0.55), w * _rng.randf_range(0.75, 1.05)),
				deep.lightened(_rng.randf() * 0.14),
				0.0,
				true
			)
		else:
			_tree(species, z, lx, tall, deep.lightened(_rng.randf() * 0.14))
		if pace.is_valid() and _i % 3 == 2 and _slice_spent() and not await pace.call():
			return
	# The furthest layer is canopy, not trees: past a hundred metres a trunk is
	# a pixel wide, so wide dark crowns sitting on the slope carry the treeline.
	var wall_near := 88.0 if mood >= 0.16 else 60.0
	for _i in _rng.randi_range(3, 4):
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var lx: float = side * (HALF_WIDTH + _rng.randf_range(wall_near, 150.0))
		var w := _rng.randf_range(10.0, 18.0)
		_blob(
			z,
			lx,
			Vector3(w, _rng.randf_range(4.5, 8.5), w * _rng.randf_range(0.7, 1.1)),
			deep.darkened(_rng.randf() * 0.16),
			0.0,
			true
		)
	# Underwood between the planted edge and the deep band — the shaded
	# mid-layer that stops the floor reading as open grass between the trunks.
	var fill_near := 15.0 if mood < 0.16 else 20.0
	var fill_far := 46.0 if mood < 0.38 else 70.0
	for _i in _rng.randi_range(3, 5):
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var lx: float = side * (HALF_WIDTH + _rng.randf_range(fill_near, fill_far))
		var s := _rng.randf_range(1.8, 4.2)
		_blob(
			z,
			lx,
			Vector3(s * 1.7, s * _rng.randf_range(0.5, 0.8), s * 1.5),
			(_pal["prop_a"] as Color).lerp(deep, _rng.randf_range(0.4, 0.8)),
			0.0,
			true
		)
		if pace.is_valid() and _slice_spent() and not await pace.call():
			return


func _forest_verge(z0: float, side: float, pace: Callable = Callable()) -> void:
	## Saplings, young birch and rocks in the first few metres, so the wood
	## starts at the verge instead of behind an empty strip.
	for _i in 5:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var lx: float = side * (HALF_WIDTH + 3.0 + _rng.randf_range(0.0, 6.0))
		var roll := _rng.randf()
		var species: int = (
			Flora.CONIFER if roll < 0.5 else (Flora.BIRCH if roll < 0.72 else Flora.BROADLEAF)
		)
		_tree(
			species,
			z,
			lx,
			_rng.randf_range(2.2, 4.6),
			(_pal["prop_a"] as Color).darkened(_rng.randf() * 0.3)
		)
	for _i in 8:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var lx: float = side * (HALF_WIDTH + 2.5 + _rng.randf_range(0.0, 8.0))
		var s := _rng.randf_range(0.7, 1.8)
		if _rng.randf() < 0.5:
			var rock: PackedScene = _rock_scene(_rng.randf() < 0.5)
			if rock:
				# Untinted, the Kenney boulders land as orange litter on the
				# verge — the tan blobs the summit shots kept catching. Dress
				# them in the biome's own stone like `_vista_rock` does.
				_asset_prop(
					rock, z, lx, s * 2.1, s * 1.1,
					0.0, false,
					_vista_rock_material(
						Color("3b4438").darkened(_rng.randf() * 0.2)
					)
				)
			else:
				_verge_stone(z, lx, s)
		else:
			_verge_stone(z, lx, s)
		if pace.is_valid() and _slice_spent() and not await pace.call():
			return
	# An outcrop every few chunks: a knuckle of bedrock breaking the wood edge
	# is one of the things a planted verge never says.
	if posmod(chunk_index * 2 + int(side > 0.0), 5) == 2:
		var oz := z0 + _rng.randf_range(8.0, LENGTH - 8.0)
		var ox: float = side * (HALF_WIDTH + _rng.randf_range(7.0, 16.0))
		await _forest_outcrop(oz, ox, pace)


func _verge_stone(z: float, lateral: float, s: float) -> void:
	## A mossy stone bedded in the verge. These were green boxes in the
	## canopy's own tint — a row of crates along the forest road — so they
	## are rock now: the wood's grey stone with a breath of its moss, sunk a
	## fifth of their height so they sit in the ground rather than on it.
	var stone: Color = Color("5e6157").lerp(_pal["prop_a"] as Color, 0.22).darkened(_rng.randf() * 0.22)
	_blob(z, lateral, Vector3(s * 1.7, s * _rng.randf_range(0.7, 0.95), s * 1.4), stone, -s * 0.2, false)


func _forest_outcrop(z: float, lateral: float, pace: Callable = Callable()) -> void:
	## A small crag of mossy stone: overlapping lobes, dark at the foot, moss on
	## the shoulders. One footprint check for the whole cluster.
	var s := _rng.randf_range(1.1, 2.0)
	if not _footprint_is_clear(z, lateral, s * 2.2, s * 1.8):
		return
	var stone := Color("6f6d64")
	for _i in _rng.randi_range(3, 5):
		var bz := z + _rng.randf_range(-s * 1.6, s * 1.6)
		var bx: float = lateral + _rng.randf_range(-s, s)
		var bs := s * _rng.randf_range(0.55, 1.05)
		_blob(
			bz,
			bx,
			Vector3(bs * 1.7, bs * _rng.randf_range(0.7, 1.15), bs * 1.4),
			stone.darkened(_rng.randf() * 0.22),
			0.0,
			false
		)
	# Moss and fern on top, the way a real outcrop carries its own garden.
	for _i in _rng.randi_range(2, 3):
		var bz := z + _rng.randf_range(-s * 1.2, s * 1.2)
		var bx: float = lateral + _rng.randf_range(-s * 0.8, s * 0.8)
		var ms := s * _rng.randf_range(0.4, 0.7)
		_blob(
			bz,
			bx,
			Vector3(ms * 1.6, ms * 0.5, ms * 1.4),
			(_pal["prop_a"] as Color).lerp(_pal["verge"], 0.45).lightened(0.06),
			s * 0.55,
			true
		)
		if pace.is_valid() and _slice_spent() and not await pace.call():
			return


func _forest_snag(z: float, lateral: float) -> void:
	## A standing dead trunk — forests carry their dead, and one bare spike among
	## the crowns says grown woodland rather than planted verge. Trunk bucket
	## only: nothing leafy on it, so nothing to sweep.
	if not _footprint_is_clear(z, lateral, 0.45, 0.45):
		return
	var base: Vector3 = _ground_base_for_footprint(z, lateral, 0.45, 0.45) - _origin
	var h := _rng.randf_range(3.5, 7.0)
	var yaw := Basis(Vector3.UP, _rng.randf_range(0.0, TAU))
	var lean := Basis(Vector3.RIGHT, _rng.randf_range(-0.07, 0.07))
	_trunks.append(Transform3D(yaw * lean * Basis.IDENTITY.scaled(Vector3(0.4, h, 0.4)), base))
	# Silvered deadwood, not fresh bark — a snag is pale grey long before it falls.
	_trunk_cols.append(BARK.lerp(BARK_PALE, _rng.randf_range(0.45, 0.85)))
	# One snapped bough near the top, or it reads as a telegraph pole.
	if _rng.randf() < 0.7:
		var stub := Transform3D(
			(Basis(Vector3.UP, _rng.randf_range(0.0, TAU)) * Basis(Vector3.RIGHT, _rng.randf_range(0.5, 0.9))).scaled(
				Vector3(0.16, _rng.randf_range(0.8, 1.6), 0.16)
			),
			base + Vector3(0, h * _rng.randf_range(0.55, 0.8), 0)
		)
		_trunks.append(stub)
		_trunk_cols.append(BARK.lerp(BARK_PALE, 0.5))


func _forest_water(z0: float) -> void:
	## A still pool in a dip beside the road — the forest floor detail that turns
	## a verge into a place. Rare, small, always off the carriageway, and only
	## where the ground is flat enough that a sheet of water sits in it instead
	## of clipping through the slope.
	if _on_spur or _on_lake:
		return
	if posmod(chunk_index, 6) != 2:
		return
	var side: float = -1.0 if posmod(int(_path.world_seed) + chunk_index, 2) == 0 else 1.0
	var z := z0 + LENGTH * _rng.randf_range(0.3, 0.7)
	var lx: float = side * (HALF_WIDTH + _rng.randf_range(9.0, 15.0))
	var r := _rng.randf_range(2.8, 4.6)
	if not _footprint_is_clear(z, lx, r * 1.4 + 1.0, r * 1.4 + 1.0):
		return
	# Flat enough to hold water: if the ground under the sheet tips more than a
	# metre the pool reads as a tilted mirror, so the chunk just grows marsh
	# plants instead.
	var low := INF
	var high := -INF
	for i in 9:
		var a: float = TAU * float(i) / 8.0
		var sz := z
		var sx := lx
		if i < 8:
			sz += cos(a) * r * 0.8
			sx += sin(a) * r * 0.8
		var h: float = _terrain_surface_at(sz, sx).y
		low = minf(low, h)
		high = maxf(high, h)
	if high - low > 1.5:
		return
	var water_y := low - 0.05
	var b := LowPoly.new()
	b.smooth = true
	var sheet: Vector3 = _path.ground_at(z, lx)
	sheet.y = water_y
	b.add_cylinder(Transform3D(Basis.IDENTITY, sheet - _origin), r * 1.5, 0.07, 12, Color("14383c"))
	var mesh: MeshInstance3D = b.commit_to(self, "ForestPool")
	if mesh:
		mesh.material_override = water_material()
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		LowPoly.cheap_draw(mesh)
	# Reeds round the waterline and a couple of lily pads on it: without a ragged
	# edge the sheet reads as a dropped mirror rather than a dug pool.
	for _i in _rng.randi_range(8, 13):
		var a := _rng.randf_range(0.0, TAU)
		var rz := z + cos(a) * r * _rng.randf_range(0.85, 1.5)
		var rx: float = lx + sin(a) * r * _rng.randf_range(0.85, 1.5)
		var rh: float = _terrain_surface_at(rz, rx).y
		if rh > water_y + 0.02 and rh < water_y + 0.6:
			_grass_at(
				rz, rx, Vector3(_rng.randf_range(0.22, 0.4), _rng.randf_range(1.0, 1.7), _rng.randf_range(0.22, 0.4)),
				(_pal["verge"] as Color).lerp(_pal["prop_a"], 0.4).darkened(_rng.randf_range(0.1, 0.3))
			)
	for _i in _rng.randi_range(2, 4):
		var a := _rng.randf_range(0.0, TAU)
		var pad := _rng.randf_range(0.3, 0.55)
		var world: Vector3 = _path.ground_at(
			z + cos(a) * r * _rng.randf_range(0.15, 0.55),
			lx + sin(a) * r * _rng.randf_range(0.15, 0.55)
		)
		world.y = water_y + 0.04
		_cubes.append(Transform3D(Basis.IDENTITY.scaled(Vector3(pad, 0.04, pad)), world - _origin))
		_cube_cols.append((_pal["prop_a"] as Color).darkened(_rng.randf_range(0.05, 0.2)))


func _forest_floor(side: float, pace: Callable = Callable()) -> void:
	## Undergrowth and deadfall: fern clumps where the light comes in at the
	## verge, a mossy fallen log, stumps from an old thinning, a mossy boulder
	## or two. The floor is what makes a stand read as woodland instead of
	## trees parked on a lawn — and it is all small enough to stay cheap.
	var z0: float = float(chunk_index) * LENGTH
	for _clump in _rng.randi_range(2, 3):
		var cz := z0 + _rng.randf_range(0.0, LENGTH)
		var cx: float = side * (HALF_WIDTH + 4.5 + _rng.randf_range(0.0, 13.0))
		var fern: Color = (_pal["prop_a"] as Color).lerp(_pal["verge"], _rng.randf_range(0.3, 0.6))
		for _f in _rng.randi_range(4, 7):
			var s := _rng.randf_range(0.8, 1.4)
			_blob(
				cz + _rng.randf_range(-2.4, 2.4),
				cx + _rng.randf_range(-2.0, 2.0),
				Vector3(s, s * _rng.randf_range(0.3, 0.45), s),
				fern.darkened(_rng.randf() * 0.2),
				0.0,
				true
			)
		if pace.is_valid() and _slice_spent() and not await pace.call():
			return
	if _rng.randf() < 0.55:
		var lz := z0 + _rng.randf_range(5.0, LENGTH - 5.0)
		var lx: float = side * (HALF_WIDTH + _rng.randf_range(5.5, 18.0))
		var span := _rng.randf_range(3.5, 6.5)
		_terrain_beam(lz - span * 0.5, lz + span * 0.5, lx, 0.42, 0.4, BARK.darkened(0.15), 0.18)
		_blob(
			lz, lx, Vector3(0.55, 0.3, span * 0.45),
			(_pal["prop_a"] as Color).lightened(0.14), 0.36, false
		)
	for _i in _rng.randi_range(1, 3):
		_stump(z0 + _rng.randf_range(0.0, LENGTH), side * (HALF_WIDTH + 4.0 + _rng.randf_range(0.0, 14.0)))
	# A dead standing trunk most chunks — grown woodland carries its dead.
	if _rng.randf() < 0.55:
		_forest_snag(
			z0 + _rng.randf_range(0.0, LENGTH),
			side * (HALF_WIDTH + _rng.randf_range(6.0, 30.0))
		)
	for _b in _rng.randi_range(0, 2):
		var bz := z0 + _rng.randf_range(0.0, LENGTH)
		var bx: float = side * (HALF_WIDTH + 4.0 + _rng.randf_range(0.0, 15.0))
		var s := _rng.randf_range(0.8, 1.6)
		_blob(bz, bx, Vector3(s * 1.5, s * 0.9, s * 1.3), Color("6f6d64").darkened(_rng.randf() * 0.2), 0.0, false)
		_blob(
			bz + _rng.randf_range(-0.2, 0.2), bx + _rng.randf_range(-0.2, 0.2),
			Vector3(s * 0.85, s * 0.4, s * 0.85),
			(_pal["prop_a"] as Color).lerp(_pal["verge"], 0.4).lightened(0.08),
			s * 0.42, false
		)


func _stump(z: float, lateral: float) -> void:
	## A cut trunk a stride off the ground — the trunk mesh squat down, so it
	## shares the wood bucket and the corridor rule rather than needing a mesh
	## of its own.
	if not _footprint_is_clear(z, lateral, 0.45, 0.45):
		return
	var base: Vector3 = _ground_base_for_footprint(z, lateral, 0.45, 0.45) - _origin
	var s := _rng.randf_range(0.55, 0.95)
	var basis := Basis(Vector3.UP, _rng.randf_range(0.0, TAU)).scaled(
		Vector3(s, _rng.randf_range(0.4, 0.85), s)
	)
	_trunks.append(Transform3D(basis, base))
	_trunk_cols.append(BARK.lightened(_rng.randf_range(0.05, 0.25)))


func _scenery_forest_incremental() -> void:
	## Same wood as `_scenery_forest`, one slice at a time. The helpers take the
	## streaming pace callable and yield only once a slice is spent, so the two
	## paths grow identical stands off the identical stream.
	var z0: float = float(chunk_index) * LENGTH
	var pace := Callable(self, "_keep_streaming")
	for side in [-1.0, 1.0]:
		var mood := _rng.randf()
		var stand_count := _forest_stand_count(mood)
		for _stand in stand_count:
			await _forest_stand(z0, side, mood, pace)
			if not await _keep_streaming():
				return
		await _forest_back_band(z0, side, mood, pace)
		if not await _keep_streaming():
			return
		await _forest_verge(z0, side, pace)
		await _forest_floor(side, pace)
		if not await _keep_streaming():
			return
	_forest_water(z0)


func _scenery_mountain() -> void:
	var z0: float = float(chunk_index) * LENGTH
	for side in [-1.0, 1.0]:
		# Dark montane conifer in stands on the fellside — clumps keyed to the
		# stand cells, thinning into wind-shaped pine on the exposed ground,
		# never an even scatter of specimens.
		var side_i := int(side)
		var cell_a := int(floor((z0 + _stand_phase(side_i)) / STAND_CELL))
		var cell_b := int(floor((z0 + LENGTH + _stand_phase(side_i)) / STAND_CELL))
		for cell in range(cell_a, cell_b + 1):
			var stand: Array = _stand_cell(side_i, (float(cell) + 0.5) * STAND_CELL - _stand_phase(side_i), theme)
			if not stand[0]:
				continue
			var lo := maxf(z0, float(cell) * STAND_CELL - _stand_phase(side_i))
			var hi := minf(z0 + LENGTH, float(cell + 1) * STAND_CELL - _stand_phase(side_i))
			var tint: Color = (_pal["prop_a"] as Color).darkened(_rng.randf() * 0.3)
			for _i in _rng.randi_range(6, 10):
				var z := _rng.randf_range(lo, hi)
				var lx: float = side * (HALF_WIDTH + 5.0 + _rng.randf_range(0.0, 60.0))
				var h := _stand_member_height(stand, 0.82, 1.16)
				var species: int = int(stand[1])
				if _rng.randf() < 0.14:
					species = _stand_accent(species)
				if species == Flora.BIRCH:
					h *= 0.7
				elif species == Flora.PINE:
					h *= 0.9
				_tree(species, z, lx, h, tint.lightened(_rng.randf() * 0.1))
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
		var height := _rng.randf_range(0.28, 0.58)
		var tuft := Vector3(_rng.randf_range(0.5, 0.9), height, _rng.randf_range(0.5, 0.9))
		_grass_at(
			z, lx, tuft,
			(_pal["verge"] as Color).lerp(_pal["prop_a"], _rng.randf() * 0.5).darkened(_rng.randf() * 0.25)
		)

	# A vermilion gate every few chunks — the landmark that tells you where you are.
	if chunk_index % 7 == 3:
		var z := z0 + LENGTH * 0.5
		if _on_spur:
			_spur_gate(z)
			return
		for side in [-1.0, 1.0]:
			_cube(z, side * (HALF_WIDTH + 1.8), Vector3(0.55, 8.0, 0.55), _pal["accent"])
		_cube(z, 0.0, Vector3(HALF_WIDTH * 2.0 + 7.0, 0.6, 0.7), _pal["accent"], 0.0, 7.2, true, false)
		_cube(z - 0.9, 0.0, Vector3(HALF_WIDTH * 2.0 + 9.0, 0.5, 0.8), _pal["accent"], 0.0, 8.2, true, false)


func _spur_gate(z: float) -> void:
	## The same gate, on an overlook chunk. Props built here are tagged to the
	## highway corridor and freed the moment the rider commits to the detour, but
	## a gate over the main road stands in plain view of the spur beside it, so it
	## blinked out of the world as the bike took the exit. It gets its own mesh,
	## kept out of the corridor split. Where the exit lane still runs against the
	## carriageway a post would stand in the slip road, so the gate skips that
	## stretch rather than straddle the junction.
	# The highway pass runs again if the rider turns back after it was freed;
	# this mesh was never freed, so it must not be built twice.
	if has_meta("spur_gate_built"):
		return
	if float(_path.spur_half_width(z)) > 0.0 and float(_path.spur_gap(z)) < 14.0:
		return
	var b := LowPoly.new()
	var flat: Basis = _path.frame_flat_at(z)
	var accent: Color = _pal["accent"]
	for side in [-1.0, 1.0]:
		var lateral: float = side * (HALF_WIDTH + 1.8)
		var base: Vector3 = _ground_base_for_footprint(z, lateral, 0.28, 0.28, true) - _origin
		b.add_box(Transform3D(flat, base + flat.y * 4.0), Vector3(0.55, 8.0, 0.55), accent)
	var road: Vector3 = _path.point_at(z, 0.0) - _origin
	b.add_box(Transform3D(flat, road + flat.y * 7.5), Vector3(HALF_WIDTH * 2.0 + 7.0, 0.6, 0.7), accent)
	var back: Vector3 = _path.point_at(z - 0.9, 0.0) - _origin
	b.add_box(Transform3D(flat, back + flat.y * 8.45), Vector3(HALF_WIDTH * 2.0 + 9.0, 0.5, 0.8), accent)
	var mesh: MeshInstance3D = b.commit_to(self, "SpurGate")
	if mesh:
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mesh.set_meta("shared_corridor", true)
	set_meta("spur_gate_built", true)


func _scenery_mountain_incremental() -> void:
	_scenery_mountain()
	if not await _keep_streaming():
		return


func _scenery_country(streamed: bool = false) -> void:
	## Rolling farmland: hedged fields running off over the hills, post-and-rail
	## along the verge, broadleaf trees and hay bales. No buildings — this route
	## is meant to feel like nobody lives out here.
	##
	## `streamed` lets frame boundaries land between the stages: the fences,
	## hedgerows and tree passes all answer clearance queries, so the whole pass
	## in one slice was a ~20 ms lump on every other country chunk.
	var z0: float = float(chunk_index) * LENGTH

	# Field boundaries hugging both verges — mostly post-and-rail, with whole
	# stretches of dry-stone wall and the odd open pasture where the field grass
	# runs right up to the verge. One repeating fence is a wallpaper stripe; a
	# boundary that changes its mind every field is what reads as worked land.
	# The scenic-side verge keeps its boundary too, broken where the junction's
	# lane stands on the fence line and picking up past the gore — the way a
	# real field boundary crosses a junction mouth.
	for side in [-1.0, 1.0]:
		var blx: float = side * (HALF_WIDTH + 4.0)
		var bz := z0
		while bz < z0 + LENGTH - 0.01:
			var seg_end := minf(bz + _rng.randf_range(20.0, 55.0), z0 + LENGTH)
			var kind := _rng.randf()
			var lane_on_verge := (
				is_equal_approx(side, _vp_side) and _boundary_under_lane(bz, seg_end)
			)
			if not lane_on_verge:
				if kind < 0.55:
					_boundary_rail(bz, seg_end, blx)
				elif kind < 0.85:
					_boundary_stone(bz, seg_end, blx)
			# The open stretches and the segment joints are where a gate belongs:
			# one entrance every few hundred metres, not one per field.
			if not lane_on_verge and seg_end < z0 + LENGTH - 6.0 and _rng.randf() < 0.14:
				_field_gate(seg_end + 2.1, side)
				seg_end += 4.2
			bz = seg_end
			if streamed and _slice_spent() and not await _keep_streaming():
				return
		if streamed and _slice_spent() and not await _keep_streaming():
			return

	# Hedgerows grown on the painted parcel map: each field's road-end may
	# stand a hedge line across its own depth band, the longer depth edges
	# carry broken runs of hedge parallel to the road, and the odd mature oak
	# stands in the line — which is most of what an English hedgerow is. The
	# cells these read are the same ones _country_field_tint paints, so the
	# line you see shaded on the ground is the line you see grown.
	for side in [-1.0, 1.0]:
		if _on_spur and is_equal_approx(side, _vp_side):
			continue
		var side_i := int(side)
		for band in 4:
			var len_i := FIELD_LENGTHS[band]
			var phase := _field_phase(side_i, band)
			var k0 := int(floor((z0 + phase) / len_i)) - 1
			var k1 := int(floor((z0 + LENGTH + phase) / len_i))
			for k in range(k0, k1 + 1):
				var zb: float = float(k) * len_i - phase
				if zb < z0 + 1.5 or zb > z0 + LENGTH - 1.5:
					continue
				if not _field_hedged(side_i, band, k):
					continue
				_field_hedge_line(zb, side, band)
				if band == 0 and _rng.randf() < 0.35:
					# The gateway sits where the boundary meets the verge.
					_field_gate(zb + _rng.randf_range(-1.4, 1.4), side)
				if streamed and _slice_spent() and not await _keep_streaming():
					return
		for edge_i in [0, 1, 2]:
			var zs := z0
			while zs < z0 + LENGTH:
				var seg := int(floor(zs / FIELD_RUN))
				var seg_b: float = minf(z0 + LENGTH, float(seg + 1) * FIELD_RUN)
				if _field_hedge_run(side_i, edge_i, seg) and seg_b - zs > 3.0:
					var zz := zs
					while zz < seg_b - 1.2:
						var lat: float = side * (_field_edge_at(edge_i, zz, side_i) + 0.7)
						_leaf_cube(
							zz,
							lat,
							Vector3(1.7, _rng.randf_range(1.4, 2.3), _rng.randf_range(2.4, 3.3)),
							(_pal["prop_a"] as Color).darkened(0.04 + _rng.randf() * 0.26).lerp(
								_pal["verge"], _rng.randf() * 0.16
							),
							0.0,
							0.0,
							false,
							false
						)
						if _rng.randf() < 0.05:
							_tree(
								Flora.BROADLEAF,
								zz,
								lat + side * _rng.randf_range(0.8, 1.6),
								_rng.randf_range(9.0, 13.5),
								(_pal["prop_a"] as Color).darkened(0.04 + _rng.randf() * 0.16)
							)
						zz += _rng.randf_range(2.6, 3.4)
						if streamed and _slice_spent() and not await _keep_streaming():
							return
				zs += FIELD_RUN
				if streamed and _slice_spent() and not await _keep_streaming():
					return

	# Hedgerow oaks, the odd birch clump or shelterbelt conifer, and one big
	# field tree standing alone — grouped by the stand cells so they read as
	# grown groups, not a scattering of specimens on a lawn.
	for side in [-1.0, 1.0]:
		var side_i := int(side)
		var cell_a := int(floor((z0 + _stand_phase(side_i)) / STAND_CELL))
		var cell_b := int(floor((z0 + LENGTH + _stand_phase(side_i)) / STAND_CELL))
		for cell in range(cell_a, cell_b + 1):
			var stand: Array = _stand_cell(side_i, (float(cell) + 0.5) * STAND_CELL - _stand_phase(side_i), theme)
			if not stand[0]:
				continue
			var lo := maxf(z0, float(cell) * STAND_CELL - _stand_phase(side_i))
			var hi := minf(z0 + LENGTH, float(cell + 1) * STAND_CELL - _stand_phase(side_i))
			var tint: Color = (_pal["prop_a"] as Color).darkened(0.05 + _rng.randf() * 0.24)
			for _i in _rng.randi_range(2, 5):
				var z := _rng.randf_range(lo, hi)
				var lx: float = side * (HALF_WIDTH + 8.0 + _rng.randf_range(0.0, 74.0))
				var species: int = int(stand[1])
				if _rng.randf() < 0.14:
					species = _stand_accent(species)
				var h := _stand_member_height(stand, 0.82, 1.14)
				if species == Flora.BIRCH:
					h *= 0.8
				_tree(species, z, lx, h, tint.darkened(_rng.randf() * 0.14))
				if streamed and _slice_spent() and not await _keep_streaming():
					return
		if _rng.randf() < 0.55:
			_tree(
				Flora.BROADLEAF,
				z0 + _rng.randf_range(0.0, LENGTH),
				side * (HALF_WIDTH + 26.0 + _rng.randf_range(0.0, 50.0)),
				_rng.randf_range(11.0, 15.0),
				(_pal["prop_a"] as Color).darkened(0.04 + _rng.randf() * 0.17)
			)
		if streamed and _slice_spent() and not await _keep_streaming():
			return

	# Copses and spinneys cresting the midfield — a tight stand reads on a swell
	# at a hundred metres where a lone tree is only a speck.
	for side in [-1.0, 1.0]:
		if _on_spur and is_equal_approx(side, _vp_side):
			continue
		if _rng.randf() > 0.45:
			continue
		var cz2 := z0 + _rng.randf_range(5.0, LENGTH - 5.0)
		var clx2: float = side * (HALF_WIDTH + _rng.randf_range(50.0, 125.0))
		var stand_col: Color = (_pal["prop_a"] as Color).darkened(_rng.randf_range(0.1, 0.26))
		var reach := _rng.randf_range(5.0, 10.0)
		for _t in _rng.randi_range(4, 8):
			var a2 := _rng.randf_range(0.0, TAU)
			var rr := sqrt(_rng.randf()) * reach
			_tree(
				Flora.CONIFER if _rng.randf() < 0.28 else Flora.BROADLEAF,
				cz2 + cos(a2) * rr,
				clx2 + sin(a2) * rr * 0.8,
				_rng.randf_range(7.0, 12.5),
				stand_col.lightened(_rng.randf() * 0.06)
			)

	# A low down swelling through the field plain now and then: the terrain
	# already rolls, but a broad hump drapes a couple of parcels over a shoulder
	# and gives the far hedges something to climb. Unculled like the skyline
	# ridges — a hill popping in at a hundred metres is worse than its draw.
	for side in [-1.0, 1.0]:
		if _on_spur and is_equal_approx(side, _vp_side):
			continue
		if _rng.randf() > 0.5:
			continue
		var dz2 := z0 + _rng.randf_range(0.0, LENGTH)
		var dlx: float = side * _rng.randf_range(95.0, 160.0)
		_ridge(
			dz2,
			dlx,
			Vector3(_rng.randf_range(48.0, 92.0), _rng.randf_range(4.5, 8.0), _rng.randf_range(40.0, 75.0)),
			(_pal["ground_alt"] as Color).lerp(_pal["ground"], 0.3).darkened(_rng.randf_range(0.0, 0.1))
		)
		if _rng.randf() < 0.45:
			# And a spinney on its crest — the classic hilltop clump.
			for _t in _rng.randi_range(3, 6):
				_tree(
					Flora.BROADLEAF,
					dz2 + _rng.randf_range(-12.0, 12.0),
					dlx + _rng.randf_range(-8.0, 8.0),
					_rng.randf_range(6.0, 10.0),
					(_pal["prop_a"] as Color).darkened(0.04 + _rng.randf() * 0.16)
				)

	# Grass out across the fields themselves, thinning with distance — the verge
	# planting alone stops at ~13 m and left everything beyond it a bare tinted
	# ground plane instead of pasture. Plough stays bare earth.
	for _i in 80:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var side: float = 1.0 if _rng.randf() < 0.5 else -1.0
		var lx: float = side * (HALF_WIDTH + 10.0 + pow(_rng.randf(), 1.4) * 80.0)
		var fkind := _field_kind_at(int(side), absf(lx), z)
		if fkind == Field.FALLOW and _rng.randf() < 0.7:
			continue
		var height := _rng.randf_range(0.3, 0.62)
		var tuft := Vector3(_rng.randf_range(0.5, 0.9), height, _rng.randf_range(0.5, 0.9))
		var tuft_col: Color = (
			(_pal["verge"] as Color).lerp(_pal["prop_a"], _rng.randf() * 0.5).darkened(_rng.randf() * 0.25)
		)
		if fkind == Field.MOWN:
			tuft_col = tuft_col.lerp(_pal["prop_c"], 0.3)
		_grass_at(z, lx, tuft, tuft_col)
		if streamed and int(_i) % 10 == 9 and _slice_spent() and not await _keep_streaming():
			return

	# Round bales in the cut fields — dropped where the parcel map says mown,
	# in loose little clusters rather than an even scatter, the way a baler
	# actually leaves them behind.
	for _i in 5:
		var cz := z0 + _rng.randf_range(0.0, LENGTH)
		var cside: float = 1.0 if _rng.randf() > 0.5 else -1.0
		var clx: float = cside * (HALF_WIDTH + 14.0 + _rng.randf_range(0.0, 65.0))
		if _field_kind_at(int(cside), absf(clx), cz) != Field.MOWN and _rng.randf() < 0.72:
			continue
		var bales: int = _rng.randi_range(2, 4)
		# No lightening: the pale end of the jitter is exactly where a bale
		# stops being hay and starts being a dune.
		var bale_color: Color = (_pal["prop_c"] as Color).darkened(_rng.randf_range(0.0, 0.1))
		for _j in bales:
			var z := cz + _rng.randf_range(-4.0, 4.0)
			var lx: float = clx + _rng.randf_range(-4.0, 4.0)
			_hay_bale(z, lx, _rng.randf_range(0.55, 0.7), _rng.randf_range(1.1, 1.4), bale_color)

	# Sheep out in the nearer fields — a flock every couple of chunks, never an
	# even scatter, and keyed to the grass parcels so they crop the pasture
	# instead of standing in the barley. At the only distances they are ever
	# seen from, a cream blob with a dark head tucked under its shoulder is a
	# ewe; rarer, a bigger brown-black body is cattle. All of it goes through
	# the same corridor checks as the bales.
	for _flock in 2:
		if _rng.randf() > 0.58:
			continue
		var fz2 := z0 + _rng.randf_range(2.0, LENGTH - 2.0)
		var fside: float = 1.0 if _rng.randf() < 0.5 else -1.0
		# The near edge of the band matters most: a ewe 20 m out is a cream dot
		# over the wall top, one at 60 m is lost against the far pasture.
		var fx: float = fside * (HALF_WIDTH + _rng.randf_range(12.0, 44.0))
		var flock_kind := _field_kind_at(int(fside), absf(fx), fz2)
		if flock_kind != Field.GRAZED and flock_kind != Field.PASTURE and _rng.randf() < 0.75:
			continue
		if not _footprint_is_clear(fz2, fx, 7.0, 9.0):
			continue
		if _rng.randf() < 0.2:
			# Cattle: fewer, bigger, darker, spread wider across the field.
			var hide := Color("4a362a").darkened(_rng.randf() * 0.15)
			for _i in _rng.randi_range(2, 4):
				_grazer(
					fz2 + _rng.randf_range(-9.0, 9.0), fx + _rng.randf_range(-8.0, 8.0),
					_rng.randf_range(1.5, 1.75), hide
				)
		else:
			var wool := Color("f0ead9").darkened(_rng.randf() * 0.08)
			for _i in _rng.randi_range(5, 8):
				_sheep(
					fz2 + _rng.randf_range(-7.0, 7.0), fx + _rng.randf_range(-5.5, 5.5),
					wool.darkened(_rng.randf() * 0.07)
				)

	# No farmstead, no telegraph stubs: buildings are out, and the power line is
	# built by _power_line() with real spans rather than bare poles.


func _field_hedge_line(z: float, side: float, band: int) -> void:
	## A hedgerow stood on one painted parcel boundary, marching out across its
	## own depth band. The cell is the same one the ground colour reads, so the
	## grown line always sits inside the shadow already painted under it.
	var side_i := int(side)
	var out := 16.5 if band == 0 else _field_edge_at(band - 1, z, side_i) + 1.6
	var outer: float = _field_edge_at(band, z, side_i) - 1.4
	var line_col: Color = (_pal["prop_a"] as Color).darkened(_rng.randf() * 0.1)
	while out < outer:
		var h := _rng.randf_range(1.5, 2.6)
		# follow_terrain=false, as before: a hedge segment this narrow sits fine
		# on a single terrain sample, and the nine-sample corner fit was the
		# single largest per-chunk streaming hitch.
		_leaf_cube(
			z + _rng.randf_range(-0.9, 0.9),
			side * out,
			Vector3(_rng.randf_range(2.4, 3.2), h, 1.6),
			line_col.lerp(_pal["verge"], _rng.randf() * 0.16).darkened(_rng.randf() * 0.18),
			0.0,
			0.0,
			false,
			false
		)
		if _rng.randf() < 0.05:
			# A mature oak stood in the hedge line — most of what makes the
			# English field pattern read from a distance is the trees on it.
			_tree(
				Flora.BROADLEAF,
				z + _rng.randf_range(-1.0, 1.0),
				side * (out + _rng.randf_range(0.5, 1.5)),
				_rng.randf_range(9.0, 14.0),
				line_col.lightened(_rng.randf() * 0.08)
			)
		out += _rng.randf_range(2.5, 3.4)


func _boundary_rail(z_a: float, z_b: float, lateral: float) -> void:
	## Post-and-rail on the verge line. Rails span two post bays (8 m), the way
	## real post-and-rail runs do, rather than one terrain-fitted beam per 4 m:
	## half the beam count, and each beam is two `_terrain_surface_at` plus a
	## footprint query, so the fence was once the second-largest streaming cost.
	var fz := z_a
	var fseg := 0
	while fz < z_b - 0.01:
		_cube(fz, lateral, Vector3(0.12, 1.15, 0.12), _pal["rail"])
		if fseg % 2 == 0:
			var zend: float = minf(fz + 8.0, z_b)
			# The rails face up into the key — a bare palette colour blooms to
			# cream, so the beams run a step under the posts.
			var beam: Color = (_pal["rail"] as Color).darkened(0.12)
			_terrain_beam(fz, zend, lateral, 0.09, 0.09, beam, 0.92)
			_terrain_beam(fz, zend, lateral, 0.09, 0.09, beam, 0.58)
		fz += 4.0
		fseg += 1


func _boundary_stone(z_a: float, z_b: float, lateral: float) -> void:
	## A run of dry-stone wall: a course beam and a wider coping course per bay.
	## Kept low — about hip height — so the fields still read over the top, and
	## slightly darker than the rail timber so the swap reads at a glance.
	var stone: Color = (_pal["rail"] as Color).lerp(Color("565c50"), 0.55).darkened(0.05)
	var fz := z_a
	var fseg := 0
	while fz < z_b - 0.01:
		var zend: float = minf(fz + 4.0, z_b)
		_terrain_beam(fz, zend, lateral, 0.5, 0.86, stone.darkened(_rng.randf() * 0.14), 0.43)
		_terrain_beam(fz, zend, lateral, 0.6, 0.13, stone.lightened(0.04).darkened(_rng.randf() * 0.1), 0.93)
		# A stood through-stone every third bay gives the wall its silhouette
		# breaks — the piece that says dry stone, not poured kerb.
		if fseg % 3 == 1:
			_cube(
				fz + _rng.randf_range(0.0, 3.0), lateral,
				Vector3(0.26, 1.12, 0.34), stone.darkened(_rng.randf_range(0.12, 0.3))
			)
		fz += 4.0
		fseg += 1


func _sheep(z: float, lateral: float, wool: Color) -> void:
	## One grazing sheep: a fat woolly body, a dark head tucked low at one end,
	## and a thin dark slab under it for legs and shade. Headed whichever way it
	## happened to be cropping when we looked. Run a touch over true scale — a
	## ewe at forty metres is a moving dot, not a silhouette.
	_grazer(z, lateral, _rng.randf_range(1.25, 1.5), wool)


func _grazer(z: float, lateral: float, s: float, coat: Color) -> void:
	## Body plus head plus a leg-shadow slab; `s` scales a sheep up into a cow.
	## The head sits low at one end of the body — grazing, not alert — and is a
	## separate blob so the animal reads as two tones instead of one lozenge.
	var head_col := Color("4a423c").darkened(_rng.randf() * 0.1)
	_cube(z, lateral, Vector3(0.42 * s, 0.32 * s, 0.9 * s), head_col.darkened(0.15))
	_blob(z, lateral, Vector3(s * 0.95, s * 0.62, s * 1.3), coat, 0.24 * s, false)
	var a := _rng.randf_range(0.0, TAU)
	_blob(
		z + cos(a) * 0.62 * s, lateral + sin(a) * 0.62 * s,
		Vector3(s * 0.26, s * 0.3, s * 0.3), head_col, 0.34 * s, false
	)


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
	for side in [-1.0, 1.0]:
		_build_distant_scenery_side(side)


func _build_distant_scenery_incremental() -> void:
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
	for band in BANDS:
		var count: int = band["count"]
		for i in count:
			var z := z0 + (float(i) + 0.5) * LENGTH / float(count) + _rng.randf_range(-6.0, 6.0)
			var lateral_range: Array = band["lateral"]
			var lx: float = side * _rng.randf_range(lateral_range[0], lateral_range[1])
			# The overlook authors its own range, far shore and headland on the
			# view side — a backdrop cone parked in the basin fights that
			# composition and stands in the water.
			if _viewpoint_reserves_sightline(z, lx):
				continue
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
	var width: float = 2.6
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
	var stone := Color("6c6f62").darkened(0.08)
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
	# A copse is one planting: take the stand cell's family and height so the
	# knoll reads as grown together, not eleven separate rolls on a mound.
	var stand: Array = _stand_cell(int(side), z, theme)
	var copse_species: int = int(stand[1])
	var copse_tall := float(stand[2])
	for i in 11:
		var tz: float = z + _rng.randf_range(-6.5, 6.5)
		var tlat: float = lx + _rng.randf_range(-7.0, 7.0)
		if _on_tarmac(tz, tlat, 1.6):
			continue
		var species: int = copse_species
		if _rng.randf() < 0.18:
			species = _stand_accent(species)
		_tree(species, tz, tlat, copse_tall * _rng.randf_range(0.84, 1.14), tint, true, 1.6)
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
	return floori(centre / LENGTH) == index and theme_id in [Env.FOREST, Env.MOUNTAIN, Env.COUNTRY]


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
# biome: country lake and pass, forest gorge, mountain tarn.


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
		# The gravel is the made ground's own dark tone — the palette shoulder in
		# mountain read as poured concrete and in country as a strip of sand.
		for edge in [-1.0, 1.0]:
			var facing_road: bool = (edge < 0.0) == (inner_edge == 0)
			if facing_road and minf(gore_a, gore_b) < RoadPathGD.SPUR_SHOULDER + GORE_OPEN:
				continue
			var la: float = span_a.x if edge < 0.0 else span_a.y
			var lb: float = span_b.x if edge < 0.0 else span_b.y
			var oa: float = la + edge * RoadPathGD.SPUR_SHOULDER
			var ob: float = lb + edge * RoadPathGD.SPUR_SHOULDER
			var gravel: Color = _deck_color((za + zb) * 0.5, (la + lb) * 0.5 + edge * RoadPathGD.SPUR_SHOULDER * 0.5)
			if edge < 0.0:
				hard.add_quad(_p(za, oa, 0.0), _p(za, la, -PROUD), _p(zb, lb, -PROUD), _p(zb, ob, 0.0), gravel)
			else:
				hard.add_quad(_p(za, la, -PROUD), _p(za, oa, 0.0), _p(zb, ob, 0.0), _p(zb, lb, -PROUD), gravel)
		var width_a := span_a.y - span_a.x
		var width_b := span_b.y - span_b.x
		if maxf(width_a, width_b) < 0.3:
			continue  # the very tip of the mouth taper is below paint width
		# Edge lines, and a dashed centre line on the running sections only — a
		# painted centre line across a car park would be nonsense.
		for edge in [-1.0, 1.0]:
			var on_road_side: bool = (edge < 0.0) == (inner_edge == 0)
			if on_road_side and minf(gore_a, gore_b) < GORE_OPEN:
				continue  # the carriageway's own edge line is already there
			# The boundary line hugs the edge: a fixed inset only fits once the
			# taper is nearly a metre wide, and would leave the first stretch of
			# the mouth an unpainted sliver of tarmac.
			var inset_a := clampf(width_a * 0.5, 0.14, 0.45)
			var inset_b := clampf(width_b * 0.5, 0.14, 0.45)
			var la: float = (span_a.x + inset_a) if edge < 0.0 else (span_a.y - inset_a)
			var lb: float = (span_b.x + inset_b) if edge < 0.0 else (span_b.y - inset_b)
			hard.add_quad(
				_p(za, la - 0.1, -PROUD - LINE),
				_p(za, la + 0.1, -PROUD - LINE),
				_p(zb, lb + 0.1, -PROUD - LINE),
				_p(zb, lb - 0.1, -PROUD - LINE),
				stripe
			)
		# A centre line belongs to the two-way road, not to the deceleration
		# lane it grows out of or the car park it ends at.
		var half_a := float(_path.spur_half_width(za))
		if half_a >= 2.5 and half_a < RoadPathGD.SPUR_HALF_WIDTH + 1.0 and fposmod(za, 7.0) < 3.6:
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
		# The lane line appears as the mouth taper completes, not inside the
		# wedge — paint splitting a half-formed lane reads as two slivers.
		if float(_path.spur_half_width(za)) < RoadPathGD.SPUR_LANE_HALF - 0.15:
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
## Widths are set against the saddle view, not the map: road paint on tarmac is
## only ever seen at a grazing angle, where a nominal 30 cm line foreshortens to
## a hairline. A real chevron is nearer 50 cm of laid paint — the fat bar is
## what makes the wedge read as a marking instead of a texture seam.
const GORE_LINE := 0.21  # half width of the two border lines
const GORE_BAR := 0.34  # half width of a chevron, measured along the route
const GORE_PITCH := 3.4  # route metres from one chevron to the next
const GORE_SLANT := 0.62  # chevron run along the route per metre of gap


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
	# Grit and tyre wear take a gore's paint down long before the lines beside
	# it. Fresh-line cream across the whole wedge was the brightest object in
	# the junction frame — a sunlit triangle where the eye should find tarmac.
	var stripe: Color = (_pal["stripe"] as Color).lerp(_pal["road"], 0.55).darkened(0.10)
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


func _build_gore_paving(road: LowPoly, z0: float) -> void:
	## The gore is tarmac, not verge: a paved wedge filling the mouth between
	## the carriageway's edge and the slip lane's, hatched over by the paint.
	## Without it the junction read as a lane bolted onto pale dirt — the
	## "sandy" strip every mouth used to grow — where the roads should still
	## be one surface. It ends where the roads truly part; past that the
	## separation is grass and the made ground steps back with it. Drawn on the
	## road ribbon itself so it carries the same tarmac material, not the
	## flatter paint surface the markings use.
	const PROUD := 0.05
	var surface: Color = _pal["road"]
	var step := LENGTH / float(STEPS)
	for i in STEPS:
		var za := z0 + float(i) * step
		var zb := za + step
		var span_a := _spur_span(za)
		var span_b := _spur_span(zb)
		if span_a == Vector2.ZERO or span_b == Vector2.ZERO:
			continue  # no lane yet — nothing to pave against
		var gap_a: float = float(_path.spur_gap(za))
		var gap_b: float = float(_path.spur_gap(zb))
		if minf(gap_a, gap_b) < 0.12 or maxf(gap_a, gap_b) >= RoadPathGD.GORE_GRASSED:
			continue
		# Stop short of the lane's own surfaced shoulder where one is drawn:
		# two skins at near the same height is a shimmer, not a seam.
		var margin := 0.0
		if minf(gap_a, gap_b) >= RoadPathGD.SPUR_SHOULDER + 1.6:
			margin = RoadPathGD.SPUR_SHOULDER
		var ia: float = _gore_outer(za) + 0.35 - margin
		var ib: float = _gore_outer(zb) + 0.35 - margin
		var edge := _gore_inner() - 0.45
		# Wound the way the road ribbon winds: outward on the right, back inward
		# on the left, so the quad faces up whichever side the overlook is on.
		var l0 := _vp_side * edge
		var l1 := _vp_side * ia
		var l2 := _vp_side * edge
		var l3 := _vp_side * ib
		if _vp_side < 0.0:
			l0 = _vp_side * ia
			l1 = _vp_side * edge
			l2 = _vp_side * ib
			l3 = _vp_side * edge
		road.add_quad_uv(
			_p(za, l0, -PROUD),
			_p(za, l1, -PROUD),
			_p(zb, l3, -PROUD),
			_p(zb, l2, -PROUD),
			surface,
			# Same road-space UV the carriageway uses: past the edge line the
			# shader lays plain tarmac, so the wedge reads as the road's own
			# surface rather than a lane of its own.
			Vector2(l0, za),
			Vector2(l1, za),
			Vector2(l3, zb),
			Vector2(l2, zb)
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


func _build_spur_barrier(hard: LowPoly, z0: float, streamed: bool = false) -> void:
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
		# The road-side face is a waist-high band at handlebar height — it
		# foreshortens into a broad field, and any warm stone tone on it reads
		# as a sand apron running the length of the climb. Painting the side
		# faces with the bank's own mossy cut colour makes them read as the
		# shaded grassed bank the wall stands on; only the pale coping carries
		# the drystone read now.
		var face_dark: Color = _embankment_color(la, za).lerp(Color("20301f"), 0.72)
		hard.add_quad(a_foot - out, b_foot - out, b_top - out, a_top - out, face_dark)
		hard.add_quad(b_foot + out, a_foot + out, a_top + out, b_top + out, face_dark)
		hard.add_quad(a_top - out, b_top - out, b_top + out, a_top + out, segment_stone.lerp(Color("5a6058"), 0.5))
		if i % 3 == 2 and streamed and _slice_spent() and not await _keep_streaming():
			return


func _spur_span(z: float) -> Vector2:
	## Signed lateral span of the spur surface at z, ordered low to high so every
	## quad built from it winds face-up whichever side the overlook is on.
	var span: Vector2 = _path.spur_interval(z)
	if span == Vector2.ZERO:
		return span
	return Vector2(minf(span.x, span.y), maxf(span.x, span.y))


func _spur_local(z: float, lateral: float) -> float:
	return (lateral - _vp_side * float(_path.spur_offset(z))) * _vp_side


func _build_platform_bays(hard: LowPoly, z0: float, streamed: bool = false) -> void:
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
		if streamed and _slice_spent() and not await _keep_streaming():
			return


func _build_spur_furniture(streamed: bool = false) -> void:
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
		if streamed and _slice_spent() and not await _keep_streaming():
			return


func _build_highway_spur_screen(streamed: bool = false) -> void:
	## Trees between the carriageway and the unused climb. Once the scenic
	## corridor is culled, this is what the bottom road looks at instead of a
	## fenced empty spur.
	if not _on_spur:
		return
	var z0: float = float(chunk_index) * LENGTH
	for station in 5:
		if streamed and _slice_spent() and not await _keep_streaming():
			return
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
		# The screen grows where the verge's stand cells say wood grows —
		# clumps and openings on the same grid the climb itself plants.
		var stand: Array = _stand_cell(int(_vp_side), z, _vp_theme)
		if not stand[0]:
			continue
		var species: int = int(stand[1])
		if _rng.randf() < 0.1:
			species = _stand_accent(species)
		var height: float = _stand_member_height(stand, 0.86, 1.12)
		_tree(
			species,
			z,
			inner,
			height,
			Color("2a4634").lerp(
				Color("4a6840"), clampf(float(stand[3]) * 0.4 + _rng.randf() * 0.1, 0.0, 0.35)
			),
			true
		)


func _build_basin_roadside(streamed: bool = false) -> void:
	## The main-road side of an overlook stretch. The theme scatter stops at the
	## same depth it uses on every chunk, and on this shelf that leaves a lawn
	## eighty metres deep between the verge and the headland — the bare plain
	## the whole stretch read as. Copses and shrubs carry the biome's look out
	## across the shelf, the drowned tails and the shore fringe. Nothing here
	## bypasses the ordinary rules: the seat's reserve, both tarmacs and the
	## waterline are still `_footprint_is_clear` and `_height_above_water`, so
	## dressing stops exactly where the corridor and the lake begin.
	if not _on_spur or _vp_side == 0.0:
		return
	var z0: float = float(chunk_index) * LENGTH
	var woody: Color = _pal["prop_a"]
	var deep: Color = _pal["prop_c"]
	# View-side copses: small stands of the basin biome's trees stepping down
	# the shelf toward the water — a real valley side is never one lawn.
	for _clump in 5:
		if streamed and _slice_spent() and not await _keep_streaming():
			return
		var cz := z0 + _rng.randf_range(0.0, LENGTH)
		var shore: float = float(_path.viewpoint_near_shore(cz))
		var out := _rng.randf_range(HALF_WIDTH + 16.0, maxf(shore - 6.0, HALF_WIDTH + 26.0))
		var cx: float = _vp_side * out
		if _height_above_water(cz, out) < 2.0:
			continue
		# Foliage deep, not raw prop_c: the country prop_c is cut-hay gold kept
		# for the bales — copse crowns lerped toward it were the pale-gold
		# islands jumping off the green slope.
		var leaf_deep: Color = deep if _vp_theme != Env.COUNTRY else Color("2e4a2c")
		var tint: Color = woody.lerp(leaf_deep, _rng.randf() * 0.6).darkened(_rng.randf() * 0.2)
		if _vp_theme == Env.COUNTRY and _rng.randf() < 0.3:
			# A hedge line out on the pasture shelf — the country side reads as
			# worked fields, not a plantation.
			var hz := cz - _rng.randf_range(0.0, 14.0)
			var hx: float = cx + _rng.randf_range(-6.0, 6.0) * _vp_side
			for seg in _rng.randi_range(4, 8):
				_leaf_cube(
					hz + float(seg) * _rng.randf_range(2.4, 3.2),
					hx,
					Vector3(2.6, _rng.randf_range(1.4, 2.2), 1.5),
					tint.darkened(_rng.randf() * 0.25),
					0.0,
					0.0,
					false,
					false
				)
			continue
		# One copse is one planting: a family and a size shared by its members,
		# with the odd accent — not a fresh species roll for every trunk.
		var clump_stand: Array = _stand_cell(int(_vp_side), cz, _vp_theme)
		var clump_species: int = int(clump_stand[1])
		var clump_tall := float(clump_stand[2]) * _rng.randf_range(0.75, 0.95)
		for _i in _rng.randi_range(2, 5):
			var z := cz + _rng.randf_range(-9.0, 9.0)
			var lx: float = cx + _vp_side * _rng.randf_range(-8.0, 8.0)
			# Ground to the drawn chord, not the analytic surface — the copse
			# trees and their skirts were the floaters on the s1 face.
			var lift := _face_ground_lift(z, absf(lx))
			var species: int = clump_species
			if _vp_theme == Env.COUNTRY:
				species = Flora.BROADLEAF
			elif _rng.randf() < 0.2:
				species = _stand_accent(species)
			_tree(species, z, lx, clump_tall * _rng.randf_range(0.82, 1.12), tint, false, lift)
			if streamed and _slice_spent() and not await _keep_streaming():
				return
		# The clump's skirt — a stand with no undergrowth is lollipops on a lawn.
		for _i in _rng.randi_range(2, 4):
			var s := _rng.randf_range(1.2, 2.6)
			var bz := cz + _rng.randf_range(-8.0, 8.0)
			var bx: float = cx + _vp_side * _rng.randf_range(-7.0, 7.0)
			_blob(
				bz,
				bx,
				Vector3(s * 1.6, s * _rng.randf_range(0.5, 0.8), s * 1.4),
				tint.darkened(_rng.randf_range(0.15, 0.35)),
				_face_ground_lift(bz, absf(bx)),
				true
			)
	# The shore fringe: reeds and low bushes where the drowned tails flatten to
	# the water, so the shelf's far edge reads as a shoreline and not a mown
	# strip. Inside the basin span the reserve refuses these by itself.
	for _i in 8:
		if streamed and _slice_spent() and not await _keep_streaming():
			return
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var shore: float = float(_path.viewpoint_near_shore(z))
		var out: float = shore + _rng.randf_range(-14.0, 2.0)
		if _height_above_water(z, out) < 0.7:
			continue
		var s := _rng.randf_range(0.8, 1.8)
		_blob(
			z,
			_vp_side * out,
			Vector3(s * 1.8, s * _rng.randf_range(0.4, 0.7), s * 1.6),
			(_pal["verge"] as Color).lerp(deep, 0.45).darkened(_rng.randf() * 0.2),
			# The fringe bushes at the drowned tail's edge were the floaters on
			# the island lip — ground to the drawn chord like the rest of the face.
			_face_ground_lift(z, out),
			true
		)
	# The opposite verge keeps its trees too — a few deeper specimens put trunks
	# on the inland hillside rather than letting the wood stop at the usual line.
	for _i in 3:
		if streamed and _slice_spent() and not await _keep_streaming():
			return
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var lx: float = -_vp_side * (HALF_WIDTH + _rng.randf_range(80.0, 160.0))
		var species := Flora.BROADLEAF if _vp_theme == Env.COUNTRY else Flora.CONIFER
		_tree(species, z, lx, _rng.randf_range(8.0, 14.0), deep.darkened(_rng.randf() * 0.15))


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
	# The same marker at the merge. The gore is symmetric, so the closing nose
	# is the entry nose mirrored through the overlook — without a board there
	# the rejoin read as the slip road quietly running out of road.
	var merge := _vp_centre + (_vp_centre - nose)
	if merge >= z0 and merge < z0 + LENGTH:
		var lateral: float = _vp_side * (float(_path.spur_offset(merge)) - float(_path.spur_half_width(merge)) - 1.8)
		var yaw := _spur_yaw(merge) * 0.5
		_deck_cube(merge, lateral, Vector3(0.18, 1.7, 0.18), Color("626a70"), yaw, 0.0)
		_deck_cube(merge, lateral, Vector3(2.3, 1.05, 0.16), Color("f0b33b"), yaw, 1.7)
		_deck_cube(merge, lateral, Vector3(2.3, 0.14, 0.18), Color("2b2f36"), yaw, 2.2)
	_build_summit_gate()


func _build_summit_gate() -> void:
	## A threshold where the climb empties onto the parking apron. The last
	## hundred metres before the platform used to carry nothing at eye level —
	## one milepost on a widening ribbon of bare tarmac. A real summit lays
	## the arrival out: stone gate piers straddling the lane, a low wing wall
	## leading the eye to the parapet, an interpretive board at the lip. The
	## gate stands a few metres before the deck starts to widen, so it frames
	## the widening rather than standing on the car park itself.
	var z0 := float(chunk_index) * LENGTH
	var apron: float = RoadPathGD.PLATFORM_HALF_LENGTH + RoadPathGD.PLATFORM_TAPER
	var scarp := _face_scarp_palette()
	var stone: Color = (scarp["rock_hi"] as Color).lerp(scarp["soil"], 0.35).darkened(0.10)
	var cap: Color = (scarp["rock_hi"] as Color).darkened(0.04)
	for gate in [_vp_centre - apron - 3.0, _vp_centre + apron + 3.0]:
		if gate < z0 or gate >= z0 + LENGTH:
			continue
		var off: float = float(_path.spur_offset(gate))
		var half: float = float(_path.spur_half_width(gate))
		for side_i in [-1.0, 1.0]:
			var pier_lat: float = _vp_side * (off + side_i * (half + 1.45))
			if _on_tarmac(gate, pier_lat, 0.4):
				continue
			_deck_cube(gate, pier_lat, Vector3(0.95, 2.3, 0.95), stone, 0.0, 0.0)
			_deck_cube(gate, pier_lat, Vector3(1.25, 0.26, 1.25), cap, 0.0, 2.3)
			_deck_cube(gate, pier_lat, Vector3(0.62, 0.5, 0.62), stone.darkened(0.08), 0.0, 2.56)
		# A wing wall on the drop side, leading in toward the parapet line.
		var inward: float = signf(_vp_centre - gate)
		var wall_lat: float = _vp_side * (off + half + 2.6)
		var w_a: float = gate + inward * 1.5
		var w_b: float = gate + inward * 11.5
		_terrain_beam(w_a, w_b, wall_lat, 0.46, 0.9, stone, 0.42, true)
		_terrain_beam(w_a, w_b, wall_lat, 0.6, 0.16, cap, 0.93, true)
		# The board faces the vista: the gate says you have arrived, the board
		# says what you are looking at. It stands inside the gate line — on the
		# platform side whichever end of the apron this threshold marks.
		_viewpoint_board(gate + signf(_vp_centre - gate) * 2.2, _vp_side, half + 3.6, cap)
		# And a couple of bedded boulders so the threshold reads as built into
		# the headland, not pinned onto it.
		for b in 2:
			var bz: float = gate + _rng.randf_range(-3.0, 4.0)
			var bl: float = _vp_side * (off + half + _rng.randf_range(1.8, 3.4))
			if _on_tarmac(bz, bl, 0.5):
				continue
			var s: float = _rng.randf_range(1.1, 2.0)
			_deck_blob(
				bz,
				bl,
				Vector3(s * 1.5, s * _rng.randf_range(0.55, 0.85), s * 1.2),
				(scarp["rock_lo"] as Color).lerp(scarp["soil"], _rng.randf() * 0.3),
				_rng.randf_range(-0.3, 0.0),
				false
			)


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
	_build_headland_face()
	# Even on a spur whose face drowned entirely, terrain and ledges still
	# wear the fill layer — the light has to exist whether the skin emitted or
	# not, and `_headland_fill` is itself a no-op off the owning chunk.
	_headland_fill()
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
	_build_headland_face()


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
	##
	## All ten specs, not the first four. The stand was cut to four on the
	## reasoning that one side of a ninety-four-degree frame is plenty, and it is:
	## the problem was never the angle spread but the *count*. Four trees at
	## thirty-three to forty-three degrees leave the outer fifth of the picture
	## bare, and a frame is a pair of verticals with something between them, not
	## one vertical and a lot of sky. Ten at a spread of thirty-three to
	## forty-seven degrees puts mass in both outer thirds and leaves the middle
	## third of the axis clear, which is the composition: edges and a gate.
	##
	## Heights are graded outward, larger away from the axis, because that is the
	## only arrangement in which the near elements read as near. A stand of equal
	## heights at increasing angle is a hedge.
	var layout := _view_frame_layout()
	var ranked: Array = layout[4]
	_build_view_frame_specs(layout, ranked, 0, ranked.size())
	_build_view_frame_talus(layout)


func _build_view_frame_incremental() -> void:
	## Same stand in the same order, a few specs per slice — every tree goes
	## through the corridor clearance sweep, so all ten in one frame was a ~50 ms
	## lump while the rider was still climbing to the seat.
	var layout := _view_frame_layout()
	var ranked: Array = layout[4]
	var first := 0
	while first < ranked.size():
		_build_view_frame_specs(layout, ranked, first, 3)
		first += 3
		if _slice_spent() and not await _keep_streaming():
			return
	_build_view_frame_talus(layout)


func _view_frame_layout() -> Array:
	var z0 := _vp_centre - 120.0
	var view_span := 240.0
	var hand: float = (
		1.0
		if posmod(hash(Vector2i(int(round(_vp_centre)), int(_path.world_seed) ^ 0x5f3a)), 2) == 0
		else -1.0
	)
	# Where the eye actually is, so the angles below mean what they say.
	var eye_out: float = float(_path.spur_offset(_vp_centre)) + RoadPathGD.PLATFORM_BENCH_OUT
	var ranked := FRAME_CLUMP.duplicate()
	ranked.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	return [z0, view_span, hand, eye_out, ranked]


func _build_view_frame_specs(layout: Array, ranked: Array, first: int, count: int) -> void:
	var z0: float = layout[0]
	var view_span: float = layout[1]
	var hand: float = layout[2]
	var eye_out: float = layout[3]
	for i in range(first, mini(first + count, ranked.size())):
		var spec: Array = ranked[i]
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
		if (
			_height_above_water(z, absf(lateral)) < 3.0
			or not _face_above_water(z, absf(lateral), 1.5)
			or not _face_dressing_ok(z)
		):
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
			# Keep the light blob inside the crown's footprint: the old offsets
			# walked it a tree-width off the trunk, and on the face reads — where
			# the camera is low and the crown is thin — it hung in the air as a
			# pale boulder over the apron.
			_blob(
				z + hand * _rng.randf_range(0.4, 1.8),
				lateral + _vp_side * _rng.randf_range(0.5, 1.8),
				Vector3(height * 0.26, height * 0.15, height * 0.24),
				tint.lightened(0.32),
				height * 0.80 + _face_ground_lift(z, absf(lateral)),
				true,
				true
			)


func _build_view_frame_talus(layout: Array) -> void:
	var z0: float = layout[0]
	var view_span: float = layout[1]
	var hand: float = layout[2]
	var eye_out: float = layout[3]
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
	## that pours the biome: Art of Rally / Firewatch country, Mononoke gorge,
	## Glen Coe tarn. Kenney rocks are the only imported mass.
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
	_dress_nose_tip()
	match _vp_theme:
		Env.FOREST:
			_dress_vista_forest()
		Env.MOUNTAIN:
			_dress_vista_mountain()
		_:
			_dress_vista_country()


func _dress_vista_incremental() -> void:
	## Same passes in the same order, one stage per slice — the five loops in a
	## row were a ~40 ms frame at the end of the basin build.
	await _build_far_bank_bands(true)
	if not await _keep_streaming():
		return
	await _build_far_bank_ground(true)
	if not await _keep_streaming():
		return
	await _build_vista_accent(true)
	if not await _keep_streaming():
		return
	await _dress_nose_tip_incremental()
	if not await _keep_streaming():
		return
	match _vp_theme:
		Env.FOREST:
			await _dress_vista_forest(true)
		Env.MOUNTAIN:
			await _dress_vista_mountain(true)
		_:
			await _dress_vista_country(true)


func _dress_nose_tip_incremental() -> void:
	## Same pieces in the same order as `_dress_nose_tip`; each candidate runs
	## the water and deck checks, so both sides at once was a mid-ride lump.
	for side: float in [-1.0, 1.0]:
		for _i in 10:
			var z: float = _vp_centre + side * _rng.randf_range(
				RoadPathGD.LAKE_SPAN * 0.7, RoadPathGD.LAKE_SPAN * 1.45
			)
			var out: float = float(_path.headland_crest(z)) - _rng.randf_range(-6.0, 30.0)
			if (
				_height_above_water(z, out) < 2.5
				or not _face_above_water(z, out, 0.8)
				or not _face_dressing_ok(z)
			):
				continue
			if float(_path.spur_deck_blend(z, _vp_side * out)) > 0.1:
				continue
			if _rng.randf() < 0.35:
				_tree(
					Flora.BROADLEAF if _vp_theme == Env.COUNTRY else Flora.CONIFER,
					z,
					_vp_side * out,
					_rng.randf_range(6.0, 13.0),
					Color("2c4036").lightened(_rng.randf() * 0.12),
					true,
					_face_ground_lift(z, out)
				)
			else:
				_vista_rock(
					z, _vp_side * out, _rng.randf_range(2.0, 6.5), _rng.randf_range(-0.4, 0.4) + _face_ground_lift(z, out)
				)
			if _slice_spent() and not await _keep_streaming():
				return
		if not await _keep_streaming():
			return


func _dress_nose_tip() -> void:
	## A real point is never bare: wind-battered pines and boulders cling to the
	## spine and scree spills to the water. Bare of all of them the tail is the
	## scarp's two flanks meeting in a smooth pale tent — the last smooth cone
	## in the vista. A few pieces on the diving back break the silhouette no
	## relief pass can; the water guards drop everything where the nose drowns.
	for side: float in [-1.0, 1.0]:
		for _i in 10:
			var z: float = _vp_centre + side * _rng.randf_range(
				RoadPathGD.LAKE_SPAN * 0.7, RoadPathGD.LAKE_SPAN * 1.45
			)
			var out: float = float(_path.headland_crest(z)) - _rng.randf_range(-6.0, 30.0)
			if (
				_height_above_water(z, out) < 2.5
				or not _face_above_water(z, out, 0.8)
				or not _face_dressing_ok(z)
			):
				continue
			if float(_path.spur_deck_blend(z, _vp_side * out)) > 0.1:
				continue
			if _rng.randf() < 0.35:
				_tree(
					Flora.BROADLEAF if _vp_theme == Env.COUNTRY else Flora.CONIFER,
					z,
					_vp_side * out,
					_rng.randf_range(6.0, 13.0),
					Color("2c4036").lightened(_rng.randf() * 0.12),
					true,
					_face_ground_lift(z, out)
				)
			else:
				_vista_rock(
					z, _vp_side * out, _rng.randf_range(2.0, 6.5), _rng.randf_range(-0.4, 0.4) + _face_ground_lift(z, out)
				)


func _dress_vista_forest(streamed: bool = false) -> void:
	## Yakushima / Ghost of Tsushima shrine forest: the gorge is a dark slot,
	## water a long way down, cedar walls you cannot see the top of until you
	## sit. The reveal is depth, not a postcard lake.
	var z0 := _vp_centre - LENGTH * 0.5
	for _i in 22:
		if streamed and _slice_spent() and not await _keep_streaming():
			return
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
		if streamed and _slice_spent() and not await _keep_streaming():
			return
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var out: float = float(_path.headland_crest(z)) + 8.0 + _rng.randf_range(0.0, 40.0)
		if (
			_height_above_water(z, out) < 10.0
			or not _face_above_water(z, out, 2.0)
			or not _face_dressing_ok(z)
		):
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
		if streamed and _slice_spent() and not await _keep_streaming():
			return
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var out: float = float(_path.viewpoint_near_shore(z)) + _rng.randf_range(-6.0, 14.0)
		# Margin -0.5, not the old -1.5: a rock whose base sits a metre and a
		# half under the waterline floats brown in the shallows — the dark eggs
		# offshore in the day frames were these.
		if not _face_above_water(z, out, -0.5) or not _face_dressing_ok(z):
			continue
		_vista_rock(
			z, _vp_side * out, _rng.randf_range(2.4, 5.5),
			# Bed-biased: positive jitter is what left boulders hovering on the
			# s1 face overviews.
			_rng.randf_range(-0.6, 0.25) + _face_ground_lift(z, out)
		)
	# Mid-face scatter: the apron between the spur lane and the gorge lip was
	# bare face colour all the way down — the flat dark band the s1 climb shots
	# read as an unlit void. Sparse scrub and stones on the drawn chord give
	# the slope scale without crowding the skyline or the sightline.
	for _i in 18:
		if streamed and _slice_spent() and not await _keep_streaming():
			return
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		if not _face_dressing_ok(z):
			continue
		var prof := _face_profile(z)
		var out: float = _profile_out(prof, _rng.randf_range(0.1, 0.68))
		var lateral := _vp_side * out
		if (
			_on_tarmac(z, lateral, 3.0)
			or not _face_above_water(z, out, 1.5)
			or float(_path.spur_deck_blend(z, lateral)) > 0.1
		):
			continue
		var lift := _face_ground_lift(z, out)
		var roll := _rng.randf()
		if roll < 0.4:
			_tree(
				Flora.CONIFER,
				z,
				lateral,
				_rng.randf_range(4.5, 9.0),
				Color("1a3024").lerp(Color("2c4a38"), _rng.randf()),
				true,
				lift
			)
		elif roll < 0.78:
			var s: float = _rng.randf_range(1.2, 2.6)
			_blob(
				z,
				lateral,
				Vector3(s * 1.7, s * _rng.randf_range(0.7, 1.0), s * 1.4),
				Color("1c3628").lerp(Color("315e3e"), _rng.randf()).darkened(_rng.randf() * 0.15),
				lift,
				true
			)
		else:
			_vista_rock(z, lateral, _rng.randf_range(1.6, 3.6), _rng.randf_range(-0.5, 0.1) + lift)
	# A near cedar rank gives the forest overlook a readable frame instead of a
	# bare hillside. It is deliberately sparse: trunks, water and a clear gap.
	for _i in 10:
		if streamed and _slice_spent() and not await _keep_streaming():
			return
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


func _dress_vista_mountain(streamed: bool = false) -> void:
	## Glen Coe from the pass: a small tarn, scree to the water, peaks that
	## actually fill the sky. Talus, snags, a few dwarf pines on the folds —
	## not a forest, but not a quarry either.
	var z0 := _vp_centre - LENGTH * 0.5
	for _i in 16:
		if streamed and _slice_spent() and not await _keep_streaming():
			return
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var out: float = float(_path.headland_crest(z)) + 4.0 + _rng.randf_range(0.0, 80.0)
		if float(_path.spur_deck_blend(z, _vp_side * out)) > 0.12:
			continue
		if (
			_height_above_water(z, out) < 3.0
			or not _face_above_water(z, out, 1.2)
			or not _face_dressing_ok(z)
		):
			continue
		_vista_rock(
			z, _vp_side * out, _rng.randf_range(2.4, 8.5),
			_rng.randf_range(-0.6, 0.25) + _face_ground_lift(z, out)
		)
	for _i in 14:
		if streamed and _slice_spent() and not await _keep_streaming():
			return
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var out: float = float(_path.headland_crest(z)) + 8.0 + _rng.randf_range(0.0, 64.0)
		if (
			_height_above_water(z, out) < 4.0
			or not _face_above_water(z, out, 1.5)
			or not _face_dressing_ok(z)
		):
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
		if streamed and _slice_spent() and not await _keep_streaming():
			return
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var out: float = float(_path.headland_crest(z)) + 6.0 + _rng.randf_range(0.0, 40.0)
		if (
			_height_above_water(z, out) < 8.0
			or not _face_above_water(z, out, 2.5)
			or not _face_dressing_ok(z)
		):
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
		if streamed and _slice_spent() and not await _keep_streaming():
			return
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


func _dress_vista_country(streamed: bool = false) -> void:
	## Wastwater / Art of Rally Wales: dark water, a sun path, screes, a pass
	## between fells you look *through*. Heather on the near face, Kenney
	## boulders as talus, trees only on the side folds.
	var z0 := _vp_centre - LENGTH * 0.5
	for _i in 11:
		if streamed and _slice_spent() and not await _keep_streaming():
			return
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var out: float = float(_path.headland_crest(z)) + 5.0 + _rng.randf_range(0.0, 55.0)
		if float(_path.spur_deck_blend(z, _vp_side * out)) > 0.12:
			continue
		if (
			_height_above_water(z, out) < 3.0
			or not _face_above_water(z, out, 1.5)
			or not _face_dressing_ok(z)
		):
			continue
		_vista_rock(
			z, _vp_side * out, _rng.randf_range(2.2, 5.8),
			_rng.randf_range(-0.4, 0.5) + _face_ground_lift(z, out)
		)
	for _i in 18:
		if streamed and _slice_spent() and not await _keep_streaming():
			return
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var out: float = float(_path.headland_crest(z)) + 10.0 + _rng.randf_range(0.0, 48.0)
		if (
			_height_above_water(z, out) < 8.0
			or not _face_above_water(z, out, 2.0)
			or not _face_dressing_ok(z)
		):
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
		if streamed and _slice_spent() and not await _keep_streaming():
			return
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
	# The brow line, missing entirely: from the water the country headland used
	# to read as one smooth green plate while the forest's crest carried trees
	# and scree. A fell top is never bare — wind-bent hawthorns stand on the
	# rim, an intermittent dry-stone wall follows the lip, and limestone breaks
	# through the turf where the plateau ends. All of it sits on the plateau's
	# own band, behind the brow, so the silhouette gains teeth without any
	# prop standing on the face.
	var scarp := _face_scarp_palette()
	for _i in 16:
		if streamed and _slice_spent() and not await _keep_streaming():
			return
		var z: float = _vp_centre + _rng.randf_range(-RoadPathGD.LAKE_SPAN * 0.6, RoadPathGD.LAKE_SPAN * 0.6)
		if absf(z - _vp_centre) < 38.0:
			continue  # the seated sightline owns the open middle of the rim
		var out: float = float(_path.headland_crest(z)) - _rng.randf_range(6.0, 26.0)
		if (
			not _face_dressing_ok(z)
			or float(_path.spur_deck_blend(z, _vp_side * out)) > 0.1
			or _on_tarmac(z, _vp_side * out, 2.0)
		):
			continue
		# Ground to the plain surface — these stand on the plateau, not on the
		# face the chord-lift helper is built for.
		_tree(
			Flora.BROADLEAF,
			z,
			_vp_side * out,
			_rng.randf_range(5.0, 9.5),
			Color("2a4630").lerp(Color("43603a"), _rng.randf() * 0.6),
			true
		)
	for _i in 8:
		if streamed and _slice_spent() and not await _keep_streaming():
			return
		var wz: float = _vp_centre + _rng.randf_range(-RoadPathGD.LAKE_SPAN * 0.55, RoadPathGD.LAKE_SPAN * 0.55)
		if absf(wz - _vp_centre) < 30.0:
			continue
		var out: float = float(_path.headland_crest(wz)) - _rng.randf_range(4.0, 18.0)
		if (
			not _face_dressing_ok(wz)
			or float(_path.spur_deck_blend(wz, _vp_side * out)) > 0.1
		):
			continue
		var wstone: Color = (scarp["rock_lo"] as Color).lerp(scarp["soil"], 0.4).darkened(0.05)
		_terrain_beam(wz, wz + _rng.randf_range(7.0, 13.0), _vp_side * out, 0.42, 0.85, wstone, 0.44)
	for _i in 12:
		if streamed and _slice_spent() and not await _keep_streaming():
			return
		var z: float = _vp_centre + _rng.randf_range(-RoadPathGD.LAKE_SPAN * 0.55, RoadPathGD.LAKE_SPAN * 0.55)
		if absf(z - _vp_centre) < 30.0:
			continue
		var out: float = float(_path.headland_crest(z)) - _rng.randf_range(2.0, 14.0)
		if (
			not _face_above_water(z, out, 2.0)
			or not _face_dressing_ok(z)
			or float(_path.spur_deck_blend(z, _vp_side * out)) > 0.1
		):
			continue
		_vista_rock(
			z, _vp_side * out, _rng.randf_range(1.6, 3.8),
			_rng.randf_range(-0.5, 0.1)
		)


func _chunk_covers(z: float) -> bool:
	var z0 := float(chunk_index) * LENGTH
	return z >= z0 and z < z0 + LENGTH


func _build_headland_face() -> void:
	## The drop under the rail: a faceted rock skin around the headland nose.
	##
	## Without it the face is one smooth ribbon painted a single pale tone, and
	## under the dusk key that is a gradient slab — a dune, not a cliff. What
	## the eye wants off a real drop is beds: lit shelf tops against shadowed
	## seams, a grass lip on the brow and talus at the foot. A skin of quads
	## stood a little proud of the rendered chord, stepped per stratum, gives
	## all of that for a few hundred triangles.
	##
	## It runs the length of the nose now, not just the patch under the seat.
	## The skin used to stop dead ±110 m out while the face itself ran on for
	## half a kilometre — a rock cliff that changed into a green curtain at a
	## vertical line, which is the cut edge the left-looking rider sees. Where
	## the nose finally dives under the water the face profile shortens to
	## nothing and `_add_face_scarp` stops emitting on its own, so the skin
	## ends where the land does.
	var z0 := _vp_centre - RoadPathGD.LAKE_SPAN - 200.0
	var z_span: float = RoadPathGD.LAKE_SPAN * 2.0 + 400.0
	var b := LowPoly.new()
	var pal := _face_scarp_palette()
	var built := false
	var t := z0
	while t < z0 + z_span - 0.4:
		var t1: float = minf(t + 10.0, z0 + z_span)
		if _add_face_scarp(b, t, t1, pal):
			built = true
		t = t1
	if not built:
		return
	var mesh: MeshInstance3D = b.commit_to(self, "ViewpointHeadland")
	if mesh:
		mesh.material_override = LowPoly.terrain_material()
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mesh.visibility_range_end = 0.0
		mesh.layers = HEADLAND_FILL_LAYER
		_headland_fill()


func _build_headland_face_incremental() -> void:
	var z0 := _vp_centre - RoadPathGD.LAKE_SPAN - 200.0
	var z_span: float = RoadPathGD.LAKE_SPAN * 2.0 + 400.0
	var b := LowPoly.new()
	var pal := _face_scarp_palette()
	var built := false
	var t := z0
	while t < z0 + z_span - 0.4:
		var t1: float = minf(t + 10.0, z0 + z_span)
		if _add_face_scarp(b, t, t1, pal):
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
		mesh.layers = HEADLAND_FILL_LAYER
		_headland_fill()


func _headland_fill() -> void:
	## The face's own skylight: a weak cool directional restricted to layer 20.
	## Everything the shade side needs — beds, seams, talus tone — is already
	## painted into the vertices; the day ambient is simply too weak to show
	## it, which is what collapsed the whole face into one black slab. The fill
	## arrives the way skylight actually lands on a cliff: mostly level, from
	## over the water, so the steep face catches the bulk of it and the flat
	## pasture beside the platform only gets the little it would.
	##
	## One light per overlook: only the platform-owning chunk adds it, and its
	## cull mask then reaches every lake chunk's skin, terrain and ledges in
	## view — a light per lake chunk would stack on the shared face.
	if not _owns_platform or get_node_or_null("HeadlandFill") != null:
		return
	var fill := DirectionalLight3D.new()
	fill.name = "HeadlandFill"
	fill.shadow_enabled = false
	fill.light_cull_mask = HEADLAND_FILL_LAYER
	fill.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	fill.light_color = Color("8fa8bd")
	fill.light_energy = 1.0
	var dir := (
		_vista_basis.x * -_vp_side * 0.9 + _vista_basis.z * 0.14 + Vector3(0.0, -0.3, 0.0)
	).normalized()
	fill.basis = Basis.looking_at(dir)
	add_child(fill)


func _face_scarp_palette() -> Dictionary:
	## lip — turf that overhangs the brow; soil — the weathered band under it;
	## rock_hi/rock_lo — the two ends the beds swing between; seam — the shadowed
	## underside of a bed; scree — the talus apron at the foot. Country is chalk
	## and limestone with a grass lip, mountain and forest are greyer crag.
	# Every value here fights the same battle: the face is the one slope in the
	# world turned squarely into the key, and sun at ~1.4 warm saturates any
	# albedo past about a third straight to cream. Values that would read as
	# mid stone on flat ground have to live at a quarter of that on this face
	# for the beds to land as mossed rock and not as a sunlit curtain.
	match _vp_theme:
		Env.MOUNTAIN:
			return {
				"lip": Color("3e4a30"), "soil": Color("38352e"),
				"rock_hi": Color("566062"), "rock_lo": Color("3a4248"),
				"seam": Color("2c3238"), "scree": Color("484840"),
			}
		Env.FOREST:
			# The old warm set was the seed-1 cream dune: 96938a sky-fill over the
			# whole skin rendered as smooth sand under the day key. Mossed like
			# the country set but a step deeper — shaded stone under a cedar
			# canopy, with a wet moss toe at the waterline.
			return {
				"lip": Color("242e1e"), "soil": Color("2d332b"),
				"rock_hi": Color("3d4c38"), "rock_lo": Color("29362a"),
				"seam": Color("20281f"), "scree": Color("354035"),
			}
	# Greyed from the old warm chalk set: under the day key the soil band and
	# the shaded beds rendered as solid ochre, ringing the lake in what read
	# as orange sand. The greys still land as warm earth — the grade does the
	# warming — but at half the saturation. Deepened again for the face that
	# stands square to the key: chalk survives as the lit caps, not the base.
	return {
		"lip": Color("485232"), "soil": Color("3c403a"),
		"rock_hi": Color("55604a"), "rock_lo": Color("3a413a"),
		"seam": Color("2c322b"), "scree": Color("4c5348"),
	}


const SCARP_ROWS := 12
const SCARP_STEP := 2.0


var _face_prof_cache: Dictionary = {}


func _face_profile(z: float) -> Dictionary:
	## Chord samples down the headland face, from just over the brow to a
	## couple of metres under the waterline, with cumulative arc length. The
	## skin's rows are spaced along this curve, not in lateral distance — on a
	## near-vertical drop lateral spacing puts nine rows of ten on the drowned
	## foot and leaves the whole cliff to a single quad, which is exactly the
	## smooth slab this replaces.
	##
	## Cached per metre of z: the skin walks the nose in strips that share an
	## edge, so every profile below used to be computed twice, and the turf
	## dressing asks for the same brow line again.
	var key := snappedf(z, 1.0)
	var cached: Variant = _face_prof_cache.get(key)
	if cached != null:
		return cached
	var crest := float(_path.headland_crest(z))
	var limit: float = minf(float(_path.viewpoint_near_shore(z)) + 30.0, VIEW_REFINE_OUTER - 4.0)
	var top_y := _face_chord_point(z, crest - 5.0).y
	var brow := crest - 5.0
	while brow < limit and _face_chord_point(z, brow).y >= top_y - 0.9:
		brow += SCARP_STEP
	# Start a couple of metres inboard of the fall line: the first row is the
	# turf lip curling over the edge, and it laps under the terrace slab edge
	# rather than leaving a hairline of sky between deck and face.
	brow = maxf(brow - SCARP_STEP * 1.5, crest - 6.0)
	var pts := PackedVector3Array()
	var outs := PackedFloat32Array()
	var acc := PackedFloat32Array()
	var out := brow
	while out <= limit:
		var p := _face_chord_point(z, out)
		outs.append(out)
		acc.append(0.0 if pts.is_empty() else acc[acc.size() - 1] + p.distance_to(pts[pts.size() - 1]))
		pts.append(p)
		if p.y + _origin.y < _vp_water_y - 1.5:
			break
		out += SCARP_STEP
	if pts.size() < 4 or acc[acc.size() - 1] < 8.0:
		_face_prof_cache[key] = {}
		return {}
	var prof := {"pts": pts, "outs": outs, "acc": acc, "total": acc[acc.size() - 1], "brow": brow}
	_face_prof_cache[key] = prof
	return prof


func _face_live_arc(prof: Dictionary) -> float:
	## How far down the profile the ground is still genuinely falling.
	##
	## A face is worth its skin and its ledges only while it drops. Out on the
	## drowned tail the brow can stand a couple of metres proud while the chord
	## under it runs nearly flat for tens of metres, and the skin laid over
	## that plain is the floating slate sheet the waterline shots kept finding.
	## "Still falling" is a *local* test — a shallow apron that loses ten
	## metres over a hundred and fifty still has metres of fall below almost
	## everywhere on it, so measuring what is left to drop ends the arc at the
	## waterline and keeps the sheet. The live end is the last step that falls
	## like a face; everything after it is apron, whatever the brow said.
	var pts: PackedVector3Array = prof["pts"]
	var acc: PackedFloat32Array = prof["acc"]
	for k in range(pts.size() - 1, 0, -1):
		var seg: float = maxf(acc[k] - acc[k - 1], 0.01)
		if (pts[k - 1].y - pts[k].y) / seg >= 0.28:
			return acc[k]
	return 0.0


func _face_is_face(prof: Dictionary) -> bool:
	## The strip test for face dressing: several metres of live fall, or what
	## the profile describes is marsh apron with a proud brow, not a cliff.
	return _face_live_arc(prof) >= 5.0


func _face_dressing_ok(z: float) -> bool:
	## Whether face dressing — ledges, scree, talus, the framing stand — is
	## wanted at this z. Past the fall line the ribbon chord bridges metres
	## over drowned apron and everything lifted onto it stands on air.
	var prof := _face_profile(z)
	return not prof.is_empty() and _face_is_face(prof)


func _profile_arc(prof: Dictionary, f: float) -> int:
	## Index of the profile segment holding arc fraction f.
	var acc: PackedFloat32Array = prof["acc"]
	var target: float = f * float(prof["total"])
	var k := 1
	while k < acc.size() - 1 and acc[k] < target:
		k += 1
	return k


func _profile_out(prof: Dictionary, f: float) -> float:
	## The lateral offset f of the way down the face — for ledges and other
	## dressing that wants a fraction of the drop rather than of the run-out.
	var acc: PackedFloat32Array = prof["acc"]
	var outs: PackedFloat32Array = prof["outs"]
	var k := _profile_arc(prof, f)
	var seg: float = maxf(acc[k] - acc[k - 1], 0.01)
	return lerpf(outs[k - 1], outs[k], clampf((f * float(prof["total"]) - acc[k - 1]) / seg, 0.0, 1.0))


func _face_slope_at(prof: Dictionary, f: float) -> float:
	## Local chord slope at arc fraction f — drop per metre of arc. This is the
	## test that actually separates face from apron: the drowned tail can carry
	## a hundred and fifty metres of chord that still technically *falls*, just
	## a hand's breadth over the water, and both the live arc and the waterline
	## guards wave it through. A slope under ~0.2 is a shoal, not a scarp.
	var pts: PackedVector3Array = prof["pts"]
	var acc: PackedFloat32Array = prof["acc"]
	var k := _profile_arc(prof, clampf(f, 0.0, 1.0))
	var seg: float = maxf(acc[k] - acc[k - 1], 0.01)
	return (pts[k - 1].y - pts[k].y) / seg


func _scarp_relief(z: float, i: int, f: float) -> float:
	## How far the skin stands off the ribbon chord at this vertex. Stepped per
	## bed — two rows share a stratum, the next stratum juts or sinks — which is
	## what draws ledges; a smooth offset is just the dune again. Hashed off
	## (z, row) so both sides of a strip seam agree.
	var edge := smoothstep(0.0, 0.12, f) * (1.0 - smoothstep(0.86, 1.0, f))
	var s := i >> 1
	var bed := float(posmod(hash(Vector2i(s * 37 + 11, int(round(z * 0.5)))), 997)) / 997.0
	var under := -0.45 * float(i & 1)
	var jit := 0.18 * sin(z * 1.13 + float(i) * 1.97)
	# Craggier on the nose tail: out there the skin is the silhouette, and a
	# metre of stratum is invisible — a rocky point wants blocks, not beds.
	var crag := 1.0 + 1.7 * smoothstep(0.62, 1.3, absf(z - _vp_centre) / RoadPathGD.LAKE_SPAN)
	return (0.22 + edge * (bed * 1.35 + under + jit)) * crag


func _scarp_point(prof: Dictionary, z: float, i: int) -> Vector4:
	## One skin vertex: the chord point i/ROWS of the way down the face profile,
	## pushed out along the local face normal by the stratum step. The w
	## component is the chord's own world height — the quad pass needs to know
	## where the *ground* sits, not where the skin stands off it.
	var f := float(i) / float(SCARP_ROWS)
	var pts: PackedVector3Array = prof["pts"]
	var acc: PackedFloat32Array = prof["acc"]
	var k := _profile_arc(prof, f)
	var seg: float = maxf(acc[k] - acc[k - 1], 0.01)
	var t: float = clampf((f * float(prof["total"]) - acc[k - 1]) / seg, 0.0, 1.0)
	var p: Vector3 = pts[k - 1].lerp(pts[k], t)
	var dir: Vector3 = pts[k] - pts[k - 1]
	var flat: Basis = _path.frame_flat_at(z)
	var n := dir.cross(flat.z)
	if n.length_squared() < 1e-8:
		n = flat.x * _vp_side
	else:
		n = n.normalized()
	if n.dot(flat.x * _vp_side) < 0.0:
		n = -n
	# The stand-off only means something where the chord is actually falling.
	# On a drowned flat the profile normal points at the sky and the same
	# metre of relief lifts the skin off the ground as a floating wafer — the
	# slate sheets on the lake. Scaled by the local slope it fades out on the
	# flats and the skin beds into the apron instead of hovering over it.
	var slope := (pts[k - 1].y - pts[k].y) / seg
	# A small floor keeps the skin off the ribbon it is welded to — a quad
	# drawn in the exact chord plane z-fights it — while still reading flat.
	var relief := maxf(_scarp_relief(z, i, f) * smoothstep(0.30, 0.62, slope), 0.08)
	var q := p + n * relief
	return Vector4(q.x, q.y, q.z, p.y + _origin.y)


func _scarp_color(pal: Dictionary, z: float, i: int, f: float) -> Color:
	## Grass lip, soil seam, then bedded rock shading to the talus apron. The
	## bed a row belongs to picks its tone and its lower row darkens into the
	## seam under it — the same row boundaries `_scarp_relief` steps at, so a
	## bed's colour and its jut always agree. Everything hashed off (z, row) so
	## a quad edge shared by two strips is coloured once.
	var s := i >> 1
	var tone := float(posmod(hash(Vector2i(s * 53 + 5, int(floorf(z * 0.04)))), 991)) / 991.0
	var rock: Color = (pal["rock_hi"] as Color).lerp(pal["rock_lo"], 0.08 + 0.8 * tone)
	# The shaded underside of a bed is cooler than the lit cap — it is lit by
	# the sky, not the sun. Same-hue darkening alone compresses to nothing under
	# the warm key, which is why the beds used to read as one gold slope.
	var seam_cool: Color = (pal["seam"] as Color).lerp(Color("3c4148"), 0.4)
	# Under the warm key the far side of the nose gets only sky and fill, and
	# at the old strength the seam rows multiplied down to the same black as
	# the beds between them — one flat plane. Half keeps the bedding without
	# giving back the slab.
	rock = rock.lerp(seam_cool, 0.45 * float(i & 1))
	var col: Color = (pal["lip"] as Color).lerp(pal["soil"], smoothstep(0.0, 0.06, f)).lerp(
		rock, smoothstep(0.04, 0.16, f)
	)
	col = col.lerp(pal["scree"], smoothstep(0.8, 1.0, f))
	var jit := float(posmod(hash(Vector2i(i * 91 + 13, int(round(z * 0.4)))), 997)) / 997.0
	return col.darkened(jit * 0.17).lightened(0.05 * float(1 - (i & 1)))


func _add_face_scarp(b: LowPoly, za: float, zb: float, pal: Dictionary) -> bool:
	## Wherever the nose still stands: the face profile goes empty where the
	## headland has dived under the water, and that — not a fixed distance —
	## is what ends the skin. Past the end of the basin nothing is emitted at
	## all, so the loop bound in the callers only has to be generous.
	if absf((za + zb) * 0.5 - _vp_centre) > RoadPathGD.LAKE_SPAN + 140.0:
		return false
	var prof_a := _face_profile(za)
	var prof_b := _face_profile(zb)
	if prof_a.is_empty() or prof_b.is_empty():
		return false
	# The skin stands a fraction of a metre proud of the chord it is wrapped
	# around — that is what makes the beds read. Off the drowned tail the chord
	# itself is at the waterline, so the same stand-off breaches the surface:
	# a trail of thin wafers and turf blobs floating in open water, the sliver
	# line the spur overview drew trailing the point. A drowned face needs no
	# rock skin — where the brow is already at the water, emit nothing.
	var brow_a: float = prof_a["brow"]
	var brow_b: float = prof_b["brow"]
	var brow_a_y: float = (prof_a["pts"] as PackedVector3Array)[0].y + _origin.y
	var brow_b_y: float = (prof_b["pts"] as PackedVector3Array)[0].y + _origin.y
	# Both ends, not the higher one: a strip whose far end is barely proud still
	# draws a wafer at the waterline, which is exactly the sliver being removed.
	if minf(brow_a_y, brow_b_y) < _vp_water_y + 1.5:
		return false
	# And it still has to *be* a face. Out on the drowned tail the brow stands
	# proud while the chord under it runs nearly flat for tens of metres — the
	# skin then lies on a plain a hand's breadth over the water, which is the
	# floating slate sheet the waterline shots kept finding. The live arc is
	# how far each end still falls; a strip emits only while one end does.
	var live_a := _face_live_arc(prof_a)
	var live_b := _face_live_arc(prof_b)
	if maxf(live_a, live_b) < 5.0:
		return false
	var rowa: Array[Vector4] = []
	var rowb: Array[Vector4] = []
	var cols_a: Array[Color] = []
	var cols_b: Array[Color] = []
	var slope_a := PackedFloat32Array()
	var slope_b := PackedFloat32Array()
	for i in range(SCARP_ROWS + 1):
		var f := float(i) / float(SCARP_ROWS)
		rowa.append(_scarp_point(prof_a, za, i))
		rowb.append(_scarp_point(prof_b, zb, i))
		cols_a.append(_scarp_color(pal, za, i, f))
		cols_b.append(_scarp_color(pal, zb, i, f))
		slope_a.append(_face_slope_at(prof_a, f))
		slope_b.append(_face_slope_at(prof_b, f))
	# Sky fill, measured off each quad's real tilt rather than painted flat: a
	# bed top that faces up at the sky is lit by it, so it carries a paler,
	# cooler value than the riser under it. Without it every vertex on the
	# shaded side shares one small albedo and the whole face reads as the black
	# slab the overviews kept flagging.
	var sky_fill := (pal["rock_hi"] as Color).lerp(Color("8d9aa6"), 0.55)
	var out_x: Vector3 = _path.frame_flat_at(za).x * _vp_side
	for i in range(SCARP_ROWS):
		var va := Vector3(rowa[i].x, rowa[i].y, rowa[i].z)
		var vb := Vector3(rowb[i].x, rowb[i].y, rowb[i].z)
		var va1 := Vector3(rowa[i + 1].x, rowa[i + 1].y, rowa[i + 1].z)
		var vb1 := Vector3(rowb[i + 1].x, rowb[i + 1].y, rowb[i + 1].z)
		var qn := (va1 - va).cross(vb - va)
		if qn.length_squared() < 1e-8:
			continue
		if qn.dot(out_x) < 0.0:
			qn = -qn
		var up := qn.normalized().y
		var chord_hi := maxf(maxf(rowa[i].w, rowa[i + 1].w), maxf(rowb[i].w, rowb[i + 1].w))
		var chord_lo := minf(minf(rowa[i].w, rowa[i + 1].w), minf(rowb[i].w, rowb[i + 1].w))
		# Past the live arc on both sides the strip has stopped falling — the
		# quad would be skin over apron, and apron is marsh's job.
		var f_arc := float(i) / float(SCARP_ROWS)
		if f_arc * float(prof_a["total"]) >= live_a and f_arc * float(prof_b["total"]) >= live_b:
			continue
		# Four flat corners is a shoal, whatever the brow did upstream: out on
		# the drowned tails the chord still *falls*, just a quarter metre to the
		# metre, and the skin lying on it reads as a pale sheet standing off the
		# lake — the slate raft the across shot kept catching. The same 0.30 the
		# relief ramp starts at: below it the skin adds a pale film and no beds,
		# so the bare ribbon — which is marsh's job — can simply take over.
		if maxf(maxf(slope_a[i], slope_a[i + 1]), maxf(slope_b[i], slope_b[i + 1])) < 0.30:
			continue
		# The direct version of every waterline guard above: ask the ground
		# under the quad's middle whether it is still land. On the face the
		# chord is a carving of the headland itself, metres over the analytic
		# surface and both high and dry; on the drowned tails the same chord
		# bridges the marsh the lake swallowed, and the skin over it hangs in
		# the air as the slate sheet. A quad over drowned ground does not emit.
		var f_mid := (float(i) + 0.5) / float(SCARP_ROWS)
		var out_mid := (
			_profile_out(prof_a, f_mid) + _profile_out(prof_b, f_mid)
		) * 0.5
		var ground_y: float = _terrain_surface_at(
			(za + zb) * 0.5, _vp_side * out_mid
		).y
		# Flat only: a steep quad over drowned ground is a cliff toe running
		# into the lake and is wanted; a *level* one standing proud of marsh or
		# shoal is a plate. The far bank floor runs a couple of metres proud of
		# the waterline, so the ground test has to reach that far above it.
		if up > 0.35 and ground_y < _vp_water_y + 3.0 and chord_lo > ground_y + 0.8:
			continue
		# Rows lying on drowned ground need no skin — the opaque water hides
		# them anyway. And a row whose *low* corner reaches the waterline while
		# lying anywhere near flat is apron — the skin stands its relief off a
		# chord the lake has already swallowed, which is the slate sheet the
		# waterline shots kept finding. The test runs off the low corner, not
		# the high one: a quad draped from a live brow down onto drowned ground
		# still earns a pale plate. A steep row that ends low is a cliff toe
		# running under the water and keeps its quad.
		if chord_hi < _vp_water_y + 0.2 or (up > 0.35 and chord_lo < _vp_water_y + 1.2):
			continue
		var fill := clampf(up, 0.0, 1.0) * 0.38
		# Sky fill is a bed-top effect: a shelf catches the sky because the
		# cliff under it throws it into clear air. On the drowned apron the
		# same flat quad catches nothing — it is the pale cap on a dark bank,
		# the slate plate in every across frame. The fill therefore needs a
		# face under it as well as height over the water: off the live slope
		# and within the last metres of the drop it fades away entirely.
		var steepest := maxf(maxf(slope_a[i], slope_a[i + 1]), maxf(slope_b[i], slope_b[i + 1]))
		# The apron's shade is baked, not lit: HeadlandFill exists only once the
		# platform chunk streams, and on the low rows the sky term was the whole
		# reason the foot washed to a pale cap whenever the light was — or was
		# not — there. Nothing within fourteen metres of the waterline keeps
		# any of it; the toe carries its own dark value instead.
		fill *= smoothstep(0.30, 0.55, steepest) * smoothstep(
			_vp_water_y + 4.0, _vp_water_y + 14.0, chord_lo
		)
		# And wet the toe: a flat quad lying on the low bank carries the same
		# dark value the marsh under it does, or the sheet reads as a pale
		# plate floating on shadowed water. The flatter the row the wetter it
		# reads, but even the rising beds just above the waterline keep a share
		# of it — the foot of a lake cliff is wet rock whatever its slope.
		var wet := (
			(1.0 - smoothstep(_vp_water_y + 1.0, _vp_water_y + 10.0, chord_lo))
			* lerpf(0.45, 0.8, smoothstep(0.3, 0.75, up))
		)
		var wet_tone := (pal["seam"] as Color).lerp(Color("232a2c"), 0.6)
		var ca0 := cols_a[i].lerp(sky_fill, fill).lerp(wet_tone, wet)
		var ca1 := cols_a[i + 1].lerp(sky_fill, fill).lerp(wet_tone, wet)
		var cb0 := cols_b[i].lerp(sky_fill, fill).lerp(wet_tone, wet)
		var cb1 := cols_b[i + 1].lerp(sky_fill, fill).lerp(wet_tone, wet)
		if _vp_side > 0.0:
			b.add_quad_shaded(va, va1, vb1, vb, ca0, ca1, cb1, cb0)
		else:
			b.add_quad_shaded(va1, va, vb, vb1, ca1, ca0, cb0, cb1)
	# Turf tufts overhanging the brow, hashed into place — the grass lip is
	# what sells the top of a cliff, and a bare edge reads as a cut cake.
	for k in 4:
		var t := (float(k) + 0.5) / 4.0
		var kz: float = za + t * (zb - za)
		var kout: float = (
			lerpf(brow_a, brow_b, t)
			+ 0.5
			+ float(posmod(hash(Vector2i(k * 17 + 3, int(round(kz * 0.7)))), 100)) / 90.0
		)
		if float(_path.spur_deck_blend(kz, _vp_side * kout)) > 0.1:
			continue
		_blob(
			kz,
			_vp_side * kout,
			Vector3(0.95, 0.42, 0.9),
			(pal["lip"] as Color).lightened(0.05),
			_face_ground_lift(kz, kout),
			true,
			true
		)
	return true


func _build_vista_landmarks() -> void:
	## One authored silhouette in the view, not a building: cairn, dry-stone
	## wall. Planted on the chunk that owns a fixed z offset so
	## each overlook gets exactly one.
	match _vp_theme:
		Env.MOUNTAIN:
			_vista_cairn()
		Env.COUNTRY:
			_vista_shore_wall()
	# The composed landmarks emit once, on the owner — one islet, one crag
	# and one stair per overlook, not one per lake chunk.
	if _owns_platform:
		_build_islet()
		_build_bastion()
		_build_face_path()


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


func _facet_tone(base: Color, amount: float) -> Color:
	## Per-face brightness for hand-built facets: a little lighter on the lit
	## side, darker opposite, so a flat-coloured prism still models like rock.
	return base.lightened(amount) if amount >= 0.0 else base.darkened(-amount)


func _build_islet() -> void:
	## The Bled anchor — a small islet standing in open water, carrying a tiny
	## pale beacon and a dark copse. A panorama gives the eye nowhere to land;
	## an island in the middle of the lake is the thing a rider came an hour
	## to see. One per overlook, off the view axis so it composes against the
	## shore rather than parking dead centre in the shot.
	var hand := 1.0 if posmod(
		hash(Vector2i(int(round(_vp_centre)), int(_path.world_seed) ^ 0x51ed)), 2
	) == 0 else -1.0
	var z: float = _vp_centre + hand * 55.0
	var near: float = float(_path.viewpoint_near_shore(z))
	var far: float = float(_path.viewpoint_far_shore(z, _vp_centre))
	if far - near < 110.0:
		return
	# The deck stands eighty-odd metres over the water, so anything parked in
	# the middle of the lake vanishes under the rail — the island has to sit
	# well out and stand tall to earn its place in the frame, the way Bled's
	# island reads from the castle terrace and not from the shore.
	var out: float = far - 60.0
	if out - near < 80.0:
		return
	var lat: float = _vp_side * out
	var wy: float = _vp_water_y - _origin.y
	var rock := Color("414a3e")
	var rock_wet := Color("2b332c")
	var moss := Color("3a4c2e")
	var plaster := Color("ddd3bd")
	var slate := Color("37332f")
	var leaf := Color("24402d")
	var b := LowPoly.new()
	const SIDES := 9
	var rings := [
		{"y": wy - 0.9, "r": 30.0, "c": rock_wet},
		{"y": wy + 2.6, "r": 21.0, "c": rock},
		{"y": wy + 5.2, "r": 12.0, "c": moss.darkened(0.14)},
	]
	var apex := _far_point(z, lat, wy + 7.4)
	b.hull_origin = _far_point(z, lat, wy + 2.0)
	for i in SIDES:
		var a0: float = TAU * float(i) / SIDES + 0.17
		var a1: float = TAU * float(i + 1) / SIDES + 0.17
		var wob0 := 1.0 + 0.13 * sin(float(i) * 2.71 + _vp_phase)
		var wob1 := 1.0 + 0.13 * sin(float(i + 1) * 2.71 + _vp_phase)
		for k in rings.size() - 1:
			var r_lo: Dictionary = rings[k]
			var r_hi: Dictionary = rings[k + 1]
			var shade := 0.14 * sin(float(i) * 1.7 + float(k) * 2.3)
			b.add_hull_quad(
				_far_point(
					z + sin(a0) * float(r_lo["r"]) * wob0,
					lat + cos(a0) * float(r_lo["r"]) * wob0,
					float(r_lo["y"])
				),
				_far_point(
					z + sin(a1) * float(r_lo["r"]) * wob1,
					lat + cos(a1) * float(r_lo["r"]) * wob1,
					float(r_lo["y"])
				),
				_far_point(
					z + sin(a1) * float(r_hi["r"]) * wob1,
					lat + cos(a1) * float(r_hi["r"]) * wob1,
					float(r_hi["y"])
				),
				_far_point(
					z + sin(a0) * float(r_hi["r"]) * wob0,
					lat + cos(a0) * float(r_hi["r"]) * wob0,
					float(r_hi["y"])
				),
				_facet_tone(r_hi["c"] as Color, shade)
			)
		var r_top: Dictionary = rings[rings.size() - 1]
		b.add_hull_tri(
			_far_point(
				z + sin(a0) * float(r_top["r"]) * wob0,
				lat + cos(a0) * float(r_top["r"]) * wob0,
				float(r_top["y"])
			),
			apex,
			_far_point(
				z + sin(a1) * float(r_top["r"]) * wob1,
				lat + cos(a1) * float(r_top["r"]) * wob1,
				float(r_top["y"])
			),
			_facet_tone(moss, 0.12 * sin(float(i) * 2.9))
		)
		# A lit hem on the water around the shore — the shallow lap a real
		# islet carries, drawn one ring out so it sits on the sheet, not in it.
		b.hull_origin = apex - Vector3(0.0, 30.0, 0.0)
		b.add_hull_quad(
			_far_point(z + sin(a0) * 31.0 * wob0, lat + cos(a0) * 31.0 * wob0, wy + 0.05),
			_far_point(z + sin(a1) * 31.0 * wob1, lat + cos(a1) * 31.0 * wob1, wy + 0.05),
			_far_point(z + sin(a1) * 36.5 * wob1, lat + cos(a1) * 36.5 * wob1, wy + 0.05),
			_far_point(z + sin(a0) * 36.5 * wob0, lat + cos(a0) * 36.5 * wob0, wy + 0.05),
			_water_color().lightened(0.09)
		)
		b.hull_origin = _far_point(z, lat, wy + 2.0)
	# The beacon: a squat nave with a hipped cap and a slim belfry — the Bled
	# chapel silhouette. Pale plaster catches the key where bare rock would
	# dissolve into the water tone at three hundred metres.
	var top := wy + 7.2
	var vb := _vista_basis
	b.add_box(
		Transform3D(vb, _far_point(z + 2.6, lat - _vp_side * 2.4, top + 2.4)),
		Vector3(4.4, 4.8, 3.4),
		plaster
	)
	b.add_cone(
		Transform3D(vb.rotated(vb.y, PI * 0.25), _far_point(z + 2.6, lat - _vp_side * 2.4, top + 4.8)),
		3.2, 2.2, 4, slate
	)
	b.add_box(
		Transform3D(vb, _far_point(z + 1.4, lat - _vp_side * 4.4, top + 3.4)),
		Vector3(1.4, 6.8, 1.4),
		plaster.lightened(0.05)
	)
	b.add_cone(
		Transform3D(vb.rotated(vb.y, PI * 0.25), _far_point(z + 1.4, lat - _vp_side * 4.4, top + 6.8)),
		1.2, 1.6, 4, slate
	)
	# The copse: a handful of dark crowns holding the tower in the middle of
	# the rock — bare it reads as a chimney, wooded it reads as a place.
	for t in [[0.0, 4.0, 3.0, 9.5], [-4.8, -1.4, 2.6, 7.2], [4.2, -4.6, 3.4, 10.5], [-2.2, 6.0, 2.2, 6.2]]:
		b.add_cone(
			Transform3D(vb, _far_point(z + float(t[0]), lat + _vp_side * float(t[1]), top)),
			float(t[2]), float(t[3]), 6, leaf.lerp(moss, _rng.randf() * 0.3)
		)
	var mesh: MeshInstance3D = b.commit_to(self, "ViewpointIslet")
	if mesh:
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _build_bastion() -> void:
	## The crag the terrace stands on. From across the water the belvedere's
	## plinth met the face as a single thin course over a smooth dome — a
	## shelf, not a place. Stepped rock benches run the platform span down the
	## face, so the terrace reads as a bastion on bedrock the way Bled castle
	## or Glacier Point does — the drop you can see is what makes the rail
	## worth leaning on.
	var pal := _face_scarp_palette()
	var rock: Color = pal["rock_lo"]
	var lip: Color = pal["lip"]
	var b := LowPoly.new()
	var half: float = RoadPathGD.PLATFORM_HALF_LENGTH
	var placed := 0
	# The bastion is one stepped apron, not a row of blocks: hull strips run
	# continuously along the platform span, each course's bottom edge pushed
	# a touch further out than its top — the battered profile of a retaining
	# crag the way Bled's promontory reads from the lake. Every strip stays
	# inside the live arc; past the fall line the chord bridges drowned apron
	# and a wall keyed to it stands on air.
	var zs: Array[float] = []
	var profs: Array[Dictionary] = []
	for i in 9:
		var z: float = _vp_centre + lerpf(-0.82, 0.82, float(i) / 8.0) * half
		var prof := _face_profile(z)
		if prof.is_empty() or not _face_is_face(prof):
			continue
		zs.append(z)
		profs.append(prof)
	if zs.size() < 2:
		return
	var fmaxs := PackedFloat32Array()
	for p in profs:
		fmaxs.append(minf(0.85, _face_live_arc(p) / float(p["total"]) * 0.9))
	b.hull_origin = _face_chord_point(zs[0], _profile_out(profs[0], 0.3)) + Vector3(0.0, 8.0, 0.0)
	const COURSES := 3
	for s in COURSES:
		var ft0: float = 0.10 + 0.75 * float(s) / float(COURSES)
		var ft1: float = 0.10 + 0.75 * float(s + 1) / float(COURSES)
		var proud := float(s) * 2.0 + 1.2
		for j in range(zs.size() - 1):
			var fa := minf(ft0, fmaxs[j])
			var fb := minf(ft1, fmaxs[j])
			var fc := minf(ft1, fmaxs[j + 1])
			var fd := minf(ft0, fmaxs[j + 1])
			var pa := _face_chord_point(zs[j], _profile_out(profs[j], fa)) + _vista_basis.x * (_vp_side * proud)
			var pb := _face_chord_point(zs[j], _profile_out(profs[j], fb)) + _vista_basis.x * (_vp_side * (proud + 1.4))
			var pc := _face_chord_point(zs[j + 1], _profile_out(profs[j + 1], fc)) + _vista_basis.x * (_vp_side * (proud + 1.4))
			var pd := _face_chord_point(zs[j + 1], _profile_out(profs[j + 1], fd)) + _vista_basis.x * (_vp_side * proud)
			var shade := 0.09 * sin(float(s) * 2.1 + float(j) * 1.3) - 0.04 * float(s)
			b.add_hull_quad(pd, pc, pb, pa, _facet_tone(rock, shade))
		# A turf lip along the top edge of each course — the strata line that
		# reads at two hundred metres and keeps the apron geology, not masonry.
		for j in range(zs.size() - 1):
			var fa := minf(ft0, fmaxs[j])
			var fd := minf(ft0, fmaxs[j + 1])
			var pa := _face_chord_point(zs[j], _profile_out(profs[j], fa)) + _vista_basis.x * (_vp_side * (proud + 0.35))
			var pd := _face_chord_point(zs[j + 1], _profile_out(profs[j + 1], fd)) + _vista_basis.x * (_vp_side * (proud + 0.35))
			b.add_hull_quad(
				pd + Vector3(0.0, 0.5, 0.0),
				pa + Vector3(0.0, 0.5, 0.0),
				pa - _vista_basis.x * (_vp_side * 0.9) - Vector3(0.0, 0.35, 0.0),
				pd - _vista_basis.x * (_vp_side * 0.9) - Vector3(0.0, 0.35, 0.0),
				lip.darkened(0.06)
			)
		placed += 1
	if placed == 0:
		return
	var mesh: MeshInstance3D = b.commit_to(self, "ViewpointBastion")
	if mesh:
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _build_face_path() -> void:
	## The way down — the Bled ninety-nine steps. A pale stair leaving the
	## platform's far end and dropping the face to a plank jetty, with the
	## little boat that says the water is something you can touch, not just
	## look at. From the seat it is the scale cue the bare face never had;
	## from across the water it is the line that says people come here.
	var zs: Array[float] = []
	for end in [1.0, -1.0]:
		var z: float = _vp_centre + end * (RoadPathGD.PLATFORM_HALF_LENGTH + 15.0)
		var prof := _face_profile(z)
		if not prof.is_empty() and _face_is_face(prof) and _face_above_water(z, _profile_out(prof, 0.25), 2.0):
			zs.append(z)
			break
	if zs.is_empty():
		return
	var z: float = zs[0]
	# Weathered step stone off the same crag, not fresh limestone: at overlook
	# distance the pale 9a9078 flight merged into a bright plank wall.
	var tread: Color = (_face_scarp_palette()["rock_hi"] as Color).darkened(0.10)
	var timber := Color("54452f")
	var b := LowPoly.new()
	# The flight: alternate straight runs with a jog — the stair's own
	# switchback, so the line zigzags twice on the way down instead of
	# drawing one ruled diagonal.
	var step_i := 0
	var jog := 0.0
	var jog_dir := 1.0
	var f := 0.14
	var last_out := 0.0
	var prof := _face_profile(z)
	var fmax: float = _face_live_arc(prof) / float(prof["total"]) * 0.92
	while f < fmax and step_i < 44:
		var out: float = _profile_out(prof, f)
		var chord := _face_chord_point(z + jog, out)
		# Past the fall line the chord bridges drowned apron — the flight
		# stops where the face does, and the jetty finishes the reach.
		if _terrain_surface_at(z + jog, _vp_side * out).y < _vp_water_y + 0.6:
			break
		last_out = out
		var tread_basis := _vista_basis.rotated(_vista_basis.y, 0.25 * jog_dir)
		b.add_box(
			Transform3D(tread_basis, chord + Vector3(0.0, 0.10, 0.0)),
			Vector3(0.85, 0.22, 1.9),
			tread.darkened(_rng.randf() * 0.1)
		)
		# A slim post every fourth step — the balustrade tick that makes a row
		# of pale dots read as a stair and not as scree.
		if step_i % 4 == 0:
			b.add_box(
				Transform3D(
					tread_basis,
					chord + _vista_basis.x * (_vp_side * 1.1) + Vector3(0.0, 0.55, 0.0)
				),
				Vector3(0.16, 0.9, 0.16),
				timber
			)
		step_i += 1
		f += 0.022
		jog += jog_dir * 0.55
		if step_i % 9 == 0:
			jog_dir = -jog_dir
	# The jetty: a short plank over the shallows at the foot of the stair,
	# and a flat-bottomed boat alongside — the pletna at the landing. Out
	# past the face the point is placed on the vista frame directly, the
	# same space the water sheet is drawn in.
	var water_y: float = _vp_water_y - _origin.y
	var jetty_out: float = last_out + 3.4
	var jp := _far_point(z + jog, _vp_side * jetty_out, water_y + 0.35)
	b.add_box(
		Transform3D(_vista_basis, jp),
		Vector3(5.6, 0.24, 1.9),
		timber.lightened(0.10)
	)
	for off in [-2.4, 2.4]:
		var post_p := _far_point(z + jog + off, _vp_side * jetty_out, water_y - 0.15)
		b.add_box(Transform3D(_vista_basis, post_p), Vector3(0.22, 1.3, 0.22), timber.darkened(0.15))
	# The boat: one flat hull and a thwart — three quads of silhouette at
	# two hundred metres is a boat.
	var boat_p := _far_point(z + jog + 1.2, _vp_side * (jetty_out + 2.6), water_y + 0.02)
	var hull := Color("6a4f36")
	b.add_box(
		Transform3D(_vista_basis.rotated(_vista_basis.y, 0.5), boat_p),
		Vector3(3.0, 0.5, 1.15),
		hull
	)
	b.add_box(
		Transform3D(_vista_basis.rotated(_vista_basis.y, 0.5), boat_p + Vector3(0.0, 0.3, 0.0)),
		Vector3(2.2, 0.12, 0.9),
		hull.darkened(0.25)
	)
	var mesh: MeshInstance3D = b.commit_to(self, "ViewpointPath")
	if mesh:
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _water_color() -> Color:
	## Deep and frankly teal. This is an albedo under a 1.5 sun and the lake fills
	## a third of the frame, so it has to be dark enough to stay the calmest mass
	## in the composition — but the desaturated slate it used to be gave the middle
	## of the picture no colour to hold against the ochre of the fells around it.
	## The whole warm-land / cool-water opposition is what the view is built on.
	match _vp_theme:
		Env.MOUNTAIN:
			return Color("103f52")
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
	var outer: float = float(_path.viewpoint_far_shore(_vp_centre, _vp_centre)) + 520.0
	# The basin carving — and so the lake bed — ends LAKE_SPAN * 1.55 out along
	# the route (`_viewpoint_terrain_drop`). Past it the land stands on its own
	# and only stray hollows dip under the waterline; a sheet drawn the vista's
	# full reach painted water over those hollows all the way to the junction
	# ends of the spur, where it read as a pale concrete apron from the air.
	# Holding the sheet to the carved reach keeps the waterline on the bed —
	# and the shorter span gives a finer step for the shoreline to follow.
	var z_half := RoadPathGD.LAKE_SPAN * 1.55
	var z0 := _vp_centre - z_half
	var z_span := z_half * 2.0
	var surface := _water_color()
	var b := LowPoly.new()
	b.smooth = true
	for i in zs:
		var za := z0 + z_span * float(i) / float(zs)
		var zb := z0 + z_span * float(i + 1) / float(zs)
		for j in ls:
			var out_a: float = lerpf(inner, outer, float(j) / float(ls))
			var out_b: float = lerpf(inner, outer, float(j + 1) / float(ls))
			if _lake_quad_dry(za, zb, out_a, out_b):
				continue
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


var _lake_surface: Dictionary = {}


func _lake_surface_y(z: float, out: float) -> float:
	## Ground height at a sheet-grid node. The 4x4 dry test shares its edge
	## samples with every neighbouring quad, so each node pays its basin
	## queries once instead of four times.
	var key := Vector2(z, out)
	var surface: Variant = _lake_surface.get(key)
	if surface == null:
		surface = float(_path.height_at(z)) - float(_path.terrain_drop(_vp_side * out, z))
		_lake_surface[key] = surface
	return surface


func _lake_quad_dry(za: float, zb: float, out_a: float, out_b: float) -> bool:
	## True when the ground under this stretch of the sheet stands entirely
	## above the water.
	##
	## The sheet is one flat band run the length of the overlook, but the lake
	## only exists where the basin was actually carved. Past the closing bay —
	## out across the junction ends and over made ground under the spur — the
	## land stands above the surface, and the band used to lay over it anyway
	## as a dead-flat sheet mirroring the pale sky. From the air and on the
	## approach it read as a concrete apron wedged against the junction. Skipping
	## the dry quads keeps the waterline on the landform: open water where the
	## bed sinks, grassed bank and made ground where it stands up out of it.
	const SAMPLES := 3
	for i in SAMPLES + 1:
		var z: float = lerpf(za, zb, float(i) / float(SAMPLES))
		for j in SAMPLES + 1:
			var out: float = lerpf(out_a, out_b, float(j) / float(SAMPLES))
			if _lake_surface_y(z, out) <= _vp_water_y + 0.05:
				return false
	return true


func _build_lake_water_incremental() -> void:
	if not _owns_platform:
		return
	## Same continuous sheet as `_build_lake_water`, one Z strip per frame, then commit.
	const ZS := 24
	var zs: int = 24
	var ls: int = 12
	var inner: float = float(_path.viewpoint_near_shore(_vp_centre)) - 140.0
	var outer: float = float(_path.viewpoint_far_shore(_vp_centre, _vp_centre)) + 520.0
	var z_half := RoadPathGD.LAKE_SPAN * 1.55
	var z0 := _vp_centre - z_half
	var z_span := z_half * 2.0
	var surface := _water_color()
	var b := LowPoly.new()
	b.smooth = true
	for i in zs:
		var za := z0 + z_span * float(i) / float(zs)
		var zb := z0 + z_span * float(i + 1) / float(zs)
		for j in ls:
			var out_a: float = lerpf(inner, outer, float(j) / float(ls))
			var out_b: float = lerpf(inner, outer, float(j + 1) / float(ls))
			if _lake_quad_dry(za, zb, out_a, out_b):
				continue
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
		# Every strip costs a dozen shoreline samples; checking every other one
		# let a pair run ~13 ms past the slice budget on a loaded frame.
		if _slice_spent() and not await _keep_streaming():
			return
	var mesh: MeshInstance3D = b.commit_to(self, "ViewpointLake")
	if mesh:
		mesh.material_override = water_material()
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
	# Waterline work: a thin lit rim where the sheet meets the far bank keeps
	# the seated edge readable, and a darker shallow apron inside each shore
	# gives the grazing view a band of water-body before the mirror takes over.
	# The near shore gets no rim — the cells run ~60 m across, so one corner
	# inside the band lit a whole quad into the pale plate the across frames
	# kept catching. There the waterline is drawn by the terrain meeting the
	# water, and the shallow band carries the tone.
	var near: float = float(_path.viewpoint_near_shore(z))
	var far: float = float(_path.viewpoint_far_shore(z, _vp_centre))
	var shallow: float = (
		smoothstep(near + 4.0, near + 14.0, out) * (1.0 - smoothstep(near + 36.0, near + 78.0, out))
	)
	shallow = maxf(
		shallow,
		smoothstep(far - 90.0, far - 44.0, out) * (1.0 - smoothstep(far - 12.0, far - 4.0, out))
	)
	color = color.lerp(surface.darkened(0.26), minf(shallow, 1.0) * 0.45)
	var rim: float = (
		smoothstep(far - 6.0, far - 2.5, out) * (1.0 - smoothstep(far - 1.5, far + 1.5, out))
	)
	color = color.lerp(surface.lightened(0.30), rim * 0.2)
	# Very broad horizontal variations catch the sky as painted planes — two
	# wavelengths now, so the far half of the basin keeps a slow value drift at
	# grazing angles instead of averaging to one flat tone. Still under six
	# percent, so it facets rather than striping.
	var drift := (0.5 + 0.5 * sin(out * 0.043 + z * 0.018)) * 0.032
	drift += (0.5 + 0.5 * sin(out * 0.011 - z * 0.006)) * 0.045
	return color.lightened(drift)


func _build_far_ground() -> void:
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
	var rises := _far_cliff_rises()
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
		# Where the shore-side edge of this sheet meets the back of the drawn
		# bank. The bank's own back row lands at forty-two percent of its height;
		# a skirt edge standing any higher than that is a pale shelf hovering
		# over whatever lies behind the bank — which at the diving ends of the
		# lake is open water. Tuck it just under instead.
		var cap_a: float = _vp_water_y + _far_scree_rise(za, rises.x, rises.y) * 0.42 + 0.35
		var cap_b: float = _vp_water_y + _far_scree_rise(zb, rises.x, rises.y) * 0.42 + 0.35
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
			# near the water punches a black triangle in the one place the eye
			# looks. Two metres over the surface: at +0.8 the clamped corners
			# hung in the air over the shoreline as a pale slab.
			var floor_y: float = _vp_water_y + 2.2
			ya0 = maxf(ya0, floor_y)
			ya1 = maxf(ya1, floor_y)
			yb1 = maxf(yb1, floor_y)
			yb0 = maxf(yb0, floor_y)
			if j == 0:
				# The inner edge is whichever vertex sits on `inner`: on the
				# road's right that is the a corner, mirrored it is the b one.
				if _vp_side > 0.0:
					ya0 = minf(ya0, cap_a)
					yb0 = minf(yb0, cap_b)
				else:
					ya1 = minf(ya1, cap_a)
					yb1 = minf(yb1, cap_b)
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
		# Hayfield, but muted: unshaded 9a8547 went straight to orange-gold and
		# drew a sand-coloured parcel across the far meadow, and the khaki that
		# followed it still read as a dry patch. Green-gold: a meadow before
		# the cut, which keeps the parcel lighter without leaving the greens.
		return Color("7d8a4a")
	if fh == 2:
		return Color("668343")
	return Color("365d38")


func _build_far_ground_incremental() -> void:
	## Same basin skirt as `_build_far_ground`, spread across the complete seated vista.
	var z0 := _vp_centre - RANGE_REACH * 2.0
	var z_span: float = RANGE_REACH * 4.0
	var b := LowPoly.new()
	b.smooth = true
	var color := Color("435c4a")
	match _vp_theme:
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
	var rises := _far_cliff_rises()
	const FAR_ZS := 64
	const FAR_LS := 8
	for i in FAR_ZS:
		var za := z0 + z_span * float(i) / float(FAR_ZS)
		var zb := z0 + z_span * float(i + 1) / float(FAR_ZS)
		var shift_a: float = _vp_side * (float(_path.viewpoint_far_shore(za, _vp_centre)) - float(_path.viewpoint_far_shore(_vp_centre, _vp_centre)))
		var shift_b: float = _vp_side * (float(_path.viewpoint_far_shore(zb, _vp_centre)) - float(_path.viewpoint_far_shore(_vp_centre, _vp_centre)))
		# Same tuck under the bank's back edge as the sync path: an edge standing
		# above it is a pale shelf hovering over open water at the diving ends.
		var cap_a: float = _vp_water_y + _far_scree_rise(za, rises.x, rises.y) * 0.42 + 0.35
		var cap_b: float = _vp_water_y + _far_scree_rise(zb, rises.x, rises.y) * 0.42 + 0.35
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
			var floor_y: float = _vp_water_y + 2.2
			ya0 = maxf(ya0, floor_y)
			ya1 = maxf(ya1, floor_y)
			yb1 = maxf(yb1, floor_y)
			yb0 = maxf(yb0, floor_y)
			if j == 0:
				if _vp_side > 0.0:
					ya0 = minf(ya0, cap_a)
					yb0 = minf(yb0, cap_b)
				else:
					ya1 = minf(ya1, cap_a)
					yb1 = minf(yb1, cap_b)
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
	## rather than a sunlit table.
	var far: float = float(_path.viewpoint_far_shore(z, _vp_centre))
	var bank: float = 24.0
	var col: float = 1.0 - 0.88 * exp(-pow((z - _vp_centre) / 300.0, 2.0))
	match _vp_theme:
		Env.FOREST:
			bank = 48.0
			col = 1.0 - 0.18 * exp(-pow((z - _vp_centre) / 220.0, 2.0))
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
	await _build_lake_edge_boulders(true)
	if not await _keep_streaming():
		return false
	var fan_count := SCREE_FANS * 2 if _vp_theme == Env.MOUNTAIN else SCREE_FANS
	var z0 := _vp_centre - LENGTH * 0.5
	var face_run: float = maxf(
		float(_path.viewpoint_near_shore(_vp_centre)) - float(_path.headland_crest(_vp_centre)) - 8.0, 24.0
	)
	for _fan in fan_count:
		_build_face_scree_fan(z0, face_run)
		if not await _keep_streaming():
			return false
	await _build_face_ledges(true)
	if not await _keep_streaming():
		return false
	_build_lake_reeds()
	if not await _keep_streaming():
		return false
	return await _build_basin_rocks_incremental()


func _build_lake_edge_boulders(streamed: bool = false) -> void:
	var z0 := _vp_centre - LENGTH * 0.5
	# Boulders at and just under the waterline, in groups, and big enough to
	# matter at a hundred and forty metres. The whole near shore sits in the
	# bottom of the seated frame; at the old two-to-six metres, evenly sprinkled,
	# it contributed nothing but noise and the foreground read as empty water.
	var groups: int = 6 if _vp_theme == Env.MOUNTAIN else 4
	for group in groups:
		if streamed and group > 0 and _slice_spent() and not await _keep_streaming():
			return
		var head_z: float = z0 + _rng.randf_range(0.0, LENGTH)
		var head_out: float = float(_path.viewpoint_near_shore(head_z)) + _rng.randf_range(-14.0, 2.0)
		for _i in 5:
			var z: float = head_z + _rng.randf_range(-9.0, 9.0)
			var out: float = head_out + _rng.randf_range(-7.0, 7.0)
			var above := _height_above_water(z, out)
			# Drowned ground is no shore either: off the sunken tip of the point
			# the stones come out standing in open water, a reef where there is
			# no reef — the clump chain the spur overview drew across the lake.
			if above > 3.0 or above < -0.9:
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
	# anything roots in its margins — there these were half a dozen saturated
	# green chips lying flat on a dark bank, reading as litter rather than as
	# planting.
	if _vp_theme == Env.MOUNTAIN:
		return
	var z0 := _vp_centre - LENGTH * 0.5
	for _i in 18:
		var z := z0 + _rng.randf_range(0.0, LENGTH)
		var out: float = float(_path.viewpoint_near_shore(z)) + _rng.randf_range(-3.0, 8.0)
		var above := _height_above_water(z, out)
		if above > 1.2 or above < -0.8:
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
# The answer is mass standing in the water, and the rest of this section is
# that answer for the three biomes.


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
	# The crown was ab9f80 — pale straw that lit to bread-roll orange standing
	# in the shallows. Still the lit shoulder, now a wet-stone tan off the moss
	# band rather than off the hay field.
	return [Color("4a463c"), Color("8d8468")]


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
		Env.MOUNTAIN:
			# A moraine-drowned tarn. The densest of the three and the only one
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
	## Site count is per biome on purpose, not per seed: a biome whose whole
	## subject is rock can afford three times the sites of a wooded lake and
	## still be under a hundred instances of an instanced sphere.
	var stone := _basin_stone()
	var body: Color = stone[0]
	var crown: Color = stone[1]
	var groups: int = 0
	var per_group: int = 0
	match _vp_theme:
		Env.FOREST:
			groups = 3
			per_group = 1
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
			# 9aa088 was the forest half of the pale dash row — a pale sage slab
			# that rendered cream at the waterline. Wet moss + grey-green
			# shingle, the same ladder the country strip uses.
			return [Color("37443a"), Color("59664f")]
		Env.MOUNTAIN:
			return [Color("5a5f62"), Color("a8aeb0")]
	# b6a888 rendered as a pale ochre rim right at the bank's lit lip — the last
	# piece of the sand ring. Grey shingle keeps the value step without the hue.
	# Grey was not enough either: a3a392 lies flat at the waterline where the
	# key is strongest, and every grey tried there arrives as sand. Moss-green
	# shingle keeps the step and loses the beach.
	return [Color("333d33"), Color("4f5947")]


func _build_shore_strip() -> void:
	## Shingle along the far waterline — the one edge in the frame the eye is
	## actually looking for.
	##
	## The far bank is the only shoreline a seated rider can see: the near one is
	## under the lens's bottom edge, as the section header explains. So the strip
	## follows `viewpoint_far_shore` and not the near curve, which is where the
	## obvious reading of "a strip along the water" would have put it and where it
	## would have been invisible.
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
		# The shore line is an estimate — where the bank behind it has gone
		# under, the "beach" is a slab on open water: the thin pale dashes the
		# across shot drew off the drowned reach. No bank, no beach.
		if _far_bank_rise(z, line + 6.0) < 0.6:
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


func _build_far_bank_bands(streamed: bool = false) -> void:
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
		if streamed and _slice_spent() and not await _keep_streaming():
			return
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
			# Lichened stone rather than shadow: once these were faceted rock the
			# near-black end of the ladder read as holes punched in the meadow.
			return [Color("6a7262"), Color("3b4738")]
		Env.MOUNTAIN:
			return [Color("4f5a57"), Color("2a3133")]
		Env.COUNTRY:
			return [Color("6e7060"), Color("3c4634")]
	return [Color("434c3d"), Color("242a21")]


func _build_far_bank_ground(streamed: bool = false) -> void:
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
		if streamed and _slice_spent() and not await _keep_streaming():
			return
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
			if _rng.randf() < 0.14:
				col = pale.lightened(_rng.randf() * 0.08)
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


func _build_vista_accent(streamed: bool = false) -> void:
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
	## down to the water, because country is fields seen edge-on. Forest gets a
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
				if streamed and i % 4 == 3 and _slice_spent() and not await _keep_streaming():
					return
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
				if streamed and i % 4 == 3 and _slice_spent() and not await _keep_streaming():
					return
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
	for _fan in (SCREE_FANS * 2 if _vp_theme == Env.MOUNTAIN else SCREE_FANS):
		_build_face_scree_fan(z0, face_run)


func _build_face_scree_fan(z0: float, face_run: float) -> void:
	# Source of the fan: a point partway down the face, in this chunk. Sourcing
	# right at the brow parked round stones on the near-vertical upper wall,
	# where a talus block cannot rest — each one a rock glued to a cliff.
	var head_z: float = z0 + _rng.randf_range(0.0, LENGTH)
	var head_out: float = float(_path.headland_crest(head_z)) + _rng.randf_range(0.35, 0.62) * face_run
	var spread: float = _rng.randf_range(9.0, 22.0)
	for _i in SCREE_PER_FAN:
		# Fall line, biased downslope, spreading as it goes.
		var run: float = _rng.randf() * _rng.randf()  # bunched near the head
		var out: float = head_out + run * (face_run - (head_out - float(_path.headland_crest(head_z))))
		var z: float = head_z + _rng.randf_range(-1.0, 1.0) * spread * (0.35 + run)
		var above := _height_above_water(z, out)
		var prof := _face_profile(z)
		# Off the face the chord floats over drowned apron — a scree stone
		# planted on it is a rock hovering over marsh, not talus.
		var on_face := not prof.is_empty() and _face_is_face(prof)
		if (
			above < 1.0
			or not on_face
			or not _face_above_water(z, out, 0.6)
			or float(_path.spur_deck_blend(z, _vp_side * out)) > 0.15
		):
			continue
		# And only as far down as the face itself falls — past the live arc the
		# profile is a flat apron and a stone at its foot is still on the chord,
		# which is to say still in the air.
		out = minf(out, _profile_out(prof, _face_live_arc(prof) / maxf(float(prof["total"]), 1.0)))
		# Graded: fines at the head of the fan, blocks at the foot. Kept low and
		# bedded in — a tall round stone on the open apron reads as an egg.
		var s: float = lerpf(0.55, 2.3, run * run) * _rng.randf_range(0.82, 1.24)
		# And graded in value the same way. A stone lying in the shade of the
		# lip is not the same colour as one out on the open apron below it, and
		# a single pale grey for all of them is what made them read as popcorn
		# scattered over a dark slope.
		var stone := Color("4c463c").lerp(Color("6b6357"), run)
		_blob(
			z,
			_vp_side * out,
			Vector3(s * 1.7, s * 0.8, s * 1.5),
			stone.darkened(_rng.randf() * 0.20),
			_face_ground_lift(z, out) - s * 0.22,
			false,
			true
		)


static var _face_edges_left: Array = []
static var _face_edges_right: Array = []


func _face_band_edges() -> Array:
	## The view bands as a table sorted by inner edge, built once per side. The
	## face profile walks it ~30 times per z and the linear band scan that used
	## to answer each lookup was most of the headland's build cost.
	var edges: Array = _face_edges_right if _vp_side > 0.0 else _face_edges_left
	if edges.is_empty():
		var side := _vp_side if _vp_side != 0.0 else 1.0
		for band in _view_bands():
			var u0: float = float(band[0]) * side
			var u1: float = float(band[2]) * side
			var lo := minf(u0, u1)
			var hi := maxf(u0, u1)
			if hi - lo < 0.01:
				continue
			edges.append([lo, hi, u0, u1, float(band[0]), float(band[1]), float(band[2]), float(band[3])])
		edges.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
		if _vp_side > 0.0:
			_face_edges_right = edges
		else:
			_face_edges_left = edges
	return edges


func _face_chord_point(z: float, out: float) -> Vector3:
	## The surface the terrain ribbon actually *draws* at this spot on the
	## headland face: the straight chord between the mesh's own lateral edge
	## vertices. The analytic surface and the rendered strip sit metres apart on
	## this profile — dressing placed on the analytic one ends up underneath the
	## drawn slope, which is what buried every earlier attempt at face detail.
	var side := _vp_side
	var edges := _face_band_edges()
	# The band covering `out` is the last one whose inner edge starts at or
	# before it; bands tile the profile contiguously, so one binary search
	# replaces the seventy-odd band tests this used to pay per point.
	var lo_i := 0
	var hi_i := edges.size()
	while lo_i < hi_i:
		var mid := (lo_i + hi_i) >> 1
		if float((edges[mid] as Array)[0]) <= out:
			lo_i = mid + 1
		else:
			hi_i = mid
	if lo_i > 0:
		var band: Array = edges[lo_i - 1]
		if out <= float(band[1]):
			var e0: float = float(band[4])
			var e1: float = float(band[6])
			var pa := _p(z, e0, _band_drop(z, e0, float(band[5])))
			var pb := _p(z, e1, _band_drop(z, e1, float(band[7])))
			return pa.lerp(pb, (out - float(band[2])) / (float(band[3]) - float(band[2])))
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
	# The lower bound used to be -0.4: where the drawn chord sags *below* the
	# analytic surface (the concave reaches of the face), a prop capped there
	# hovered visibly over the mesh — the floating specks the s1 overviews
	# caught. Let it bed down to the drawn surface instead.
	return clampf(chord_y - ground_y, -1.8, 9.0)


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
	# Bedded two-thirds deep: on a convex reach of the face a slab stood proud
	# at half thickness leaves its ends hanging off the chord, and the gap
	# under the downhill end is what reads as floating.
	_ledges.append(Transform3D(scaled, point + normal * (size.y * 0.18)))
	_ledge_cols.append(color)


func _build_face_ledges(streamed: bool = false) -> void:
	## Broken lines of rock shelves at the stratum boundaries — the crisp edge
	## the vertex-colour bands cannot draw at seven-metre vertex spacing. The
	## eye reads geology from the lit top edge of a shelf against the shadowed
	## seam under it; a smooth gradient, however wide the values swing, is a
	## dune.
	var z0 := float(chunk_index) * LENGTH
	# Three runs sit at fractions down the face, so the built ledges and the
	# benched profile describe the same geology: a broken brow just under the
	# lip, a long pale shelf mid-face, and a second shelf where the dark seam
	# gives way to the talus. The lip moves along the route now that the top
	# tapers, so the runs measure off the crest at each z, not a constant.
	for run in [0.16, 0.42, 0.66]:
		var z := z0 + _rng.randf_range(0.0, 6.0)
		while z < z0 + LENGTH - 4.0:
			if streamed and _slice_spent() and not await _keep_streaming():
				return
			var prof := _face_profile(z)
			# Not a face, no ledges: past the fall line the chord the slabs sit
			# on bridges over drowned apron, and a slab there is litter on the
			# water — the bright dashes the across shot kept catching.
			if prof.is_empty() or not _face_is_face(prof):
				z += _rng.randf_range(6.0, 10.0)
				continue
			# A run is a fraction of the *falling* arc, not of the whole chord —
			# past the live end the profile lies flat over the drowned apron,
			# and a slab there is the pale dash floating on the water.
			var frac_cap: float = _face_live_arc(prof) / maxf(float(prof["total"]), 1.0)
			var frac := minf(run, frac_cap - 0.03) + _rng.randf_range(-0.05, 0.05)
			# And only where the profile is still steep enough to carry a bed:
			# a shelf slab needs a face under it, not the drowned tail's apron —
			# lying flat on a low bench it is litter, not strata.
			if _face_slope_at(prof, frac) < 0.35:
				z += _rng.randf_range(4.0, 8.0)
				continue
			var out: float = _profile_out(prof, frac)
			var above := _height_above_water(z, out)
			if above < 4.0 or not _face_above_water(z, out, 2.5) or float(_path.spur_deck_blend(z, _vp_side * out)) > 0.15:
				z += _rng.randf_range(4.0, 8.0)
				continue
			var slab := Vector3(
				_rng.randf_range(2.4, 3.6),
				_rng.randf_range(0.55, 1.05),
				_rng.randf_range(3.4, 6.4)
			)
			var tone := Color("8a8072").lerp(Color("6a6258"), _rng.randf())
			if _vp_theme == Env.MOUNTAIN:
				tone = Color("8a9096").lerp(Color("5c6268"), _rng.randf())
			elif _vp_theme == Env.FOREST:
				# Warm tan like the old country tone — read as sandstone slabs
				# on the forest face. Mossy grey-green instead.
				tone = Color("707761").lerp(Color("4c5340"), _rng.randf())
			elif _vp_theme == Env.COUNTRY:
				# Cooled a step — 9a8c74 is the warm tan that kept reading as
				# sandstone slabs on a grassed headland under the day key.
				tone = Color("7f7d68").lerp(Color("5f5947"), _rng.randf())
			_face_ledge(z, out, slab, tone)
			z += slab.z * _rng.randf_range(0.72, 0.95) + _rng.randf_range(2.0, 7.0)


## Far-bank profile, metres out from the shoreline: the ledge the water face
## climbs to (and the share of the bank's height it reaches there), the crown,
## and the back edge the skirt tucks under. The face used to climb fifty-eight
## percent of the bank in nine metres — a sixty-degree wall the length of the
## lake that, with the sun anywhere past it, never saw light and ran across
## every seated frame as a black dam. Laid back to a forty-degree bank it
## catches the sky like the meadow above it and reads as a shore. Shared by
## the mesh and `_far_bank_rise`, so planting stays on the drawn ground.
const FAR_BANK_LEDGE := 15.0
const FAR_BANK_LEDGE_RISE := 0.5
const FAR_BANK_CROWN := 36.0
const FAR_BANK_BACK := 60.0


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
			# Moss and turf, a step under the meadow: with the bank laid back it
			# takes the sky, and the near-black stone it used to carry turned the
			# whole shore into a void at noon. Wet moss stays the darkest step.
			return [Color("2c3f2c"), Color("1d281e"), Color("3c5634")]
		Env.MOUNTAIN:
			return [Color("282e32"), Color("1f2528"), Color("474f52")]
		Env.COUNTRY:
			# Ochre rather than grey, and still the darkest land in the frame: the
			# composition rests on warm land against cool water, and it rests on
			# the *water* being the subject, so this stays a value and not a hue.
			# Cooled off from 3d382c/2e2c24/5a543e: under the day key those warmed
			# to solid ochre and the whole bank read as a sand berm. These land as
			# olive-grey earth — the grade supplies the warmth it always does.
			# Down again, and greener: the seated day frames still read the
			# sun-facing spans as a tan berm (measured ~(160,124,65) off the
			# pixels), so the band now starts at wet moss on the waterline and
			# ends at dark turf on the lip.
			# Greener again once the bank was laid back: a sloped face is lit
			# like the pasture it carries, so it can be turf rather than earth.
			return [Color("33452a"), Color("1e2a1f"), Color("465a33")]
	return [Color("28261f"), Color("21201b"), Color("3c372c")]


func _build_far_cliffs() -> void:
	## Continuous far-shore scree with a pass in the middle of the view, owned once.
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
	var h: float = maxf(base * (1.0 + fold), pass_rise * 0.5) * 0.72
	# And shed it like a ridge running into a lake, not a wall ending at a face.
	# The old dive only shortened the last two hundred metres, which left the
	# end standing as a smooth dome — an island the size of a hill in the middle
	# of the water. A real bank loses height over a reach: a long fore-slope
	# first, shouldered by `fold`, then the last of it slips under the water.
	var retreat := 1.0 - 0.82 * smoothstep(
		RoadPathGD.LAKE_SPAN * 0.35, RoadPathGD.LAKE_SPAN - 40.0, dist
	)
	retreat *= 1.0 - 0.92 * smoothstep(
		RoadPathGD.LAKE_SPAN - 180.0, RoadPathGD.LAKE_SPAN - 6.0, dist
	)
	return h * retreat


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
	var ledge_a := _far_point(za, _vp_side * (shore_a + FAR_BANK_LEDGE), _vp_water_y + h_a * FAR_BANK_LEDGE_RISE)
	var ledge_b := _far_point(zb, _vp_side * (shore_b + FAR_BANK_LEDGE), _vp_water_y + h_b * FAR_BANK_LEDGE_RISE)
	var crown_a := _far_point(za, _vp_side * (shore_a + FAR_BANK_CROWN), _vp_water_y + h_a)
	var crown_b := _far_point(zb, _vp_side * (shore_b + FAR_BANK_CROWN), _vp_water_y + h_b)
	var back_a := _far_point(za, _vp_side * (shore_a + FAR_BANK_BACK), _vp_water_y + h_a * 0.42)
	var back_b := _far_point(zb, _vp_side * (shore_b + FAR_BANK_BACK), _vp_water_y + h_b * 0.42)
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
				if part.name == "Crowns":
					# The kit's crowns carried a private copy of the foliage shader,
					# so they never received the per-mood sky fill and air tint every
					# other tree is pushed, and their greens sat a step above the
					# woods around them. Backlit by a day or dusk sun the leaf glow
					# then took them to cream: rows of pale popcorn stands on every
					# forest hillside. Shared material, woodland greens, and each
					# tree its own small drift so a stand still reads as many trees.
					part.material_override = LowPoly.foliage_material()
					for tree_index in part.multimesh.instance_count:
						var leaf: Color = part.multimesh.get_instance_color(tree_index)
						var drift: float = 0.5 + 0.5 * sin(float(tree_index) * 2.3 + float(i) * 1.1 + _vp_phase)
						part.multimesh.set_instance_color(
							tree_index, leaf.darkened(0.22 + 0.16 * drift).lerp(Color("2d4a33"), 0.25)
						)
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
	if d < -3.0 or d > FAR_BANK_BACK:
		return -1.0
	if d < FAR_BANK_LEDGE:
		return h * FAR_BANK_LEDGE_RISE * (d + 3.0) / (FAR_BANK_LEDGE + 3.0)
	if d < FAR_BANK_CROWN:
		return h * lerpf(FAR_BANK_LEDGE_RISE, 1.0, (d - FAR_BANK_LEDGE) / (FAR_BANK_CROWN - FAR_BANK_LEDGE))
	return h * lerpf(1.0, 0.42, (d - FAR_BANK_CROWN) / (FAR_BANK_BACK - FAR_BANK_CROWN))


func _far_bank_lift(z: float, out: float) -> float:
	## `_tree` lift that stands a tree on the drawn far bank, bedded in a little
	## so a trunk on the slope does not show daylight under its downhill side.
	var bank_y: float = _vp_water_y + _far_bank_rise(z, out) - 0.4
	return bank_y - _terrain_surface_at(z, _vp_side * out).y


func _build_far_shore_incremental() -> void:
	var z0 := _vp_centre - RoadPathGD.LAKE_SPAN
	var z_span: float = RoadPathGD.LAKE_SPAN * 2.0
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
		if i % 4 == 3 and _slice_spent() and not await _keep_streaming():
			return
	if not await _keep_streaming():
		return
	if _vp_theme == Env.FOREST:
		# Same close-set bank rank as the sync path.
		var tz := z0 + 4.0
		var step_n := 0
		while tz < z0 + z_span:
			step_n += 1
			if step_n % 48 == 0 and _slice_spent() and not await _keep_streaming():
				return
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
	{"lateral": 900.0, "height": 220.0, "spread": 55.0, "width": 420.0, "haze": 0.04, "pass_width": 440.0, "left": -320.0, "right": 460.0, "cliff": false},
	{"lateral": 1300.0, "height": 280.0, "spread": 65.0, "width": 520.0, "haze": 0.14, "pass_width": 500.0, "left": -460.0, "right": 280.0, "cliff": false},
	{"lateral": 1700.0, "height": 340.0, "spread": 75.0, "width": 620.0, "haze": 0.30, "pass_width": 560.0, "left": -380.0, "right": 460.0, "cliff": false},
	{"lateral": 2100.0, "height": 400.0, "spread": 85.0, "width": 740.0, "haze": 0.48, "pass_width": 620.0, "left": -470.0, "right": 320.0, "cliff": false},
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
	## Stacked ranges behind the water: a near fell, a pass, and two blue
	## distances behind it for every rural overlook.
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
	# Heights are what the view is *for*. From a bench eighty metres over the
	# water a 250 m summit a kilometre out stands nine degrees above the eye —
	# a row of hills. The mountain overlook has to look up at its peaks.
	if _vp_theme == Env.FOREST:
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
		"last_layer": RANGE_LAYERS.size(),
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
## is convex.
func _range_profile() -> Dictionary:
	match _vp_theme:
		Env.COUNTRY:
			# A chalk down is not a dome: a long easy apron, a definite scarp
			# face, then a brow — the two-kinks-in-the-slope profile that reads
			# as an escarpment and not a balloon. The old five-row spread ran the
			# whole climb at one gradient, which shaded as a pillow.
			return {
				"g": [0.62, 0.44, 0.28, 0.16, 0.07, 0.02, 0.0],
				"f": [0.0, 0.10, 0.26, 0.54, 0.80, 0.94, 1.0],
				"back": 1.05,
			}
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
	## Sharpness > 1 is alpine. < 1 is a round fell. ≤ 0.35 is a flat-topped plateau.
	if sharpness <= 0.35:
		return minf(1.0, 1.0 - pow(1.0 - t, 2.4))
	return pow(t, sharpness)


func _range_massif(
	local: float, centre: float, inner_w: float, outer_w: float, peak: float, sharpness: float
) -> float:
	## Steep face toward the pass, long backslope the other way.
	##
	## A lone tent is a cone, and a green cone standing by itself on the valley
	## floor is a witch's hat — pointed summit, straight sides, one silhouette
	## and nothing to say it is a piece of a range. Two changes make it a hill:
	## the summit comes off the point (`pow(t, 6)` only bites in the top sixth,
	## so the flanks keep their shape while the apex lands as a brow), and a
	## shoulder steps in partway down the outer flank, so the backslope descends
	## in a stair instead of one ruled line.
	var toward_pass: bool = (local - centre) * centre < 0.0
	var half: float = inner_w if toward_pass else outer_w
	var d: float = absf(local - centre)
	var t: float = 1.0 - clampf(d / maxf(half, 1.0), 0.0, 1.0)
	var body: float = _range_tent(t, sharpness)
	var shoulder := 0.0
	if not toward_pass:
		shoulder = 0.22 * exp(-pow((d / maxf(half, 1.0) - 0.60) / 0.28, 2.0)) * (1.0 - body)
	return peak * (body - 0.16 * pow(t, 6.0) + shoulder)


func _range_sample(z: float, layer: Dictionary, phase: float, depth: int = 0) -> Vector2:
	## x = crest height above the base, y = how far out the crest line runs.
	## Mountain: horns and a deep col. Country: round fells you look through.
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
			# Shoulders that actually step down (`other`), massifs narrow enough
			# to read as separate hills, and a crest that rolls — a downland
			# skyline is a succession of brows with dry valleys between, not one
			# level ridge. The old values drew a single level green wall.
			sharpness = 0.52
			other = 0.66
			sag0 = 0.52
			jag_a = 0.05
			jag_b = 0.03
			inner_k = 0.52
			outer_k = 0.50
			foothill_lo = 0.34
			foothill_span = 0.22
			floor_h = 0.08
		Env.FOREST:
			# Below linear, so the shoulders swell: at 0.88 every summit was a
			# straight-sided cone, which wooded hills never are. `outer_k` stays
			# generous for the same reason: at 0.24 a hero's backslope died inside
			# four hundred metres and the summit stood alone as a green pyramid
			# on the valley floor — the witch's hat in the seated frame.
			sharpness = 0.70
			other = 0.74
			sag0 = 0.40
			inner_k = 0.58
			outer_k = 0.44
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
	# Each heavy step is sliced inside itself too — a whole belvedere or
	# pergola between yields was a 30–55 ms frame while the rider climbed.
	await _platform_step(rng, _build_belvedere.bind(true))
	if not await _keep_streaming():
		return false
	await _platform_step(rng, _build_platform_seating.bind(true))
	if not await _keep_streaming():
		return false
	await _platform_step(rng, _build_platform_gate.bind(true))
	if not await _keep_streaming():
		return false
	# The walk's three lanterns each instantiate a packed scene and its bollard
	# light, and the pergola is a dozen timber members through the clearance
	# sweep — one step for both was a 50 ms lump on arrival.
	await _platform_step(rng, _build_platform_lanterns.bind(true))
	if not await _keep_streaming():
		return false
	await _platform_step(rng, _build_platform_pergola.bind(true))
	if not await _keep_streaming():
		return false
	await _platform_step(rng, _build_platform_trees.bind(true))
	if not await _keep_streaming():
		return false
	await _platform_step(rng, _build_platform_planting.bind(true))
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
	## One platform step on the platform's generator. The swap now spans the
	## step's own awaits — a streamed step keeps drawing from this sequence
	## after a frame yield, so the platform is identical however it is sliced.
	var world_rng := _rng
	_rng = rng
	await step.call()
	_rng = world_rng


func _build_platform_furniture() -> void:
	## The destination. Everything is placed from the overlook centre on ground
	## the path has already levelled, so nothing here needs a fudge height.
	## Split in three so the incremental pass can yield between the imported set
	## pieces and the built pergola — all of it in one call was a ~50 ms frame.
	_build_platform_seating()
	_build_platform_gate()
	_build_platform_walk()


func _build_platform_seating(streamed: bool = false) -> void:
	var centre := _vp_centre
	var side := _vp_side
	# Out on the terrace, clear of anything the bike can reach.
	var edge: float = RoadPathGD.PLATFORM_HALF_WIDTH + 6.2
	var timber := Color("6d4f38")

	# Benches square on to the water, planted on the terrace rather than hovering
	# a world-up offset above a pitched deck.
	for offset in RoadPathGD.PLATFORM_BENCH_Z:
		_viewpoint_bench(centre + float(offset), side, RoadPathGD.PLATFORM_BENCH_OUT)
		if streamed and _slice_spent() and not await _keep_streaming():
			return
	_viewpoint_board(centre + 14.0, side, RoadPathGD.PLATFORM_HALF_WIDTH + 1.6, timber)
	# The kit's balcony carries its own coin viewer out over the drop.
	if _lookout_scene(LOOKOUT_BALCONY) == null:
		_viewpoint_telescope(centre - 0.2, side, edge - 1.4)


func _build_platform_gate(streamed: bool = false) -> void:
	var centre := _vp_centre
	var timber := Color("6d4f38")
	# Painted bays and the brown board at the way in, when the kit has them.
	# The bays share the deck's cooled family so the pergola does not keep the
	# baked salmon of the old bake against the now-stone plaza.
	var bays: PackedScene = _lookout_scene(LOOKOUT_BAYS)
	if bays:
		for at in [-8.0, 8.0]:
			_place_lookout(
				bays, centre + at, RoadPathGD.PLATFORM_HALF_WIDTH, BAYS_LIFT,
				"LookoutBays_%d" % int(at), Color(0.45, 0.66, 0.92)
			)
			if streamed and _slice_spent() and not await _keep_streaming():
				return
	var stop: PackedScene = _lookout_scene(LOOKOUT_STOP)
	if stop:
		# One at the way in, and one a long stopping distance before it, so the
		# rider is told before the bays open rather than as they pass them.
		for pair in [[RoadPathGD.PLATFORM_HALF_LENGTH + 8.0, "LookoutStop"], [150.0, "LookoutStopAdvance"]]:
			var stop_z: float = centre - float(pair[0])
			var verge: float = float(_path.spur_half_width(stop_z)) + RoadPathGD.SPUR_SHOULDER + 1.4
			_place_lookout(stop, stop_z, -verge, 0.0, str(pair[1]))
			if streamed and _slice_spent() and not await _keep_streaming():
				return
	var bin_z := centre + 17.5
	var bin_lat: float = _platform_lateral(RoadPathGD.PLATFORM_HALF_WIDTH + 1.4, bin_z)
	_deck_cube(bin_z, bin_lat, Vector3(0.62, 0.92, 0.62), timber.darkened(0.2), 0.0, -0.04)
	_deck_cube(bin_z, bin_lat, Vector3(0.76, 0.1, 0.76), timber.lightened(0.15), 0.0, 0.88)


func _build_platform_walk() -> void:
	_build_platform_lanterns()
	_build_platform_pergola()


func _build_platform_lanterns(streamed: bool = false) -> void:
	var centre := _vp_centre
	# Promenade lanterns along the parking side of the walk: tall enough to read
	# as street furniture from the road, behind the benches so the seated view
	# never has a pole in it. Only the outer two own real lights (the per-chunk
	# cap); the middle one keeps its emissive glass.
	for offset in [-12.0, 0.0, 12.0]:
		_viewpoint_lantern(centre + offset, RoadPathGD.PLATFORM_HALF_WIDTH + 1.05, absf(offset) > 1.0)
		if streamed and _slice_spent() and not await _keep_streaming():
			return


func _viewpoint_lantern(z: float, out: float, lit: bool) -> void:
	var packed: PackedScene = _lookout_scene("res://scenes/lookout_bollard.tscn")
	if packed == null:
		return
	var lamp: Node3D = packed.instantiate()
	var lateral := _platform_lateral(out, z)
	lamp.transform = Transform3D(_path.frame_flat_at(z), _p(z, lateral, -0.05 - _terrace_floor_at(z, lateral)))
	lamp.name = "LookoutLight_%d" % int(z)
	add_child(lamp)
	if lit:
		_deck_light(z, lateral, 0.81, Color("ffd399"), 5.0, 0.55)

func _build_platform_pergola(streamed: bool = false) -> void:
	## A timber pergola over the walk beside the seated bench, with benches of
	## its own and blossom over the rafters. It is the silhouette that makes the
	## terrace a destination from the parking: an open frame, not a roof, so the
	## lake still shows through it.
	##
	## It shelters the end of the walk the rider actually sits at — the seat
	## nearest the platform centre is at +6 — rather than standing at the far
	## end where nobody ever reaches it. The rafters overhang the parapet side
	## so the vista bench sits under the canopy's edge, while the posts stay
	## inside the bench line and out of its z span: a post through the seat is
	## not shade. All of it stays outboard of the parking.
	var timber := Color("544839")
	var stone := Color("8e8270")
	var bloom := _platform_bloom()
	var inner := RoadPathGD.PLATFORM_HALF_WIDTH + 1.15
	var outer := RoadPathGD.PLATFORM_HALF_WIDTH + 5.45
	var z_a := _vp_centre + 1.0
	var z_b := _vp_centre + 13.0
	var z_mid := (z_a + z_b) * 0.5
	# Four bents, spaced so no outer post lands on the vista bench's z span
	# (the bench runs +4.9 to +7.1) or beside the promenade lantern at +12.
	var posts: Array[float] = [z_a, z_a + 3.6, z_b - 4.1, z_b]
	const HEIGHT := 2.85
	for pz in posts:
		for out in [inner, outer]:
			# The parapet line keeps only its end posts. Its middle pair stood a
			# hand's width from the seated rider, so turning the head put a timber
			# column across half the frame; the beam spans the gap on its own.
			if out == outer and pz != z_a and pz != z_b:
				continue
			var lat: float = _platform_lateral(out, pz)
			_deck_cube(pz, lat, Vector3(0.36, 0.3, 0.36), stone, 0.0, -0.04)
			_deck_cube(pz, lat, Vector3(0.2, HEIGHT - 0.26, 0.2), timber, 0.0, 0.26)
			# A low planting at the foot. Climber pods hung up the shaft read as
			# green seed cases on a stick, not as a vine.
			_deck_blob(pz, lat, Vector3(0.55, 0.42, 0.55), Color("3f6443").darkened(_rng.randf() * 0.15), 0.18, true)
	# Beams along the walk, running a little past the end posts.
	var span: float = z_b - z_a + 1.0
	for out in [inner, outer]:
		_deck_cube(z_mid, _platform_lateral(out, z_mid), Vector3(0.16, 0.26, span), timber.darkened(0.08), 0.0, HEIGHT)
	# Rafters across, overhanging both beams — the outer overhang reaches the
	# vista bench, so the seat the rider takes is in the shade.
	var width: float = outer - inner + 1.6
	var centre_out: float = (inner + outer) * 0.5
	var rz := z_a - 0.3
	while rz <= z_b + 0.31:
		_deck_cube(rz, _platform_lateral(centre_out, rz), Vector3(width, 0.18, 0.09), timber, 0.0, HEIGHT + 0.26)
		rz += 0.55
		if streamed and _slice_spent() and not await _keep_streaming():
			return
	# A creeper over the rafters: clumps of small leaf pads, bloom worked into
	# about half of them. The old pass scattered large flat mounds along the
	# roofline, which at the bench's eye height read as a row of eggs.
	for _i in 11:
		var vz: float = _rng.randf_range(z_a - 0.3, z_b + 0.3)
		var vo: float = _rng.randf_range(inner - 0.25, outer + 0.25)
		var blooming := _rng.randf() < 0.45
		for _k in _rng.randi_range(2, 4):
			var bz: float = vz + _rng.randf_range(-0.55, 0.55)
			var bo: float = vo + _rng.randf_range(-0.5, 0.5)
			var s: float = _rng.randf_range(0.2, 0.36)
			var col: Color = Color("486c44").darkened(_rng.randf() * 0.2)
			if blooming and _rng.randf() < 0.35:
				col = Color("a993cf").lerp(Color("d8cbe9"), _rng.randf() * 0.4)
			# Lumpy pads, not flat lenses: seen from the bench, straight up into
			# the sky, a flat leaf disc was a dark saucer on a beam.
			_deck_blob(
				bz, _platform_lateral(bo, bz),
				Vector3(s * 1.5, s * 0.85, s * 1.3), col, HEIGHT + 0.16 + _rng.randf() * 0.14, true
			)
		if streamed and _slice_spent() and not await _keep_streaming():
			return
	# Wisteria racemes: soft drapes wide at the rafter and narrowing to a tip,
	# enough of them that the canopy reads as hanging bloom rather than a
	# handful of ornaments.
	var wisteria := Color("a993cf")
	for _i in 32:
		var hz: float = _rng.randf_range(z_a, z_b)
		var ho: float = _rng.randf_range(inner + 0.2, outer - 0.2)
		var tint: Color = wisteria.lerp(Color("d8cbe9"), _rng.randf() * 0.55)
		_deck_raceme(hz, _platform_lateral(ho, hz), HEIGHT + 0.32, tint)
		if streamed and _slice_spent() and not await _keep_streaming():
			return
	# Lanterns hung off the rafters — the glow that reads as "sit here" at dusk.
	# Emissive glass only; the chunk's two real lights are spent on the walk.
	for lz in [z_a + 1.6, z_mid, z_b - 1.6]:
		var llat: float = _platform_lateral(centre_out, lz)
		_deck_cube(lz, llat, Vector3(0.04, 0.3, 0.04), Color("2a2e31"), 0.0, HEIGHT - 0.14)
		_deck_lamp(lz, llat, Vector3(0.2, 0.26, 0.2), LAMP_WARM, HEIGHT - 0.44)
	if streamed and _slice_spent() and not await _keep_streaming():
		return
	# Two benches under the canopy, facing the water between the posts — with
	# the vista bench at the canopy's edge that makes three seats in the shade.
	for bench_z in [z_a + 2.0, z_b - 2.2]:
		var bench_lat := _platform_lateral(outer - 0.75, bench_z)
		_deck_cube(bench_z, bench_lat, Vector3(0.5, 0.12, 1.9), stone, 0.0, -0.04)
		for leg in [-0.7, 0.7]:
			_deck_cube(bench_z + leg, bench_lat, Vector3(0.44, 0.36, 0.1), Color("3a3d42"), 0.0, 0.08)
		for slat in [-0.14, 0.0, 0.14]:
			_deck_cube(bench_z, bench_lat + _vp_side * slat, Vector3(0.11, 0.06, 1.8), timber.lightened(0.12), 0.0, 0.44)
	# A trough of bloom on the inner line so the frame sits in a garden —
	# on the parapet side it would crowd the vista bench it now shelters.
	var trough_lat := _platform_lateral(inner + 0.65, z_mid)
	_deck_cube(z_mid, trough_lat, Vector3(0.6, 0.42, 1.6), Color("b8ac98"), 0.0, -0.04)
	_deck_blob(z_mid, trough_lat, Vector3(0.55, 0.4, 1.4), Color("4a6a46"), 0.34, true)
	for k in 3:
		_deck_bloom_cluster(z_mid - 0.5 + float(k) * 0.5, trough_lat, bloom.lightened(0.05 * float(k)), 0.52, 3, 0.14)
	# Pots at both open ends, so the frame's thresholds are planted alike.
	for pz in [z_a + 0.9, z_b - 0.9]:
		var pot_lat: float = _platform_lateral(inner + 0.15, pz)
		_deck_cube(pz, pot_lat, Vector3(0.5, 0.5, 0.5), Color("b8ac98"), 0.0, -0.04)
		_deck_blob(pz, pot_lat, Vector3(0.46, 0.34, 0.46), Color("4a6a46"), 0.42, true)
		_deck_bloom_cluster(pz, pot_lat, bloom.lightened(0.08), 0.6, 4, 0.16)


func _deck_raceme(z: float, lateral: float, top: float, col: Color) -> void:
	## One hanging raceme: two or three overlapping drops tapering to a tip,
	## hung straight off the rafter. Beads on a visible thread — however many
	## and however tinted — read from the bench as eggs on strings; a drape
	## that is one continuous soft mass, darker at the stalk and pale at the
	## tip, is what a wisteria actually hangs as.
	var length: float = _rng.randf_range(0.42, 0.7)
	var drops: int = 3 if length > 0.55 else 2
	var reach: float = 0.0
	for k in drops:
		var f: float = float(k) / float(drops)
		var w: float = lerpf(0.22, 0.11, f) * _rng.randf_range(0.9, 1.1)
		var h: float = length / float(drops) * 1.55
		_deck_blob(
			z + _rng.randf_range(-0.03, 0.03),
			lateral + _vp_side * _rng.randf_range(-0.03, 0.03),
			Vector3(w, h, w * _rng.randf_range(0.85, 1.1)),
			col.darkened(0.12 * (1.0 - f)).lightened(0.1 * f),
			top - reach - h * 0.92,
			true
		)
		reach += h * 0.62


func _deck_bloom_cluster(
	z: float, lateral: float, col: Color, lift: float, count: int = 4, spread: float = 0.3
) -> void:
	## A tuft of small heads over a leaf mound. One bloom-sized ellipsoid is an
	## egg from the bench; a handful of beads of mixed sizes is a flower head.
	## Kept thumbnail-small and near the base hue — pale and fist-sized they
	## were eggs again whatever else was true.
	for _i in count:
		var s := _rng.randf_range(0.075, 0.13)
		_deck_blob(
			z + _rng.randf_range(-spread, spread),
			lateral + _vp_side * _rng.randf_range(-spread * 0.6, spread * 0.6),
			Vector3(s * 1.2, s, s * 1.2),
			col.lightened(_rng.randf() * 0.08),
			lift + _rng.randf_range(-0.02, 0.06),
			true
		)


func _build_platform_trees(streamed: bool = false) -> void:
	# Pines along the back of the platform, screening the carriageway.
	# Mountain is a screen of wind-shaped pine; forest and country keep the
	# wooded backstop.
	var centre := _vp_centre
	var reach: float = RoadPathGD.PLATFORM_HALF_LENGTH + 8.0
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
		if streamed and _slice_spent() and not await _keep_streaming():
			return
	# Two sentinel trees at the terrace ends — the silhouette that says this
	# is a belvedere and not a lay-by. They stand on the road side: planted
	# past the parapet they parked a dark canopy across the seated view.
	# Mountain leaves the view open.
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
		if streamed and _slice_spent() and not await _keep_streaming():
			return


func _lookout_tree(packed: PackedScene, z: float, lateral: float, height: float, node_name: String) -> void:
	## A kit tree grounded the way `_tree` grounds its own: footprint fitted to
	## the slope, then scaled from the kit's ten metres to the height asked for.
	## The sentinels stand beside the parking apron, so the planted canopy is
	## measured off the scene's own bounds and shifted until it clears the
	## corridor — same rule as the grown trees.
	var foot: float = clampf(height * 0.1, 0.35, 1.1)
	var scale := height / LOOKOUT_TREE_HEIGHT
	var tree: Node3D = packed.instantiate()
	var bounds := _scene_bounds(tree)
	var centre_local: Vector3 = bounds.get_center()
	# Horizontal half-diagonal of the kit's bounds — the same corner measure the
	# corridor check applies to the bucket meshes, so a canopy offset from the
	# trunk axis is counted at its real reach.
	var reach: float = Vector2(bounds.size.x, bounds.size.z).length() * 0.5 * scale
	for _attempt in 3:
		var rng_state: int = _rng.state
		var base: Vector3 = _ground_base_for_footprint(z, lateral, foot, foot) - _origin
		var centre: Vector3 = base + Vector3(centre_local.x, 0.0, centre_local.z) * scale + _origin
		var bottom: float = base.y + _origin.y + bounds.position.y * scale
		var push := _foliage_road_push(centre, reach, bottom)
		if push == 0.0:
			tree.transform = Transform3D(
				Basis(Vector3.UP, _rng.randf_range(0.0, TAU)).scaled(Vector3.ONE * scale), base
			)
			tree.name = node_name
			add_child(tree)
			return
		if is_inf(push):
			break
		lateral += push
		_rng.state = rng_state
	tree.free()


static func _scene_bounds(node: Node3D) -> AABB:
	## Combined local bounds of every mesh under `node`, in node space.
	var bounds := AABB()
	var found := false
	var meshes: Array[Node] = node.find_children("*", "MeshInstance3D", true, false)
	if node is MeshInstance3D:
		meshes.push_front(node)
	for mesh_node: Node in meshes:
		var mesh_instance := mesh_node as MeshInstance3D
		if mesh_instance.mesh == null:
			continue
		var local_frame := Transform3D.IDENTITY
		var ancestor: Node3D = mesh_instance
		while ancestor != node:
			local_frame = ancestor.transform * local_frame
			ancestor = ancestor.get_parent() as Node3D
		var a: AABB = local_frame * mesh_instance.get_aabb()
		bounds = a if not found else bounds.merge(a)
		found = true
	return bounds


func _platform_bloom() -> Color:
	## What the biome would actually grow in a trough: anemone in shade, heather
	## on the pass, gorse in the hedgerow country.
	match _vp_theme:
		Env.FOREST:
			return Color("c8c0ac")
		Env.MOUNTAIN:
			return Color("8a6a94")
	return Color("c8a83c")


func _build_platform_planting(streamed: bool = false) -> void:
	# A couple of stone planters at the ends, not a hedge across the view.
	var centre := _vp_centre
	var bloom := _platform_bloom()
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
		_deck_bloom_cluster(pz, plat, bloom, 0.6, 3, 0.28)
		if streamed and _slice_spent() and not await _keep_streaming():
			return
	# Troughs mid-terrace, flanking the centre, so the walk is a garden edge and
	# not only a place to stand the bike.
	for offset in [-7.5, 7.5]:
		var pz: float = centre + offset
		var plat: float = _platform_lateral(RoadPathGD.PLATFORM_HALF_WIDTH + 1.7, pz)
		_deck_cube(pz, plat, Vector3(1.3, 0.4, 0.62), Color("b8ac98"), 0.0, -0.04)
		_deck_blob(pz, plat, Vector3(1.15, 0.4, 0.52), Color("4a6a46"), 0.34, true)
		_deck_bloom_cluster(pz + 0.32, plat, bloom, 0.52, 4, 0.22)
		_deck_bloom_cluster(pz - 0.34, plat, bloom.lightened(0.1), 0.48, 3, 0.18)
	# Boulders and scrub on the back of the platform, screening the road.
	# The stones are dark and bedded a third of their height into the verge —
	# a smooth pale ball standing proud of the ground reads as an egg, not as
	# a rock, and the face's own pale stone tone was the worst offender.
	var reach: float = RoadPathGD.PLATFORM_HALF_LENGTH + 8.0
	for _i in 11:
		var z := centre + _rng.randf_range(-reach, reach)
		var out: float = -RoadPathGD.PLATFORM_HALF_WIDTH - _rng.randf_range(1.0, 4.0)
		var s := _rng.randf_range(0.7, 2.1)
		var flat: float = _platform_lateral(out, z)
		if _rng.randf() < 0.45:
			_deck_blob(
				z,
				flat,
				Vector3(s * 1.8, s * 0.55, s * 1.5),
				_face_base_color().lerp(Color("35322c"), 0.4).darkened(_rng.randf() * 0.18),
				-s * 0.26,
				false
			)
		else:
			_deck_blob(
				z,
				flat,
				Vector3(s * 1.7, s * 0.6, s * 1.5),
				(_pal["verge"] as Color).darkened(_rng.randf() * 0.28),
				-0.06,
				true
			)
		if streamed and _slice_spent() and not await _keep_streaming():
			return


func _build_belvedere(streamed: bool = false) -> void:
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
	# Built from the crag's own stone: a real belvedere wall is quarried from
	# the rock it stands on, and the fixed warm limestone used to read as a
	# third, unrelated material — salmon masonry over a moss-olive face under
	# a pale deck. Deriving from the scarp palette keeps one stone family from
	# parapet to waterline on every theme.
	var scarp := _face_scarp_palette()
	# The wall face is the biggest flat surface in the overlook frame and it
	# faces the key square on: scarp-stone at full value still renders as a
	# cream curtain across the whole front. Half a step into the soil band and
	# no lighten keeps it weathered masonry rather than a sunlit apron.
	var limestone: Color = (scarp["rock_hi"] as Color).lerp(scarp["soil"], 0.5)
	var mortar: Color = (scarp["rock_lo"] as Color).lerp(scarp["soil"], 0.5)
	var shadow: Color = scarp["seam"]
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
		if streamed and _slice_spent() and not await _keep_streaming():
			return
	if authored:
		await _belvedere_deck_pave(b, streamed)
		if streamed and not is_inside_tree():
			return
	_belvedere_ends(b, limestone, shadow)
	var mesh: MeshInstance3D = b.commit_to(self, "PlatformKerbs")
	if mesh:
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if _on_lake:
			# The wall's shadow faces are the darkest shape in the across view
			# — without the headland's own sky fill they render as a black slab
			# under the lip and the landed plinth still reads as hanging.
			mesh.layers = HEADLAND_FILL_LAYER
	if streamed and _slice_spent() and not await _keep_streaming():
		return
	if authored:
		await _build_authored_terrace(deck, rail, streamed)
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
		if streamed and _slice_spent() and not await _keep_streaming():
			return
	await _build_belvedere_railing(streamed)


func _build_authored_terrace(deck: PackedScene, rail: PackedScene, streamed: bool = false) -> void:
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
	# The kit's baked colours arrive as two more palettes: the flagstones pale
	# and the parapet salmon — a third and fourth material language on top of
	# the face and the wall. A gentle multiply still read as cream and rust, so
	# the tint has to fight the bake: pull red hard, lift blue, and the plaza,
	# parapet and crag land in the one weathered-stone family.
	# A second step down for the deck and the stone posts: neutral as they
	# were, under the day key the flags and the balcony's end post came out
	# cream — the brightest, sandiest thing in the seated frame, standing
	# right at its edge. Weathered grey keeps them stone and lets the view lead.
	await _place_lookout_run(
		deck, deck_zs, RoadPathGD.PLATFORM_HALF_WIDTH, TERRACE_FLOOR, "LookoutDeck", streamed,
		Color(0.48, 0.57, 0.70)
	)
	if streamed and not is_inside_tree():
		return
	if streamed and _slice_spent() and not await _keep_streaming():
		return
	await _place_lookout_run(rail, rail_zs, rail_out, TERRACE_FLOOR, "LookoutRail", streamed, Color(0.46, 0.68, 0.95))
	if balcony:
		_place_lookout(balcony, _vp_centre, rail_out, TERRACE_FLOOR, "LookoutBalcony", Color(0.42, 0.52, 0.64))
	# A pier at each end of the run, so the rail stops on something.
	var pier: PackedScene = _lookout_scene(LOOKOUT_PIER)
	if pier:
		for end in [-1.0, 1.0]:
			_place_lookout(
				pier, _vp_centre + end * (half + 1.0), rail_out, TERRACE_FLOOR,
				"LookoutPier_%d" % int(end), Color(0.42, 0.52, 0.64)
			)
			if streamed and _slice_spent() and not await _keep_streaming():
				return


func _place_lookout_run(
	packed: PackedScene,
	zs: Array[float],
	out: float,
	lift: float,
	node_name: String,
	streamed: bool = false,
	tint: Color = Color(1.0, 1.0, 1.0)
) -> void:
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
			if streamed and _slice_spent() and not await _keep_streaming():
				return
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
	var mat: Material = source.material_override
	if mat == null and source.mesh.get_surface_count() > 0:
		mat = source.mesh.surface_get_material(0)
	run.material_override = _tinted_kit_material(mat, tint)
	run.cast_shadow = source.cast_shadow
	add_child(run)
	proto.free()


func _place_lookout(
	packed: PackedScene, z: float, out: float, lift: float, node_name: String,
	tint: Color = Color(1.0, 1.0, 1.0)
) -> Node3D:
	## One kit piece `out` metres from the spur centreline, turned with the
	## overlook's side exactly as the benches are.
	var piece: Node3D = packed.instantiate()
	var flat: Basis = _path.frame_flat_at(z)
	piece.transform = Transform3D(
		Basis(flat.x * _vp_side, flat.y, flat.z * _vp_side), _p(z, _platform_lateral(out, z), -lift)
	)
	piece.name = node_name
	_tint_lookout_kit(piece, tint)
	add_child(piece)
	return piece


func _tint_lookout_kit(node: Node, tint: Color) -> void:
	## The kit pieces are single baked-material meshes: the only way to shift
	## their palette is an albedo multiply on a cloned material. Vertex colours
	## multiply with it, so a cool tint keeps each face's authored shading.
	if tint == Color(1.0, 1.0, 1.0):
		return
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			var mat: Material = mi.material_override
			if mat == null and mi.mesh != null and mi.mesh.get_surface_count() > 0:
				mat = mi.mesh.surface_get_material(0)
			mi.material_override = _tinted_kit_material(mat, tint)
		stack.append_array(n.get_children())


func _tinted_kit_material(mat: Material, tint: Color) -> Material:
	if tint == Color(1.0, 1.0, 1.0) or not (mat is StandardMaterial3D):
		return mat
	var tinted := (mat as StandardMaterial3D).duplicate() as StandardMaterial3D
	tinted.albedo_color = tinted.albedo_color * tint
	return tinted


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


func _build_belvedere_railing(streamed: bool = false) -> void:
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
		if streamed and _slice_spent() and not await _keep_streaming():
			return


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
			_p_flat(za, minf(a0, a1), -0.05), _p_flat(za, maxf(a0, a1), -0.05), _p_flat(zb, maxf(b0, b1), -0.05), _p_flat(zb, minf(b0, b1), -0.05), course.darkened(float(pair[2]))
		)
	# Joints sit a finger below the flags so they read as shadow, not paint.
	var j0: float = _platform_lateral(mid - 0.045, za)
	var j1: float = _platform_lateral(mid + 0.045, za)
	var k0: float = _platform_lateral(mid - 0.045, zb)
	var k1: float = _platform_lateral(mid + 0.045, zb)
	b.add_quad(
		_p_flat(za, minf(j0, j1), -0.028), _p_flat(za, maxf(j0, j1), -0.028), _p_flat(zb, maxf(k0, k1), -0.028), _p_flat(zb, minf(k0, k1), -0.028), course.darkened(0.24)
	)
	var e0: float = _platform_lateral(inner, zb)
	var e1: float = _platform_lateral(outer, zb)
	b.add_quad(
		_p_flat(zb - 0.10, minf(e0, e1), -0.028), _p_flat(zb - 0.10, maxf(e0, e1), -0.028), _p_flat(zb, maxf(e0, e1), -0.028), _p_flat(zb, minf(e0, e1), -0.028), course.darkened(0.24)
	)


func _p_flat(z: float, lateral: float, drop: float) -> Vector3:
	## A point on the flag plane: `_p` drapes every vert by its own terrain_drop,
	## and past the shelf lip that tips a "flat" flagstone onto its edge — the
	## cream slat curtain the across shots kept finding under the balcony.
	## Flagstones lie on a flat deck, so they keep their plan position but take
	## their height from the inner shelf band.
	var p := _p(z, lateral, drop)
	p.y = _p(z, _platform_lateral(RoadPathGD.PLATFORM_HALF_WIDTH + 0.5, z), drop).y
	return p


func _belvedere_deck_pave(b: LowPoly, streamed: bool = false) -> void:
	## Flags over the kit deck's top sheet. The authored slab is one flat tone
	## and at bench height it read as a poured apron — a blank pale plane under
	## the pergola. What goes down instead is a mortar bed a finger under the
	## stones, three courses across with a running bond, a little tonal drift
	## per flag, and a darker soldier course against the parapet. All of it
	## sits a few centimetres proud of the deck top, so nothing shares a plane
	## with the sheet it covers.
	##
	## Value is the whole battle here. Under the day key the flags' old midstone
	## overexposed to a single cream wash that hid even the joints; the stone is
	## a step deeper and cooler now, the joints a finger wider, and the border
	## course lands as a proper dark kerb line — the same reading the walk had
	## in the parapet shots, kept calm.
	var inner := RoadPathGD.PLATFORM_HALF_WIDTH + 0.30
	var outer := RoadPathGD.PLATFORM_HALF_WIDTH + TERRACE_RAIL_OUT - 0.10
	var z0 := _vp_centre - RoadPathGD.PLATFORM_HALF_LENGTH + 0.45
	var z1 := _vp_centre + RoadPathGD.PLATFORM_HALF_LENGTH - 0.45
	var mortar := Color("3b372f")
	var stone := Color("6b675b")
	var kerb := Color("4a463e")
	var m_i0 := _platform_lateral(inner, z0)
	var m_o0 := _platform_lateral(outer, z0)
	var m_i1 := _platform_lateral(inner, z1)
	var m_o1 := _platform_lateral(outer, z1)
	b.add_quad(
		_p_flat(z0, minf(m_i0, m_o0), -0.135), _p_flat(z0, maxf(m_i0, m_o0), -0.135),
		_p_flat(z1, maxf(m_i1, m_o1), -0.135), _p_flat(z1, minf(m_i1, m_o1), -0.135),
		mortar
	)
	# Three courses, the outer one a darker border against the rail foot. The
	# middle course runs half a flag off so the joints stagger like laid work.
	const FLAG := 1.34
	const JOINT := 0.15
	for ci in 3:
		var c_in := inner + float(ci) * 2.02
		var c_out := inner + 1.92 + float(ci) * 2.02 if ci < 2 else outer
		var border: bool = ci == 2
		var fz := z0 + (FLAG + JOINT) * 0.5 * float(ci == 1)
		while fz < z1 - 0.3:
			var fe: float = minf(fz + FLAG, z1)
			var a0: float = _platform_lateral(c_in, fz)
			var a1: float = _platform_lateral(c_out, fz)
			var b0: float = _platform_lateral(c_out, fe)
			var b1: float = _platform_lateral(c_in, fe)
			var jit := float(posmod(hash(Vector2i(int(round(fz * 2.0)), ci * 61 + 7)), 997)) / 997.0
			var wear := float(posmod(hash(Vector2i(int(round(fz * 3.0)) + 41, ci * 29 + 5)), 991)) / 991.0
			var col := stone.lightened(jit * 0.10 - 0.035)
			# The odd flag is a different stone entirely or ground down dark —
			# the scattered tone steps are what read as laid work instead of
			# vinyl sheet.
			if wear < 0.14:
				col = col.darkened(0.13)
			elif wear > 0.9:
				col = col.lightened(0.07)
			if border:
				col = kerb.lightened(jit * 0.08)
			b.add_quad(
				_p_flat(fz, minf(a0, a1), -0.15), _p_flat(fz, maxf(a0, a1), -0.15),
				_p_flat(fe, maxf(b0, b1), -0.15), _p_flat(fe, minf(b0, b1), -0.15),
				col
			)
			# Worn edge: a thin weathered line down one side of some flags —
			# a finger of shadow where the arris has gone.
			if wear >= 0.14 and wear < 0.34:
				var w0: float = _platform_lateral(c_in + 0.07, fz)
				var w1: float = _platform_lateral(c_in + 0.07, fe)
				b.add_quad(
					_p_flat(fz, minf(a0, w0), -0.152), _p_flat(fz, maxf(a0, w0), -0.152),
					_p_flat(fe, maxf(b1, w1), -0.152), _p_flat(fe, minf(b1, w1), -0.152),
					col.darkened(0.10)
				)
			fz += FLAG + JOINT
		if streamed and _slice_spent() and not await _keep_streaming():
			return
	# Kerb line: a narrow cap a knuckle proud along the rail foot, so the
	# pavement ends on an edge, not a fade.
	var k0: float = _platform_lateral(outer - 0.34, z0)
	var k1: float = _platform_lateral(outer - 0.34, z1)
	b.add_quad(
		_p_flat(z0, minf(k0, m_o0), -0.175), _p_flat(z0, maxf(k0, m_o0), -0.175),
		_p_flat(z1, maxf(k1, m_o1), -0.175), _p_flat(z1, minf(k1, m_o1), -0.175),
		kerb
	)
	# The balcony's floor is the same kit sheet — a bare eight-by-three metre
	# slab at the one place the view pulls the eye to. Run the same flagging
	# over it, with the kerb carried round its outer lip.
	var bc0 := _vp_centre - 4.05
	var bc1 := _vp_centre + 4.05
	var b_in := RoadPathGD.PLATFORM_HALF_WIDTH + TERRACE_RAIL_OUT - 0.42
	var b_out := RoadPathGD.PLATFORM_HALF_WIDTH + TERRACE_RAIL_OUT + 3.18
	var bi0 := _platform_lateral(b_in, bc0)
	var bo0 := _platform_lateral(b_out, bc0)
	var bi1 := _platform_lateral(b_in, bc1)
	var bo1 := _platform_lateral(b_out, bc1)
	b.add_quad(
		_p_flat(bc0, minf(bi0, bo0), -0.135), _p_flat(bc0, maxf(bi0, bo0), -0.135),
		_p_flat(bc1, maxf(bi1, bo1), -0.135), _p_flat(bc1, minf(bi1, bo1), -0.135),
		mortar
	)
	var pz := bc0
	while pz < bc1 - 0.25:
		var pe: float = minf(pz + FLAG, bc1 - 0.12)
		var a0: float = _platform_lateral(b_in + 0.08, pz)
		var a1: float = _platform_lateral(b_out - 0.42, pz)
		var a0e: float = _platform_lateral(b_in + 0.08, pe)
		var a1e: float = _platform_lateral(b_out - 0.42, pe)
		var jit := float(posmod(hash(Vector2i(int(round(pz * 2.0)) + 11, 53)), 997)) / 997.0
		var wear := float(posmod(hash(Vector2i(int(round(pz * 3.0)) + 71, 23)), 991)) / 991.0
		var col := stone.lightened(jit * 0.10 - 0.035)
		if wear < 0.14:
			col = col.darkened(0.13)
		elif wear > 0.9:
			col = col.lightened(0.07)
		b.add_quad(
			_p_flat(pz, minf(a0, a1), -0.15), _p_flat(pz, maxf(a0, a1), -0.15),
			_p_flat(pe, maxf(a0e, a1e), -0.15), _p_flat(pe, minf(a0e, a1e), -0.15),
			col
		)
		pz += FLAG + JOINT
	# Its lip takes the border stone, so the balcony reads as the same laid
	# work running out to its edge.
	var l0: float = _platform_lateral(b_out - 0.34, bc0)
	var l1: float = _platform_lateral(b_out - 0.34, bc1)
	var e0: float = _platform_lateral(b_out, bc0)
	var e1: float = _platform_lateral(b_out, bc1)
	b.add_quad(
		_p_flat(bc0, minf(l0, e0), -0.15), _p_flat(bc0, maxf(l0, e0), -0.15),
		_p_flat(bc1, maxf(l1, e1), -0.15), _p_flat(bc1, minf(l1, e1), -0.15),
		kerb
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
		_p(za, in_a, -cap), _p(za, out_a, -cap), _p(zb, out_b, -cap), _p(zb, in_b, -cap), limestone.lightened(0.07)
	)
	# Inner face, toward the parking.
	_wall_face(b, za, zb, lip_a, lip_b, 0.0, -cap, mortar)
	_wall_face(b, za, zb, face_a, face_b, -cap, 2.4, limestone)
	_wall_face(b, za, zb, face_a, face_b, 2.4, WALL, shadow)
	# Where the headland chord keeps falling past the made ground, three metres
	# of skirt ends in the air — from the water each segment was a board
	# hanging off the lip, the slat curtain the across shots kept finding. Run
	# the face on down to the drawn chord so the masonry lands. It is not the
	# parapet's black underside band though: a plinth this tall is masonry in
	# open shade, painted a step off the limestone so the face reads as stone
	# and not as the same near-black slab it was meant to fix.
	var toe_a := _belvedere_toe(za, face_a)
	var toe_b := _belvedere_toe(zb, face_b)
	if toe_a > WALL + 0.05 or toe_b > WALL + 0.05:
		var plinth := limestone.lerp(shadow, 0.45)
		b.add_quad(
			_p(za, face_a, WALL), _p(zb, face_b, WALL), _p(zb, face_b, toe_b), _p(za, face_a, toe_a), plinth
		)
		b.add_quad(
			_p(za, face_a, toe_a), _p(zb, face_b, toe_b), _p(zb, face_b, WALL), _p(za, face_a, WALL), plinth.darkened(0.08)
		)
		# A course line part-way down gives the drop masonry scale — one long
		# unjointed curtain is what read as a board curtain in the first place.
		var mid_a: float = WALL + (toe_a - WALL) * 0.45
		var mid_b: float = WALL + (toe_b - WALL) * 0.45
		b.add_quad(
			_p(za, face_a, mid_a), _p(zb, face_b, mid_b), _p(zb, face_b, mid_b + 0.4), _p(za, face_a, mid_a + 0.4),
			plinth.darkened(0.14)
		)
	# Underside, so the shelf has a bottom when seen from the drop. Where the
	# plinth runs it into the slope the same quad reads as a footing course.
	b.add_quad(
		_p(za, in_a, WALL), _p(zb, in_b, WALL), _p(zb, out_b, WALL), _p(za, out_a, WALL), shadow.darkened(0.15)
	)


func _belvedere_toe(z: float, face_lat: float) -> float:
	## How far below deck level the parapet's shadow face may run before it
	## lands on the drawn face — measured on the chord the skin is built from,
	## since the wall has to meet the surface the eye sees, not the made ground
	## under the deck. Off the headland profile the platform stands on that
	## ground and the stock three metres is all it needs.
	var prof := _face_profile(z)
	if prof.is_empty() or not _face_is_face(prof):
		return 3.0
	var deck_y: float = _p(z, face_lat, 0.0).y + _origin.y
	var chord_y: float = _face_chord_point(z, absf(face_lat)).y + _origin.y
	return clampf(deck_y - chord_y + 0.5, 3.0, 30.0)


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
		var toe := _belvedere_toe(z, c)
		b.add_quad(_p(z, a, -top), _p(z, c, -top), _p(z, c, toe), _p(z, a, toe), limestone.lerp(shadow, 0.35))


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
				# Near-neutral gravel. The old warm brown caught the low key
				# square-on and graded into the neon orange ribbon riders read
				# as the fence; the light supplies the warmth by itself. Greyed
				# further and darkened a step — anything warmer or paler still
				# renders as a sand strip beside the tarmac in day light.
				"shoulder": Color("64655f"),
				# Stone lip, not loam — the warm brown lip flat-shaded itself
				# into a second orange ribbon hugging the edge line.
				"curb": Color("64655e"),
				"verge": Color("5f7138"),
				"ground": Color("4d6638"),
				"ground_alt": Color("304d39"),
				# Weathered grey timber. The old brown carried just enough warm
				# bias for the golden key and the 1.14 saturation grade to stack
				# into a neon orange rail; a near-neutral grey leans a hair cool
				# so the same light lands on it as silvery wood.
				"rail": Color("53595c"),
				"prop_a": Color("315e3e"),
				# 70462e rendered as orange-rust litter anywhere it landed —
				# dark earth-moss instead.
				"prop_b": Color("4a4c38"),
				"prop_c": Color("234b3b"),
				"accent": Color("d7a84f"),
				"glow": Color(2.2, 2.4, 1.5),
			}
		Env.MOUNTAIN:
			# The mountain reads as green *or* as rock, and the interest is in the
			# alternation between them — a hillside is moss where water sits and
			# bare scree where it does not. Blending green into a slightly bluer
			# green, as this did, cannot produce that; it only produces mush.
			return {
				"road": ROAD_TARMAC,
				"stripe": Color("e6ddb8"),
				"shoulder": Color("66645e"),
				"curb": Color("6f6a63"),
				"verge": Color("5c6b3f"),
				"ground": Color("4a5940"),  # moss and alpine turf
				"ground_alt": Color("6a5e4e"),  # bare scree breaking through
				"rail": Color("9aa1a7"),  # galvanised, dimmed a step off the cream
				"prop_a": Color("2b5140"),  # spruce
				"prop_b": Color("8a5a34"),  # larch and rust
				"prop_c": Color("7d8794"),  # cold granite
				"accent": Color("d45a36"),
				"glow": Color(2.4, 1.8, 1.2),
			}
		Env.COUNTRY:
			# Green pasture against deeper grazing. The old olive verge and meadow
			# sat barely past G=R, so the warm day key pushed every hedge, verge and
			# field to the same sandy yellow-green — the "small bush sandy biome".
			# Everything vegetal now keeps G well ahead of R so it stays green under
			# that key; the warm grade supplies the warmth, the albedo supplies green.
			return {
				"road": ROAD_TARMAC,
				"stripe": Color("efe6bc"),
				# A thin cool gravel at the tarmac edge — sandy grit under a golden
				# key was the tan ribbon the rider read as the verge itself.
				"shoulder": Color("586553"),
				"curb": Color("556050"),
				"verge": Color("4f7a31"),  # lush verge grass
				# Two pasture greens: meadow against grazed-down turf, far enough
				# apart in value to read as patchwork without a gold in sight.
				"ground": Color("5b8339"),  # open meadow
				"ground_alt": Color("43642e"),  # grazed pasture
				# Weathered fence timber, dark enough that the toon-lit top face
				# stays grey-brown instead of blooming to cream under the key.
				"rail": Color("5f635a"),
				"prop_a": Color("3d6031"),  # hedgerow green
				"prop_b": Color("a74e32"),  # brick and rust
				# d8b96a lightened bloomed to cream — a dune field where the QA
				# wanted hay. Deeper gold keeps the one straw note as straw.
				"prop_c": Color("a68a45"),  # cut hay — the bales keep the one straw note
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
