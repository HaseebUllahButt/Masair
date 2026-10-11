extends Node3D
## Distant range that follows the rider's position but never their heading, so
## it cannot be approached. Each layer wraps one *real* 360° skyline — a
## horizon panorama raycast from DEM elevation data (`MtnProfiles`, see
## `scripts/mtn_profiles.gd`) — lofted as scree / mid-slope / crest shelves.
##
## Two rules this file exists to obey, both learnt the hard way:
##
## 1. **Real skylines, never tents.** No arrangement of jittered tents reads
##    as mountains — every attempt lands back on cones. A ridgeline raycast
##    from real terrain carries what cannot be authored by hand: asymmetric
##    massifs, cols at odd intervals, serrated arêtes, a hero peak that owns
##    a sector. Each ring borrows a different valley's horizon so the layers
##    stay independent ranges, and the ring seam inherits the panorama's own
##    continuity.
## 2. **Enough silhouette to fill a lens.** The riding camera is ~110°
##    horizontal on 16:9. Real panoramas keep several named summits in that
##    window at every heading; the profile carries 0.5° of arc per sample, so
##    even the 128-segment far ring samples real serration, not noise.

const RangeMaterial := preload("res://scripts/range_material.gd")
const CLOUD_SHADER: Shader = preload("res://shaders/horizon_cloud.gdshader")
const LowPoly := preload("res://scripts/low_poly.gd")
const MtnProfiles := preload("res://scripts/mtn_profiles.gd")

## Riding camera far clip. Layers sit inside this. Far enough that a fourth
## range can rise behind the near foothills without being sliced by the lens.
const CLIP_FAR := 2800.0
const FOOT_Y := -160.0

const GRIT_BLOCK := 8

## Four visible shelves are enough once the fragment shader owns the rock
## texture. The old six-shelf loft spent most of its triangles below the mist,
## where they contributed no readable form. The camera is always inside the
## ring, so the outward-facing backslope was culled anyway: it was pure cost.
const FACE_G := [0.42, 0.29, 0.16, 0.06, 0.00]
const FACE_F := [0.00, 0.22, 0.48, 0.76, 1.00]

const LAYERS := [
	{
		"radius": 1460.0,
		"face": 360.0,
		"high": 300.0,
		"segments": 256,
		"haze": 0.05,
		## No collar on the foothills. At fifteen hundred metres a puff sized
		## for a summit is a quarter of the lens, and it arrived as a pale sheet
		## smeared across the nearest faces rather than as cloud.
		"clouds": false,
		"phase": 0.11,
		## Keswick fells: the nearest ring is a Lake District skyline —
		## rolling tops, no horns.
		"profile": "fells",
		"floor": 0.20,
	},
	{
		"radius": 1760.0,
		"face": 320.0,
		"high": 450.0,
		"segments": 208,
		"haze": 0.24,
		"clouds": true,
		"phase": 0.47,
		"profile": "cortina",
		"floor": 0.13,
	},
	{
		"radius": 2080.0,
		"face": 270.0,
		"high": 650.0,
		"segments": 160,
		"haze": 0.45,
		"clouds": true,
		"phase": 0.83,
		"profile": "banff",
		"floor": 0.10,
	},
	{
		"radius": 2430.0,
		"face": 230.0,
		"high": 900.0,
		"segments": 128,
		"haze": 0.66,
		"clouds": false,
		"phase": 0.29,
		"profile": "chamonix",
		"floor": 0.08,
	},
]

var _player: Node3D
var _range_mat: ShaderMaterial
var _cloud_mat: ShaderMaterial
var _peaks: Array[Dictionary] = []
## Vertex → smoothed normal for the front of the layer being built.
var _front_normals: Dictionary = {}


func _ready() -> void:
	## The ring teleports with the bike. Interpolating that jump is the
	## "R flies me across the lake" restart: the camera snaps, then two
	## kilometres of skyline ease from the bench to kilometre zero.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_player = get_parent().get_node_or_null("Player") as Node3D
	_range_mat = RangeMaterial.ring()
	_cloud_mat = ShaderMaterial.new()
	_cloud_mat.shader = CLOUD_SHADER
	for i in LAYERS.size():
		_build_layer(i)
	_build_clouds()
	_follow_player()
	var game := get_node_or_null("/root/GameManager")
	if game and game.has_signal("restarted"):
		game.restarted.connect(_follow_player)


func _process(_delta: float) -> void:
	_follow_player()


func apply_mood(mood: Dictionary) -> void:
	## The ranges' colours live with the material, which the overlooks share.
	RangeMaterial.apply_mood(mood)
	if _cloud_mat:
		var lit: Color = mood.get("cloud_lit", Color("f4b07d"))
		var dark: Color = mood.get("cloud_dark", Color("413b58"))
		## Barely lightened. Pushed most of the way to white the collar stopped
		## being vapour lit by the sunset and became a lens of grey plastic.
		_cloud_mat.set_shader_parameter("cloud_lit", lit.lerp(Color.WHITE, 0.16))
		_cloud_mat.set_shader_parameter("cloud_dark", dark)
		_cloud_mat.set_shader_parameter("opacity", 0.27)


func _follow_player() -> void:
	if _player == null:
		return
	global_position = _player.global_position
	## The ring is a skybox the rider cannot approach, and that includes the
	## overlooks: it stays put, the same size and the same haze, when the rider
	## stops. Dithering it out on the spur made the distant mountains dissolve
	## into dots and then vanish entirely on the climb — the authored lake
	## range is built to interleave with the ring, not to replace it.


func _build_layer(index: int) -> void:
	var layer: Dictionary = LAYERS[index]
	var segments := int(layer["segments"])
	var high := float(layer["high"])
	var haze := float(layer["haze"])
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var samples: Array[Dictionary] = []
	for s in segments:
		var angle := TAU * float(s) / float(segments)
		samples.append(_sample(angle, layer))
	_smooth_front_normals(samples)
	for s in segments:
		var a: Dictionary = samples[s]
		var b: Dictionary = samples[(s + 1) % segments]
		## Grit is drawn per *block* of segments, not per segment. One segment
		## is a couple of degrees of arc; giving each its own tone flutes the
		## face into vertical corduroy, which is the same mistake
		## `RANGE_STEP`'s comment records at the overlooks. A block is a scree
		## patch a few degrees across — and it eases into the next one. Held
		## constant and cut at the block edge, each patch was a hard-sided
		## rectangle of its own tone, and from an overlook, where the lens is
		## narrower and the ring fills it, those read as a row of curtains.
		var blocks: int = maxi(segments / GRIT_BLOCK, 1)
		var blk: int = s / GRIT_BLOCK
		var blend: float = smoothstep(0.0, 1.0, float(s % GRIT_BLOCK) / float(GRIT_BLOCK))
		_loft_span(
			surface, a, b, high, haze, index * 2003 + blk * 13, index * 2003 + ((blk + 1) % blocks) * 13, blend, s
		)
	var mesh := MeshInstance3D.new()
	mesh.name = "Range%d" % index
	mesh.mesh = surface.commit()
	mesh.material_override = _range_mat
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh.extra_cull_margin = 280.0
	mesh.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	mesh.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(mesh)
	if bool(layer["clouds"]):
		_collect_peaks(layer, samples, segments)


func _smooth_front_normals(samples: Array[Dictionary]) -> void:
	## One normal per front vertex, from the surface around it, shared by every
	## facet that touches it.
	##
	## Each column of the front used to shade with its own flat face normal. A
	## column is a couple of degrees of arc, and neighbours face the sun at
	## slightly different angles, so the face broke into a row of vertical light
	## and dark stripes — small on the ride, and curtains from an overlook where
	## the lens is narrower and the ring fills it. The overlook ranges take their
	## normals the same way and read as one folded surface.
	_front_normals.clear()
	var count := samples.size()
	for s in count:
		var band: Array = samples[s]["band"]
		var prev: Array = samples[(s - 1 + count) % count]["band"]
		var next: Array = samples[(s + 1) % count]["band"]
		var inward := -(samples[s]["out"] as Vector3)
		var last := band.size() - 1
		for k in band.size():
			var along: Vector3 = (next[k] as Vector3) - (prev[k] as Vector3)
			var up: Vector3 = (band[mini(k + 1, last)] as Vector3) - (band[maxi(k - 1, 0)] as Vector3)
			var n := along.cross(up)
			if n.length_squared() < 1e-8:
				continue
			n = n.normalized()
			_front_normals[band[k]] = -n if n.dot(inward) < 0.0 else n


func _sample(angle: float, layer: Dictionary) -> Dictionary:
	var radius := float(layer["radius"])
	var face := float(layer["face"])
	var high := float(layer["high"])
	var phase := float(layer["phase"])
	## The skyline is a real panorama raycast from DEM data (mtn_profiles.gd):
	## each layer wraps a different valley viewpoint's actual horizon — real
	## cols, real asymmetric massifs, real serrated crests. Tent envelopes
	## always read as cones no matter how they are jittered; a real ridgeline
	## is a chain of named summits connected by arêtes, and this is what the
	## eye has been missing all along.
	var prof: Dictionary = MtnProfiles.ALL[String(layer["profile"])]
	var data: Array = prof["profile"]
	var n := data.size()
	var t := (angle + float(layer.get("rot", 0.0))) / TAU * float(n)
	var i0 := int(t) % n
	var i1 := (i0 + 1) % n
	var h_app := lerpf(float(data[i0]), float(data[i1]), t - floorf(t)) / 255.0
	## Peak the profile a touch: real panoramas carry long mid-height plateau
	## arcs (summit domes, tableland) that read as mesas under the flat loft,
	## while the eye expects crests and cols. A mild gamma deepens the cols
	## and keeps the hero arcs at full height.
	h_app = pow(h_app, 1.08)
	## A real valley has gaps — but a ring that falls to the flat horizon
	## reads as a hole in the world, so each layer keeps its own minimum
	## skyline: rolling on the near fells, a thin saw on the far heroes.
	var body := clampf(maxf(h_app, float(layer.get("floor", 0.035))), 0.0, 1.0)
	## Two teeth on top of the profile: a slow 15-degree wave so a real
	## plateau crest (Mont Blanc's summit dome, a tableland rim) arrives as a
	## serrated ridge rather than a draughted straight edge, and a fine
	## gendarme tooth for the sparkle the 0.5-degree profile cannot carry.
	var crest := clampf(
		body + (
			0.028 * sin(angle * 23.0 + phase * 3.1)
			+ 0.045 * absf(sin(angle * 47.0 + phase * 5.7))
		) * body,
		0.0, 1.0
	)
	var height: float = high * crest
	## Real skylines carry no depth, so the radial pull is synthesised: high
	## crest advances toward the rider, low cols recede — the opposite of a
	## ruled cylinder and the reason a chain reads as folded country rather
	## than a round wall. Slow bows keep whole sectors breathing.
	var pull := (body - 0.42) * face * 0.34
	var fold: float = (
		42.0 * sin(angle * 3.0 + phase * 2.2)
		+ 22.0 * sin(angle * 7.0 + phase * 1.1)
	)
	var out := Vector3(cos(angle), 0.0, sin(angle))
	var r: float = radius + pull + fold
	## Ribs and gullies, each break on its own frequency and phase, and each
	## scaled by however much room it has between its neighbours so the face
	## can never fold back through itself.
	var last: int = FACE_G.size() - 1
	var rise: float = high * body - FOOT_Y
	var band: Array[Vector3] = []
	for k in FACE_G.size():
		var g := float(FACE_G[k])
		var f := float(FACE_F[k])
		if k > 0 and k < last:
			var room_g: float = minf(
				float(FACE_G[k - 1]) - g, g - float(FACE_G[k + 1])
			)
			var room_f: float = minf(
				f - float(FACE_F[k - 1]), float(FACE_F[k + 1]) - f
			)
			var kf := float(k)
			## Frequencies stay well under the segment count. Ribs the eye can
			## follow, not noise the ring cannot sample.
			## Modest against the radius, generous against the height. Radial
			## noise as big as a break's own horizontal run tips facets flat,
			## and a flat facet high on a peak is where the ice lands.
			g += room_g * 0.32 * sin(angle * (7.0 + 2.6 * kf) + phase * (1.7 + 0.9 * kf)) * body
			f += room_f * 0.52 * sin(angle * (9.0 + 3.1 * kf) + phase * (2.3 + 1.3 * kf)) * body
			band.append(out * (r - face * g) + Vector3(0.0, FOOT_Y + rise * f, 0.0))
		elif k == last:
			band.append(out * r + Vector3(0.0, height, 0.0))
		else:
			band.append(out * (r - face * g) + Vector3(0.0, FOOT_Y, 0.0))
	## Decoupling the slopes from the crest means a deep notch in the skyline
	## can drop the summit below a shelf that is still riding the smooth
	## envelope. Walk down from the crest and keep the breaks in order; without
	## it the face turns itself inside out in the cols.
	for k in range(last - 1, 0, -1):
		var p: Vector3 = band[k]
		p.y = clampf(p.y, FOOT_Y, float((band[k + 1] as Vector3).y) - 4.0)
		band[k] = p
	return {
		"angle": angle,
		"out": out,
		"height": height,
		"band": band,
		"crest": band[last],
	}


func _loft_span(
	surface: SurfaceTool,
	a: Dictionary,
	b: Dictionary,
	high: float,
	haze: float,
	block: int,
	next_block: int,
	blend: float,
	step: int
) -> void:
	## Always loft. Skipping a low col punched a hole in the ring, and the
	## dusk sky showed through as a beige strip at the sides of the lens.
	var inward := -((a["out"] as Vector3) + (b["out"] as Vector3))
	## Every break on the front gets its own quad. One quad from foot to summit
	## is a card, and a card is what a backlit dusk turns into a black triangle.
	var ba: Array = a["band"]
	var bb: Array = b["band"]
	for k in ba.size() - 1:
		_quad(
			surface,
			ba[k],
			bb[k],
			bb[k + 1],
			ba[k + 1],
			inward,
			high,
			haze,
			lerpf(_hash(block + k * 5 + 3), _hash(next_block + k * 5 + 3), blend),
			(step + k) % 2 == 1
		)


func _quad(
	surface: SurfaceTool,
	p0: Vector3,
	p1: Vector3,
	p2: Vector3,
	p3: Vector3,
	hint: Vector3,
	high: float,
	haze: float,
	grit: float,
	flip: bool
) -> void:
	## Both triangles take the same tone, and the diagonal alternates.
	##
	## These quads are deliberately not planar, so the two triangles carry
	## different normals and light differently — that is where a lot of the
	## rock's texture comes from. But cut every one of them corner-to-corner the
	## same way and those pairs line up into a wide facet and a narrow one,
	## repeating right across the hillside: the fluting that survived a finer
	## ring, a coarser ring, block tone and three shading rewrites, because none
	## of those touched the triangulation. Alternating the cut scatters the same
	## pairs into a lattice.
	# The quad is intentionally non-planar, but both triangles belong to the
	# same distant mountain facet. Share their averaged normal so the diagonal
	# cannot light as a checkerboard.
	var face_normal := (p1 - p0).cross(p2 - p0) + (p2 - p0).cross(p3 - p0)
	if flip:
		_facet(surface, p1, p2, p3, hint, high, haze, grit, face_normal)
		_facet(surface, p1, p3, p0, hint, high, haze, grit, face_normal)
	else:
		_facet(surface, p0, p1, p2, hint, high, haze, grit, face_normal)
		_facet(surface, p0, p2, p3, hint, high, haze, grit, face_normal)


func _facet(
	surface: SurfaceTool,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	hint: Vector3,
	high: float,
	haze: float,
	grit: float,
	face_normal: Vector3 = Vector3.ZERO
) -> void:
	var normal := face_normal
	if normal.length_squared() < 0.0001:
		normal = (b - a).cross(c - a)
	if normal.length_squared() < 0.0001:
		return
	normal = normal.normalized()
	if normal.dot(hint) < 0.0:
		normal = -normal
	# Godot's front-face winding is opposite the geometric normal used by this
	# mesh. Reverse each triangle exactly once, after orienting the shading
	# normal; a conditional swap left the inward slopes in culled order.
	var tmp := b
	b = c
	c = tmp
	var mid: Vector3 = (a + b + c) / 3.0
	var lift := clampf(mid.y / maxf(high, 1.0), 0.0, 1.0)
	var span := (maxf(a.y, maxf(b.y, c.y)) - minf(a.y, minf(b.y, c.y))) / maxf(high, 1.0)
	## One snow value for the whole facet. Per-vertex snow on a tall side face
	## interpolates into a white streak down the mountain — that was the left
	## and right of the last screenshot. Only compact, high, upward faces cap.
	var snow := 0.0
	if span < 0.20:
		snow = clampf(
			smoothstep(0.86, 0.97, lift) * smoothstep(0.28, 0.55, normal.y),
			0.0,
			1.0
		)
	surface.set_smooth_group(-1)
	var vi := 0
	for p in [a, b, c]:
		var v_lift := clampf(p.y / maxf(high, 1.0), 0.0, 1.0)
		# The patch tone, and nothing per vertex. A random value on every corner
		# of a column two degrees wide and a hundred metres tall is a tall thin
		# gradient, and side by side those were the vertical streaks that ran
		# through every face — curtains, from an overlook. Tone variation that
		# the eye should read lives in the patch blend and in the shader's noise.
		var v_grit := clampf(grit, 0.0, 1.0)
		# The smoothed front normal where this vertex has one and the facet is on
		# the same side; the backslope keeps its own.
		var v_normal: Vector3 = _front_normals.get(p, normal)
		surface.set_normal(v_normal if v_normal.dot(normal) > 0.0 else normal)
		surface.set_color(Color(snow, v_grit, v_lift, haze))
		surface.add_vertex(p)
		vi += 1


func _collect_peaks(layer: Dictionary, samples: Array[Dictionary], segments: int) -> void:
	## Clouds hang off the summits the real skyline actually planted: scan the
	## built ridgeline for local maxima and drop a collar on every summit that
	## stands clear of its neighbours, read back from the mesh so the wisp
	## sits on the crest it ended up with — radial pull, teeth and all.
	var high := float(layer["high"])
	for s in segments:
		var at: Dictionary = samples[s]
		var crest: Vector3 = at["crest"]
		if crest.y < maxf(160.0, high * 0.45):
			continue
		var prev: Vector3 = samples[(s - 1 + segments) % segments]["crest"]
		var next: Vector3 = samples[(s + 1) % segments]["crest"]
		if crest.y < prev.y or crest.y <= next.y:
			continue
		## A summit, not a tooth: it has to still stand proud a dozen segments
		## out either side, or every wave in the crest collects its own wisp.
		var wide_a: Vector3 = samples[(s - 12 + segments) % segments]["crest"]
		var wide_b: Vector3 = samples[(s + 12) % segments]["crest"]
		if crest.y < maxf(wide_a.y, wide_b.y) + 6.0:
			continue
		_peaks.append({
			"out": at["out"],
			"radius": Vector3(crest.x, 0.0, crest.z).length(),
			"height": crest.y,
			"face": float(layer["face"]),
			"phase": float(layer["phase"]) + s,
		})


func _build_clouds() -> void:
	var xforms: Array[Transform3D] = []
	var cols: Array[Color] = []
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	for peak in _peaks:
		var phase := float(peak["phase"])
		var radius := float(peak["radius"])
		var height := float(peak["height"])
		var face := float(peak["face"])
		var out: Vector3 = peak["out"]
		var angle: float = atan2(out.z, out.x)
		## A thin wind-brushed wisp, not a stack of plates. Three narrow cards
		## overlap above the actual crest; their shader tears the edges and drops
		## to zero before the quad boundary, so no saucer can appear in the sky.
		var metre: float = clampf(height * 0.20, 70.0, 130.0)
		for k in 3:
			var f := float(k)
			var around: float = (f - 1.0) * 0.095 + sin(phase + f * 1.3) * 0.024
			var a: float = angle + around
			var lift: float = height * (0.92 + 0.05 * sin(phase * 1.1 + f * 2.0)) + metre * 0.12
			## Pulled in off the crest line so the wisp overlaps the face it
			## belongs to rather than hovering in clear air in front of it.
			var at: float = radius - face * (0.12 + 0.16 * _hash(int(phase * 97.0) + k))
			var pos := Vector3(cos(a) * at, lift, sin(a) * at)
			var wide: float = metre * (1.45 + 0.35 * sin(phase + f * 0.8))
			var tall: float = metre * (0.34 + 0.10 * sin(phase * 1.3 + f))
			var basis := _billboard_at(pos).scaled(Vector3(wide, tall, 1.0))
			xforms.append(Transform3D(basis, pos))
			cols.append(
				Color(
					0.5 + 0.5 * sin(phase + f * 1.6),
					0.5 + 0.5 * sin(phase * 1.7 + f),
					1.0,
					0.30 + 0.18 * absf(sin(phase * 0.9 + f))
				)
			)
	if xforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = quad
	LowPoly.fill_multimesh(mm, xforms, cols)
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Clouds"
	mmi.multimesh = mm
	mmi.material_override = _cloud_mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.visibility_range_end = 0.0
	mmi.extra_cull_margin = 400.0
	mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	mmi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(mmi)


func _billboard_at(pos: Vector3) -> Basis:
	if pos.length_squared() < 0.001:
		return Basis.IDENTITY
	return Basis.looking_at(pos, Vector3.UP)


func _hash(i: int) -> float:
	return fposmod(sin(float(i) * 12.9898) * 43758.5453, 1.0)
