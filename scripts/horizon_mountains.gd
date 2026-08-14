extends Node3D
## Two extremely distant mountain silhouettes. The mesh follows the rider's
## position but never its rotation, so it has no approach motion and can never
## become roadside geometry. Two draw calls replace dozens of uncullable
## per-chunk ridges.

## Dense enough that the skyline stays curved even at a wide FOV. This is still
## only a few hundred triangles per layer and is built once at startup.
const SEGMENTS := 256
const INNER_RADIUS := 1180.0
const OUTER_RADIUS := 1840.0
const MASSIFS := 5

var _player: Node3D
var _path: Node


func _ready() -> void:
	_player = get_parent().get_node_or_null("Player") as Node3D
	_path = get_node_or_null("/root/RoadPath")
	# Phases put a broad, recognisable mass ahead of the opening road while the
	# complete ring keeps the horizon filled through long bends and head turns.
	_build_layer(INNER_RADIUS, Color("2a3840"), Color("3d524c"), 82.0, 268.0, 0.0)
	_build_layer(OUTER_RADIUS, Color("4a5e6a"), Color("6a7e88"), 58.0, 196.0, 0.8)
	_follow_player()


func _process(_delta: float) -> void:
	_follow_player()


func _follow_player() -> void:
	if _player:
		global_position = _player.global_position
		# The endless-road skyline is deliberately a complete ring, which is useful
		# while riding and disastrous at the authored overlook: its near layer sits
		# turns all of them into one unbroken wall.  The overlook owns its horizon.
		visible = not (
			_path
			and _path.has_method("at_platform")
			and bool(_path.call("at_platform", _player.track_z, _player.lateral))
		)


func _build_layer(radius: float, foot: Color, crest: Color, low: float, high: float, phase: float) -> void:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in SEGMENTS:
		var a0 := TAU * float(i) / float(SEGMENTS)
		var a1 := TAU * float(i + 1) / float(SEGMENTS)
		var h0 := _height(a0, low, high, phase)
		var h1 := _height(a1, low, high, phase)
		var b0 := Vector3(cos(a0) * radius, -420.0, sin(a0) * radius)
		var b1 := Vector3(cos(a1) * radius, -420.0, sin(a1) * radius)
		var t0 := Vector3(cos(a0) * radius, h0, sin(a0) * radius)
		var t1 := Vector3(cos(a1) * radius, h1, sin(a1) * radius)
		var lift0 := clampf((h0 - low) / maxf(high - low, 1.0), 0.0, 1.0)
		var lift1 := clampf((h1 - low) / maxf(high - low, 1.0), 0.0, 1.0)
		# Fake a raking key from +Z so neighbouring faces don't share one value.
		var radial := Vector3(cos((a0 + a1) * 0.5), 0.0, sin((a0 + a1) * 0.5))
		var lit := clampf(radial.dot(Vector3(0.15, 0.0, 1.0).normalized()) * 0.5 + 0.5, 0.0, 1.0)
		var shade := 0.22 * (1.0 - smoothstep(0.35, 0.75, lit))
		var key := 0.10 * smoothstep(0.35, 0.75, lit)
		var c_foot := foot.darkened(shade).lightened(key)
		var c0 := c_foot.lerp(crest.darkened(shade).lightened(key), lift0)
		var c1 := c_foot.lerp(crest.darkened(shade).lightened(key), lift1)
		# Both windings: the camera lives inside the ring and overview cameras may
		# inspect it from outside.
		_tri(surface, b0, t0, t1, c_foot, c0, c1)
		_tri(surface, b0, t1, b1, c_foot, c1, c_foot)
		_tri(surface, t1, t0, b0, c1, c0, c_foot)
		_tri(surface, b1, t1, b0, c_foot, c1, c_foot)
	var mesh := MeshInstance3D.new()
	mesh.name = "FarSilhouette"
	mesh.mesh = surface.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.roughness = 1.0
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material_override = mat
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mesh)


func _height(angle: float, low: float, high: float, phase: float) -> float:
	## Few alpine massifs, not a palisade of matching tents. Peak heights are
	## skewed so one or two dominate and the rest sit as supporting ridges.
	var crest := 0.08
	for k in MASSIFS:
		var f := float(k)
		var centre: float = TAU * f / float(MASSIFS) + phase * 0.37 + sin(phase + f * 1.71) * 0.18
		var left_w: float = 0.34 + 0.12 * sin(phase * 1.4 + f * 0.9)
		var right_w: float = 0.48 + 0.14 * sin(phase * 0.8 + f * 1.3)
		var lift: float = 0.5 + 0.5 * sin(phase * 0.85 + f * 2.41)
		var peak: float = 0.20 + 0.80 * pow(lift, 1.65)
		var delta: float = fposmod(angle - centre + PI, TAU) - PI
		var half: float = left_w if delta < 0.0 else right_w
		var t: float = 1.0 - clampf(absf(delta) / half, 0.0, 1.0)
		crest = maxf(crest, peak * pow(t, 1.12))
	return lerpf(low, high, clampf(crest, 0.0, 1.0))


func _tri(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, ca: Color, cb: Color, cc: Color) -> void:
	var normal := (c - a).cross(b - a).normalized()
	var points := [a, b, c]
	var colors := [ca, cb, cc]
	for i in 3:
		surface.set_normal(normal)
		surface.set_color(colors[i])
		surface.add_vertex(points[i])
