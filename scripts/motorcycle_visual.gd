extends Node3D
## Café racer. Faces +Z, tyres on y = 0.
##
## One tubular chassis: every part hangs off a joint. Forks run to the front
## axle, the swingarm runs to the rear, the tank sits on the top tube. That is
## what stops it reading as a pile of primitives parked next to each other.
## Every garage bike is the same kind of motorcycle: round lamp, clip-ons,
## teardrop tank, hump tail. Paint, tank, seat and pipes change. Fairings do not.

const LowPoly := preload("res://scripts/low_poly.gd")
const BikeCatalog := preload("res://scripts/bike_catalog.gd")
const CONTACT_SHADOW_SHADER: Shader = preload("res://shaders/contact_shadow.gdshader")

const BLACK := Color("141418")
const BLACK_S := Color("22222a")
const BLACK_D := Color("0c0c10")
const COPPER := Color("b8733a")
const COPPER_D := Color("8a5528")
const ALUM := Color("9aa3ad")
const ALUM_D := Color("6a727c")
const CHROME := Color("c5ccd3")
const TYRE := Color("0b0b0f")
const RUBBER := Color("18181e")
const LEATHER := Color("2a1812")
const LAMP := Color(3.4, 3.1, 2.4)
const TAIL := Color(2.8, 0.25, 0.22)
const DIAL := Color(0.28, 0.48, 0.62)
const DIAL_LIT := Color(1.4, 1.9, 2.3)
const NEEDLE := Color(2.8, 0.6, 0.4)
const CREAM := Color("e8dcc4")
const PAINT := Color("c92a38")
const PAINT_D := Color("8a1c28")
const BLUE := Color("2f6aa0")
const BLUE_D := Color("1e4a74")
const GOLD := Color("c9a24a")
const GOLD_D := Color("8a6a28")
const GREEN := Color("1e4a32")
const GREEN_D := Color("123224")
const INK := Color("1c1c22")
const INK_D := Color("101014")
const MIRROR := Color("9fb2c4")
const SHELL := Color("3b4450")

const METALS: Array[Color] = [ALUM, ALUM_D, CHROME, COPPER, COPPER_D]
const PAINTED: Array[Color] = [PAINT, PAINT_D, CREAM, BLUE, BLUE_D, GOLD, GOLD_D, GREEN, GREEN_D, INK, INK_D]

const HEADLIGHT_AT := Vector3(0, 0.82, 0.64)
const WHEEL_R := 0.33
const FRONT_Z := 0.80
const REAR_Z := -0.74
const HEAD := Vector3(0.0, 0.78, 0.50)
const SEAT_J := Vector3(0.0, 0.70, -0.28)
const PIVOT := Vector3(0.0, 0.38, -0.22)
const ENGINE := Vector3(0.0, 0.44, 0.08)
const SIDES := 16
const DIAL_TOP_SPEED := 62.0
const MAX_BAR_STEER := deg_to_rad(11.0)

var _bars: Node3D
var _front: MeshInstance3D
var _rear: MeshInstance3D
var _spin: float = 0.0
var _rider: Node
var _needles: Array[Node3D] = []
var _needle_base: Basis = Basis.IDENTITY
var _revs: float = 0.0
var _headlight: SpotLight3D
var _hero_rig: Node3D
var _hero_cam: Camera3D
var _hero_view: bool = false
var _hero_yaw0: float = deg_to_rad(18.0)
var _hero_t: float = 0.0
var _bike_style: int = 0
var _kits: Array[Node3D] = []
var _fenders: Array[MeshInstance3D] = []
var _dial_top_speed: float = DIAL_TOP_SPEED


func _ready() -> void:
	_rider = get_parent()
	_build_body()
	_bars = _build_steering()
	_front = _build_wheel(Vector3(0, WHEEL_R - _bars.position.y, FRONT_Z - _bars.position.z), true)
	_bars.add_child(_front)
	_rear = _build_wheel(Vector3(0, WHEEL_R, REAR_Z), false)
	_build_contact_shadow()
	_build_bike_variants()
	set_bike_style(_bike_style)
	_build_hero_camera()


func _process(delta: float) -> void:
	if _hero_view and _hero_rig:
		# A small sway, never a full orbit — orbiting looked off the end of the road.
		_hero_t += delta
		_hero_rig.rotation.y = _hero_yaw0 + sin(_hero_t * 0.35) * deg_to_rad(10.0)
		return
	var speed: float = _rider.speed if _rider and "speed" in _rider else 0.0
	if _front:
		_spin += speed / WHEEL_R * delta
		_front.rotation.x = _spin
		_rear.rotation.x = _spin
	var lean: float = _rider.lean if _rider and "lean" in _rider else 0.0
	var steer := Input.get_axis("steer_left", "steer_right") if InputMap.has_action("steer_left") else 0.0
	var target_bar_y := -lean * 0.15 + steer * MAX_BAR_STEER
	_bars.rotation.y = lerpf(_bars.rotation.y, target_bar_y, 1.0 - exp(-12.0 * delta))
	if _needles.is_empty():
		return
	var v: float = clampf(speed / _dial_top_speed, 0.0, 1.0)
	_revs = lerpf(_revs, fposmod(v * 3.4, 1.0) * 0.75 + v * 0.25, 1.0 - exp(-6.0 * delta))
	_needles[0].basis = _needle_base * Basis(Vector3.UP, lerpf(2.3, -2.3, v))
	_needles[1].basis = _needle_base * Basis(Vector3.UP, lerpf(2.3, -2.3, _revs))


func set_hero_view(on: bool) -> void:
	_hero_view = on
	_hero_t = 0.0
	process_mode = Node.PROCESS_MODE_ALWAYS if on else Node.PROCESS_MODE_INHERIT
	if _hero_rig:
		_hero_rig.rotation.y = _hero_yaw0
	var ride_cam: Camera3D = _rider.get_node_or_null("CameraPivot/Camera3D") if _rider else null
	if on:
		if _hero_cam:
			_hero_cam.make_current()
	else:
		if _hero_cam:
			_hero_cam.current = false
			if ride_cam:
				ride_cam.make_current()


func set_bike_style(style: int) -> void:
	var n := _kits.size()
	if n == 0:
		return
	_bike_style = clampi(style, 0, n - 1)
	_dial_top_speed = float(BikeCatalog.BIKES[_bike_style]["top_speed"])
	for i in n:
		_kits[i].visible = i == _bike_style
	for i in _fenders.size():
		_fenders[i].visible = i == _bike_style


func _build_bike_variants() -> void:
	## Five cafés, one family. The diamond frame, twin and wheels stay; tank,
	## seat, tail and pipes are rebuilt so the picker changes the machine.
	_make_kit("MesaKit", _mesa_spec())
	_make_kit("SabreKit", _sabre_spec())
	_make_kit("HalcyonKit", _halcyon_spec())
	_make_kit("TempestKit", _tempest_spec())
	_make_kit("RavenKit", _raven_spec())


func _mesa_spec() -> Dictionary:
	## Classic red café. Honest teardrop, cream belly, one megaphone.
	return {
		"paint": PAINT,
		"belly": CREAM,
		"stripe": CREAM,
		"pipe": CHROME,
		"tip": ALUM_D,
		"exhaust": "single",
		"knee": 0.178,
		"filler_z": -0.12,
		"stripe_len": 0.62,
		"tank_c": [
			Vector3(0, 0.86, 0.58),
			Vector3(0, 0.84, 0.42),
			Vector3(0, 0.82, 0.22),
			Vector3(0, 0.81, 0.02),
			Vector3(0, 0.82, -0.16),
			Vector3(0, 0.84, -0.28),
		],
		"tank_r": [
			Vector2(0.070, 0.052),
			Vector2(0.120, 0.082),
			Vector2(0.175, 0.110),
			Vector2(0.185, 0.112),
			Vector2(0.140, 0.090),
			Vector2(0.090, 0.065),
		],
		"belly_c": [
			Vector3(0, 0.76, 0.42),
			Vector3(0, 0.74, 0.18),
			Vector3(0, 0.735, -0.02),
			Vector3(0, 0.75, -0.18),
		],
		"belly_r": [Vector2(0.090, 0.042), Vector2(0.145, 0.050), Vector2(0.150, 0.048), Vector2(0.100, 0.038)],
		"seat_c": [Vector3(0, 0.78, -0.18), Vector3(0, 0.76, -0.34), Vector3(0, 0.78, -0.48)],
		"seat_r": [Vector2(0.092, 0.034), Vector2(0.086, 0.030), Vector2(0.070, 0.026)],
		"tail_c": [
			Vector3(0, 0.84, -0.46),
			Vector3(0, 0.88, -0.60),
			Vector3(0, 0.90, -0.74),
			Vector3(0, 0.86, -0.86),
		],
		"tail_r": [Vector2(0.095, 0.050), Vector2(0.082, 0.046), Vector2(0.062, 0.038), Vector2(0.038, 0.028)],
	}


func _sabre_spec() -> Dictionary:
	## Longer café. Slimmer tank, tucked seat, stretched hump, twin pipes.
	return {
		"paint": BLUE,
		"belly": CREAM,
		"stripe": CREAM,
		"pipe": CHROME,
		"tip": ALUM_D,
		"exhaust": "twin",
		"knee": 0.162,
		"filler_z": -0.16,
		"stripe_len": 0.70,
		"tank_c": [
			Vector3(0, 0.87, 0.64),
			Vector3(0, 0.85, 0.44),
			Vector3(0, 0.83, 0.20),
			Vector3(0, 0.82, -0.02),
			Vector3(0, 0.83, -0.22),
			Vector3(0, 0.85, -0.38),
		],
		"tank_r": [
			Vector2(0.058, 0.046),
			Vector2(0.100, 0.072),
			Vector2(0.148, 0.096),
			Vector2(0.158, 0.098),
			Vector2(0.118, 0.078),
			Vector2(0.072, 0.052),
		],
		"belly_c": [
			Vector3(0, 0.76, 0.44),
			Vector3(0, 0.74, 0.18),
			Vector3(0, 0.735, -0.04),
			Vector3(0, 0.75, -0.22),
		],
		"belly_r": [Vector2(0.082, 0.038), Vector2(0.132, 0.046), Vector2(0.138, 0.044), Vector2(0.090, 0.034)],
		"seat_c": [Vector3(0, 0.78, -0.24), Vector3(0, 0.76, -0.42), Vector3(0, 0.78, -0.56)],
		"seat_r": [Vector2(0.080, 0.030), Vector2(0.074, 0.026), Vector2(0.058, 0.022)],
		"tail_c": [
			Vector3(0, 0.82, -0.52),
			Vector3(0, 0.86, -0.68),
			Vector3(0, 0.88, -0.84),
			Vector3(0, 0.84, -0.98),
		],
		"tail_r": [Vector2(0.084, 0.044), Vector2(0.070, 0.038), Vector2(0.050, 0.030), Vector2(0.030, 0.020)],
	}


func _halcyon_spec() -> Dictionary:
	## Thruxton peanut. British racing green, gold pinstripe, twin reverse-cones.
	return {
		"paint": GREEN,
		"tail_paint": GOLD,
		"belly": GOLD,
		"stripe": GOLD,
		"pipe": CHROME,
		"tip": CHROME,
		"exhaust": "twin",
		"knee": 0.198,
		"filler_z": -0.08,
		"stripe_len": 0.56,
		"tank_c": [
			Vector3(0, 0.88, 0.52),
			Vector3(0, 0.87, 0.36),
			Vector3(0, 0.85, 0.16),
			Vector3(0, 0.84, -0.02),
			Vector3(0, 0.85, -0.16),
			Vector3(0, 0.86, -0.26),
		],
		"tank_r": [
			Vector2(0.078, 0.058),
			Vector2(0.138, 0.092),
			Vector2(0.198, 0.122),
			Vector2(0.208, 0.126),
			Vector2(0.150, 0.096),
			Vector2(0.095, 0.068),
		],
		"belly_c": [
			Vector3(0, 0.76, 0.36),
			Vector3(0, 0.73, 0.14),
			Vector3(0, 0.725, -0.04),
			Vector3(0, 0.75, -0.16),
		],
		"belly_r": [Vector2(0.100, 0.044), Vector2(0.162, 0.054), Vector2(0.168, 0.052), Vector2(0.112, 0.040)],
		"seat_c": [Vector3(0, 0.80, -0.16), Vector3(0, 0.78, -0.30), Vector3(0, 0.80, -0.42)],
		"seat_r": [Vector2(0.100, 0.036), Vector2(0.094, 0.032), Vector2(0.078, 0.028)],
		"tail_c": [
			Vector3(0, 0.86, -0.40),
			Vector3(0, 0.92, -0.54),
			Vector3(0, 0.94, -0.68),
			Vector3(0, 0.88, -0.82),
		],
		"tail_r": [Vector2(0.108, 0.054), Vector2(0.092, 0.050), Vector2(0.070, 0.042), Vector2(0.042, 0.030)],
	}


func _tempest_spec() -> Dictionary:
	## Italian round-case café. Fat cream tank, gold hump, upswept megaphones.
	return {
		"paint": CREAM,
		"tail_paint": GOLD,
		"belly": GOLD,
		"stripe": GOLD,
		"pipe": CHROME,
		"tip": COPPER,
		"exhaust": "high",
		"knee": 0.208,
		"filler_z": -0.10,
		"stripe_len": 0.58,
		"tank_c": [
			Vector3(0, 0.90, 0.54),
			Vector3(0, 0.88, 0.38),
			Vector3(0, 0.86, 0.16),
			Vector3(0, 0.85, -0.04),
			Vector3(0, 0.86, -0.18),
			Vector3(0, 0.88, -0.30),
		],
		"tank_r": [
			Vector2(0.090, 0.064),
			Vector2(0.150, 0.100),
			Vector2(0.210, 0.130),
			Vector2(0.220, 0.132),
			Vector2(0.165, 0.102),
			Vector2(0.102, 0.072),
		],
		"belly_c": [
			Vector3(0, 0.76, 0.38),
			Vector3(0, 0.73, 0.14),
			Vector3(0, 0.725, -0.04),
			Vector3(0, 0.75, -0.16),
		],
		"belly_r": [Vector2(0.108, 0.046), Vector2(0.168, 0.056), Vector2(0.174, 0.054), Vector2(0.116, 0.042)],
		"seat_c": [Vector3(0, 0.82, -0.18), Vector3(0, 0.80, -0.32), Vector3(0, 0.82, -0.44)],
		"seat_r": [Vector2(0.108, 0.038), Vector2(0.100, 0.034), Vector2(0.082, 0.030)],
		"tail_c": [
			Vector3(0, 0.88, -0.42),
			Vector3(0, 0.96, -0.56),
			Vector3(0, 1.00, -0.70),
			Vector3(0, 0.92, -0.86),
		],
		"tail_r": [Vector2(0.112, 0.056), Vector2(0.096, 0.052), Vector2(0.072, 0.044), Vector2(0.042, 0.032)],
	}


func _raven_spec() -> Dictionary:
	## Black bomber. Long tank, copper pipes, short tail, almost no brightwork.
	return {
		"paint": INK,
		"belly": COPPER_D,
		"stripe": COPPER,
		"pipe": COPPER,
		"tip": BLACK_S,
		"exhaust": "twin",
		"knee": 0.170,
		"filler_z": -0.18,
		"stripe_len": 0.74,
		"tank_c": [
			Vector3(0, 0.84, 0.66),
			Vector3(0, 0.83, 0.46),
			Vector3(0, 0.81, 0.22),
			Vector3(0, 0.80, 0.00),
			Vector3(0, 0.81, -0.22),
			Vector3(0, 0.83, -0.40),
		],
		"tank_r": [
			Vector2(0.064, 0.048),
			Vector2(0.112, 0.078),
			Vector2(0.168, 0.104),
			Vector2(0.176, 0.106),
			Vector2(0.130, 0.084),
			Vector2(0.078, 0.056),
		],
		"belly_c": [
			Vector3(0, 0.74, 0.46),
			Vector3(0, 0.72, 0.20),
			Vector3(0, 0.715, -0.04),
			Vector3(0, 0.73, -0.24),
		],
		"belly_r": [Vector2(0.086, 0.040), Vector2(0.138, 0.048), Vector2(0.144, 0.046), Vector2(0.094, 0.036)],
		"seat_c": [Vector3(0, 0.76, -0.26), Vector3(0, 0.74, -0.44), Vector3(0, 0.76, -0.58)],
		"seat_r": [Vector2(0.084, 0.030), Vector2(0.078, 0.026), Vector2(0.060, 0.022)],
		"tail_c": [
			Vector3(0, 0.80, -0.54),
			Vector3(0, 0.84, -0.70),
			Vector3(0, 0.86, -0.86),
			Vector3(0, 0.82, -1.00),
		],
		"tail_r": [Vector2(0.078, 0.040), Vector2(0.064, 0.034), Vector2(0.046, 0.026), Vector2(0.028, 0.018)],
	}


func _make_kit(node_name: String, spec: Dictionary) -> Node3D:
	var kit := Node3D.new()
	kit.name = node_name
	add_child(kit)
	var body := LowPoly.new()
	body.smooth = true
	_spec_tank(body, spec)
	_spec_seat(body, spec)
	_spec_hardware(body, spec)
	_spec_exhaust(body, spec)
	_attach(kit, body, node_name + "Body")
	_kits.append(kit)
	return kit


func _spec_tank(b: LowPoly, spec: Dictionary) -> void:
	var paint: Color = spec["paint"]
	var tank_c: Array = spec["tank_c"]
	_loft(b, tank_c, spec["tank_r"], paint)
	_sphere(b, tank_c[0] + Vector3(0, 0.00, 0.02), float((spec["tank_r"] as Array)[0].x) * 0.78, paint)
	_loft(b, spec["belly_c"], spec["belly_r"], spec["belly"], 12)
	_capsule(b, Vector3(0, 0.928, 0.10), 0.014, float(spec["stripe_len"]), spec["stripe"], Vector3(90, 0, 0))
	for s in [-1.0, 1.0]:
		_capsule(b, Vector3(s * 0.030, 0.924, 0.10), 0.005, float(spec["stripe_len"]) + 0.02, COPPER, Vector3(90, 0, 0))
		_cyl(b, Vector3(s * float(spec["knee"]), 0.818, 0.06), 0.026, 0.008, CHROME, Vector3(0, 0, 90))
	var filler_z: float = float(spec["filler_z"])
	_cyl(b, Vector3(0, 0.942, filler_z), 0.038, 0.022, ALUM, Vector3(0, 0, 0))
	_cyl(b, Vector3(0, 0.956, filler_z), 0.026, 0.012, CHROME, Vector3(0, 0, 0))


func _spec_seat(b: LowPoly, spec: Dictionary) -> void:
	var paint: Color = spec.get("tail_paint", spec["paint"])
	var tail: Array = spec["tail_c"]
	_loft(b, spec["seat_c"], spec["seat_r"], LEATHER, 12)
	_loft(b, tail, spec["tail_r"], paint, 12)
	var tip: Vector3 = tail[tail.size() - 1]
	_sphere(b, tip + Vector3(0, 0.00, -0.02), 0.032, paint.lightened(0.04))
	_sphere(b, tip + Vector3(0, -0.04, -0.04), 0.024, TAIL, true)
	_bone(b, SEAT_J, Vector3(0, tip.y - 0.02, tail[0].z), 0.012, BLACK_S)


func _spec_hardware(b: LowPoly, spec: Dictionary) -> void:
	var paint: Color = spec["paint"]
	# Side covers and a small oil tank under the seat so the midriff is finished.
	for s in [-1.0, 1.0]:
		_bx(b, Vector3(s * 0.12, 0.58, -0.18), Vector3(0.04, 0.10, 0.18), paint, 0.018)
		_bx(b, Vector3(s * 0.12, 0.58, -0.18), Vector3(0.018, 0.06, 0.10), BLACK_S, 0.008)
	_bx(b, Vector3(0, 0.56, -0.16), Vector3(0.16, 0.08, 0.14), ALUM_D, 0.02)
	# Rear hoop and a cream number plate so the tail is a machine, not a blob.
	var tail: Array = spec["tail_c"]
	var tip: Vector3 = tail[tail.size() - 1]
	_bone(b, Vector3(0, 0.52, REAR_Z), Vector3(0, 0.70, tip.z + 0.08), 0.010, BLACK_S)
	_bx(b, Vector3(0, 0.58, tip.z + 0.04), Vector3(0.14, 0.10, 0.012), CREAM, 0.006)
	# A short rear fender over the tyre, painted with the tank.
	_bx(b, Vector3(0, 0.56, REAR_Z + 0.02), Vector3(0.15, 0.026, 0.28), paint, 0.02)
	for s in [-1.0, 1.0]:
		_bone(b, Vector3(s * 0.07, 0.56, REAR_Z + 0.02), Vector3(s * 0.09, WHEEL_R + 0.08, REAR_Z + 0.10), 0.008, ALUM_D)


func _spec_exhaust(b: LowPoly, spec: Dictionary) -> void:
	var kind: String = spec["exhaust"]
	var pipe: Color = spec["pipe"]
	var tip: Color = spec["tip"]
	var head_y := ENGINE.y + 0.18
	match kind:
		"single":
			_exhaust_side(b, -1.0, 0.48, -0.76, pipe, tip, head_y)
		"high":
			for s in [-1.0, 1.0]:
				_exhaust_side(b, s, 0.62, -0.70, pipe, tip, head_y)
		_:
			for s in [-1.0, 1.0]:
				_exhaust_side(b, s, 0.46, -0.78, pipe, tip, head_y)


func _exhaust_side(b: LowPoly, side: float, tip_y: float, tip_z: float, pipe: Color, tip: Color, head_y: float) -> void:
	## Headers leave both heads and run into one megaphone on this flank.
	var head_a := Vector3(side * 0.08, head_y, ENGINE.z + 0.10)
	var head_b := Vector3(side * 0.08, head_y, ENGINE.z - 0.10)
	var join := Vector3(side * 0.20, 0.36, 0.02)
	var mid := Vector3(side * 0.24, 0.38, -0.34)
	var end := Vector3(side * 0.26, tip_y, tip_z)
	_bone(b, head_a, join, 0.020, pipe)
	_bone(b, head_b, join, 0.020, pipe)
	_bone(b, join, mid, 0.024, pipe)
	_bone(b, mid, end, 0.040, tip)
	_cyl(b, end, 0.048, 0.034, pipe, Vector3(108, side * 6.0, 0))


func _build_body() -> void:
	var hard := LowPoly.new()
	_build_chassis(hard)
	_build_engine(hard)
	_commit(hard, "Body")


func _build_chassis(b: LowPoly) -> void:
	## Diamond frame. Joints first, then the tubes that meet them, then the
	## swingarm to the rear axle. Nothing floats: if a part is on the bike it
	## is welded to one of these bones.
	_joint(b, HEAD, 0.038, BLACK_S)
	_joint(b, SEAT_J, 0.034, BLACK_S)
	_joint(b, PIVOT, 0.034, BLACK_S)
	_joint(b, ENGINE, 0.030, BLACK_S)
	_bone(b, HEAD, SEAT_J, 0.024, BLACK_S)
	_bone(b, HEAD, ENGINE, 0.024, BLACK_S)
	_bone(b, ENGINE, PIVOT, 0.022, BLACK_S)
	_bone(b, SEAT_J, PIVOT, 0.020, BLACK)
	for s in [-1.0, 1.0]:
		var pivot_s := PIVOT + Vector3(s * 0.09, 0, 0)
		var axle := Vector3(s * 0.09, WHEEL_R, REAR_Z)
		_joint(b, pivot_s, 0.022, ALUM)
		_bone(b, pivot_s, axle, 0.022, BLACK_S)
		_joint(b, axle, 0.024, ALUM)
		# Rearsets off the swingarm pivot.
		_bone(b, pivot_s, pivot_s + Vector3(s * 0.10, -0.04, 0.02), 0.010, ALUM)
		_sphere(b, pivot_s + Vector3(s * 0.12, -0.04, 0.02), 0.020, RUBBER)
	_bone(b, SEAT_J, Vector3(0, 0.52, REAR_Z), 0.012, BLACK_D)
	# Chain run on the left, the side the title camera looks at.
	_bx(b, Vector3(-0.11, 0.36, -0.48), Vector3(0.035, 0.028, 0.40), BLACK, 0.008)


func _build_engine(b: LowPoly) -> void:
	## Parallel twin filling the frame diamond: cases, two finned barrels,
	## heads, velocity stacks. The cases touch the down tube and the pivot.
	_bx(b, ENGINE, Vector3(0.30, 0.18, 0.38), ALUM, 0.04)
	_bx(b, ENGINE + Vector3(0, -0.08, 0.01), Vector3(0.26, 0.10, 0.32), ALUM_D, 0.03)
	for i in 2:
		var z: float = ENGINE.z + 0.09 - float(i) * 0.18
		var barrel := Vector3(0, ENGINE.y + 0.12, z)
		_cyl(b, barrel, 0.072, 0.14, ALUM_D, Vector3(10, 0, 0))
		for f in 7:
			_cyl(b, Vector3(0, ENGINE.y + 0.06 + float(f) * 0.016, z), 0.088, 0.009, ALUM, Vector3(10, 0, 0))
		_bx(b, Vector3(0, ENGINE.y + 0.22, z - 0.01), Vector3(0.17, 0.065, 0.13), ALUM, 0.014)
		_cyl(b, Vector3(0, ENGINE.y + 0.27, z - 0.02), 0.028, 0.036, CHROME, Vector3(8, 0, 0))
	_cyl(b, ENGINE + Vector3(0.155, 0.01, 0.02), 0.078, 0.028, CHROME, Vector3(0, 0, 90))
	_cyl(b, ENGINE + Vector3(-0.155, 0.01, 0.02), 0.062, 0.024, ALUM_D, Vector3(0, 0, 90))


func _build_steering() -> Node3D:
	var head := Node3D.new()
	head.name = "Steering"
	head.position = HEAD
	add_child(head)

	var b := LowPoly.new()
	var o := -head.position
	# Forks: yoke to the front axle. Same tubes, no gap.
	for s in [-1.0, 1.0]:
		var yoke := o + Vector3(s * 0.11, 0.96, 0.54)
		var axle := o + Vector3(s * 0.11, WHEEL_R, FRONT_Z)
		_bone(b, yoke, axle, 0.022, CHROME)
		_bone(b, yoke + Vector3(0, -0.22, 0.05), axle, 0.030, BLACK)
		_joint(b, yoke, 0.022, ALUM_D)
		_joint(b, axle, 0.020, ALUM)
	_bx(b, o + Vector3(0, 0.98, 0.53), Vector3(0.26, 0.026, 0.09), ALUM_D, 0.008)
	_bx(b, o + Vector3(0, 0.84, 0.56), Vector3(0.24, 0.026, 0.08), ALUM_D, 0.008)
	_build_clipons(b, o)
	_build_clocks(b, o)
	_build_headlight(b, o)

	var mi := MeshInstance3D.new()
	mi.name = "SteeringMesh"
	mi.mesh = b.commit()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	head.add_child(mi)
	_build_style_fenders(head, o)

	var axis: Vector3 = _needle_base * Vector3.UP
	for s in [-1.0, 1.0]:
		_needles.append(_build_needle(head, o + Vector3(s * 0.078, 1.018, 0.448) - axis * 0.040))

	_headlight = SpotLight3D.new()
	_headlight.name = "Headlight"
	_headlight.position = o + HEADLIGHT_AT + Vector3(0, 0, 0.115)
	_headlight.rotation_degrees = Vector3(-4.0, 180.0, 0.0)
	_headlight.light_color = Color(1.0, 0.93, 0.8)
	_headlight.light_energy = 2.6
	_headlight.spot_range = 40.0
	_headlight.spot_angle = 24.0
	_headlight.spot_angle_attenuation = 1.1
	_headlight.spot_attenuation = 0.75
	_headlight.shadow_enabled = false
	head.add_child(_headlight)
	return head


func _build_clipons(b: LowPoly, o: Vector3) -> void:
	for s in [-1.0, 1.0]:
		var clamp_at := o + Vector3(s * 0.11, 0.94, 0.54)
		_cyl(b, clamp_at, 0.028, 0.032, BLACK_S, Vector3(12, 0, 0))
		var elbow := o + Vector3(s * 0.22, 0.93, 0.50)
		var grip := o + Vector3(s * 0.34, 0.91, 0.44)
		_bone(b, clamp_at, elbow, 0.013, BLACK_S)
		_bone(b, elbow, grip, 0.013, BLACK_S)
		_capsule(b, grip, 0.022, 0.13, RUBBER, Vector3(0, s * 34, 86))
		_sphere(b, grip + Vector3(s * 0.07, -0.006, -0.04), 0.022, ALUM)
		_cyl(b, grip + Vector3(s * 0.08, 0.02, -0.05), 0.030, 0.012, BLACK_S, Vector3(70, s * 18, 0))
		_cyl(b, grip + Vector3(s * 0.08, 0.022, -0.06), 0.024, 0.006, MIRROR, Vector3(70, s * 18, 0))
		_bone(b, elbow, elbow + Vector3(s * 0.04, 0.01, 0.05), 0.006, CHROME)


func _build_headlight(b: LowPoly, o: Vector3) -> void:
	var at: Vector3 = o + HEADLIGHT_AT
	_cyl(b, at, 0.118, 0.15, SHELL, Vector3(90, 0, 0))
	_cyl(b, at + Vector3(0, 0, -0.078), 0.128, 0.016, CHROME, Vector3(90, 0, 0))
	_cyl(b, at + Vector3(0, 0, 0.076), 0.128, 0.018, CHROME, Vector3(90, 0, 0))
	_cyl(b, at + Vector3(0, 0, 0.084), 0.102, 0.010, LAMP, Vector3(90, 0, 0), true)
	# Ears onto the fork tubes at the same height, so the lamp is clamped
	# between them rather than hanging off a stalk in front of the wheel.
	for s in [-1.0, 1.0]:
		_bone(b, at + Vector3(s * 0.10, 0.0, -0.02), o + Vector3(s * 0.11, 0.82, 0.58), 0.014, ALUM_D)


func _build_clocks(b: LowPoly, o: Vector3) -> void:
	var tilt := deg_to_rad(52.0)
	var axis := Vector3(0, cos(tilt), sin(tilt))
	_needle_base = Basis.from_euler(Vector3(tilt, 0, 0))
	for s in [-1.0, 1.0]:
		var at := o + Vector3(s * 0.078, 1.018, 0.448)
		_cyl(b, at, 0.050, 0.048, BLACK, Vector3(52, 0, 0))
		_cyl(b, at - axis * 0.024, 0.052, 0.012, CHROME, Vector3(52, 0, 0))
		_cyl(b, at - axis * 0.030, 0.044, 0.007, DIAL, Vector3(52, 0, 0))
		for i in 11:
			var a: float = lerpf(2.35, -2.35, float(i) / 10.0)
			var dir: Vector3 = _needle_base * (Vector3(sin(a), 0.0, cos(a)) * 0.034)
			_sphere(b, at - axis * 0.034 + dir, 0.0026, DIAL_LIT, true)
		_sphere(b, at - axis * 0.034, 0.008, COPPER)


func _build_style_fenders(head: Node3D, o: Vector3) -> void:
	var colors: Array[Color] = [PAINT, BLUE, GREEN, CREAM, INK]
	for i in colors.size():
		var fb := LowPoly.new()
		_build_fender(fb, o, colors[i])
		var fender := MeshInstance3D.new()
		fender.name = "FrontFender%d" % i
		fender.mesh = fb.commit()
		fender.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		fender.visible = i == 0
		head.add_child(fender)
		_fenders.append(fender)


func _build_fender(b: LowPoly, o: Vector3, col: Color) -> void:
	b.channel = LowPoly.PAINT
	b.add_rounded_box(
		Transform3D(Basis.IDENTITY, o + Vector3(0, 0.58, 0.80)), Vector3(0.16, 0.028, 0.34), 0.024, col
	)
	for s in [-1.0, 1.0]:
		_bone(b, o + Vector3(s * 0.08, 0.58, 0.80), o + Vector3(s * 0.11, 0.50, 0.70), 0.010, ALUM_D)


func set_night_lighting(darkness: float) -> void:
	if _headlight == null:
		return
	var t: float = pow(clampf(darkness, 0.0, 1.0), 0.55)
	_headlight.light_energy = lerpf(0.0, 4.6, t)
	_headlight.spot_range = lerpf(26.0, 60.0, t)
	_headlight.spot_angle = lerpf(20.0, 31.0, t)
	_headlight.light_color = Color(1.0, 0.90, 0.72).lerp(Color(1.0, 0.95, 0.86), t)


func _build_needle(head: Node3D, at: Vector3) -> Node3D:
	var b := LowPoly.new()
	b.add_rounded_box(
		Transform3D(Basis.IDENTITY, Vector3(0, 0, 0.022)), Vector3(0.005, 0.0035, 0.048), 0.0015, NEEDLE, true
	)
	var mi := MeshInstance3D.new()
	mi.mesh = b.commit()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pivot := Node3D.new()
	pivot.name = "Needle"
	pivot.transform = Transform3D(_needle_base, at)
	pivot.add_child(mi)
	head.add_child(pivot)
	return pivot


func _build_wheel(pos: Vector3, is_front: bool) -> MeshInstance3D:
	var b := LowPoly.new()
	var lie := Basis.from_euler(Vector3(0, 0, PI * 0.5))
	var width := 0.12 if is_front else 0.145
	b.channel = LowPoly.SOLID
	b.add_cylinder(Transform3D(lie, Vector3.ZERO), WHEEL_R, width, 20, TYRE)
	b.add_cylinder(Transform3D(lie, Vector3.ZERO), WHEEL_R * 0.96, width * 0.68, 20, TYRE.lightened(0.05))
	b.add_cylinder(Transform3D(lie, Vector3.ZERO), WHEEL_R * 0.58, width * 1.04, 16, BLACK_S)
	b.channel = LowPoly.METAL
	b.add_cylinder(Transform3D(lie, Vector3.ZERO), WHEEL_R * 0.54, width * 1.08, 16, ALUM_D)
	b.add_cylinder(Transform3D(lie, Vector3.ZERO), WHEEL_R * 0.50, width * 0.22, 16, CHROME)
	b.add_cylinder(Transform3D(lie, Vector3.ZERO), 0.06, width * 1.12, 10, ALUM)
	if is_front:
		b.add_cylinder(Transform3D(lie, Vector3(0.068, 0, 0)), WHEEL_R * 0.64, 0.010, 18, ALUM)
	else:
		b.add_cylinder(Transform3D(lie, Vector3(-0.078, 0, 0)), WHEEL_R * 0.42, 0.012, 16, ALUM_D)
	for i in 12:
		var a := TAU * float(i) / 12.0
		b.add_cylinder(Transform3D(Basis(Vector3.RIGHT, a), Vector3.ZERO), 0.005, WHEEL_R * 1.50, 6, CHROME)
	var mi := MeshInstance3D.new()
	mi.name = "FrontWheel" if is_front else "RearWheel"
	mi.mesh = b.commit()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = pos
	if not is_front:
		add_child(mi)
	return mi


func _build_contact_shadow() -> void:
	var shadow := MeshInstance3D.new()
	shadow.name = "ContactShadow"
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	shadow.mesh = quad
	var mat := ShaderMaterial.new()
	mat.shader = CONTACT_SHADOW_SHADER
	shadow.material_override = mat
	shadow.position = Vector3(0, 0.03, 0.04)
	shadow.rotation.x = -PI * 0.5
	shadow.scale = Vector3(0.55, 1.15, 1.0)
	shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(shadow)


func _build_hero_camera() -> void:
	## From the left verge, looking across the carriageway. Both wheels sit on
	## tarmac and the road runs through the shot instead of dropping into a void.
	_hero_rig = Node3D.new()
	_hero_rig.name = "HeroRig"
	_hero_rig.position = Vector3(0.0, 0.48, 0.04)
	_hero_rig.rotation.y = _hero_yaw0
	_hero_rig.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_hero_rig)
	_hero_cam = Camera3D.new()
	_hero_cam.name = "HeroCamera"
	_hero_cam.fov = 34.0
	_hero_cam.near = 0.08
	_hero_cam.far = 5200.0
	_hero_cam.current = false
	_hero_rig.add_child(_hero_cam)
	_hero_cam.position = Vector3(-2.8, 3.6, 3.8)
	_hero_cam.look_at(_hero_rig.global_position + Vector3(0.0, -0.2, 0.05), Vector3.UP)


# --------------------------------------------------------------------- helpers


func _bone(b: LowPoly, a: Vector3, c: Vector3, radius: float, col: Color) -> void:
	var delta := c - a
	var length := delta.length()
	if length < 0.001:
		return
	var y := delta / length
	var up := Vector3.UP if absf(y.dot(Vector3.UP)) < 0.97 else Vector3.RIGHT
	var x := y.cross(up).normalized()
	var z := x.cross(y)
	b.channel = _channel_for(col)
	b.add_capsule(Transform3D(Basis(x, y, z), (a + c) * 0.5), radius, length + radius * 0.2, SIDES, col)


func _joint(b: LowPoly, pos: Vector3, radius: float, col: Color) -> void:
	_sphere(b, pos, radius, col)


static func _channel_for(col: Color) -> int:
	if col == MIRROR:
		return LowPoly.MIRROR
	if col in METALS:
		return LowPoly.METAL
	if col in PAINTED:
		return LowPoly.PAINT
	return LowPoly.SOLID


func _bx(b: LowPoly, pos: Vector3, size: Vector3, col: Color, bevel: float = -1.0, glow: bool = false) -> void:
	if bevel < 0.0:
		bevel = minf(minf(size.x, minf(size.y, size.z)) * 0.3, 0.03)
	b.channel = _channel_for(col)
	b.add_rounded_box(Transform3D(Basis.IDENTITY, pos), size, bevel, col, glow)


func _cyl(
	b: LowPoly, pos: Vector3, radius: float, height: float, col: Color, rot_deg: Vector3, glow: bool = false
) -> void:
	var basis := Basis.from_euler(rot_deg * (PI / 180.0))
	b.channel = _channel_for(col)
	b.add_cylinder(Transform3D(basis, pos), radius, height, SIDES, col, glow)


func _capsule(
	b: LowPoly, pos: Vector3, radius: float, height: float, col: Color, rot_deg: Vector3, glow: bool = false
) -> void:
	var basis := Basis.from_euler(rot_deg * (PI / 180.0))
	b.channel = _channel_for(col)
	b.add_capsule(Transform3D(basis, pos), radius, height, SIDES, col, glow)


func _sphere(b: LowPoly, pos: Vector3, radius: float, col: Color, glow: bool = false) -> void:
	b.channel = _channel_for(col)
	b.add_sphere(Transform3D(Basis.IDENTITY, pos), radius, SIDES, maxi(SIDES / 2, 6), col, glow)


func _loft(b: LowPoly, centers: Array, radii: Array, col: Color, sides: int = SIDES) -> void:
	var c := PackedVector3Array()
	var r := PackedVector2Array()
	for p in centers:
		c.append(p)
	for p in radii:
		r.append(p)
	b.channel = _channel_for(col)
	b.add_loft(c, r, sides, col)


func _attach(parent: Node, b: LowPoly, node_name: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = b.commit()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


func _commit(b: LowPoly, node_name: String) -> MeshInstance3D:
	return _attach(self, b, node_name)
