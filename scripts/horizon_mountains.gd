extends Node3D
## Two extremely distant, smooth mountain silhouettes. The mesh follows the
## rider's position but never its rotation, so it has no approach motion and can
## never become roadside geometry. Two draw calls replace dozens of uncullable
## per-chunk ridges.

## Dense enough that the skyline stays curved even at a wide FOV. This is still
## only a few hundred triangles per layer and is built once at startup.
const SEGMENTS := 256
const INNER_RADIUS := 1180.0
const OUTER_RADIUS := 1840.0

var _player: Node3D
var _path: Node


func _ready() -> void:
	_player = get_parent().get_node_or_null("Player") as Node3D
	_path = get_node_or_null("/root/RoadPath")
	# Phases put a broad, recognisable mass ahead of the opening road while the
	# complete ring keeps the horizon filled through long bends and head turns.
	_build_layer(INNER_RADIUS, Color("263c49"), 76.0, 238.0, 0.0)
	_build_layer(OUTER_RADIUS, Color("526a76"), 62.0, 188.0, 0.8)
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


func _build_layer(radius: float, color: Color, low: float, high: float, phase: float) -> void:
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
		# Both windings: the camera lives inside the ring and overview cameras may
		# inspect it from outside.
		_tri(surface, b0, t0, t1, color)
		_tri(surface, b0, t1, b1, color)
		_tri(surface, t1, t0, b0, color)
		_tri(surface, b1, t1, b0, color)
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
	# A few overlapping mountain-scale harmonics create recognisable summits and
	# saddles. The high segment count keeps their outlines continuously curved.
	var shape := (
		0.50
		+ 0.25 * sin(angle * 7.0 + phase)
		+ 0.14 * sin(angle * 13.0 + phase * 1.9)
		+ 0.07 * sin(angle * 21.0 + phase * 0.7)
	)
	# Smoothstep rounds the transition into every saddle and summit.
	return lerpf(low, high, smoothstep(0.0, 1.0, clampf(shape, 0.0, 1.0)))


func _tri(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, color: Color) -> void:
	var normal := (c - a).cross(b - a).normalized()
	for point in [a, b, c]:
		surface.set_normal(normal)
		surface.set_color(color)
		surface.add_vertex(point)
