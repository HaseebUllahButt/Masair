extends RefCounted
## Vertex-coloured low-poly mesh builder.
##
## Consumers `const LowPoly := preload("res://scripts/low_poly.gd")` rather than
## relying on `class_name` — the global class registry only exists once the
## project has been imported by the editor, and headless CLI runs have not.
##
## A handful of shared materials for the entire game instead of one
## StandardMaterial3D per box — that is what lets road chunks, cars and the bike
## collapse into a couple of draw calls each. Colour lives in the vertices;
## brightness above 1.0 on the unshaded material blows past the glow threshold
## and blooms.
##
## Surfaces are grouped into channels. A builder emits at most one surface per
## channel it actually used, so adding chrome to the bike costs one extra draw
## call for the whole bike rather than one per part.

## Which shared material a primitive is emitted under. Set `channel` on the
## builder before adding geometry; `glow: true` still overrides to GLOW, since
## most call sites express "this is a lamp" that way.
enum { SOLID, GLOW, METAL, PAINT, FOLIAGE, MIRROR }

static var _solid: StandardMaterial3D
static var _glow: StandardMaterial3D
static var _road: ShaderMaterial
static var _terrain: StandardMaterial3D
static var _metal: StandardMaterial3D
static var _paint: StandardMaterial3D
static var _foliage: ShaderMaterial
static var _mirror: StandardMaterial3D


## Every colour in this game is authored as a hex string — "3b3b3d" for tarmac,
## "7cad4e" for grass — read out of a palette and pushed straight into a vertex
## colour. Godot takes vertex colour as *linear* light, so "3b3b3d" was arriving
## as 0.231 linear: the value a mid grey has, not the value dark tarmac has. Every
## authored colour in the world was landing about a gamma brighter than written,
## which is why the road came out at 0.58 on screen instead of 0.26, why the
## greens went mint, and why no amount of pulling the ambient down produced a
## dark anywhere in the frame — the albedos themselves had no darks in them.
##
## Reading them as sRGB puts them where the hex says. It also widens the gap
## between channels, so the colours get their saturation back at the same time;
## a pale mint and a proper green are the same hue at different gammas.
##
## Not applied to the glow channel: those colours are deliberately over 1.0 and
## are light, not albedo.
static func _srgb(mat: StandardMaterial3D) -> StandardMaterial3D:
	mat.vertex_color_is_srgb = true
	return mat


static func material_for(channel: int) -> Material:
	match channel:
		GLOW:
			return glow_material()
		METAL:
			return metal_material()
		PAINT:
			return paint_material()
		FOLIAGE:
			return foliage_material()
		MIRROR:
			return mirror_material()
	return solid_material()


static func mirror_material() -> StandardMaterial3D:
	## Near-perfect reflector for the two mirror faces. They sit in the corners of
	## the first-person view and are the only surface that shows the rider the sky
	## behind them, so they are worth their own draw call.
	if _mirror == null:
		_mirror = _srgb(StandardMaterial3D.new())
		_mirror.vertex_color_use_as_albedo = true
		_mirror.metallic = 1.0
		_mirror.roughness = 0.03
		_mirror.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	return _mirror


static func metal_material() -> StandardMaterial3D:
	## Chrome, aluminium, exhaust. Fully metallic with no texture, so everything
	## it shows is the sky reflection — which is exactly why the sky shader feeds
	## the reflection probe. Under a sunset this is what puts warm highlights on
	## the fork tubes and cold sky on their undersides.
	if _metal == null:
		_metal = _srgb(StandardMaterial3D.new())
		_metal.vertex_color_use_as_albedo = true
		_metal.metallic = 1.0
		_metal.roughness = 0.24
		_metal.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	return _metal


static func paint_material() -> StandardMaterial3D:
	## Bodywork: a coloured base under a clear lacquer. The clearcoat is the
	## difference between "red box" and "painted tank" — it adds a tight white
	## highlight that survives even when the paint itself is nearly black.
	if _paint == null:
		_paint = _srgb(StandardMaterial3D.new())
		_paint.vertex_color_use_as_albedo = true
		_paint.metallic = 0.0
		_paint.roughness = 0.42
		_paint.clearcoat_enabled = true
		_paint.clearcoat = 0.75
		_paint.clearcoat_roughness = 0.06
		_paint.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	return _paint


static func foliage_material() -> ShaderMaterial:
	## Wind-swayed and slightly translucent. See shaders/foliage.gdshader.
	if _foliage == null:
		_foliage = ShaderMaterial.new()
		_foliage.shader = load("res://shaders/foliage.gdshader")
	return _foliage


static func solid_material() -> StandardMaterial3D:
	if _solid == null:
		_solid = _srgb(StandardMaterial3D.new())
		_solid.vertex_color_use_as_albedo = true
		_solid.roughness = 0.92
		_solid.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		_solid.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		# Banded rather than smooth falloff. This game renders no shadows at all,
		# so a Lambert ramp is the only thing separating a lit face from a shaded
		# one, and across a low-poly tree or boulder that ramp is so gentle that
		# every facet lands within a few percent of its neighbour — which is what
		# made the props read as flat cut-outs of one colour. A toon terminator
		# gives each facet a definite side of the light.
		_solid.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
	return _solid


static func glow_material() -> StandardMaterial3D:
	## Unshaded: vertex colour goes straight to the framebuffer, so colours over
	## 1.0 bloom. Cheaper than emission and it takes per-vertex colour, which
	## StandardMaterial3D emission does not.
	if _glow == null:
		_glow = StandardMaterial3D.new()
		_glow.vertex_color_use_as_albedo = true
		_glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return _glow


static func road_material() -> ShaderMaterial:
	## Procedural tarmac — see shaders/road.gdshader. Callers that know the lane
	## geometry push `lane_width` / `half_width` into it; the defaults are only a
	## fallback for isolated tests.
	if _road == null:
		_road = ShaderMaterial.new()
		_road.shader = load("res://shaders/road.gdshader")
	return _road


static func terrain_material() -> StandardMaterial3D:
	## Keep the broad landscape matte so its colour gradient and fog do the work;
	## a glossy 300 m ground plane makes the horizon shimmer on mobile GPUs.
	if _terrain == null:
		_terrain = _srgb(StandardMaterial3D.new())
		_terrain.vertex_color_use_as_albedo = true
		_terrain.roughness = 1.0
		_terrain.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		_terrain.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		# Plain Lambert, not wrapped. Wrap remaps N·L from [-1,1] into [0,1], so a
		# slope facing directly away from the sun still collects half the key —
		# and under a strongly coloured key (the dusk sun is `ff9e62` at 1.42)
		# that paints every face in the landscape the same hue no matter which
		# way it points. It is why four differently-coloured overlooks all came
		# out as the same orange dunes: the albedos were fine, the light was
		# erasing them.
		#
		# The seam this was guarding against belongs to a *toon* terminator, not
		# to Lambert. Lambert's falloff is still smooth across rolling ground —
		# it just reaches an honest dark on the shaded side, which is the only
		# thing giving a hillside form in a game that renders no shadows.
		_terrain.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT
	return _terrain


## Averaged vertex normals instead of hard per-face ones. Rolling ground and
## round bike parts want this; flat panels and road markings do not.
var smooth: bool = false

## Centre used by add_hull_* to decide which way is "out". Set to the shape's
## own origin before building a convex primitive.
var hull_origin: Vector3 = Vector3.ZERO

## Material channel for everything added from here on — SOLID, METAL, PAINT or
## FOLIAGE. Stateful like `smooth`, so a caller sets it once and keeps building.
var channel: int = SOLID

const SIGNS := [-1, 1]

var _st := {}


func _tool(glow: bool) -> SurfaceTool:
	var key: int = GLOW if glow else channel
	if not _st.has(key):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_st[key] = st
	return _st[key]


func is_empty() -> bool:
	return _st.is_empty()


func add_tri(a: Vector3, b: Vector3, c: Vector3, color: Color, glow: bool = false) -> void:
	## a, b, c clockwise as seen from the front face (Godot's winding).
	var st := _tool(glow)
	var n := (c - a).cross(b - a)
	if n.length_squared() < 1e-12:
		return
	if smooth:
		# generate_normals() at commit time averages across shared vertices.
		st.set_smooth_group(0)
	else:
		st.set_normal(n.normalized())
	for v in [a, b, c]:
		st.set_color(color)
		st.add_vertex(v)


func add_quad(q0: Vector3, q1: Vector3, q2: Vector3, q3: Vector3, color: Color, glow: bool = false) -> void:
	add_tri(q0, q1, q2, color, glow)
	add_tri(q0, q2, q3, color, glow)


func add_quad_shaded(
	q0: Vector3, q1: Vector3, q2: Vector3, q3: Vector3, c0: Color, c1: Color, c2: Color, c3: Color
) -> void:
	## Per-vertex colour. Needed for smooth terrain: index() only merges verts
	## that match on every attribute, so a per-quad colour would keep every quad's
	## vertices distinct and normals would never average.
	_tri_shaded(q0, q1, q2, c0, c1, c2)
	_tri_shaded(q0, q2, q3, c0, c2, c3)


func add_quad_uv(
	q0: Vector3,
	q1: Vector3,
	q2: Vector3,
	q3: Vector3,
	color: Color,
	uv0: Vector2,
	uv1: Vector2,
	uv2: Vector2,
	uv3: Vector2
) -> void:
	## Quad carrying explicit UVs. Only the tarmac needs them: its shader works in
	## road space (lateral metres, distance along the route) rather than world
	## space, which is what lets it put wheel polish where the lanes actually are
	## however the ribbon curves.
	_tri_uv(q0, q1, q2, color, uv0, uv1, uv2)
	_tri_uv(q0, q2, q3, color, uv0, uv2, uv3)


func _tri_uv(a: Vector3, b: Vector3, c: Vector3, color: Color, ua: Vector2, ub: Vector2, uc: Vector2) -> void:
	var st := _tool(false)
	var n := (c - a).cross(b - a)
	if n.length_squared() < 1e-12:
		return
	if smooth:
		st.set_smooth_group(0)
	else:
		st.set_normal(n.normalized())
	var verts := [a, b, c]
	var uvs := [ua, ub, uc]
	for i in 3:
		st.set_color(color)
		st.set_uv(uvs[i])
		st.add_vertex(verts[i])


func _tri_shaded(a: Vector3, b: Vector3, c: Vector3, ca: Color, cb: Color, cc: Color) -> void:
	var st := _tool(false)
	var n := (c - a).cross(b - a)
	if n.length_squared() < 1e-12:
		return
	if smooth:
		st.set_smooth_group(0)
	else:
		st.set_normal(n.normalized())
	var verts := [a, b, c]
	var cols := [ca, cb, cc]
	for i in 3:
		st.set_color(cols[i])
		st.add_vertex(verts[i])


func add_box(xform: Transform3D, size: Vector3, color: Color, glow: bool = false) -> void:
	var h := size * 0.5
	# (normal axis, tangent, up) triples chosen so tangent x up = normal.
	const FACES := [
		[Vector3.RIGHT, Vector3.UP, Vector3.BACK],
		[Vector3.LEFT, Vector3.BACK, Vector3.UP],
		[Vector3.UP, Vector3.BACK, Vector3.RIGHT],
		[Vector3.DOWN, Vector3.RIGHT, Vector3.BACK],
		[Vector3.BACK, Vector3.RIGHT, Vector3.UP],
		[Vector3.FORWARD, Vector3.UP, Vector3.RIGHT],
	]
	for f in FACES:
		var n: Vector3 = f[0] * h
		var t: Vector3 = f[1] * h
		var u: Vector3 = f[2] * h
		add_quad(
			xform * (n - t + u),
			xform * (n + t + u),
			xform * (n + t - u),
			xform * (n - t - u),
			color,
			glow
		)


func add_hull_tri(a: Vector3, b: Vector3, c: Vector3, color: Color, glow: bool = false) -> void:
	## Same as add_tri but auto-orients the winding outward, relative to
	## `hull_origin`. Valid for convex shapes only — which is every primitive
	## below, and it means no hand-reasoning about winding for the fiddly ones.
	var n := (c - a).cross(b - a)
	if n.dot((a + b + c) / 3.0 - hull_origin) < 0.0:
		add_tri(a, c, b, color, glow)
	else:
		add_tri(a, b, c, color, glow)


func add_hull_quad(q0: Vector3, q1: Vector3, q2: Vector3, q3: Vector3, color: Color, glow: bool = false) -> void:
	add_hull_tri(q0, q1, q2, color, glow)
	add_hull_tri(q0, q2, q3, color, glow)


func add_rounded_box(xform: Transform3D, size: Vector3, bevel: float, color: Color, glow: bool = false) -> void:
	## Box with chamfered edges and corners: 6 face quads + 12 edge quads + 8
	## corner triangles. The chamfer is what stops everything reading as a stack
	## of sharp cubes — it catches a different shade on every edge.
	var h := size * 0.5
	var b := minf(bevel, minf(h.x, minf(h.y, h.z)) * 0.9)
	hull_origin = xform.origin

	# A corner has three verts, one per axis left un-inset.
	var v := func(s: Vector3i, major: int) -> Vector3:
		var p := Vector3(
			float(s.x) * (h.x - (0.0 if major == 0 else b)),
			float(s.y) * (h.y - (0.0 if major == 1 else b)),
			float(s.z) * (h.z - (0.0 if major == 2 else b))
		)
		return xform * p

	for axis in 3:
		var t := (axis + 1) % 3
		var u := (axis + 2) % 3
		for sa in SIGNS:
			# Face quad.
			var corners: Array[Vector3] = []
			for st in SIGNS:
				for su in SIGNS:
					var s := Vector3i.ZERO
					s[axis] = sa
					s[t] = st
					s[u] = su
					corners.append(v.call(s, axis))
			add_hull_quad(corners[0], corners[1], corners[3], corners[2], color, glow)

		# Edge quads running along `axis`, one per (t, u) sign pair.
		for st in SIGNS:
			for su in SIGNS:
				var lo := Vector3i.ZERO
				lo[axis] = -1
				lo[t] = st
				lo[u] = su
				var hi := lo
				hi[axis] = 1
				add_hull_quad(v.call(lo, t), v.call(hi, t), v.call(hi, u), v.call(lo, u), color, glow)

	# Corner triangles.
	for sx in SIGNS:
		for sy in SIGNS:
			for sz in SIGNS:
				var s := Vector3i(sx, sy, sz)
				add_hull_tri(v.call(s, 0), v.call(s, 1), v.call(s, 2), color, glow)


func add_cone(xform: Transform3D, radius: float, height: float, sides: int, color: Color) -> void:
	## Base on local Y=0, apex at Y=height. Trees and rocks, rounder than a pyramid.
	hull_origin = xform * Vector3(0, height * 0.25, 0)
	var apex := xform * Vector3(0, height, 0)
	var centre := xform * Vector3.ZERO
	for i in sides:
		var a0: float = TAU * float(i) / float(sides)
		var a1: float = TAU * float(i + 1) / float(sides)
		var p0: Vector3 = xform * (Vector3(cos(a0), 0, sin(a0)) * radius)
		var p1: Vector3 = xform * (Vector3(cos(a1), 0, sin(a1)) * radius)
		add_hull_tri(p0, apex, p1, color)
		add_hull_tri(centre, p1, p0, color)


func add_cylinder(
	xform: Transform3D, radius: float, height: float, sides: int, color: Color, glow: bool = false
) -> void:
	## Axis along local Y, centred on the origin.
	hull_origin = xform.origin
	var hy := height * 0.5
	for i in sides:
		var a0: float = TAU * float(i) / float(sides)
		var a1: float = TAU * float(i + 1) / float(sides)
		var p0 := Vector3(cos(a0), 0, sin(a0)) * radius
		var p1 := Vector3(cos(a1), 0, sin(a1)) * radius
		add_hull_quad(
			xform * (p0 + Vector3(0, hy, 0)),
			xform * (p1 + Vector3(0, hy, 0)),
			xform * (p1 + Vector3(0, -hy, 0)),
			xform * (p0 + Vector3(0, -hy, 0)),
			color,
			glow
		)
		add_hull_tri(
			xform * Vector3(0, hy, 0), xform * (p0 + Vector3(0, hy, 0)), xform * (p1 + Vector3(0, hy, 0)), color, glow
		)
		add_hull_tri(
			xform * Vector3(0, -hy, 0),
			xform * (p1 + Vector3(0, -hy, 0)),
			xform * (p0 + Vector3(0, -hy, 0)),
			color,
			glow
		)


func add_sphere(
	xform: Transform3D, radius: float, segments: int, rings: int, color: Color, glow: bool = false
) -> void:
	## Low-poly UV sphere. Used for tank ends, mirror heads, grip bulbs — anything
	## that should read round rather than chamfered-box.
	hull_origin = xform.origin
	var segs := maxi(segments, 6)
	var rgs := maxi(rings, 4)
	for ring in rgs:
		var v0 := float(ring) / float(rgs)
		var v1 := float(ring + 1) / float(rgs)
		var phi0 := (v0 - 0.5) * PI
		var phi1 := (v1 - 0.5) * PI
		var y0 := sin(phi0) * radius
		var y1 := sin(phi1) * radius
		var r0 := cos(phi0) * radius
		var r1 := cos(phi1) * radius
		for seg in segs:
			var u0 := float(seg) / float(segs)
			var u1 := float(seg + 1) / float(segs)
			var a0 := u0 * TAU
			var a1 := u1 * TAU
			var p00 := xform * Vector3(cos(a0) * r0, y0, sin(a0) * r0)
			var p10 := xform * Vector3(cos(a1) * r0, y0, sin(a1) * r0)
			var p11 := xform * Vector3(cos(a1) * r1, y1, sin(a1) * r1)
			var p01 := xform * Vector3(cos(a0) * r1, y1, sin(a0) * r1)
			add_hull_quad(p00, p10, p11, p01, color, glow)


func add_capsule(
	xform: Transform3D, radius: float, height: float, segments: int, color: Color, glow: bool = false
) -> void:
	## Cylinder with spherical end caps. Axis along local Y. `height` is the full
	## tip-to-tip length (includes the two hemispheres).
	var body_h := maxf(height - radius * 2.0, 0.0)
	if body_h > 0.001:
		add_cylinder(xform, radius, body_h, segments, color, glow)
	# End-cap hemispheres via full spheres clipped by overlapping the cylinder —
	# cheap and reads round at bike scale.
	var half := height * 0.5 - radius
	var top := xform * Transform3D(Basis.IDENTITY, Vector3(0, half, 0))
	var bot := xform * Transform3D(Basis.IDENTITY, Vector3(0, -half, 0))
	add_sphere(top, radius, segments, maxi(segments / 2, 4), color, glow)
	add_sphere(bot, radius, segments, maxi(segments / 2, 4), color, glow)


func add_loft(
	centers: PackedVector3Array, radii: PackedVector2Array, sides: int, color: Color, glow: bool = false
) -> void:
	## Elliptical rings lofted along a polyline. `radii[i]` is (half-width, half-height)
	## in the ring plane. This is how a café tank stops being a stack of boxes.
	var n := mini(centers.size(), radii.size())
	if n < 2:
		return
	var segs := maxi(sides, 6)
	var mid := Vector3.ZERO
	for i in n:
		mid += centers[i]
	hull_origin = mid / float(n)
	var rings: Array[PackedVector3Array] = []
	for i in n:
		var tangent := _loft_tangent(centers, i, n)
		var basis := _loft_basis(tangent)
		var pts := PackedVector3Array()
		pts.resize(segs)
		for s in segs:
			var a := TAU * float(s) / float(segs)
			pts[s] = centers[i] + basis * Vector3(cos(a) * radii[i].x, sin(a) * radii[i].y, 0.0)
		rings.append(pts)
	for i in n - 1:
		var a: PackedVector3Array = rings[i]
		var b: PackedVector3Array = rings[i + 1]
		for s in segs:
			var s1 := (s + 1) % segs
			add_hull_quad(a[s], a[s1], b[s1], b[s], color, glow)
	_loft_cap(rings[0], centers[0], color, glow)
	_loft_cap(rings[n - 1], centers[n - 1], color, glow)


func _loft_tangent(centers: PackedVector3Array, i: int, n: int) -> Vector3:
	var tangent: Vector3
	if i == 0:
		tangent = centers[1] - centers[0]
	elif i == n - 1:
		tangent = centers[i] - centers[i - 1]
	else:
		tangent = centers[i + 1] - centers[i - 1]
	if tangent.length_squared() < 1e-10:
		return Vector3.FORWARD
	return tangent.normalized()


func _loft_basis(tangent: Vector3) -> Basis:
	var up := Vector3.UP
	if absf(tangent.dot(up)) > 0.97:
		up = Vector3.RIGHT
	return Basis.looking_at(tangent, up)


func _loft_cap(pts: PackedVector3Array, center: Vector3, color: Color, glow: bool) -> void:
	for s in pts.size():
		add_hull_tri(center, pts[s], pts[(s + 1) % pts.size()], color, glow)


func commit() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	# Sorted so surface order is deterministic regardless of build order — meshes
	# are compared by surface index in the self-checks.
	var channels: Array = _st.keys()
	channels.sort()
	for key in channels:
		var st: SurfaceTool = _st[key]
		if smooth:
			st.index()  # merge coincident verts so normals can average across them
			st.generate_normals()
		st.commit(mesh)
		mesh.surface_set_material(mesh.get_surface_count() - 1, material_for(key))
	_st.clear()
	return mesh


func commit_to(parent: Node3D, name_hint: String = "Mesh") -> MeshInstance3D:
	if is_empty():
		return null
	var mi := MeshInstance3D.new()
	mi.name = name_hint
	mi.mesh = commit()
	parent.add_child(mi)
	return mi
