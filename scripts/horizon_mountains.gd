extends Node3D
## Distant range that follows the rider's position but never their heading, so
## it cannot be approached. Each layer is one continuous ridgeline built the way
## the overlooks build theirs (`RoadChunk._range_sample`): the upper *envelope*
## of many overlapping alpine tents — heroes, shoulders, foothills and spurs —
## lofted as scree / mid-slope / crest / backslope.
##
## Two rules this file exists to obey, both learnt the hard way:
##
## 1. **Envelope, never a sum, never a floor term.** Summed tents stack past the
##    layer top and clamp flat where they overlap; a floor term fills the cols.
##    Either one gives a mesa with paper fins glued to it.
## 2. **Enough massifs to fill a lens.** The riding camera is 78° *vertical* on
##    16:9, which is roughly 110° horizontal. Seven massifs around 360° puts two
##    of them in that window and two tents in a window is a pair of pyramids, no
##    matter how the tents themselves are shaped. Seventeen on the near ring puts
##    five primaries plus their spurs in front of the rider.

const RANGE_SHADER: Shader = preload("res://shaders/horizon.gdshader")
const CLOUD_SHADER: Shader = preload("res://shaders/horizon_cloud.gdshader")

## Riding camera far clip. Kept at the original 2200 m window so the scenic
## spur does not draw three kilometres of set piece. Layers sit inside this.
const CLIP_FAR := 2200.0
const FOOT_Y := -160.0

## Relative summit heights walked around the ring. Written out rather than
## rolled so the composition is designed: hero, col, shoulder, foothill, hero.
## Thirteen entries is prime against every massif count below, so the rhythm
## never lines up with itself and no two sectors of the horizon are twins.
const RHYTHM := [1.00, 0.42, 0.78, 0.48, 0.92, 0.38, 0.70, 0.52, 0.88, 0.44, 0.66, 0.50, 0.82]
## Neighbours overlap just enough for a col, not enough to fill into a wall.
const REACH := 1.02
const GRIT_BLOCK := 4

## Scree starts near the crest line so the ring is not an inner wall. A deep
## inset was a beige cylinder you could see out the sides of the lens.
const FACE_G := [0.38, 0.28, 0.18, 0.10, 0.04, 0.00]
const FACE_F := [0.00, 0.22, 0.42, 0.62, 0.80, 1.00]

const LAYERS := [
	{
		"radius": 1520.0,
		"face": 300.0,
		"high": 380.0,
		"count": 17,
		"segments": 144,
		"haze": 0.08,
		"clouds": true,
		"phase": 0.11,
		"sharp": 0.88,
		"beat": 0,
	},
	{
		"radius": 1760.0,
		"face": 250.0,
		"high": 300.0,
		"count": 15,
		"segments": 120,
		"haze": 0.28,
		"clouds": true,
		"phase": 0.47,
		"sharp": 0.82,
		"beat": 5,
	},
	{
		"radius": 1980.0,
		"face": 200.0,
		"high": 240.0,
		"count": 13,
		"segments": 96,
		"haze": 0.48,
		"clouds": false,
		"phase": 0.83,
		"sharp": 0.78,
		"beat": 9,
	},
]

var _player: Node3D
var _range_mat: ShaderMaterial
var _cloud_mat: ShaderMaterial
var _peaks: Array[Dictionary] = []


func _ready() -> void:
	## The ring teleports with the bike. Interpolating that jump is the
	## "R flies me across the lake" restart: the camera snaps, then two
	## kilometres of skyline ease from the bench to kilometre zero.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_player = get_parent().get_node_or_null("Player") as Node3D
	_range_mat = ShaderMaterial.new()
	_range_mat.shader = RANGE_SHADER
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
	if _range_mat == null:
		return
	var haze: Color = mood.get("horizon_color", Color("f6b06a"))
	var fog: Color = mood.get("fog_color", Color("8b625f"))
	var lit: Color = mood.get("cloud_lit", Color("f4b07d"))
	var dark: Color = mood.get("cloud_dark", Color("413b58"))
	var light_angle: Vector3 = mood.get("light_angle", Vector3(-7.0, 14.0, 0.0))
	var euler := Vector3(deg_to_rad(light_angle.x), deg_to_rad(light_angle.y), deg_to_rad(light_angle.z))
	## DirectionalLight points down its -Z; N·L wants the vector toward the sun.
	var toward_sun: Vector3 = Basis.from_euler(euler).z
	_range_mat.set_shader_parameter("haze_color", haze)
	## Warm scree at the foot walking to cooler rock at the crest. One rock
	## colour lit by a backlit sun is a card whichever way the facets point.
	_range_mat.set_shader_parameter("foot_color", fog.darkened(0.44))
	_range_mat.set_shader_parameter("crest_color", fog.darkened(0.06).lerp(Color("5a6790"), 0.52))
	## What an up-facing plane collects from the dusk dome. This is the term
	## that keeps the backlit face off zero without smearing sunset over it.
	_range_mat.set_shader_parameter("sky_color", haze.lerp(Color("8fa6c8"), 0.58))
	_range_mat.set_shader_parameter("snow_color", Color("eef2f8"))
	_range_mat.set_shader_parameter("sun_dir", toward_sun)
	if _cloud_mat:
		## Barely lightened. Pushed most of the way to white the collar stopped
		## being vapour lit by the sunset and became a lens of grey plastic.
		_cloud_mat.set_shader_parameter("cloud_lit", lit.lerp(Color.WHITE, 0.16))
		_cloud_mat.set_shader_parameter("cloud_dark", dark)
		_cloud_mat.set_shader_parameter("opacity", 0.52)


func _follow_player() -> void:
	if _player == null:
		return
	global_position = _player.global_position
	visible = true


func _build_layer(index: int) -> void:
	var layer: Dictionary = LAYERS[index]
	var massifs: Array[Dictionary] = _plant_massifs(index, layer)
	var segments := int(layer["segments"])
	var high := float(layer["high"])
	var haze := float(layer["haze"])
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var samples: Array[Dictionary] = []
	for s in segments:
		var angle := TAU * float(s) / float(segments)
		samples.append(_sample(angle, layer, massifs))
	for s in segments:
		var a: Dictionary = samples[s]
		var b: Dictionary = samples[(s + 1) % segments]
		## Grit is drawn per *block* of segments, not per segment. One segment
		## is a couple of degrees of arc; giving each its own tone flutes the
		## face into vertical corduroy, which is the same mistake
		## `RANGE_STEP`'s comment records at the overlooks. A block is a scree
		## patch a few degrees across.
		_loft_span(surface, a, b, high, haze, index * 2003 + int(s / GRIT_BLOCK) * 13, s)
	var mesh := MeshInstance3D.new()
	mesh.name = "Range%d" % index
	mesh.mesh = surface.commit()
	mesh.material_override = _range_mat
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh.extra_cull_margin = 280.0
	add_child(mesh)
	if bool(layer["clouds"]):
		_collect_peaks(layer, massifs, samples, segments)


func _plant_massifs(index: int, layer: Dictionary) -> Array[Dictionary]:
	## The whole silhouette lives here. A primary every `spacing`, jittered off
	## the grid; a companion horn beside the tall ones so no summit is a lone
	## symmetric spike; and a spur pulled *inward* off each substantial massif
	## so the crest has ridges running toward the rider rather than one clean
	## tent outline. Half-widths are deliberately wider than the spacing: the
	## tents are meant to overlap, because the col between two overlapping
	## tents is what reads as a mountain pass.
	var count := int(layer["count"])
	var spacing := TAU / float(count)
	var sharp := float(layer["sharp"])
	var face := float(layer["face"])
	var beat := int(layer["beat"])
	var planted: Array[Dictionary] = []
	for m in count:
		var seed := index * 977 + m * 31
		var centre: float = spacing * (float(m) + float(layer["phase"])) + (_hash(seed) - 0.5) * spacing * 0.34
		var beat_h: float = float(RHYTHM[(m + beat) % RHYTHM.size()])
		var peak: float = clampf(beat_h * (0.90 + 0.18 * _hash(seed + 3)), 0.34, 1.0)
		var shape: float = clampf(sharp * (0.90 + 0.16 * beat_h), 0.72, 0.95)
		var steep_sign := 1.0 if _hash(seed + 5) > 0.5 else -1.0
		planted.append({
			"centre": centre,
			"peak": peak,
			"inner": spacing * REACH * (0.82 + 0.10 * _hash(seed + 6)),
			"outer": spacing * REACH * (1.04 + 0.12 * _hash(seed + 8)),
			"steep": steep_sign,
			"sharp": shape,
			"radial": (_hash(seed + 12) - 0.5) * face * 0.28,
		})
		if peak > 0.78:
			planted.append({
				"centre": centre + steep_sign * spacing * (0.22 + 0.08 * _hash(seed + 10)),
				"peak": peak * (0.70 + 0.10 * _hash(seed + 11)),
				"inner": spacing * 0.55,
				"outer": spacing * 0.72,
				"steep": -steep_sign,
				"sharp": 0.80,
				"radial": (_hash(seed + 13) - 0.5) * face * 0.16,
			})
		if peak > 0.62:
			var side := -steep_sign if _hash(seed + 14) > 0.42 else steep_sign
			planted.append({
				"centre": centre + side * spacing * (0.32 + 0.12 * _hash(seed + 15)),
				"peak": peak * (0.42 + 0.14 * _hash(seed + 16)),
				"inner": spacing * (0.40 + 0.10 * _hash(seed + 17)),
				"outer": spacing * (0.58 + 0.12 * _hash(seed + 18)),
				"steep": side,
				"sharp": 0.76,
				"radial": -face * (0.10 + 0.10 * _hash(seed + 19)),
			})
	return planted


func _sample(angle: float, layer: Dictionary, massifs: Array[Dictionary]) -> Dictionary:
	var radius := float(layer["radius"])
	var face := float(layer["face"])
	var high := float(layer["high"])
	var phase := float(layer["phase"])
	var crest := 0.0
	var pull := 0.0
	var weight := 0.0
	for massif in massifs:
		var delta := _wrap(angle - float(massif["centre"]))
		var half: float = float(massif["inner"]) if delta * float(massif["steep"]) < 0.0 else float(massif["outer"])
		var t: float = 1.0 - clampf(absf(delta) / maxf(half, 0.0001), 0.0, 1.0)
		if t <= 0.0:
			continue
		var value: float = float(massif["peak"]) * _tent(t, float(massif["sharp"]))
		crest = maxf(crest, value)
		## Whichever tent is winning the envelope here also owns the radial
		## offset. A fifth power picks the winner nearly outright but still
		## crosses over smoothly, so a spur folds into its parent instead of
		## tearing a step in the ridgeline.
		var dominance: float = pow(value, 5.0)
		pull += dominance * float(massif["radial"])
		weight += dominance
	if weight > 1e-6:
		pull /= weight
	else:
		pull = 0.0
	## Flank jag only. Scaled by crest alone every summit became a needle; by
	## crest * (1 - crest) it lands on the slopes and leaves the tops and the
	## cols where the composition put them. The amplitudes have to be generous
	## even so — that weighting peaks at a quarter, so a tenth here is a couple
	## of metres of relief and a ridge that runs dead straight from foot to
	## apex, which is the tell that gave the last version away as folded paper.
	var jag: float = (
		0.24 * sin(angle * 11.0 + phase * 4.0)
		+ 0.13 * sin(angle * 19.0 + phase * 9.0)
		+ 0.06 * sin(angle * 31.0 + phase * 2.3)
	)
	## The jagged skyline belongs to the skyline. Carry the smooth envelope
	## separately and hang the slopes below off *that*: the fine relief on a
	## crest does not repeat itself in the scree apron four hundred metres
	## underneath it, and if it does — if every break up the face is the same
	## curve scaled by the same number — then each angular column is a flat
	## panel and the hillside is a pleated paper fan. That is the whole reason
	## the last two attempts read as cardboard, and no amount of extra segments
	## or per-facet tone fixes it, because it is the surface that is ruled.
	var body := clampf(maxf(crest, 0.14), 0.0, 1.0)
	crest = clampf(body + jag * body * (1.0 - body), 0.0, 1.0)
	var height: float = high * crest
	## Slow bows across whole sectors of the ring. Anything fast lives in the
	## per-break terms below, where it can differ from one shelf to the next.
	var fold: float = (
		42.0 * sin(angle * 3.0 + phase * 2.2)
		+ 22.0 * sin(angle * 7.0 + phase * 1.1)
		+ body * 14.0 * sin(angle * 17.0 + phase * 3.1)
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
		"back": out * (r + face * 1.10) + Vector3(0.0, FOOT_Y, 0.0),
	}


func _tent(t: float, sharpness: float) -> float:
	## Sharpness > 1 is alpine, < 1 is a round fell. Same curve the overlooks use.
	return pow(t, sharpness)


func _wrap(delta: float) -> float:
	return fposmod(delta + PI, TAU) - PI


func _loft_span(
	surface: SurfaceTool,
	a: Dictionary,
	b: Dictionary,
	high: float,
	haze: float,
	block: int,
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
			_hash(block + k * 5 + 3),
			(step + k) % 2 == 1
		)
	_quad(
		surface,
		a["crest"],
		b["crest"],
		b["back"],
		a["back"],
		-inward,
		high,
		haze,
		_hash(block + 41),
		step % 2 == 1
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
	if flip:
		_facet(surface, p1, p2, p3, hint, high, haze, grit)
		_facet(surface, p1, p3, p0, hint, high, haze, grit)
	else:
		_facet(surface, p0, p1, p2, hint, high, haze, grit)
		_facet(surface, p0, p2, p3, hint, high, haze, grit)


func _facet(
	surface: SurfaceTool,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	hint: Vector3,
	high: float,
	haze: float,
	grit: float
) -> void:
	var normal := (b - a).cross(c - a)
	if normal.length_squared() < 0.0001:
		return
	normal = normal.normalized()
	if normal.dot(hint) < 0.0:
		normal = -normal
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
		var v_grit := clampf(grit * (0.55 + 0.90 * _hash(int(p.x * 0.13 + p.y * 0.21 + p.z * 0.17) + vi)), 0.0, 1.0)
		surface.set_normal(normal)
		surface.set_color(Color(snow, v_grit, v_lift, haze))
		surface.add_vertex(p)
		vi += 1


func _collect_peaks(
	layer: Dictionary, massifs: Array[Dictionary], samples: Array[Dictionary], segments: int
) -> void:
	## Clouds hang off the summits that were actually planted, read back from
	## the built ridgeline so the collar sits on the crest the mesh ended up
	## with — radial pull, jag and all — instead of on the ideal circle.
	for massif in massifs:
		if float(massif["peak"]) < 0.72:
			continue
		var centre: float = fposmod(float(massif["centre"]), TAU)
		var s: int = int(round(centre / TAU * float(segments))) % segments
		var at: Dictionary = samples[s]
		var crest: Vector3 = at["crest"]
		if crest.y < 120.0:
			continue
		_peaks.append({
			"out": at["out"],
			"radius": Vector3(crest.x, 0.0, crest.z).length(),
			"height": crest.y,
			"face": float(layer["face"]),
			"phase": float(layer["phase"]) + centre,
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
		## A bank, not a lens. The puffs used to be spread by a couple of degrees
		## while each one was twenty degrees wide, so all of them landed on the
		## same pixels and the collar arrived as one hard-rimmed disc parked on
		## the summit. Spread wider than the puff, overlap loosely, stagger the
		## height, and it reads as cloud caught on a peak.
		var metre: float = clampf(height * 0.46, 170.0, 360.0)
		for k in 4:
			var f := float(k)
			var around: float = (f - 1.5) * 0.072 + sin(phase + f * 1.3) * 0.026
			var a: float = angle + around
			var lift: float = height * (0.58 + 0.34 * absf(sin(phase * 1.1 + f * 2.0)))
			## Pulled in off the crest line so the bank overlaps the face it
			## belongs to rather than hovering in clear air in front of it.
			var at: float = radius - face * (0.10 + 0.20 * _hash(int(phase * 97.0) + k))
			var pos := Vector3(cos(a) * at, lift, sin(a) * at)
			var wide: float = metre * (1.25 + 0.50 * sin(phase + f * 0.8))
			var tall: float = metre * (0.72 + 0.26 * sin(phase * 1.3 + f))
			var basis := _billboard_at(pos).scaled(Vector3(wide, tall, 1.0))
			xforms.append(Transform3D(basis, pos))
			cols.append(
				Color(
					0.5 + 0.5 * sin(phase + f * 1.6),
					0.5 + 0.5 * sin(phase * 1.7 + f),
					1.0,
					0.44 + 0.34 * absf(sin(phase * 0.9 + f))
				)
			)
	if xforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = quad
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
		mm.set_instance_color(i, cols[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Clouds"
	mmi.multimesh = mm
	mmi.material_override = _cloud_mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.visibility_range_end = 0.0
	mmi.extra_cull_margin = 400.0
	add_child(mmi)


func _billboard_at(pos: Vector3) -> Basis:
	if pos.length_squared() < 0.001:
		return Basis.IDENTITY
	return Basis.looking_at(pos, Vector3.UP)


func _hash(i: int) -> float:
	return fposmod(sin(float(i) * 12.9898) * 43758.5453, 1.0)
