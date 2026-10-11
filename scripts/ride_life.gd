extends Node3D
## What flies while the rider is moving — the life of the kilometres between
## benches, where LookoutLife only owns the seated view. A skein crosses the
## sky ahead every little while, a bird darts low over the tarmac now and
## then, and once in a while a buzzard hangs in a circle over the roadside.
##
## All of it is the overlook's shared bird mesh and bird shader in at most a
## couple of small MultiMeshes at a time: the eye is meant to notice it, the
## frame time is not. Nothing spawns over the corridor — even the low dart
## crosses above handlebar height for a heartbeat, never through it.

const LookoutLifeGD := preload("res://scripts/lookout_life.gd")
const LowPoly := preload("res://scripts/low_poly.gd")

## main.gd's LightingMode and RoadPath's theme ids.
enum Mood { DUSK, DAY, NIGHT }
const COUNTRY := 4

## Seconds between flights. Rare enough that a crossing still reads as a
## happening, common enough that a five-minute ride meets a few of them.
const EVENT_GAP := Vector2(8.0, 21.0)
const MAX_ACTORS := 2

var _player: Node
var _path: Node
var _main: Node
var _rng := RandomNumberGenerator.new()
var _actors: Array[Dictionary] = []
var _t: float = 0.0
var _next: float = 4.0

var _bird_mat: ShaderMaterial
var _bird_mesh: ArrayMesh


func _ready() -> void:
	_path = get_node_or_null("/root/RoadPath")
	_main = get_parent()
	_player = _main.get_node_or_null("Player") if _main else null
	_rng.seed = 0x51DE
	_bird_mat = LookoutLifeGD.bird_material()
	_bird_mesh = LookoutLifeGD.bird_mesh()


func _process(delta: float) -> void:
	if _player == null or _path == null or _bird_mesh == null:
		return
	if bool(_player.get("seated")):
		return  # The bench has its own life; the road is quiet here anyway.
	_step(minf(delta, 0.1))


func _step(dt: float) -> void:
	_t += dt
	var i := 0
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
	if _t >= _next and _actors.size() < MAX_ACTORS:
		_spawn()
		var gap := _rng.randf_range(EVENT_GAP.x, EVENT_GAP.y)
		# A night bird is a silhouette looking for a dark sky: they still come,
		# just half as often.
		if _mood_now() == Mood.NIGHT:
			gap *= 2.0
		_next = _t + gap


func _mood_now() -> int:
	return int(_main.get("lighting_mode")) if _main != null else Mood.DUSK


func _dark_bird() -> Color:
	match _mood_now():
		Mood.DAY:
			return Color("2b2c33")
		Mood.NIGHT:
			return Color("0f1119")
	return Color("1d1a24")


func _spawn() -> void:
	var roll := _rng.randf()
	if roll < 0.52:
		_skein()
	elif roll < 0.85:
		_dart()
	else:
		_soarer()


func _air_ceiling(z_a: float, la: float, z_b: float, lb: float) -> float:
	## The highest ground under the flight line. A crossing that ignores the
	## hills under it reads as birds popping out of the soil — a few samples
	## along the line is all it takes to keep them in the air.
	var ceil := -INF
	for t in [0.0, 0.25, 0.5, 0.75, 1.0]:
		ceil = maxf(ceil, _path.ground_at(lerpf(z_a, z_b, t), lerpf(la, lb, t)).y)
	return ceil


func _skein() -> void:
	## A flock crossing the sky well ahead — geese in a skein out in the open
	## country, a loose chatter everywhere else. From the saddle a moving line
	## of birds is the thing that makes a valley read as occupied.
	var z_here: float = maxf(float(_player.get("track_z")), 0.0)
	var side: float = 1.0 if _rng.randf() < 0.5 else -1.0
	var z_a := z_here + _rng.randf_range(130.0, 230.0)
	var z_b := z_a + _rng.randf_range(30.0, 80.0)
	var la := side * _rng.randf_range(40.0, 95.0)
	var lb := -side * _rng.randf_range(40.0, 95.0)
	var ceil := _air_ceiling(z_a, la, z_b, lb)
	var start: Vector3 = _path.point_at(z_a, la)
	var finish: Vector3 = _path.point_at(z_b, lb)
	start.y = maxf(start.y + _rng.randf_range(16.0, 34.0), ceil + 11.0)
	finish.y = maxf(finish.y + _rng.randf_range(16.0, 34.0), ceil + 13.0)
	var v_form := int(_path.theme_at(z_a)) == COUNTRY and _rng.randf() < 0.6
	var count := _rng.randi_range(9, 15) if v_form else _rng.randi_range(5, 10)
	var span := _rng.randf_range(1.5, 2.1) if v_form else _rng.randf_range(1.0, 1.5)
	var speed := _rng.randf_range(11.0, 16.0) if v_form else _rng.randf_range(13.0, 19.0)
	_crossing(count, span, speed, start, finish, v_form)


func _dart() -> void:
	## A bird bursting across the road ahead at handlebar height — the life a
	## rider actually sees most often. Low and quick, out of one verge and into
	## the other; at night it is near-invisible and stays rare.
	var z_here: float = maxf(float(_player.get("track_z")), 0.0)
	var side: float = 1.0 if _rng.randf() < 0.5 else -1.0
	var z_a := z_here + _rng.randf_range(45.0, 100.0)
	var z_b := z_a + _rng.randf_range(-4.0, 10.0)
	var la := side * _rng.randf_range(14.0, 34.0)
	var lb := -side * _rng.randf_range(16.0, 40.0)
	var ceil := _air_ceiling(z_a, la, z_b, lb)
	var road_y: float = (_path.point_at(z_a, 0.0).y + _path.point_at(z_b, 0.0).y) * 0.5
	var start: Vector3 = _path.point_at(z_a, la)
	var finish: Vector3 = _path.point_at(z_b, lb)
	var low := maxf(ceil + 1.6, road_y + _rng.randf_range(1.4, 2.4))
	start.y = low
	finish.y = low + _rng.randf_range(1.0, 3.5)
	_crossing(
		_rng.randi_range(1, 3), _rng.randf_range(0.9, 1.25),
		_rng.randf_range(16.0, 24.0), start, finish, false
	)


func _soarer() -> void:
	## One buzzard hanging in a slow circle high over the roadside: barely
	## flapping, a wing shape the eye keeps finding between the road and the
	## sky. Where a skein passes through, this one owns a piece of air.
	var z_here: float = maxf(float(_player.get("track_z")), 0.0)
	var side: float = 1.0 if _rng.randf() < 0.5 else -1.0
	var cz := z_here + _rng.randf_range(150.0, 300.0)
	var clat := side * _rng.randf_range(25.0, 70.0)
	var radius := _rng.randf_range(16.0, 30.0)
	var centre: Vector3 = _path.point_at(cz, clat)
	var ceil := -INF
	for k in 6:
		var a := TAU * float(k) / 6.0
		ceil = maxf(ceil, _path.ground_at(cz + sin(a) * radius, clat + cos(a) * radius).y)
	centre.y = maxf(centre.y + _rng.randf_range(24.0, 36.0), ceil + 18.0)
	var flock := _flock(1, _dark_bird(), _rng.randf_range(2.2, 2.8), Vector2(9.0, 11.0), 0.0)
	var rate := _rng.randf_range(0.35, 0.55) * (1.0 if _rng.randf() < 0.5 else -1.0)
	_actors.append(
		{
			"fn": _step_soarer, "t": 0.0, "node": flock["node"], "f": flock,
			"c": centre, "r": radius, "rate": rate, "a0": _rng.randf() * TAU,
			"dur": _rng.randf_range(13.0, 21.0),
		}
	)


func _step_soarer(a: Dictionary, dt: float) -> bool:
	var t: float = a["t"]
	var f: Dictionary = a["f"]
	var ang := float(a["a0"]) + float(a["rate"]) * t
	var pos := (a["c"] as Vector3) + Vector3(cos(ang), sin(t * 0.4) * 0.06, sin(ang)) * float(a["r"])
	_put(f, 0, pos, dt)
	# Mostly a glide with the wings held in a V; a couple of beats every few
	# seconds keeps the circle honest.
	var mm: MultiMesh = f["mm"]
	var c: Color = mm.get_instance_custom_data(0)
	mm.set_instance_custom_data(0, Color(c.r, 1.0 if fposmod(t + float(a["a0"]), 9.0) < 1.1 else 0.0, c.b, 0.0))
	return t < float(a["dur"])


func _crossing(count: int, span: float, speed: float, start: Vector3, finish: Vector3, v_form: bool) -> void:
	## The shared crossing actor: a lead point moving start→finish, the rest of
	## the flock hanging off it in a skein or a loose cluster.
	var flock := _flock(count, _dark_bird(), span, Vector2(13.0, 17.0) if v_form else Vector2(22.0, 30.0), 1.0)
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
	_actors.append(
		{
			"fn": _step_crossing, "t": 0.0, "node": flock["node"], "f": flock,
			"start": start, "heading": heading, "speed": speed,
			"length": start.distance_to(finish), "offsets": offsets, "phases": phases,
			"v": v_form,
		}
	)


func _step_crossing(a: Dictionary, dt: float) -> bool:
	var t: float = a["t"]
	var f: Dictionary = a["f"]
	var lead: Vector3 = (a["start"] as Vector3) + (a["heading"] as Vector3) * float(a["speed"]) * t
	var offsets: PackedVector3Array = a["offsets"]
	var phases: PackedFloat32Array = a["phases"]
	var loose: float = 0.25 if bool(a["v"]) else 1.0
	for i in int(f["n"]):
		var ph: float = phases[i]
		var wob := (
			Vector3(sin(t * 0.9 + ph), sin(t * 1.3 + ph * 1.7) * 0.6, cos(t * 0.7 + ph))
			* float(f["span"]) * 1.4 * loose
		)
		_put(f, i, lead + offsets[i] + wob, dt)
	return float(a["speed"]) * t < float(a["length"]) + 30.0


func _flock(count: int, color: Color, span: float, beat_rate: Vector2, flap: float) -> Dictionary:
	## One MultiMesh per flight: the wingbeat lives in the shader, so a flock is
	## a handful of transforms and a colour each, same as the overlook's birds.
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = _bird_mesh
	mm.instance_count = count
	# Birds roam the sky far off their node's origin; culling needs the room.
	mm.custom_aabb = AABB(Vector3(-3000.0, -1200.0, -3000.0), Vector3(6000.0, 2400.0, 6000.0))
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.material_override = _bird_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	LowPoly.cheap_draw(mi)
	add_child(mi)
	var lin := color.srgb_to_linear()
	var prev := PackedVector3Array()
	var dirs := PackedVector3Array()
	var banks := PackedFloat32Array()
	prev.resize(count)
	dirs.resize(count)
	banks.resize(count)
	for i in count:
		var jitter := _rng.randf_range(-0.05, 0.05)
		mm.set_instance_color(i, Color(lin.r + jitter * lin.r, lin.g + jitter * lin.g, lin.b + jitter * lin.b))
		mm.set_instance_custom_data(i, Color(_rng.randf(), flap, _rng.randf_range(beat_rate.x, beat_rate.y) / 40.0, 0.0))
		prev[i] = Vector3.INF
		dirs[i] = Vector3.FORWARD
		mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ONE * 0.001), Vector3(0.0, -500.0, 0.0)))
	return {"mm": mm, "node": mi, "n": count, "span": span, "prev": prev, "dir": dirs, "bank": banks}


func _put(f: Dictionary, i: int, pos: Vector3, dt: float) -> void:
	## Place bird `i` and point it along the way it actually moved, banked into
	## its turn the way a bird leans into a curve.
	var prev: PackedVector3Array = f["prev"]
	var dirs: PackedVector3Array = f["dir"]
	var banks: PackedFloat32Array = f["bank"]
	var dir: Vector3 = dirs[i]
	var speed := 0.0
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
	var up := Vector3.UP if absf(dir.y) < 0.97 else Vector3.FORWARD
	var b := Basis.looking_at(dir, up) * Basis(Vector3.BACK, banks[i])
	(f["mm"] as MultiMesh).set_instance_transform(i, Transform3D(b.scaled(Vector3.ONE * float(f["span"])), pos))
