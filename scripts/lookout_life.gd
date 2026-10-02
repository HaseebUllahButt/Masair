extends Node3D
## What moves in the view while the rider sits on an overlook bench.
##
## The vistas are static meshes — a lake, a far bank, a range, a sky — and a
## landscape in which nothing moves is a painting: something glanced at, not sat
## in front of. This puts life into the frame. Birds work the wind over every
## lake; the coast gets a whale and a pod of dolphins, the pass an eagle that
## stoops on the tarn, the gorge its mist and a heron, the vale its balloons and
## a murmuration at dusk.
##
## All of it exists only while the rider is sitting: built on the frame they sit
## down, freed the frame they stand. The ride never pays for any of it, and the
## seated view — bike parked, streamer idle — is the cheapest moment in the game.
##
## Placement uses two spaces. Things in the air are placed by angle off the seated
## eye, because that is what the picture is made of. Things on the water are
## checked in route space against the same RoadPath shoreline the lake was built
## from, so nothing surfaces through a meadow.

const LowPoly := preload("res://scripts/low_poly.gd")
const RoadPathGD := preload("res://scripts/road_path.gd")
const BIRD_SHADER: Shader = preload("res://shaders/life_bird.gdshader")
const MIST_SHADER: Shader = preload("res://shaders/life_mist.gdshader")
const GLOW_SHADER: Shader = preload("res://shaders/life_glow.gdshader")

## RoadPath theme ids for the four overlook biomes.
const FOREST := 1
const COAST := 2
const MOUNTAIN := 3
const COUNTRY := 4

## main.gd's LightingMode.
enum Mood { DUSK, DAY, NIGHT }

## Pooled spray and ripples, shared by every splash in the view.
const SPRAY_POOL := 360
const RING_POOL := 28

## How often the big moments come round. The first lands a few seconds after
## sitting down, so the reward is for stopping at all, not for waiting.
const FIRST_EVENT := 3.5
const EVENT_GAP := Vector2(11.0, 18.0)

## Half the horizontal field of view at the seated 62° lens on 16:9, less a margin
## so a hero event never happens half out of frame.
const HERO_ANGLE := 30.0

var _player: Node
var _path: Node
var _main: Node
var _root: Node3D
var _seated: bool = false
var _built_key: Vector2i = Vector2i(0x7fffffff, 0)
var _t: float = 0.0
var _rng := RandomNumberGenerator.new()

# The view, fixed at the moment the rider sat down.
var _eye := Vector3.ZERO
var _fwd := Vector3.FORWARD
var _right := Vector3.RIGHT
var _centre: float = 0.0
var _side: float = 1.0
var _water_y: float = 0.0
var _theme: int = COUNTRY
var _mood: int = Mood.DUSK

var _actors: Array[Dictionary] = []
var _events: Array[StringName] = []
var _event_index: int = 0
var _next_event: float = FIRST_EVENT
var _next_fish: float = 2.0
var _next_star: float = 4.0

var _bird_mat: ShaderMaterial
var _body_mat: StandardMaterial3D
var _bird_mesh: ArrayMesh

var _spray: MultiMesh
var _spray_pos := PackedVector3Array()
var _spray_vel := PackedVector3Array()
var _spray_life := PackedFloat32Array()
var _spray_max := PackedFloat32Array()
var _spray_size := PackedFloat32Array()
var _spray_drag := PackedFloat32Array()
var _spray_next: int = 0
var _spray_live: int = 0

var _rings: MultiMesh
var _ring_pos := PackedVector3Array()
var _ring_age := PackedFloat32Array()
var _ring_dur := PackedFloat32Array()
var _ring_r0 := PackedFloat32Array()
var _ring_r1 := PackedFloat32Array()
var _ring_alpha := PackedFloat32Array()
var _ring_next: int = 0


func _ready() -> void:
	_path = get_node_or_null("/root/RoadPath")
	_main = get_parent()
	_player = _main.get_node_or_null("Player") if _main else null


func _process(delta: float) -> void:
	if _player == null or _path == null:
		return
	var seated: bool = bool(_player.get("seated"))
	if not seated:
		if _seated:
			_clear()
		return
	var centre: float = float(_path.call("viewpoint_centre_for", float(_player.get("track_z"))))
	var key := Vector2i(int(round(centre)), int(_path.get("world_seed")))
	if not _seated or key != _built_key:
		_clear()
		_build(centre, key)
	_step(minf(delta, 0.1))


func is_active() -> bool:
	return _seated


func stage_capture() -> void:
	## For the gallery: start this biome's signature moment and run it forward to
	## the frame worth photographing, so a still shows what the view is like to
	## sit in rather than whichever lull the clock happened to land on.
	if not _seated:
		return
	var hero: StringName = _events[0] if not _events.is_empty() else &""
	var lead: float = 0.0
	match _theme:
		COAST:
			hero = &"breach"
			lead = 1.5
		MOUNTAIN:
			hero = &"eagle_dive"
			lead = 2.4
		FOREST:
			hero = &"birds_burst"
			lead = 3.2
		_:
			hero = &"geese"
			lead = 9.0
	var i: int = _actors.size() - 1
	while i >= 0:
		if not bool(_actors[i].get("ambient", false)):
			var node: Node = _actors[i].get("node")
			if is_instance_valid(node):
				node.queue_free()
			_actors.remove_at(i)
		i -= 1
	_start_event(hero)
	var step: float = 1.0 / 30.0
	var t: float = 0.0
	while t < lead:
		_step(step)
		t += step
	_next_event = _t + 30.0


# ---------------------------------------------------------------- lifecycle


func _clear() -> void:
	if _root:
		_root.queue_free()
	_root = null
	_actors.clear()
	_seated = false
	_built_key = Vector2i(0x7fffffff, 0)


func _build(centre: float, key: Vector2i) -> void:
	_seated = true
	_built_key = key
	_t = 0.0
	_centre = centre
	_side = float(_path.call("viewpoint_side_for", centre))
	_water_y = float(_path.call("viewpoint_water_y", centre))
	_theme = int(_path.call("theme_at", centre))
	_mood = int(_main.get("lighting_mode")) if _main else Mood.DUSK
	# Same overlook, same seed, same opening: a place has a character.
	_rng.seed = hash(Vector2i(key.x, key.y ^ 0x1f7a))
	var seat: Transform3D = _path.call("viewpoint_seat", float(_player.get("track_z")))
	_eye = seat.origin
	var look: Vector3 = -seat.basis.z
	_fwd = Vector3(look.x, 0.0, look.z).normalized()
	_right = _fwd.cross(Vector3.UP).normalized()
	_root = Node3D.new()
	_root.name = "Life"
	add_child(_root)
	_make_materials()
	_make_spray()
	_make_rings()
	_ambient()
	_events = _event_cycle()
	_event_index = 0
	_next_event = FIRST_EVENT
	_next_fish = _rng.randf_range(1.5, 4.0)
	_next_star = _rng.randf_range(2.0, 6.0)


func _step(dt: float) -> void:
	_t += dt
	var i: int = 0
	while i < _actors.size():
		var a: Dictionary = _actors[i]
		a["t"] = float(a["t"]) + dt
		var keep: bool = (a["fn"] as Callable).call(a, dt)
		if keep:
			i += 1
		else:
			var node: Node = a.get("node")
			if is_instance_valid(node):
				node.queue_free()
			_actors.remove_at(i)
	if _t >= _next_event and not _events.is_empty():
		_start_event(_events[_event_index % _events.size()])
		_event_index += 1
		_next_event = _t + _rng.randf_range(EVENT_GAP.x, EVENT_GAP.y)
	if _theme != COAST and _t >= _next_fish:
		_fish_jump()
		_next_fish = _t + _rng.randf_range(2.5, 6.5)
	if _mood == Mood.NIGHT and _t >= _next_star:
		_shooting_star()
		_next_star = _t + _rng.randf_range(5.0, 12.0)
	_step_spray(dt)
	_step_rings(dt)


func _event_cycle() -> Array[StringName]:
	match _theme:
		COAST:
			return [&"dolphins", &"breach", &"cormorants", &"spout"]
		MOUNTAIN:
			return [&"eagle_dive", &"choughs", &"eagle_dive", &"choughs"]
		FOREST:
			return [&"birds_burst", &"heron", &"flock"]
	return [&"geese", &"heron", &"flock"]


func _start_event(id: StringName) -> void:
	match id:
		&"breach":
			_whale_breach()
		&"spout":
			_whale_spout()
		&"dolphins":
			_dolphins()
		&"cormorants":
			_crossing(7, _dark_bird().lightened(0.04), 2.1, _rng.randf_range(90.0, 150.0), -6.0, 13.0, true)
		&"eagle_dive":
			_eagle_dive()
		&"choughs":
			_crossing(14, _dark_bird(), 1.5, _rng.randf_range(70.0, 120.0), _rng.randf_range(3.0, 8.0), 12.0, false)
		&"birds_burst":
			_birds_burst()
		&"heron":
			_heron()
		&"geese":
			_crossing(11, _dark_bird().lightened(0.06), 2.6, _rng.randf_range(110.0, 170.0), _rng.randf_range(5.0, 10.0), 14.0, true)
		_:
			_crossing(18, _dark_bird(), 1.4, _rng.randf_range(80.0, 140.0), _rng.randf_range(2.0, 9.0), 12.0, false)


func _ambient() -> void:
	## What is always there while you sit. The events come and go over it.
	var before: int = _actors.size()
	match _theme:
		COAST:
			_soarers(6, _gull(), 2.0, Vector2(26.0, 70.0), Vector2(-4.0, 10.0), 9.0)
		MOUNTAIN:
			_soarers(2, Color("3b2e24"), 4.6, Vector2(90.0, 150.0), Vector2(12.0, 30.0), 11.0)
			_mist(5)
		FOREST:
			_mist(6)
			_soarers(1, Color("3b2e24"), 3.8, Vector2(110.0, 160.0), Vector2(18.0, 30.0), 10.0)
		_:
			_balloons()
			if _mood == Mood.DUSK:
				_murmuration()
	if _mood != Mood.DAY and (_theme == FOREST or _theme == COUNTRY):
		_fireflies(46 if _mood == Mood.NIGHT else 30)
	for k in range(before, _actors.size()):
		_actors[k]["ambient"] = true


# ------------------------------------------------------------------- space


func _view(angle_deg: float, dist: float, rise: float) -> Vector3:
	## A point by bearing off the seated line of sight (positive is to the right),
	## horizontal distance, and height above the eye.
	var a: float = deg_to_rad(angle_deg)
	return _eye + (_fwd * cos(a) + _right * sin(a)) * dist + Vector3.UP * rise


func _sky(angle_deg: float, dist: float, elev_deg: float) -> Vector3:
	return _view(angle_deg, dist, dist * tan(deg_to_rad(elev_deg)))


func _bearing(p: Vector3) -> float:
	var d := p - _eye
	return rad_to_deg(atan2(d.dot(_right), d.dot(_fwd)))


func _route_of(p: Vector3) -> Vector2:
	## World point back into route space (along, out). Two Newton steps along the
	## path's own frame are plenty: the lake is a few hundred metres of one curve.
	var z: float = _centre
	for _i in 3:
		var c: Vector3 = _path.call("center_at", z)
		var f: Basis = _path.call("frame_flat_at", z)
		z += (p - c).dot(f.z)
	var c2: Vector3 = _path.call("center_at", z)
	var f2: Basis = _path.call("frame_flat_at", z)
	return Vector2(z, _side * (p - c2).dot(f2.x))


func _on_water(p: Vector3, margin: float) -> bool:
	var r := _route_of(p)
	if absf(r.x - _centre) > RoadPathGD.LAKE_SPAN - margin:
		return false
	var near: float = float(_path.call("viewpoint_near_shore", r.x))
	var far: float = float(_path.call("viewpoint_far_shore", r.x, _centre))
	return r.y > near + margin and r.y < far - margin


func _water_spot(min_d: float, max_d: float, max_angle: float, margin: float) -> Vector3:
	## Somewhere on open water, in shot, and far enough down the frame that the
	## headland does not hide it. INF when the lake has nowhere that fits.
	var lift: float = maxf(_eye.y - _water_y, 1.0)
	for _i in 48:
		var angle: float = _rng.randf_range(-max_angle, max_angle)
		var dist: float = _rng.randf_range(min_d, max_d)
		var p := _view(angle, dist, -lift)
		if not _on_water(p, margin):
			continue
		# Not hidden under the brow of the headland: the near basin is out of
		# sight from a bench set back from the lip.
		if rad_to_deg(atan2(lift, dist)) > 32.0:
			continue
		p.y = _water_y
		return p
	return Vector3.INF


# ---------------------------------------------------------------- palette


func _dark_bird() -> Color:
	match _mood:
		Mood.DAY:
			return Color("2b2c33")
		Mood.NIGHT:
			return Color("0f1119")
	return Color("1d1a24")


func _gull() -> Color:
	return Color("737a88") if _mood == Mood.NIGHT else Color("ece8df")


func _foam() -> Color:
	match _mood:
		Mood.NIGHT:
			return Color(0.42, 0.46, 0.56)
		Mood.DAY:
			return Color(0.96, 0.98, 1.0)
	return Color(1.0, 0.9, 0.82)


# --------------------------------------------------------------- materials


func _make_materials() -> void:
	_bird_mat = bird_material()
	_body_mat = body_material()
	if _bird_mesh == null:
		_bird_mesh = _make_bird_mesh()


## Every material the life here can draw, in the form it draws it. Compatibility
## compiles a program the first time something draws with it, so these are
## shared factories: the overlook uses them, and so does `warm_into`, which the
## start menu's warmup calls so the first bench is not the first compile.
static var _bird_shared: ShaderMaterial
static var _body_shared: StandardMaterial3D
static var _spray_shared: StandardMaterial3D
static var _ring_shared: StandardMaterial3D


static func bird_material() -> ShaderMaterial:
	if _bird_shared == null:
		_bird_shared = ShaderMaterial.new()
		_bird_shared.shader = BIRD_SHADER
	return _bird_shared


static func body_material() -> StandardMaterial3D:
	## Whales, dolphins and fish: wet skin, so a little sheen off the low sun.
	if _body_shared == null:
		_body_shared = StandardMaterial3D.new()
		_body_shared.vertex_color_use_as_albedo = true
		_body_shared.vertex_color_is_srgb = true
		_body_shared.roughness = 0.42
		_body_shared.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _body_shared


static func spray_material() -> StandardMaterial3D:
	if _spray_shared == null:
		_spray_shared = StandardMaterial3D.new()
		_spray_shared.vertex_color_use_as_albedo = true
		_spray_shared.roughness = 0.8
		# Foam is lit, but it also scatters: a little of its own light keeps a
		# splash white against a dusk sea instead of sinking into it.
		_spray_shared.emission_enabled = true
		_spray_shared.emission = Color(0.55, 0.55, 0.58)
		_spray_shared.emission_energy_multiplier = 0.6
	return _spray_shared


static func ring_material() -> StandardMaterial3D:
	if _ring_shared == null:
		_ring_shared = StandardMaterial3D.new()
		_ring_shared.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_ring_shared.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_ring_shared.vertex_color_use_as_albedo = true
		_ring_shared.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _ring_shared


static func balloon_material() -> StandardMaterial3D:
	## One per balloon: each burner lights its own envelope.
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.roughness = 0.75
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.55, 0.22)
	mat.emission_energy_multiplier = 0.0
	return mat


static func glow_material(color: Color, energy: float, blink: float) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = GLOW_SHADER
	mat.set_shader_parameter("glow_color", color)
	mat.set_shader_parameter("energy", energy)
	mat.set_shader_parameter("blink", blink)
	return mat


static func mist_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = MIST_SHADER
	return mat


static func star_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.disable_fog = true
	return mat


static func warm_into(parent: Node3D) -> void:
	## One of everything, drawn the way the overlook draws it — MultiMesh where
	## it batches, a plain mesh where it does not — so the programs exist before
	## anyone sits down.
	var cube := BoxMesh.new()
	var batched: Array = [
		[bird_material(), true, true], [spray_material(), true, false], [ring_material(), true, false],
		[glow_material(Color.WHITE, 1.0, 1.0), false, true],
	]
	var x: float = -12.0
	for row in batched:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = bool(row[1])
		mm.use_custom_data = bool(row[2])
		mm.mesh = cube
		mm.instance_count = 1
		mm.set_instance_transform(0, Transform3D.IDENTITY)
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = row[0]
		mmi.position = Vector3(x, -9.0, 0.0)
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mmi)
		x += 3.0
	for mat: Material in [body_material(), balloon_material(), mist_material(), star_material()]:
		var mi := MeshInstance3D.new()
		mi.mesh = cube
		mi.material_override = mat
		mi.position = Vector3(x, -9.0, 0.0)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mi)
		x += 3.0


static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, color: Color, outward: Vector3) -> void:
	## One flat-shaded triangle, wound and lit to face `outward`.
	var n := (c - a).cross(b - a)
	if n.length_squared() < 1e-10:
		return
	if n.dot(outward) < 0.0:
		var swap := b
		b = c
		c = swap
		n = -n
	st.set_normal(n.normalized())
	for v in [a, b, c]:
		st.set_color(color)
		st.add_vertex(v)


static func _make_bird_mesh() -> ArrayMesh:
	## One-metre wingspan, nose to -Z, wings flat in XZ. The shader beats them.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var w := Color.WHITE
	var up := Vector3.UP
	var nose := Vector3(0.0, 0.0, -0.26)
	var tail := Vector3(0.0, 0.0, 0.16)
	for s: float in [-1.0, 1.0]:
		var root_f := Vector3(0.045 * s, 0.0, -0.08)
		var root_b := Vector3(0.045 * s, 0.0, 0.07)
		var elbow_f := Vector3(0.25 * s, 0.015, -0.07)
		var elbow_b := Vector3(0.23 * s, 0.015, 0.06)
		var tip := Vector3(0.5 * s, 0.0, 0.07)
		_tri(st, nose, root_f, tail, w, up)
		_tri(st, root_f, root_b, tail, w, up)
		_tri(st, root_f, elbow_f, elbow_b, w, up)
		_tri(st, root_f, elbow_b, root_b, w, up)
		_tri(st, elbow_f, tip, elbow_b, w, up)
		_tri(st, tail, Vector3(0.07 * s, 0.0, 0.27), Vector3(0.0, 0.0, 0.24), w, up)
	# A thin keel so a bird seen edge-on is still a dash, not nothing.
	_tri(st, nose, Vector3(0.0, 0.05, -0.02), tail, w, Vector3.RIGHT)
	_tri(st, nose, Vector3(0.0, -0.045, 0.0), tail, w, Vector3.RIGHT)
	return st.commit()


static func _loft_body(
	st: SurfaceTool, profile: Array, sides: int, squash: float, dark: Color, pale: Color, belly: float
) -> void:
	## A streamlined body along Z (nose at the most negative z). Profile rows are
	## [z, radius]; dark above, pale below the `belly` line.
	for k in profile.size() - 1:
		var z0: float = float(profile[k][0])
		var z1: float = float(profile[k + 1][0])
		var r0: float = float(profile[k][1])
		var r1: float = float(profile[k + 1][1])
		for i in sides:
			var a0: float = TAU * float(i) / float(sides)
			var a1: float = TAU * float(i + 1) / float(sides)
			var p00 := Vector3(cos(a0) * r0, sin(a0) * r0 * squash, z0)
			var p01 := Vector3(cos(a1) * r0, sin(a1) * r0 * squash, z0)
			var p10 := Vector3(cos(a0) * r1, sin(a0) * r1 * squash, z1)
			var p11 := Vector3(cos(a1) * r1, sin(a1) * r1 * squash, z1)
			var mid: float = (sin(a0) + sin(a1)) * 0.5
			var col: Color = pale if mid < belly else dark
			var axis := Vector3(0.0, 0.0, (z0 + z1) * 0.5)
			var centroid := (p00 + p01 + p10 + p11) * 0.25
			_tri(st, p00, p01, p11, col, centroid - axis)
			_tri(st, p00, p11, p10, col, centroid - axis)


static func _make_whale_mesh() -> ArrayMesh:
	## A humpback: dark back, white throat, the long white flippers and a broad
	## fluke. Thirteen metres, nose to -Z.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var dark := Color("27303a")
	var pale := Color("d6d0c4")
	var profile := [
		[-6.6, 0.12], [-5.8, 0.85], [-4.4, 1.42], [-2.6, 1.72], [-0.6, 1.66],
		[1.4, 1.32], [3.2, 0.86], [4.7, 0.46], [5.9, 0.24], [6.6, 0.13],
	]
	_loft_body(st, profile, 10, 0.86, dark, pale, -0.35)
	for s: float in [-1.0, 1.0]:
		var root_a := Vector3(1.25 * s, -0.55, -3.2)
		var root_b := Vector3(1.3 * s, -0.6, -2.1)
		var tip := Vector3(5.4 * s, -1.6, -0.4)
		var mid := Vector3(3.4 * s, -1.05, -1.0)
		var fin := Color("e2dccf")
		_tri(st, root_a, mid, root_b, fin, Vector3.UP)
		_tri(st, root_b, mid, tip, fin, Vector3.UP)
		_tri(st, root_a, tip, mid, fin, Vector3.UP)
		# Flukes: dark above, white beneath, as a pair of sheets back to back.
		var notch := Vector3(0.0, 0.0, 7.3)
		var root := Vector3(0.0, 0.0, 6.2)
		var ftip := Vector3(2.9 * s, 0.12, 7.9)
		var lead := Vector3(1.5 * s, 0.0, 6.7)
		_tri(st, root + Vector3(0, 0.04, 0), lead + Vector3(0, 0.04, 0), ftip + Vector3(0, 0.04, 0), dark, Vector3.UP)
		_tri(st, root + Vector3(0, 0.04, 0), ftip + Vector3(0, 0.04, 0), notch + Vector3(0, 0.04, 0), dark, Vector3.UP)
		_tri(st, root - Vector3(0, 0.04, 0), lead - Vector3(0, 0.04, 0), ftip - Vector3(0, 0.04, 0), pale, Vector3.DOWN)
		_tri(st, root - Vector3(0, 0.04, 0), ftip - Vector3(0, 0.04, 0), notch - Vector3(0, 0.04, 0), pale, Vector3.DOWN)
	# The small dorsal hump a humpback is named for.
	_tri(st, Vector3(0.0, 1.05, 2.0), Vector3(0.0, 1.55, 2.9), Vector3(0.0, 0.95, 3.5), dark, Vector3.RIGHT)
	return st.commit()


static func _make_dolphin_mesh(length: float, dark: Color, pale: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var h := length * 0.5
	var profile := [
		[-h, 0.02], [-h * 0.82, 0.06], [-h * 0.66, 0.15], [-h * 0.3, 0.22],
		[h * 0.1, 0.2], [h * 0.5, 0.12], [h * 0.82, 0.05], [h, 0.03],
	]
	for row in profile:
		row[1] = float(row[1]) * length
	_loft_body(st, profile, 8, 0.9, dark, pale, -0.4)
	var r := length * 0.2
	# Dorsal fin, swept back, and the tail flukes.
	_tri(st, Vector3(0, r * 0.85, -h * 0.05), Vector3(0, r * 2.0, h * 0.22), Vector3(0, r * 0.75, h * 0.28), dark, Vector3.RIGHT)
	for s: float in [-1.0, 1.0]:
		_tri(st, Vector3(0, 0, h * 0.9), Vector3(s * length * 0.2, 0, h * 1.08), Vector3(0, 0, h * 1.02), dark, Vector3.UP)
		_tri(st, Vector3(s * r * 0.8, -r * 0.4, -h * 0.35), Vector3(s * r * 2.0, -r * 1.1, -h * 0.12), Vector3(s * r * 0.8, -r * 0.5, -h * 0.15), dark, Vector3.UP)
	return st.commit()


func _body_node(mesh: ArrayMesh) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _body_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	LowPoly.cheap_draw(mi)
	_root.add_child(mi)
	return mi


func _big_aabb() -> AABB:
	return AABB(_eye - Vector3(3000.0, 1200.0, 3000.0), Vector3(6000.0, 2400.0, 6000.0))


# ------------------------------------------------------------------- birds


func _flock(count: int, color: Color, span: float, beat_rate: Vector2, flap: float) -> Dictionary:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = _bird_mesh
	mm.instance_count = count
	mm.custom_aabb = _big_aabb()
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.material_override = _bird_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	LowPoly.cheap_draw(mi)
	_root.add_child(mi)
	var lin := color.srgb_to_linear()
	var prev := PackedVector3Array()
	var dirs := PackedVector3Array()
	var banks := PackedFloat32Array()
	prev.resize(count)
	dirs.resize(count)
	banks.resize(count)
	for i in count:
		var jitter: float = _rng.randf_range(-0.05, 0.05)
		mm.set_instance_color(i, Color(lin.r + jitter * lin.r, lin.g + jitter * lin.g, lin.b + jitter * lin.b))
		mm.set_instance_custom_data(i, Color(_rng.randf(), flap, _rng.randf_range(beat_rate.x, beat_rate.y) / 40.0, 0.0))
		prev[i] = Vector3.INF
		dirs[i] = _right
		mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ONE * 0.001), _eye - Vector3.UP * 500.0))
	return {"mm": mm, "node": mi, "n": count, "span": span, "prev": prev, "dir": dirs, "bank": banks}


func _put(f: Dictionary, i: int, pos: Vector3, dt: float, span_scale: float = 1.0) -> void:
	## Place bird `i` and point it along the way it actually moved, banked into
	## its turn the way a bird leans into a curve.
	var prev: PackedVector3Array = f["prev"]
	var dirs: PackedVector3Array = f["dir"]
	var banks: PackedFloat32Array = f["bank"]
	var dir: Vector3 = dirs[i]
	var speed: float = 0.0
	if prev[i] != Vector3.INF and dt > 0.0:
		var v: Vector3 = (pos - prev[i]) / dt
		speed = v.length()
		if speed > 0.05:
			var target := v / speed
			var turned: Vector3 = dir.lerp(target, 1.0 - exp(-10.0 * dt))
			if turned.length_squared() > 1e-6:
				var yaw_rate: float = dir.cross(turned.normalized()).y / maxf(dt, 1e-4)
				banks[i] = lerpf(banks[i], clampf(atan(speed * yaw_rate / 9.8), -1.0, 1.0), 1.0 - exp(-4.0 * dt))
				dir = turned.normalized()
	prev[i] = pos
	dirs[i] = dir
	f["prev"] = prev
	f["dir"] = dirs
	f["bank"] = banks
	var up := Vector3.UP if absf(dir.y) < 0.97 else _fwd
	var b := Basis.looking_at(dir, up) * Basis(Vector3.BACK, banks[i])
	(f["mm"] as MultiMesh).set_instance_transform(i, Transform3D(b.scaled(Vector3.ONE * float(f["span"]) * span_scale), pos))


func _set_wings(f: Dictionary, i: int, flap: float, fold: float) -> void:
	var mm: MultiMesh = f["mm"]
	var c: Color = mm.get_instance_custom_data(i)
	mm.set_instance_custom_data(i, Color(c.r, flap, c.b, fold))


func _crossing(count: int, color: Color, span: float, dist: float, elev: float, speed: float, v_form: bool) -> void:
	## A flock crossing the frame from one edge to the other: geese in a skein,
	## cormorants low over the sea, a loose chatter of choughs.
	var flock := _flock(count, color, span, Vector2(13.0, 17.0) if v_form else Vector2(22.0, 30.0), 1.0)
	var hand: float = -1.0 if _rng.randf() < 0.5 else 1.0
	var start := _sky(-58.0 * hand, dist, elev)
	var finish := _sky(58.0 * hand, dist * _rng.randf_range(0.85, 1.2), elev + _rng.randf_range(-2.0, 4.0))
	if elev < 0.0:
		# Low over the water: hold height above the surface, not angle off the eye.
		start.y = _water_y + 6.0
		finish.y = _water_y + 9.0
	var heading := (finish - start).normalized()
	var across := heading.cross(Vector3.UP).normalized()
	var offsets := PackedVector3Array()
	var phases := PackedFloat32Array()
	for i in count:
		var o := Vector3.ZERO
		if v_form:
			var k: int = (i + 1) / 2
			var s: float = 1.0 if i % 2 == 0 else -1.0
			o = -heading * float(k) * span * 1.6 + across * s * float(k) * span * 1.35
			o += Vector3(_rng.randf_range(-0.3, 0.3), _rng.randf_range(-0.3, 0.3), _rng.randf_range(-0.3, 0.3)) * span
		else:
			o = Vector3(_rng.randf_range(-6.0, 6.0), _rng.randf_range(-2.5, 2.5), _rng.randf_range(-6.0, 6.0)) * span
		offsets.append(o)
		phases.append(_rng.randf() * TAU)
	var length: float = start.distance_to(finish)
	_actors.append({
		"fn": _step_crossing, "t": 0.0, "node": flock["node"], "f": flock, "start": start, "heading": heading,
		"speed": speed, "length": length, "offsets": offsets, "phases": phases, "v": v_form,
	})


func _step_crossing(a: Dictionary, dt: float) -> bool:
	var t: float = a["t"]
	var f: Dictionary = a["f"]
	var lead: Vector3 = (a["start"] as Vector3) + (a["heading"] as Vector3) * float(a["speed"]) * t
	var offsets: PackedVector3Array = a["offsets"]
	var phases: PackedFloat32Array = a["phases"]
	var loose: float = 0.25 if bool(a["v"]) else 1.0
	for i in int(f["n"]):
		var ph: float = phases[i]
		var wob := Vector3(sin(t * 0.9 + ph), sin(t * 1.3 + ph * 1.7) * 0.6, cos(t * 0.7 + ph)) * float(f["span"]) * 1.4 * loose
		_put(f, i, lead + offsets[i] + wob, dt)
	return float(a["speed"]) * t < float(a["length"]) + 30.0


func _soarers(count: int, color: Color, span: float, dist: Vector2, rise: Vector2, speed: float) -> void:
	## Birds riding the air in slow circles: gulls off the headland, buzzards and
	## eagles over the woods and the pass. Mostly gliding; now and then a few
	## wingbeats to hold height.
	var flock := _flock(count, color, span, Vector2(9.0, 12.0), 0.0)
	var centres := PackedVector3Array()
	var radii := PackedFloat32Array()
	var phases := PackedFloat32Array()
	var turns := PackedFloat32Array()
	for i in count:
		var c := _view(_rng.randf_range(-32.0, 32.0), _rng.randf_range(dist.x, dist.y), _rng.randf_range(rise.x, rise.y))
		if c.y < _water_y + 8.0:
			c.y = _water_y + 8.0 + _rng.randf() * 6.0
		centres.append(c)
		radii.append(_rng.randf_range(14.0, 30.0) * (span / 2.5))
		phases.append(_rng.randf() * TAU)
		turns.append(1.0 if _rng.randf() < 0.5 else -1.0)
	var drift := (_right * _rng.randf_range(-1.0, 1.0) + _fwd * _rng.randf_range(-0.3, 0.3)) * 0.8
	_actors.append({
		"fn": _step_soarers, "t": 0.0, "node": flock["node"], "f": flock, "c": centres, "r": radii,
		"ph": phases, "turn": turns, "speed": speed, "drift": drift, "taken": -1,
	})


func _step_soarers(a: Dictionary, dt: float) -> bool:
	var t: float = a["t"]
	var f: Dictionary = a["f"]
	var centres: PackedVector3Array = a["c"]
	var radii: PackedFloat32Array = a["r"]
	var phases: PackedFloat32Array = a["ph"]
	var turns: PackedFloat32Array = a["turn"]
	var drift: Vector3 = a["drift"]
	for i in int(f["n"]):
		if i == int(a["taken"]):
			continue
		var r: float = radii[i]
		var ang: float = phases[i] + turns[i] * float(a["speed"]) / r * t
		# Circles that drift and wander, so no two laps lie on top of each other.
		var c: Vector3 = centres[i] + drift * sin(t * 0.05 + phases[i]) * 30.0
		var pos := c + (_fwd * cos(ang) + _right * sin(ang)) * r * (1.0 + 0.25 * sin(t * 0.13 + phases[i]))
		pos.y += sin(t * 0.37 + phases[i]) * 3.0
		_put(f, i, pos, dt)
		var burst: float = clampf((sin(t * 0.31 + phases[i] * 2.0) - 0.72) / 0.28, 0.0, 1.0)
		_set_wings(f, i, burst, 0.0)
	return true


func _murmuration() -> void:
	## Starlings at dusk over the vale: one cloud of a couple of hundred birds,
	## stretching, folding and turning through itself. Every bird is a speck; the
	## shape is the event.
	var count: int = 260
	var flock := _flock(count, _dark_bird(), 1.5, Vector2(30.0, 38.0), 1.0)
	var base := PackedVector3Array()
	var phases := PackedFloat32Array()
	for i in count:
		var v := Vector3(_rng.randfn(0.0, 1.0), _rng.randfn(0.0, 0.55), _rng.randfn(0.0, 1.0))
		base.append(v.limit_length(2.2))
		phases.append(_rng.randf() * TAU)
	var hand: float = -1.0 if _rng.randf() < 0.5 else 1.0
	var home := _sky(hand * _rng.randf_range(10.0, 22.0), _rng.randf_range(200.0, 250.0), _rng.randf_range(4.0, 7.0))
	_actors.append({"fn": _step_murmuration, "t": 0.0, "node": flock["node"], "f": flock, "b": base, "ph": phases, "home": home})


func _step_murmuration(a: Dictionary, dt: float) -> bool:
	var t: float = a["t"]
	var f: Dictionary = a["f"]
	var base: PackedVector3Array = a["b"]
	var phases: PackedFloat32Array = a["ph"]
	var home: Vector3 = a["home"]
	var centre := home + _right * sin(t * 0.045) * 70.0 + Vector3.UP * sin(t * 0.07) * 10.0 + _fwd * sin(t * 0.031) * 40.0
	# The cloud's shape: anisotropic scale that breathes on three clocks, a slow
	# spin, and a travelling wave that folds it through itself.
	var sx: float = 19.0 * (1.0 + 0.55 * sin(t * 0.19))
	var sy: float = 7.0 * (1.0 + 0.6 * sin(t * 0.23 + 1.3))
	var sz: float = 16.0 * (1.0 + 0.5 * sin(t * 0.15 + 2.1))
	var spin := Basis(Vector3.UP, t * 0.09 + sin(t * 0.05) * 1.2)
	var k := Vector3(sin(t * 0.11), 0.4, cos(t * 0.13)).normalized() * 1.6
	for i in int(f["n"]):
		var b: Vector3 = base[i]
		var p := Vector3(b.x * sx, b.y * sy, b.z * sz)
		p.y += sin(b.dot(k) * 2.2 - t * 1.1) * 7.0
		p.x += cos(b.dot(k) * 1.7 - t * 0.8) * 6.0
		p = spin * p
		# Each bird's own little loop, so the cloud shimmers as they bank.
		var ph: float = phases[i]
		p += Vector3(cos(t * 2.1 + ph), sin(t * 1.7 + ph * 1.3) * 0.5, sin(t * 2.1 + ph)) * 2.2
		_put(f, i, centre + p, dt)
	return true


func _path_flyer(points: PackedVector3Array, times: PackedFloat32Array, flaps: PackedFloat32Array, folds: PackedFloat32Array, color: Color, span: float, rate: float, cues: Array) -> void:
	## One bird along a hand-placed line: a Catmull-Rom through `points`, reached
	## at `times`, with wing state per point and callbacks fired on cue.
	var flock := _flock(1, color, span, Vector2(rate, rate), flaps[0])
	_actors.append({
		"fn": _step_path_flyer, "t": 0.0, "node": flock["node"], "f": flock, "p": points, "k": times,
		"flap": flaps, "fold": folds, "cues": cues,
	})


static func _catmull(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, u: float) -> Vector3:
	var u2 := u * u
	var u3 := u2 * u
	return 0.5 * ((2.0 * p1) + (-p0 + p2) * u + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * u2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * u3)


func _step_path_flyer(a: Dictionary, dt: float) -> bool:
	var t: float = a["t"]
	var pts: PackedVector3Array = a["p"]
	var keys: PackedFloat32Array = a["k"]
	var n: int = pts.size()
	if t >= keys[n - 1]:
		return false
	var s: int = 0
	while s < n - 2 and t >= keys[s + 1]:
		s += 1
	var u: float = clampf((t - keys[s]) / maxf(keys[s + 1] - keys[s], 0.001), 0.0, 1.0)
	var pos := _catmull(pts[maxi(s - 1, 0)], pts[s], pts[s + 1], pts[mini(s + 2, n - 1)], u)
	var f: Dictionary = a["f"]
	_put(f, 0, pos, dt)
	var flaps: PackedFloat32Array = a["flap"]
	var folds: PackedFloat32Array = a["fold"]
	_set_wings(f, 0, lerpf(flaps[s], flaps[s + 1], u), lerpf(folds[s], folds[s + 1], u))
	var cues: Array = a["cues"]
	for cue in cues:
		if not bool(cue[2]) and t >= float(cue[0]):
			cue[2] = true
			(cue[1] as Callable).call(pos)
	return true


func _eagle_dive() -> void:
	## The pass's moment: an eagle comes off its circle, folds, and hits the tarn
	## in a burst of spray, then labours back up and away with its catch.
	var strike := _water_spot(110.0, 210.0, 22.0, 30.0)
	if strike == Vector3.INF:
		_crossing(12, _dark_bird(), 1.5, 100.0, 5.0, 12.0, false)
		return
	var hand: float = -1.0 if _bearing(strike) > 0.0 else 1.0
	var b := _bearing(strike)
	var d: float = Vector2(strike.x - _eye.x, strike.z - _eye.z).length()
	# In toward the bench rather than across it: a bird crossing the frame shows
	# its wings edge-on, and one coming at you shows all of them.
	var pts := PackedVector3Array([
		_sky(b + hand * 22.0, d * 1.7, 13.0),
		_sky(b + hand * 13.0, d * 1.3, 11.0),
		_sky(b + hand * 5.0, d * 1.04, 6.0),
		strike + Vector3.UP * 1.2,
		strike + (_right * -hand * 18.0) + Vector3.UP * 5.0,
		_sky(b - hand * 22.0, d * 1.05, 2.0),
		_sky(b - hand * 52.0, d * 1.2, 9.0),
	])
	var keys := PackedFloat32Array([0.0, 2.6, 3.9, 4.6, 5.8, 8.4, 12.0])
	var flaps := PackedFloat32Array([0.15, 0.1, 0.0, 0.0, 1.0, 0.9, 0.6])
	var folds := PackedFloat32Array([0.0, 0.0, 0.8, 0.9, 0.0, 0.0, 0.0])
	var cues := [[4.55, func(p: Vector3) -> void: _eagle_strike(p), false]]
	_path_flyer(pts, keys, flaps, folds, Color("4a3a2c"), 7.0, 9.0, cues)


func _eagle_strike(p: Vector3) -> void:
	var hit := Vector3(p.x, _water_y, p.z)
	_splash(hit, 110, 9.0, 5.0, 0.55)
	_ring(hit, 1.0, 12.0, 3.2, 0.9)
	_ring(hit, 0.5, 7.0, 2.4, 0.7)


func _heron() -> void:
	## Grey heron, low and slow along the far shore, neck tucked, deep beats.
	var dist: float = _rng.randf_range(120.0, 180.0)
	var hand: float = -1.0 if _rng.randf() < 0.5 else 1.0
	var pts := PackedVector3Array()
	var keys := PackedFloat32Array()
	var flaps := PackedFloat32Array()
	var folds := PackedFloat32Array()
	for k in 6:
		var u: float = float(k) / 5.0
		var p := _view(hand * lerpf(-60.0, 60.0, u), dist * (1.0 + 0.08 * sin(u * 5.0)), 0.0)
		p.y = _water_y + 5.0 + 2.0 * sin(u * 4.0)
		pts.append(p)
		keys.append(u * 22.0)
		flaps.append(0.85 if k % 2 == 0 else 0.3)
		folds.append(0.0)
	_path_flyer(pts, keys, flaps, folds, Color("8d949c") if _mood != Mood.NIGHT else Color("4c5260"), 4.2, 8.0, [])


func _birds_burst() -> void:
	## Something in the trees below the bench startles a flock. It bursts out of
	## the canopy on the face of the drop, climbs out over the gorge and wheels
	## away down it. Close enough to read as birds, not as dust.
	var count: int = 36
	# Pale undersides: against a dark wood and darker water, wings taking the
	# low sun are the only birds the eye can find.
	var flock := _flock(count, _gull().lerp(Color("f2d2b8"), 0.4), 1.5, Vector2(30.0, 38.0), 1.0)
	var src := _view(_rng.randf_range(-14.0, 14.0), _rng.randf_range(34.0, 48.0), -_rng.randf_range(34.0, 44.0))
	var hand: float = -1.0 if _rng.randf() < 0.5 else 1.0
	var scatter := PackedVector3Array()
	var slot := PackedVector3Array()
	for i in count:
		var dir := Vector3(_rng.randfn(0.0, 1.0), _rng.randf_range(0.2, 1.0), _rng.randfn(0.0, 1.0)).normalized()
		scatter.append(dir * _rng.randf_range(5.0, 14.0))
		slot.append(Vector3(_rng.randfn(0.0, 5.0), _rng.randfn(0.0, 2.2), _rng.randfn(0.0, 5.0)))
	_actors.append({
		"fn": _step_burst, "t": 0.0, "node": flock["node"], "f": flock, "src": src, "scatter": scatter,
		"slot": slot, "hand": hand,
	})


func _step_burst(a: Dictionary, dt: float) -> bool:
	var t: float = a["t"]
	var f: Dictionary = a["f"]
	var src: Vector3 = a["src"]
	var hand: float = a["hand"]
	var scatter: PackedVector3Array = a["scatter"]
	var slot: PackedVector3Array = a["slot"]
	# The flock's line: up out of the trees, out over the gorge, and a long
	# turn away down it.
	var centre := src + Vector3.UP * 30.0 * (1.0 - exp(-t * 0.5))
	centre += _fwd * (t * 11.0) + _right * hand * (sin(t * 0.22) * 55.0 + maxf(t - 7.0, 0.0) * 9.0)
	var gather: float = smoothstep(0.6, 4.5, t)
	for i in int(f["n"]):
		var burst: Vector3 = src + scatter[i] * (1.0 - exp(-t * 1.6)) * 1.6 + Vector3.UP * minf(t, 1.0) * 4.0
		var q: Vector3 = centre + slot[i] + Vector3(sin(t * 1.4 + float(i)), cos(t * 1.1 + float(i) * 0.7) * 0.5, cos(t * 1.4 + float(i))) * 1.5
		_put(f, i, burst.lerp(q, gather), dt)
	return t < 24.0


# ---------------------------------------------------------- whales and fish


func _whale_breach() -> void:
	var spot := _water_spot(165.0, 240.0, HERO_ANGLE - 6.0, 45.0)
	if spot == Vector3.INF:
		return
	var heading := (_right * (1.0 if _rng.randf() < 0.5 else -1.0) + _fwd * _rng.randf_range(-0.3, 0.3)).normalized()
	var whale := _body_node(_make_whale_mesh())
	# Twice life size. From a hundred metres up and two hundred out a true
	# fifteen-metre humpback is a dash; the leap has to read as a whale.
	whale.scale = Vector3.ONE * 2.0
	whale.visible = false
	_actors.append({"fn": _step_breach, "t": 0.0, "node": whale, "at": spot, "dir": heading, "cue": 0})


func _step_breach(a: Dictionary, dt: float) -> bool:
	var t: float = a["t"]
	var whale: MeshInstance3D = a["node"]
	var heading: Vector3 = a["dir"]
	var at: Vector3 = a["at"]
	var fly: float = clampf(t, 0.0, 4.4)
	var y: float = _water_y - 8.5 + 19.0 * fly - 4.9 * fly * fly
	var pos: Vector3 = at + heading * 3.2 * fly
	pos.y = y
	# Nose to the sky on the way up, then over onto its back for the landing.
	var pitch: float = deg_to_rad(lerpf(82.0, -40.0, smoothstep(0.7, 4.0, fly)))
	var roll: float = deg_to_rad(150.0) * smoothstep(1.2, 3.8, fly)
	var b := Basis.looking_at(heading, Vector3.UP) * Basis(Vector3.RIGHT, pitch) * Basis(Vector3.BACK, roll)
	whale.transform = Transform3D(b.scaled(whale.scale), pos)
	whale.visible = t < 4.5
	var cue: int = a["cue"]
	var nose: Vector3 = pos + b * Vector3(0.0, 0.0, -7.0) * whale.scale.x
	if cue == 0 and t > 0.3:
		a["cue"] = 1
		_splash(Vector3(nose.x, _water_y, nose.z), 80, 9.0, 4.5, 0.8)
		_ring(Vector3(nose.x, _water_y, nose.z), 2.0, 11.0, 3.0, 0.8)
	if cue == 1 and t > 3.36:
		a["cue"] = 2
		var hit := Vector3(pos.x, _water_y, pos.z)
		_splash(hit, 170, 14.0, 9.0, 1.3)
		_splash(hit + heading * 6.0, 70, 8.0, 7.0, 0.9)
		_ring(hit, 3.0, 22.0, 4.5, 0.95)
		_ring(hit, 1.0, 13.0, 3.2, 0.7)
	if cue == 2 and t > 4.1:
		a["cue"] = 3
		_ring(Vector3(pos.x, _water_y, pos.z), 6.0, 30.0, 5.5, 0.5)
	return t < 8.0


func _whale_spout() -> void:
	## Two breaths at the surface — back, blow, back — and then the fluke dive.
	var spot := _water_spot(140.0, 250.0, HERO_ANGLE - 4.0, 45.0)
	if spot == Vector3.INF:
		return
	var heading := (_right * (1.0 if _rng.randf() < 0.5 else -1.0) + _fwd * _rng.randf_range(-0.5, 0.5)).normalized()
	var whale := _body_node(_make_whale_mesh())
	whale.scale = Vector3.ONE * 2.0
	_actors.append({"fn": _step_spout, "t": 0.0, "node": whale, "at": spot, "dir": heading, "cue": 0})


func _step_spout(a: Dictionary, dt: float) -> bool:
	var t: float = a["t"]
	var whale: MeshInstance3D = a["node"]
	var heading: Vector3 = a["dir"]
	var pos: Vector3 = (a["at"] as Vector3) + heading * 2.4 * t
	var pitch: float = 0.0
	var y: float = _water_y - 3.0
	if t < 8.0:
		# Two rolls at the surface: rise, show the back, sink a little.
		var u: float = fposmod(t, 4.0) / 4.0
		y = _water_y - 2.3 + 1.05 * sin(PI * u)
		pitch = deg_to_rad(6.0 * cos(PI * u))
	else:
		# Fluke up: the head goes down and the tail comes clear of the water.
		var u: float = clampf((t - 8.0) / 2.6, 0.0, 1.0)
		pitch = deg_to_rad(-80.0) * smoothstep(0.0, 1.0, u)
		y = lerpf(_water_y - 1.4, _water_y - 4.8, smoothstep(0.0, 1.0, u)) - maxf(t - 10.4, 0.0) * 4.5
	pos.y = y
	var b := Basis.looking_at(heading, Vector3.UP) * Basis(Vector3.RIGHT, pitch)
	whale.transform = Transform3D(b.scaled(whale.scale), pos)
	var head: Vector3 = pos + b * Vector3(0.0, 0.0, -4.2) * whale.scale.x
	var cue: int = a["cue"]
	if (cue == 0 and t > 1.4) or (cue == 1 and t > 5.4):
		a["cue"] = cue + 1
		_blow(Vector3(head.x, _water_y + 0.6, head.z))
		_ring(Vector3(head.x, _water_y, head.z), 2.0, 9.0, 3.0, 0.45)
	if t > 9.4 and t < 11.4 and _rng.randf() < 0.6:
		# Water streaming off the trailing edge of the flukes.
		var tail: Vector3 = pos + b * Vector3(_rng.randf_range(-3.0, 3.0), 0.0, 7.6) * whale.scale.x
		if tail.y > _water_y:
			_emit(tail, Vector3(_rng.randf_range(-0.4, 0.4), -0.5, _rng.randf_range(-0.4, 0.4)), 1.4, 0.32, 0.4)
	if cue == 2 and t > 11.2:
		a["cue"] = 3
		_ring(Vector3(pos.x, _water_y, pos.z), 3.0, 18.0, 4.5, 0.6)
	return t < 14.0


func _blow(at: Vector3) -> void:
	## A whale's breath: a column of mist that rises, spreads and hangs.
	for _i in 70:
		var v := Vector3(_rng.randfn(0.0, 0.8), _rng.randf_range(8.0, 13.0), _rng.randfn(0.0, 0.8))
		_emit(at, v, _rng.randf_range(1.8, 2.8), _rng.randf_range(0.35, 0.7), 1.3)


func _dolphins() -> void:
	## A pod crossing the bay, leaping in turn.
	var spot := _water_spot(120.0, 200.0, 12.0, 40.0)
	if spot == Vector3.INF:
		return
	var hand: float = -1.0 if _rng.randf() < 0.5 else 1.0
	var heading := (_right * hand + _fwd * _rng.randf_range(-0.25, 0.25)).normalized()
	var start: Vector3 = spot - heading * 70.0
	var mesh := _make_dolphin_mesh(3.6, Color("4f5b66"), Color("c9cbc6"))
	var pod: Array = []
	for i in 5:
		var mi := _body_node(mesh)
		mi.visible = false
		pod.append({
			"mi": mi, "lag": float(i) * 4.5 + _rng.randf_range(-1.0, 1.0), "side": _rng.randf_range(-4.0, 4.0),
			"ph": float(i) * 0.47 + _rng.randf_range(0.0, 0.3), "wet": 0,
		})
	var holder := Node3D.new()
	_root.add_child(holder)
	for d in pod:
		var mi: MeshInstance3D = d["mi"]
		mi.reparent(holder)
	_actors.append({"fn": _step_dolphins, "t": 0.0, "node": holder, "start": start, "dir": heading, "pod": pod})


func _step_dolphins(a: Dictionary, dt: float) -> bool:
	var t: float = a["t"]
	var heading: Vector3 = a["dir"]
	var across := heading.cross(Vector3.UP).normalized()
	var period: float = 2.1
	var air: float = 0.48
	for d: Dictionary in a["pod"]:
		var mi: MeshInstance3D = d["mi"]
		var travel: float = t * 7.5 - float(d["lag"])
		var base: Vector3 = (a["start"] as Vector3) + heading * travel + across * float(d["side"])
		var cycle: float = fposmod(t + float(d["ph"]), period) / period
		if cycle < air and t > 0.4 and t < 16.0:
			var u: float = cycle / air
			var h: float = 2.6 * sin(PI * u) - 0.6
			var slope: float = 2.6 * PI * cos(PI * u) / (air * period * 7.5)
			var pos := base + Vector3.UP * (_water_y + h - base.y)
			var b := Basis.looking_at(heading, Vector3.UP) * Basis(Vector3.RIGHT, atan(slope))
			mi.transform = Transform3D(b, pos)
			mi.visible = true
			var wet: int = d["wet"]
			if wet == 0 and u > 0.08:
				d["wet"] = 1
				_splash(Vector3(pos.x, _water_y, pos.z) - heading * 1.0, 14, 3.5, 1.6, 0.3)
				_ring(Vector3(pos.x, _water_y, pos.z) - heading * 1.0, 0.6, 4.5, 1.8, 0.6)
			elif wet == 1 and u > 0.88:
				d["wet"] = 2
				_splash(Vector3(pos.x, _water_y, pos.z) + heading * 1.2, 18, 3.0, 2.0, 0.3)
				_ring(Vector3(pos.x, _water_y, pos.z) + heading * 1.2, 0.6, 5.0, 2.0, 0.6)
		else:
			mi.visible = false
			d["wet"] = 0
	return t < 17.0


func _fish_jump() -> void:
	## A trout taking a fly. Mostly what you see is the ring it leaves.
	var spot := _water_spot(70.0, 190.0, 40.0, 14.0)
	if spot == Vector3.INF:
		return
	var heading := Vector3(_rng.randf_range(-1.0, 1.0), 0.0, _rng.randf_range(-1.0, 1.0)).normalized()
	var fish := _body_node(_make_dolphin_mesh(1.1, Color("6f7a72"), Color("d9d6c8")))
	fish.visible = false
	_actors.append({"fn": _step_fish, "t": 0.0, "node": fish, "at": spot, "dir": heading, "cue": 0})


func _step_fish(a: Dictionary, dt: float) -> bool:
	var t: float = a["t"]
	var fish: MeshInstance3D = a["node"]
	var heading: Vector3 = a["dir"]
	var at: Vector3 = a["at"]
	var air: float = 0.75
	if t < air:
		var u: float = t / air
		var pos := at + heading * (u - 0.5) * 2.4 + Vector3.UP * (1.3 * sin(PI * u) - 0.25)
		var b := Basis.looking_at(heading, Vector3.UP) * Basis(Vector3.RIGHT, atan(1.3 * PI * cos(PI * u) / 2.4))
		fish.transform = Transform3D(b, pos)
		fish.visible = true
	else:
		fish.visible = false
	var cue: int = a["cue"]
	if cue == 0:
		a["cue"] = 1
		_ring(at - heading * 1.2, 0.3, 3.5, 2.2, 0.7)
		_splash(at - heading * 1.2, 8, 2.5, 0.8, 0.18)
	elif cue == 1 and t > air:
		a["cue"] = 2
		_ring(at + heading * 1.2, 0.4, 5.0, 3.0, 0.8)
		_ring(at + heading * 1.2, 0.2, 2.6, 2.2, 0.6)
		_splash(at + heading * 1.2, 12, 3.0, 1.0, 0.2)
	return t < 4.0


# ------------------------------------------------------------- spray pool


func _make_spray() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var pts := [Vector3.UP, Vector3.DOWN, Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK]
	for y_i in [0, 1]:
		var apex: Vector3 = pts[y_i]
		var ring := [pts[2], pts[4], pts[3], pts[5]]
		for k in 4:
			var a: Vector3 = ring[k]
			var b: Vector3 = ring[(k + 1) % 4]
			_tri(st, apex, a, b, Color.WHITE, apex + a + b)
	var mat := spray_material()
	mat.emission_energy_multiplier = 0.35 if _mood == Mood.NIGHT else 0.6
	_spray = MultiMesh.new()
	_spray.transform_format = MultiMesh.TRANSFORM_3D
	_spray.use_colors = true
	_spray.mesh = st.commit()
	_spray.instance_count = SPRAY_POOL
	_spray.custom_aabb = _big_aabb()
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = _spray
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	LowPoly.cheap_draw(mi)
	_root.add_child(mi)
	_spray_pos.resize(SPRAY_POOL)
	_spray_vel.resize(SPRAY_POOL)
	_spray_life.resize(SPRAY_POOL)
	_spray_max.resize(SPRAY_POOL)
	_spray_size.resize(SPRAY_POOL)
	_spray_drag.resize(SPRAY_POOL)
	_spray_life.fill(0.0)
	_spray_live = 0
	_spray_next = 0
	var foam := _foam()
	for i in SPRAY_POOL:
		_spray.set_instance_color(i, foam)
		_spray.set_instance_transform(i, _hidden())


func _hidden() -> Transform3D:
	return Transform3D(Basis().scaled(Vector3.ONE * 0.001), _eye - Vector3.UP * 600.0)


func _emit(at: Vector3, vel: Vector3, life: float, size: float, drag: float) -> void:
	var i := _spray_next
	_spray_next = (_spray_next + 1) % SPRAY_POOL
	if _spray_life[i] <= 0.0:
		_spray_live += 1
	_spray_pos[i] = at
	_spray_vel[i] = vel
	_spray_life[i] = life
	_spray_max[i] = life
	_spray_size[i] = size
	_spray_drag[i] = drag


func _splash(at: Vector3, count: int, up: float, out: float, size: float) -> void:
	for _i in count:
		var a: float = _rng.randf() * TAU
		var r: float = sqrt(_rng.randf())
		var v := Vector3(cos(a) * out * r, up * _rng.randf_range(0.45, 1.0) * (1.15 - r * 0.5), sin(a) * out * r)
		_emit(at + Vector3(cos(a), 0.0, sin(a)) * r * size * 2.0, v, _rng.randf_range(0.9, 2.0), size * _rng.randf_range(0.5, 1.3), 0.25)


func _step_spray(dt: float) -> void:
	if _spray_live <= 0:
		return
	for i in SPRAY_POOL:
		var life: float = _spray_life[i]
		if life <= 0.0:
			continue
		life -= dt
		var p: Vector3 = _spray_pos[i]
		var v: Vector3 = _spray_vel[i]
		v.y -= 9.8 * dt * (0.35 if _spray_drag[i] > 1.0 else 1.0)
		v *= maxf(1.0 - _spray_drag[i] * dt, 0.0)
		p += v * dt
		if life <= 0.0 or (p.y < _water_y - 0.3 and v.y < 0.0):
			_spray_life[i] = 0.0
			_spray_live -= 1
			_spray.set_instance_transform(i, _hidden())
			continue
		_spray_life[i] = life
		_spray_pos[i] = p
		_spray_vel[i] = v
		# Mist puffs grow as they hang; droplets shrink as they fall.
		var k: float = life / _spray_max[i]
		var s: float = _spray_size[i] * (lerpf(1.9, 0.9, k) if _spray_drag[i] > 1.0 else sqrt(k))
		_spray.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ONE * s), p))


# ------------------------------------------------------------- ring pool


func _make_rings() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var sides: int = 28
	for i in sides:
		var a0: float = TAU * float(i) / float(sides)
		var a1: float = TAU * float(i + 1) / float(sides)
		var o0 := Vector3(cos(a0), 0.0, sin(a0))
		var o1 := Vector3(cos(a1), 0.0, sin(a1))
		_tri(st, o0, o1, o1 * 0.84, Color.WHITE, Vector3.UP)
		_tri(st, o0, o1 * 0.84, o0 * 0.84, Color.WHITE, Vector3.UP)
	var mat := ring_material()
	_rings = MultiMesh.new()
	_rings.transform_format = MultiMesh.TRANSFORM_3D
	_rings.use_colors = true
	_rings.mesh = st.commit()
	_rings.instance_count = RING_POOL
	_rings.custom_aabb = _big_aabb()
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = _rings
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	LowPoly.cheap_draw(mi)
	_root.add_child(mi)
	_ring_age.resize(RING_POOL)
	_ring_dur.resize(RING_POOL)
	_ring_r0.resize(RING_POOL)
	_ring_r1.resize(RING_POOL)
	_ring_alpha.resize(RING_POOL)
	_ring_pos.resize(RING_POOL)
	_ring_dur.fill(0.0)
	_ring_age.fill(1.0)
	_ring_next = 0
	for i in RING_POOL:
		_rings.set_instance_transform(i, _hidden())
		_rings.set_instance_color(i, Color(1, 1, 1, 0))


func _ring(at: Vector3, r0: float, r1: float, dur: float, alpha: float) -> void:
	var i := _ring_next
	_ring_next = (_ring_next + 1) % RING_POOL
	_ring_pos[i] = Vector3(at.x, _water_y + 0.08, at.z)
	_ring_age[i] = 0.0
	_ring_dur[i] = dur
	_ring_r0[i] = r0
	_ring_r1[i] = r1
	_ring_alpha[i] = alpha


func _step_rings(dt: float) -> void:
	var foam := _foam()
	for i in RING_POOL:
		var dur: float = _ring_dur[i]
		if dur <= 0.0:
			continue
		var age: float = _ring_age[i] + dt
		if age >= dur:
			_ring_dur[i] = 0.0
			_rings.set_instance_transform(i, _hidden())
			continue
		_ring_age[i] = age
		var k: float = age / dur
		var r: float = lerpf(_ring_r0[i], _ring_r1[i], 1.0 - pow(1.0 - k, 2.2))
		_rings.set_instance_transform(i, Transform3D(Basis().scaled(Vector3(r, 1.0, r)), _ring_pos[i]))
		_rings.set_instance_color(i, Color(foam.r, foam.g, foam.b, _ring_alpha[i] * (1.0 - k) * (1.0 - k)))


# ---------------------------------------------------------------- weather


func _mist(count: int) -> void:
	## Mist lying on the lake: a few feathered sheets stacked a few metres apart
	## over open water, each carrying wisps that flow downwind. Stacked, the
	## layers part and close over each other, which is what gives it depth.
	var color := Color("cba4ac")
	var opacity: float = 0.34
	match _mood:
		Mood.DAY:
			color = Color("dde5ea")
			opacity = 0.3
		Mood.NIGHT:
			color = Color("4e5a74")
			opacity = 0.32
	var plane := PlaneMesh.new()
	plane.size = Vector2.ONE
	var wind := (_right if _rng.randf() < 0.5 else -_right) * _rng.randf_range(1.4, 2.4) + _fwd * _rng.randf_range(-0.4, 0.4)
	var sheets: Array = []
	for i in count:
		var spot := _water_spot(110.0, 300.0, 40.0, 25.0)
		if spot == Vector3.INF:
			continue
		var mat := mist_material()
		mat.set_shader_parameter("mist_color", color)
		mat.set_shader_parameter("opacity", opacity * _rng.randf_range(0.7, 1.0))
		mat.set_shader_parameter("flow", Vector2(wind.x, wind.z) * _rng.randf_range(0.8, 1.2))
		mat.set_shader_parameter("grain", _rng.randf_range(0.009, 0.016))
		mat.set_shader_parameter("seed", _rng.randf_range(0.0, 50.0))
		mat.set_shader_parameter("fade", 0.0)
		var mi := MeshInstance3D.new()
		mi.mesh = plane
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		LowPoly.cheap_draw(mi)
		_root.add_child(mi)
		var lift: float = 2.0 + float(i % 3) * 4.0 + _rng.randf_range(0.0, 2.0)
		var size := Vector3(_rng.randf_range(220.0, 340.0), 1.0, _rng.randf_range(110.0, 170.0))
		mi.transform = Transform3D(Basis(_right, Vector3.UP, -_fwd).scaled(size), spot + Vector3.UP * lift)
		sheets.append(mat)
	if sheets.is_empty():
		return
	var holder := Node3D.new()
	_root.add_child(holder)
	_actors.append({"fn": _step_mist, "t": 0.0, "node": holder, "sheets": sheets})


func _step_mist(a: Dictionary, _dt: float) -> bool:
	var t: float = a["t"]
	if t > 5.0:
		return true
	for mat: ShaderMaterial in a["sheets"]:
		mat.set_shader_parameter("fade", smoothstep(0.0, 4.0, t))
	return true


func _balloons() -> void:
	## Hot-air balloons drifting over the vale. At dusk and after dark the burners
	## light the envelopes from inside.
	var palettes := [
		[Color("d9483b"), Color("f2c14e")],
		[Color("2f6db5"), Color("f4efe3"), Color("e0a03a")],
		[Color("3b9a6b"), Color("f0d36a")],
		[Color("c43d5b"), Color("f4efe3"), Color("3d4d8f")],
	]
	var slots := [
		[-26.0, 300.0, 4.5], [14.0, 560.0, 6.5], [31.0, 230.0, 1.0],
	]
	var wind := _right * (1.0 if _rng.randf() < 0.5 else -1.0) * _rng.randf_range(1.2, 1.9)
	var glow_mat := glow_material(Color(1.0, 0.62, 0.22), 4.0, 0.0)
	var flames := MultiMesh.new()
	flames.transform_format = MultiMesh.TRANSFORM_3D
	flames.use_custom_data = true
	var flame_mesh := SphereMesh.new()
	flame_mesh.radius = 0.5
	flame_mesh.height = 1.6
	flame_mesh.radial_segments = 6
	flame_mesh.rings = 3
	flames.mesh = flame_mesh
	flames.instance_count = slots.size()
	flames.custom_aabb = _big_aabb()
	var flame_mi := MultiMeshInstance3D.new()
	flame_mi.multimesh = flames
	flame_mi.material_override = glow_mat
	flame_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_root.add_child(flame_mi)
	var list: Array = []
	var order: Array = range(palettes.size())
	for i in range(order.size() - 1, 0, -1):
		var j: int = _rng.randi_range(0, i)
		var swap = order[i]
		order[i] = order[j]
		order[j] = swap
	for i in slots.size():
		var slot: Array = slots[i]
		var palette: Array = palettes[order[i] % palettes.size()]
		var mat := balloon_material()
		var mi := MeshInstance3D.new()
		mi.mesh = _make_balloon_mesh(palette, _rng.randi_range(0, 2))
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		LowPoly.cheap_draw(mi)
		_root.add_child(mi)
		var size: float = _rng.randf_range(0.95, 1.15)
		mi.scale = Vector3.ONE * size
		var p := _sky(float(slot[0]) + _rng.randf_range(-4.0, 4.0), float(slot[1]) * _rng.randf_range(0.9, 1.1), float(slot[2]))
		p.y = maxf(p.y, _water_y + 40.0)
		mi.position = p
		mi.rotation.y = _rng.randf() * TAU
		list.append({"mi": mi, "mat": mat, "ph": _rng.randf() * TAU, "next_burn": _rng.randf_range(0.5, 6.0), "burn": 0.0, "size": size})
	_actors.append({"fn": _step_balloons, "t": 0.0, "node": flame_mi, "list": list, "wind": wind, "flames": flames})


func _step_balloons(a: Dictionary, dt: float) -> bool:
	var t: float = a["t"]
	var wind: Vector3 = a["wind"]
	var flames: MultiMesh = a["flames"]
	var glow_k: float = 0.0
	match _mood:
		Mood.DUSK:
			glow_k = 0.9
		Mood.NIGHT:
			glow_k = 2.2
	var list: Array = a["list"]
	for i in list.size():
		var b: Dictionary = list[i]
		var mi: MeshInstance3D = b["mi"]
		var ph: float = b["ph"]
		mi.position += wind * dt * (0.8 + 0.2 * sin(ph))
		mi.position.y += cos(t * 0.21 + ph) * 0.35 * dt
		mi.rotation.y += 0.02 * dt
		var bearing := _bearing(mi.position)
		if absf(bearing) > 60.0 and signf(bearing) == signf(wind.dot(_right)):
			var back := mi.position - _eye
			back.y = 0.0
			mi.position = _view(-bearing * 0.98, back.length(), mi.position.y - _eye.y)
		# Burner: a few seconds of roar every so often.
		if t >= float(b["next_burn"]):
			b["burn"] = _rng.randf_range(1.2, 2.8)
			b["next_burn"] = t + _rng.randf_range(5.0, 11.0)
		var burn: float = maxf(float(b["burn"]) - dt, 0.0)
		b["burn"] = burn
		var on: float = 1.0 if burn > 0.0 else 0.0
		var flicker: float = on * (0.75 + 0.25 * sin(t * 37.0 + ph * 5.0))
		var size: float = b["size"]
		var mouth: Vector3 = mi.position + Vector3.UP * 1.0 * size
		var s: float = maxf(flicker, 0.001) * size
		flames.set_instance_transform(i, Transform3D(Basis().scaled(Vector3(s, s * (1.0 + 0.3 * flicker), s)), mouth))
		flames.set_instance_custom_data(i, Color(0.0, 0.0, flicker, 0.0))
		var mat: StandardMaterial3D = b["mat"]
		mat.emission_energy_multiplier = lerpf(mat.emission_energy_multiplier, glow_k * on, 1.0 - exp(-6.0 * dt))
	return true


static func _make_balloon_mesh(palette: Array, style: int) -> ArrayMesh:
	## Envelope, skirt and basket, origin at the envelope's mouth. Eighteen metres
	## tall: the real size, which at four hundred metres is about forty pixels.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var profile := [
		[1.5, 0.0], [2.6, 1.6], [4.6, 4.4], [6.4, 7.6], [7.3, 10.6],
		[7.2, 13.2], [6.2, 15.6], [4.4, 17.3], [2.2, 18.2], [0.0, 18.5],
	]
	var gores: int = 14
	for k in profile.size() - 1:
		var r0: float = float(profile[k][0])
		var y0: float = float(profile[k][1])
		var r1: float = float(profile[k + 1][0])
		var y1: float = float(profile[k + 1][1])
		for g in gores:
			var a0: float = TAU * float(g) / float(gores)
			var a1: float = TAU * float(g + 1) / float(gores)
			var col: Color = palette[g % palette.size()]
			if style == 1 and (k == 4 or k == 5):
				# A band round the equator.
				col = palette[(g + 1) % palette.size()]
			elif style == 2 and k >= 6:
				# A crown in the second colour.
				col = palette[1 % palette.size()]
			if k == 0:
				col = col.darkened(0.25)
			var p00 := Vector3(cos(a0) * r0, y0, sin(a0) * r0)
			var p01 := Vector3(cos(a1) * r0, y0, sin(a1) * r0)
			var p10 := Vector3(cos(a0) * r1, y1, sin(a0) * r1)
			var p11 := Vector3(cos(a1) * r1, y1, sin(a1) * r1)
			var centroid := (p00 + p01 + p10 + p11) * 0.25
			var out := centroid - Vector3(0.0, centroid.y, 0.0)
			if k == profile.size() - 2:
				out = centroid - Vector3(0.0, 12.0, 0.0)
			_tri(st, p00, p01, p11, col, out)
			_tri(st, p00, p11, p10, col, out)
	# Basket, hung a couple of metres under the mouth on short lines.
	var wicker := Color("6b4a2e")
	var bh := Vector3(0.0, -2.8, 0.0)
	var s: float = 0.7
	var corners := [Vector3(-s, 0, -s), Vector3(s, 0, -s), Vector3(s, 0, s), Vector3(-s, 0, s)]
	for k in 4:
		var c0: Vector3 = corners[k]
		var c1: Vector3 = corners[(k + 1) % 4]
		var out: Vector3 = (c0 + c1) * 0.5
		_tri(st, bh + c0, bh + c1, bh + c1 + Vector3.UP * 1.1, wicker, out)
		_tri(st, bh + c0, bh + c1 + Vector3.UP * 1.1, bh + c0 + Vector3.UP * 1.1, wicker, out)
		# A line from each corner up to the skirt.
		var top: Vector3 = c0.normalized() * 1.4
		var side: Vector3 = c0.cross(Vector3.UP).normalized() * 0.06
		_tri(st, bh + c0 + Vector3.UP * 1.1 - side, bh + c0 + Vector3.UP * 1.1 + side, top + side, Color("2c2622"), out)
		_tri(st, bh + c0 + Vector3.UP * 1.1 - side, top + side, top - side, Color("2c2622"), out)
	return st.commit()


func _fireflies(count: int) -> void:
	## A scatter of lights drifting over the drop below the bench.
	var mat := glow_material(Color(0.95, 1.0, 0.5), 3.6 if _mood == Mood.NIGHT else 2.6, 1.0)
	var mesh := SphereMesh.new()
	mesh.radius = 0.5
	mesh.height = 1.0
	mesh.radial_segments = 6
	mesh.rings = 3
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = count
	mm.custom_aabb = _big_aabb()
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_root.add_child(mi)
	var homes := PackedVector3Array()
	var phases := PackedFloat32Array()
	var sizes := PackedFloat32Array()
	for i in count:
		var ahead: float = _rng.randf_range(5.0, 30.0)
		homes.append(_view(_rng.randf_range(-40.0, 40.0), ahead, _rng.randf_range(-ahead * 0.35, 0.5)))
		phases.append(_rng.randf() * TAU)
		sizes.append(_rng.randf_range(0.035, 0.06) * (1.0 + ahead * 0.03))
		mm.set_instance_custom_data(i, Color(_rng.randf(), _rng.randf(), 1.0, 0.0))
	_actors.append({"fn": _step_fireflies, "t": 0.0, "node": mi, "mm": mm, "homes": homes, "ph": phases, "sz": sizes})


func _step_fireflies(a: Dictionary, _dt: float) -> bool:
	var t: float = a["t"]
	var mm: MultiMesh = a["mm"]
	var homes: PackedVector3Array = a["homes"]
	var phases: PackedFloat32Array = a["ph"]
	var sizes: PackedFloat32Array = a["sz"]
	var fade: float = smoothstep(0.0, 3.0, t)
	for i in homes.size():
		var ph: float = phases[i]
		var p: Vector3 = homes[i] + Vector3(sin(t * 0.29 + ph) * 1.8, sin(t * 0.43 + ph * 1.7) * 0.8, cos(t * 0.23 + ph * 0.6) * 1.8)
		mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ONE * sizes[i] * fade), p))
	return true


func _shooting_star() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# A sliver: bright head at the origin, fading tail down +Z.
	var head := Color(1.0, 0.95, 0.85, 1.0)
	var tail := Color(0.7, 0.8, 1.0, 0.0)
	st.set_normal(Vector3.UP)
	st.set_color(head)
	st.add_vertex(Vector3(-0.6, 0.0, 0.0))
	st.set_color(head)
	st.add_vertex(Vector3(0.6, 0.0, 0.0))
	st.set_color(tail)
	st.add_vertex(Vector3(0.0, 0.0, 70.0))
	var mat := star_material()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_root.add_child(mi)
	var start := _sky(_rng.randf_range(-35.0, 35.0), 1600.0, _rng.randf_range(14.0, 24.0))
	var dir := (_right * (1.0 if _rng.randf() < 0.5 else -1.0) + Vector3.DOWN * _rng.randf_range(0.3, 0.7)).normalized()
	_actors.append({"fn": _step_star, "t": 0.0, "node": mi, "start": start, "dir": dir, "mat": mat})


func _step_star(a: Dictionary, _dt: float) -> bool:
	var t: float = a["t"]
	var mi: MeshInstance3D = a["node"]
	var dir: Vector3 = a["dir"]
	var pos: Vector3 = (a["start"] as Vector3) + dir * t * 900.0
	var to_eye := (_eye - pos).normalized()
	# The streak lies along its own track and turns its face to the eye.
	var z := -dir
	var x := to_eye.cross(z).normalized()
	var y := z.cross(x)
	var life: float = 0.7
	var fade: float = sin(PI * clampf(t / life, 0.0, 1.0))
	mi.transform = Transform3D(Basis(x, y, z).scaled(Vector3(2.4, 1.0, 1.0 + fade)), pos)
	(a["mat"] as StandardMaterial3D).albedo_color = Color(fade, fade, fade, fade)
	return t < life
