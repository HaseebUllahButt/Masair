extends Node3D
## Café racer. Faces +Z, tyres on y = 0.
##
## One silhouette: tank → seat → hump is a continuous line, fenders arc over
## the tyres, and the diamond frame stays skinny enough that paint and chrome
## do the talking. Every garage bike is the same kind of motorcycle — round
## lamp, clip-ons, teardrop tank, hump tail — with paint, tank shape, seat and
## pipes changing the character.

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

const HEADLIGHT_AT := Vector3(0, 0.80, 0.62)
const WHEEL_R := 0.33
const FRONT_Z := 0.80
const REAR_Z := -0.74
const HEAD := Vector3(0.0, 0.76, 0.48)
const SEAT_J := Vector3(0.0, 0.68, -0.30)
const PIVOT := Vector3(0.0, 0.36, -0.24)
const ENGINE := Vector3(0.0, 0.42, 0.06)
const SIDES := 18
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
	_make_kit("MesaKit", _mesa_spec())
	_make_kit("SabreKit", _sabre_spec())
	_make_kit("HalcyonKit", _halcyon_spec())
	_make_kit("TempestKit", _tempest_spec())
	_make_kit("RavenKit", _raven_spec())


func _mesa_spec() -> Dictionary:
	## Classic red café — balanced teardrop, cream belly, one megaphone.
	return {
		"paint": PAINT,
		"belly": CREAM,
		"stripe": CREAM,
		"pipe": CHROME,
		"tip": ALUM_D,
		"exhaust": "single",
		"knee": 0.168,
		"filler_z": -0.10,
		"stripe_len": 0.58,
		"tank_c": [
			Vector3(0, 0.84, 0.54),
			Vector3(0, 0.86, 0.38),
			Vector3(0, 0.87, 0.16),
			Vector3(0, 0.86, -0.04),
			Vector3(0, 0.84, -0.18),
			Vector3(0, 0.79, -0.28),
		],
		"tank_r": [
			Vector2(0.055, 0.048),
			Vector2(0.108, 0.078),
			Vector2(0.168, 0.108),
			Vector2(0.172, 0.110),
			Vector2(0.120, 0.080),
			Vector2(0.055, 0.040),
		],
		"belly_c": [
			Vector3(0, 0.74, 0.40),
			Vector3(0, 0.72, 0.16),
			Vector3(0, 0.715, -0.04),
			Vector3(0, 0.73, -0.18),
		],
		"belly_r": [Vector2(0.082, 0.038), Vector2(0.138, 0.048), Vector2(0.142, 0.046), Vector2(0.090, 0.034)],
		"seat_c": [Vector3(0, 0.755, -0.34), Vector3(0, 0.735, -0.46), Vector3(0, 0.75, -0.56)],
		"seat_r": [Vector2(0.088, 0.028), Vector2(0.082, 0.024), Vector2(0.066, 0.020)],
		"tail_c": [
			Vector3(0, 0.80, -0.52),
			Vector3(0, 0.86, -0.64),
			Vector3(0, 0.88, -0.76),
			Vector3(0, 0.84, -0.88),
		],
		"tail_r": [Vector2(0.090, 0.046), Vector2(0.076, 0.042), Vector2(0.056, 0.034), Vector2(0.032, 0.024)],
	}


func _sabre_spec() -> Dictionary:
	## Longer, slimmer café — stretched tank, tucked seat, twin pipes.
	return {
		"paint": BLUE,
		"belly": CREAM,
		"stripe": CREAM,
		"pipe": CHROME,
		"tip": ALUM_D,
		"exhaust": "twin",
		"knee": 0.150,
		"filler_z": -0.14,
		"stripe_len": 0.68,
		"tank_c": [
			Vector3(0, 0.85, 0.60),
			Vector3(0, 0.86, 0.42),
			Vector3(0, 0.86, 0.18),
			Vector3(0, 0.85, -0.04),
			Vector3(0, 0.83, -0.24),
			Vector3(0, 0.80, -0.40),
		],
		"tank_r": [
			Vector2(0.048, 0.042),
			Vector2(0.090, 0.066),
			Vector2(0.138, 0.090),
			Vector2(0.146, 0.092),
			Vector2(0.108, 0.072),
			Vector2(0.060, 0.046),
		],
		"belly_c": [
			Vector3(0, 0.74, 0.44),
			Vector3(0, 0.72, 0.18),
			Vector3(0, 0.715, -0.06),
			Vector3(0, 0.73, -0.26),
		],
		"belly_r": [Vector2(0.074, 0.034), Vector2(0.122, 0.042), Vector2(0.128, 0.040), Vector2(0.082, 0.030)],
		"seat_c": [Vector3(0, 0.755, -0.42), Vector3(0, 0.735, -0.54), Vector3(0, 0.75, -0.66)],
		"seat_r": [Vector2(0.076, 0.024), Vector2(0.070, 0.020), Vector2(0.052, 0.016)],
		"tail_c": [
			Vector3(0, 0.80, -0.62),
			Vector3(0, 0.85, -0.76),
			Vector3(0, 0.87, -0.90),
			Vector3(0, 0.82, -1.02),
		],
		"tail_r": [Vector2(0.078, 0.040), Vector2(0.064, 0.034), Vector2(0.044, 0.026), Vector2(0.026, 0.016)],
	}


func _halcyon_spec() -> Dictionary:
	## Thruxton peanut — fat mid, British green, gold pinstripe, reverse-cones.
	return {
		"paint": GREEN,
		"tail_paint": GOLD,
		"belly": GOLD,
		"stripe": GOLD,
		"pipe": CHROME,
		"tip": CHROME,
		"exhaust": "twin",
		"knee": 0.188,
		"filler_z": -0.06,
		"stripe_len": 0.52,
		"tank_c": [
			Vector3(0, 0.86, 0.48),
			Vector3(0, 0.88, 0.32),
			Vector3(0, 0.89, 0.12),
			Vector3(0, 0.88, -0.04),
			Vector3(0, 0.85, -0.14),
			Vector3(0, 0.80, -0.22),
		],
		"tank_r": [
			Vector2(0.068, 0.054),
			Vector2(0.132, 0.090),
			Vector2(0.198, 0.124),
			Vector2(0.204, 0.126),
			Vector2(0.130, 0.084),
			Vector2(0.060, 0.044),
		],
		"belly_c": [
			Vector3(0, 0.74, 0.34),
			Vector3(0, 0.71, 0.12),
			Vector3(0, 0.705, -0.04),
			Vector3(0, 0.73, -0.14),
		],
		"belly_r": [Vector2(0.096, 0.042), Vector2(0.158, 0.052), Vector2(0.162, 0.050), Vector2(0.104, 0.036)],
		"seat_c": [Vector3(0, 0.77, -0.28), Vector3(0, 0.75, -0.40), Vector3(0, 0.765, -0.50)],
		"seat_r": [Vector2(0.096, 0.030), Vector2(0.090, 0.026), Vector2(0.072, 0.022)],
		"tail_c": [
			Vector3(0, 0.84, -0.46),
			Vector3(0, 0.92, -0.58),
			Vector3(0, 0.94, -0.70),
			Vector3(0, 0.86, -0.84),
		],
		"tail_r": [Vector2(0.102, 0.050), Vector2(0.086, 0.046), Vector2(0.064, 0.038), Vector2(0.036, 0.026)],
	}


func _tempest_spec() -> Dictionary:
	## Italian round-case — fat cream tank, tall gold hump, upswept megaphones.
	return {
		"paint": CREAM,
		"tail_paint": GOLD,
		"belly": GOLD,
		"stripe": GOLD,
		"pipe": CHROME,
		"tip": COPPER,
		"exhaust": "high",
		"knee": 0.198,
		"filler_z": -0.08,
		"stripe_len": 0.54,
		"tank_c": [
			Vector3(0, 0.88, 0.50),
			Vector3(0, 0.90, 0.34),
			Vector3(0, 0.91, 0.12),
			Vector3(0, 0.90, -0.06),
			Vector3(0, 0.87, -0.16),
			Vector3(0, 0.82, -0.26),
		],
		"tank_r": [
			Vector2(0.080, 0.060),
			Vector2(0.146, 0.098),
			Vector2(0.210, 0.132),
			Vector2(0.216, 0.134),
			Vector2(0.145, 0.092),
			Vector2(0.070, 0.050),
		],
		"belly_c": [
			Vector3(0, 0.74, 0.36),
			Vector3(0, 0.71, 0.12),
			Vector3(0, 0.705, -0.04),
			Vector3(0, 0.73, -0.14),
		],
		"belly_r": [Vector2(0.102, 0.044), Vector2(0.164, 0.054), Vector2(0.168, 0.052), Vector2(0.108, 0.038)],
		"seat_c": [Vector3(0, 0.79, -0.32), Vector3(0, 0.77, -0.44), Vector3(0, 0.785, -0.54)],
		"seat_r": [Vector2(0.102, 0.032), Vector2(0.094, 0.028), Vector2(0.076, 0.024)],
		"tail_c": [
			Vector3(0, 0.86, -0.50),
			Vector3(0, 0.96, -0.62),
			Vector3(0, 1.02, -0.74),
			Vector3(0, 0.92, -0.90),
		],
		"tail_r": [Vector2(0.108, 0.052), Vector2(0.090, 0.048), Vector2(0.066, 0.040), Vector2(0.036, 0.028)],
	}


func _raven_spec() -> Dictionary:
	## Black bomber — long flat tank, copper pipes, short low tail.
	return {
		"paint": INK,
		"belly": COPPER_D,
		"stripe": COPPER,
		"pipe": COPPER,
		"tip": BLACK_S,
		"exhaust": "twin",
		"knee": 0.158,
		"filler_z": -0.16,
		"stripe_len": 0.72,
		"tank_c": [
			Vector3(0, 0.82, 0.64),
			Vector3(0, 0.83, 0.44),
			Vector3(0, 0.83, 0.20),
			Vector3(0, 0.82, -0.02),
			Vector3(0, 0.80, -0.24),
			Vector3(0, 0.78, -0.42),
		],
		"tank_r": [
			Vector2(0.052, 0.044),
			Vector2(0.100, 0.072),
			Vector2(0.156, 0.098),
			Vector2(0.162, 0.100),
			Vector2(0.118, 0.078),
			Vector2(0.068, 0.050),
		],
		"belly_c": [
			Vector3(0, 0.72, 0.46),
			Vector3(0, 0.70, 0.20),
			Vector3(0, 0.695, -0.04),
			Vector3(0, 0.71, -0.26),
		],
		"belly_r": [Vector2(0.078, 0.036), Vector2(0.128, 0.044), Vector2(0.134, 0.042), Vector2(0.086, 0.032)],
		"seat_c": [Vector3(0, 0.735, -0.44), Vector3(0, 0.715, -0.56), Vector3(0, 0.73, -0.68)],
		"seat_r": [Vector2(0.080, 0.024), Vector2(0.074, 0.020), Vector2(0.054, 0.016)],
		"tail_c": [
			Vector3(0, 0.78, -0.64),
			Vector3(0, 0.82, -0.78),
			Vector3(0, 0.84, -0.92),
			Vector3(0, 0.80, -1.02),
		],
		"tail_r": [Vector2(0.072, 0.036), Vector2(0.058, 0.030), Vector2(0.040, 0.022), Vector2(0.024, 0.014)],
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
	# Soft nose so the tank reads as a teardrop, not a cut pipe.
	var tank_r: Array = spec["tank_r"]
	_sphere(b, tank_c[0] + Vector3(0, 0.01, 0.01), float(tank_r[0].x) * 0.92, paint)
	_sphere(b, tank_c[tank_c.size() - 1] + Vector3(0, -0.01, -0.01), float(tank_r[tank_r.size() - 1].x) * 0.70, paint)
	_loft(b, spec["belly_c"], spec["belly_r"], spec["belly"], 14)
	# Centre stripe + thin copper pinstripes.
	_capsule(b, Vector3(0, 0.925, 0.08), 0.012, float(spec["stripe_len"]), spec["stripe"], Vector3(90, 0, 0))
	for s in [-1.0, 1.0]:
		_capsule(b, Vector3(s * 0.026, 0.922, 0.08), 0.004, float(spec["stripe_len"]) + 0.02, COPPER, Vector3(90, 0, 0))
		# Knee dents — shallow chrome discs pressed into the tank flanks.
		_cyl(b, Vector3(s * float(spec["knee"]), 0.808, 0.04), 0.030, 0.006, CHROME, Vector3(0, 0, 90))
		_cyl(b, Vector3(s * float(spec["knee"]), 0.808, 0.04), 0.018, 0.010, BLACK_S, Vector3(0, 0, 90))
	var filler_z: float = float(spec["filler_z"])
	_cyl(b, Vector3(0, 0.938, filler_z), 0.034, 0.018, ALUM, Vector3(0, 0, 0))
	_cyl(b, Vector3(0, 0.950, filler_z), 0.024, 0.010, CHROME, Vector3(0, 0, 0))
	_sphere(b, Vector3(0, 0.956, filler_z), 0.010, BLACK_S)


func _spec_seat(b: LowPoly, spec: Dictionary) -> void:
	var paint: Color = spec.get("tail_paint", spec["paint"])
	var tail: Array = spec["tail_c"]
	var seat_c: Array = spec["seat_c"]
	# Black seat pan under the leather so the pad reads as a separate part.
	_loft(
		b,
		[
			Vector3(seat_c[0].x, seat_c[0].y - 0.028, seat_c[0].z + 0.02),
			Vector3(seat_c[1].x, seat_c[1].y - 0.028, seat_c[1].z),
			Vector3(seat_c[2].x, seat_c[2].y - 0.026, seat_c[2].z - 0.02),
		],
		[Vector2(0.095, 0.018), Vector2(0.088, 0.016), Vector2(0.070, 0.014)],
		BLACK_S,
		12
	)
	_loft(b, seat_c, spec["seat_r"], LEATHER, 14)
	_loft(b, tail, spec["tail_r"], paint, 14)
	var tip: Vector3 = tail[tail.size() - 1]
	_sphere(b, tip + Vector3(0, 0.00, -0.015), 0.028, paint.lightened(0.05))
	_sphere(b, tip + Vector3(0, -0.035, -0.035), 0.022, TAIL, true)
	# Exposed top tube between tank and seat — the gap that stops them melting together.
	_bone(b, SEAT_J + Vector3(0, 0.04, 0.12), SEAT_J + Vector3(0, 0.02, -0.02), 0.014, BLACK_S)
	_bone(b, SEAT_J, Vector3(0, tip.y - 0.04, tail[0].z + 0.04), 0.010, BLACK_S)
	_bone(b, Vector3(0, tip.y - 0.04, tail[0].z + 0.04), Vector3(0, tip.y - 0.02, tip.z + 0.06), 0.009, BLACK_S)


func _spec_hardware(b: LowPoly, spec: Dictionary) -> void:
	var paint: Color = spec["paint"]
	var tail: Array = spec["tail_c"]
	var tip: Vector3 = tail[tail.size() - 1]
	# Side panels fair from under the seat into the midriff — oval loft, not boxes.
	for s in [-1.0, 1.0]:
		_loft(
			b,
			[
				Vector3(s * 0.10, 0.62, -0.04),
				Vector3(s * 0.118, 0.58, -0.16),
				Vector3(s * 0.110, 0.56, -0.28),
				Vector3(s * 0.085, 0.58, -0.36),
			],
			[Vector2(0.022, 0.055), Vector2(0.028, 0.070), Vector2(0.024, 0.060), Vector2(0.016, 0.040)],
			paint,
			10
		)
		_loft(
			b,
			[
				Vector3(s * 0.105, 0.58, -0.14),
				Vector3(s * 0.112, 0.56, -0.22),
				Vector3(s * 0.100, 0.55, -0.30),
			],
			[Vector2(0.014, 0.040), Vector2(0.016, 0.045), Vector2(0.012, 0.032)],
			BLACK_S,
			8
		)
	# Oil tank under the seat, tucked between the rails.
	_loft(
		b,
		[Vector3(0, 0.58, -0.08), Vector3(0, 0.55, -0.18), Vector3(0, 0.56, -0.28)],
		[Vector2(0.070, 0.040), Vector2(0.078, 0.045), Vector2(0.060, 0.034)],
		ALUM_D,
		12
	)
	# Rear hoop + small cream number plate.
	_bone(b, Vector3(0, 0.50, REAR_Z + 0.06), Vector3(0, 0.68, tip.z + 0.10), 0.008, BLACK_S)
	_bx(b, Vector3(0, 0.56, tip.z + 0.06), Vector3(0.12, 0.085, 0.010), CREAM, 0.004)
	# Curved rear fender over the tyre.
	_fender_arc(
		b,
		Vector3(0, WHEEL_R, REAR_Z),
		deg_to_rad(55.0),
		deg_to_rad(135.0),
		WHEEL_R + 0.055,
		0.072,
		0.014,
		paint,
		6
	)
	for s in [-1.0, 1.0]:
		_bone(
			b,
			Vector3(s * 0.06, WHEEL_R + 0.22, REAR_Z + 0.04),
			Vector3(s * 0.09, WHEEL_R + 0.10, REAR_Z + 0.08),
			0.007,
			ALUM_D
		)


func _spec_exhaust(b: LowPoly, spec: Dictionary) -> void:
	var kind: String = spec["exhaust"]
	var pipe: Color = spec["pipe"]
	var tip: Color = spec["tip"]
	var head_y := ENGINE.y + 0.16
	match kind:
		"single":
			_exhaust_side(b, -1.0, 0.46, -0.78, pipe, tip, head_y, false)
		"high":
			for s in [-1.0, 1.0]:
				_exhaust_side(b, s, 0.64, -0.68, pipe, tip, head_y, true)
		_:
			for s in [-1.0, 1.0]:
				_exhaust_side(b, s, 0.44, -0.80, pipe, tip, head_y, false)


func _exhaust_side(
	b: LowPoly, side: float, tip_y: float, tip_z: float, pipe: Color, tip: Color, head_y: float, upsweep: bool
) -> void:
	var head_a := Vector3(side * 0.075, head_y, ENGINE.z + 0.095)
	var head_b := Vector3(side * 0.075, head_y, ENGINE.z - 0.095)
	var join := Vector3(side * 0.18, 0.34, 0.00)
	var mid_y := 0.36 if not upsweep else 0.42
	var mid := Vector3(side * 0.22, mid_y, -0.32)
	var end := Vector3(side * 0.24, tip_y, tip_z)
	_bone(b, head_a, join, 0.016, pipe)
	_bone(b, head_b, join, 0.016, pipe)
	_bone(b, join, mid, 0.018, pipe)
	_bone(b, mid, end, 0.028, tip)
	# Megaphone flare.
	_cyl(b, end, 0.042, 0.055, tip, Vector3(100 if upsweep else 108, side * 5.0, 0))
	_cyl(b, end + Vector3(0, 0.01, -0.02), 0.050, 0.018, pipe, Vector3(100 if upsweep else 108, side * 5.0, 0))
	# Hanger from the swingarm pivot so the pipe doesn't float.
	_bone(b, PIVOT + Vector3(side * 0.08, 0.02, 0), mid + Vector3(0, 0.04, 0), 0.006, BLACK_S)


func _build_body() -> void:
	var hard := LowPoly.new()
	_build_chassis(hard)
	_build_engine(hard)
	_commit(hard, "Body")


func _build_chassis(b: LowPoly) -> void:
	## Slim diamond frame that still reads as a skeleton — top tube and down
	## tube stay visible under the tank so the bike doesn't look like floating paint.
	_cyl(b, HEAD, 0.032, 0.095, BLACK_S, Vector3(18, 0, 0))
	_sphere(b, SEAT_J, 0.024, BLACK_S)
	_sphere(b, PIVOT, 0.022, BLACK_S)
	_sphere(b, ENGINE, 0.020, BLACK_S)
	_bone(b, HEAD, SEAT_J, 0.018, BLACK_S)
	_bone(b, HEAD, ENGINE, 0.018, BLACK_S)
	_bone(b, ENGINE, PIVOT, 0.016, BLACK_S)
	_bone(b, SEAT_J, PIVOT, 0.015, BLACK)
	# Twin top-tube rails so the midriff isn't empty between tank and seat.
	for s in [-1.0, 1.0]:
		_bone(
			b,
			HEAD + Vector3(s * 0.04, -0.02, 0.02),
			SEAT_J + Vector3(s * 0.04, -0.02, 0.02),
			0.012,
			BLACK
		)
	for s in [-1.0, 1.0]:
		_bone(b, ENGINE + Vector3(s * 0.085, -0.08, 0.06), PIVOT + Vector3(s * 0.065, -0.02, 0), 0.012, BLACK)
	for s in [-1.0, 1.0]:
		var pivot_s := PIVOT + Vector3(s * 0.090, 0, 0)
		var axle := Vector3(s * 0.090, WHEEL_R, REAR_Z)
		_sphere(b, pivot_s, 0.018, ALUM)
		_bone(b, pivot_s, axle, 0.018, BLACK_S)
		# Upper shock approx — links swingarm to seat rail.
		_bone(b, pivot_s + Vector3(0, 0.02, -0.04), SEAT_J + Vector3(s * 0.05, -0.04, -0.06), 0.010, BLACK)
		_sphere(b, axle, 0.020, ALUM)
		var peg := pivot_s + Vector3(s * 0.12, -0.05, 0.04)
		_bone(b, pivot_s, peg, 0.009, ALUM)
		_cyl(b, peg, 0.015, 0.048, RUBBER, Vector3(0, 0, 90))
		_sphere(b, peg + Vector3(s * 0.02, 0, 0), 0.014, ALUM)
	_bone(b, SEAT_J, Vector3(0, 0.50, REAR_Z + 0.04), 0.011, BLACK_D)
	_loft(
		b,
		[Vector3(-0.110, 0.40, -0.28), Vector3(-0.110, 0.36, -0.48), Vector3(-0.110, 0.34, -0.66)],
		[Vector2(0.013, 0.030), Vector2(0.015, 0.024), Vector2(0.011, 0.020)],
		BLACK,
		8
	)


func _build_engine(b: LowPoly) -> void:
	## Parallel twin packing the diamond: cases, finned barrels, heads, stacks.
	_bx(b, ENGINE, Vector3(0.30, 0.17, 0.38), ALUM, 0.038)
	_bx(b, ENGINE + Vector3(0, -0.075, 0.01), Vector3(0.26, 0.095, 0.32), ALUM_D, 0.030)
	_bx(b, ENGINE + Vector3(0, -0.125, 0.00), Vector3(0.22, 0.055, 0.28), ALUM_D, 0.022)
	for i in 2:
		var z: float = ENGINE.z + 0.09 - float(i) * 0.18
		var barrel := Vector3(0, ENGINE.y + 0.115, z)
		_cyl(b, barrel, 0.070, 0.130, ALUM_D, Vector3(8, 0, 0))
		for f in 9:
			_cyl(b, Vector3(0, ENGINE.y + 0.048 + float(f) * 0.014, z), 0.088, 0.008, ALUM, Vector3(8, 0, 0))
		_bx(b, Vector3(0, ENGINE.y + 0.205, z - 0.01), Vector3(0.165, 0.058, 0.120), ALUM, 0.012)
		# Matte intake stacks — chrome was blooming into false "engine glow".
		_cyl(b, Vector3(0, ENGINE.y + 0.255, z - 0.02), 0.028, 0.034, ALUM_D, Vector3(6, 0, 0))
		_cyl(b, Vector3(0, ENGINE.y + 0.275, z - 0.025), 0.020, 0.012, BLACK_S, Vector3(6, 0, 0))
	_cyl(b, ENGINE + Vector3(0.155, 0.00, 0.02), 0.078, 0.026, CHROME, Vector3(0, 0, 90))
	_cyl(b, ENGINE + Vector3(-0.155, 0.00, 0.02), 0.062, 0.022, ALUM_D, Vector3(0, 0, 90))
	for i in 2:
		var z: float = ENGINE.z + 0.09 - float(i) * 0.18
		_bx(b, Vector3(0, ENGINE.y + 0.225, z - 0.045), Vector3(0.085, 0.042, 0.055), BLACK_S, 0.008)


func _build_steering() -> Node3D:
	var head := Node3D.new()
	head.name = "Steering"
	head.position = HEAD
	add_child(head)

	var b := LowPoly.new()
	var o := -head.position
	# Telescopic forks: chunky chrome lowers, black uppers into the yokes.
	for s in [-1.0, 1.0]:
		var yoke := o + Vector3(s * 0.108, 0.94, 0.52)
		var mid := o + Vector3(s * 0.108, 0.60, 0.64)
		var axle := o + Vector3(s * 0.108, WHEEL_R, FRONT_Z)
		_bone(b, yoke, mid, 0.032, BLACK)
		_bone(b, mid, axle, 0.024, CHROME)
		_sphere(b, yoke, 0.018, ALUM_D)
		_sphere(b, axle, 0.020, ALUM)
	# Triple clamps.
	_bx(b, o + Vector3(0, 0.96, 0.51), Vector3(0.26, 0.026, 0.080), ALUM_D, 0.006)
	_bx(b, o + Vector3(0, 0.82, 0.55), Vector3(0.24, 0.024, 0.072), ALUM_D, 0.006)
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
		_needles.append(_build_needle(head, o + Vector3(s * 0.074, 0.995, 0.435) - axis * 0.038))

	_headlight = SpotLight3D.new()
	_headlight.name = "Headlight"
	_headlight.position = o + HEADLIGHT_AT + Vector3(0, 0, 0.110)
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
		var clamp_at := o + Vector3(s * 0.108, 0.92, 0.52)
		_cyl(b, clamp_at, 0.024, 0.028, BLACK_S, Vector3(14, 0, 0))
		var elbow := o + Vector3(s * 0.21, 0.91, 0.48)
		var grip := o + Vector3(s * 0.33, 0.89, 0.42)
		_bone(b, clamp_at, elbow, 0.011, BLACK_S)
		_bone(b, elbow, grip, 0.011, BLACK_S)
		_capsule(b, grip, 0.020, 0.12, RUBBER, Vector3(0, s * 34, 86))
		_sphere(b, grip + Vector3(s * 0.065, -0.005, -0.035), 0.018, ALUM)
		# Bar-end mirror: short stalk + chrome rim + reflective face.
		var mirror_at := grip + Vector3(s * 0.075, 0.025, -0.055)
		_cyl(b, mirror_at, 0.028, 0.010, BLACK_S, Vector3(68, s * 16, 0))
		_cyl(b, mirror_at + Vector3(0, 0.002, -0.008), 0.022, 0.005, MIRROR, Vector3(68, s * 16, 0))
		_bone(b, elbow, elbow + Vector3(s * 0.035, 0.008, 0.045), 0.005, CHROME)


func _build_headlight(b: LowPoly, o: Vector3) -> void:
	var at: Vector3 = o + HEADLIGHT_AT
	_cyl(b, at, 0.110, 0.135, SHELL, Vector3(90, 0, 0))
	_cyl(b, at + Vector3(0, 0, -0.070), 0.118, 0.014, CHROME, Vector3(90, 0, 0))
	_cyl(b, at + Vector3(0, 0, 0.068), 0.118, 0.016, CHROME, Vector3(90, 0, 0))
	_cyl(b, at + Vector3(0, 0, 0.076), 0.095, 0.009, LAMP, Vector3(90, 0, 0), true)
	# Ears clamp the shell to the fork tubes.
	for s in [-1.0, 1.0]:
		_bone(b, at + Vector3(s * 0.09, 0.0, -0.02), o + Vector3(s * 0.108, 0.80, 0.56), 0.012, ALUM_D)


func _build_clocks(b: LowPoly, o: Vector3) -> void:
	var tilt := deg_to_rad(52.0)
	var axis := Vector3(0, cos(tilt), sin(tilt))
	_needle_base = Basis.from_euler(Vector3(tilt, 0, 0))
	# Shared billet mount under the twin clocks.
	_bx(b, o + Vector3(0, 0.98, 0.44), Vector3(0.18, 0.018, 0.06), ALUM_D, 0.006)
	for s in [-1.0, 1.0]:
		var at := o + Vector3(s * 0.074, 0.995, 0.435)
		_cyl(b, at, 0.046, 0.042, BLACK, Vector3(52, 0, 0))
		_cyl(b, at - axis * 0.022, 0.048, 0.010, CHROME, Vector3(52, 0, 0))
		_cyl(b, at - axis * 0.028, 0.040, 0.006, DIAL, Vector3(52, 0, 0))
		for i in 11:
			var a: float = lerpf(2.35, -2.35, float(i) / 10.0)
			var dir: Vector3 = _needle_base * (Vector3(sin(a), 0.0, cos(a)) * 0.030)
			_sphere(b, at - axis * 0.032 + dir, 0.0024, DIAL_LIT, true)
		_sphere(b, at - axis * 0.032, 0.007, COPPER)


func _build_style_fenders(head: Node3D, o: Vector3) -> void:
	var colors: Array[Color] = [PAINT, BLUE, GREEN, CREAM, INK]
	for i in colors.size():
		var fb := LowPoly.new()
		fb.smooth = true
		_build_fender(fb, o, colors[i])
		var fender := MeshInstance3D.new()
		fender.name = "FrontFender%d" % i
		fender.mesh = fb.commit()
		fender.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		fender.visible = i == 0
		head.add_child(fender)
		_fenders.append(fender)


func _build_fender(b: LowPoly, o: Vector3, col: Color) -> void:
	var axle := o + Vector3(0, WHEEL_R, FRONT_Z)
	_fender_arc(b, axle, deg_to_rad(40.0), deg_to_rad(130.0), WHEEL_R + 0.050, 0.068, 0.013, col, 7)
	for s in [-1.0, 1.0]:
		_bone(
			b,
			axle + Vector3(s * 0.055, 0.18, -0.02),
			o + Vector3(s * 0.108, 0.52, 0.68),
			0.008,
			ALUM_D
		)


func _fender_arc(
	b: LowPoly,
	axle: Vector3,
	start_a: float,
	end_a: float,
	radius: float,
	half_w: float,
	half_h: float,
	col: Color,
	rings: int
) -> void:
	## Arc loft over a tyre. `start_a`/`end_a` are angles from +Z toward +Y.
	var centers: Array = []
	var radii: Array = []
	var n := maxi(rings, 4)
	for i in n:
		var t := float(i) / float(n - 1)
		var a: float = lerpf(start_a, end_a, t)
		centers.append(axle + Vector3(0.0, sin(a) * radius, cos(a) * radius))
		# Slightly thinner toward the tips so the fender tapers.
		var taper := lerpf(0.72, 1.0, sin(t * PI))
		radii.append(Vector2(half_w * taper, half_h * taper))
	_loft(b, centers, radii, col, 12)


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
		Transform3D(Basis.IDENTITY, Vector3(0, 0, 0.020)), Vector3(0.0045, 0.003, 0.044), 0.0012, NEEDLE, true
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
	var width := 0.135 if is_front else 0.160
	var rim_r := WHEEL_R * 0.76
	var hub_r := 0.055
	# Hollow tyre — solid discs used to bury the rim and spokes.
	b.channel = LowPoly.SOLID
	b.add_ring(Transform3D(lie, Vector3.ZERO), WHEEL_R, rim_r + 0.018, width, 22, TYRE)
	b.add_ring(
		Transform3D(lie, Vector3.ZERO), WHEEL_R * 0.995, rim_r + 0.028, width * 0.58, 22, TYRE.lightened(0.08)
	)
	# Chrome lips stand proud of the tyre sidewall so they read edge-on.
	b.channel = LowPoly.METAL
	b.add_ring(Transform3D(lie, Vector3.ZERO), rim_r + 0.016, rim_r - 0.035, width * 1.08, 18, CHROME)
	b.add_ring(Transform3D(lie, Vector3.ZERO), rim_r - 0.035, hub_r + 0.04, width * 0.22, 16, ALUM_D)
	b.add_cylinder(Transform3D(lie, Vector3.ZERO), hub_r, width * 0.90, 12, ALUM)
	b.add_cylinder(Transform3D(lie, Vector3.ZERO), 0.024, width * 1.15, 10, CHROME)
	# Laced spokes in the wheel plane (YZ), thick enough for title distance.
	for i in 18:
		var a := TAU * float(i) / 18.0
		var rim_pt := Vector3(0, cos(a) * (rim_r - 0.015), sin(a) * (rim_r - 0.015))
		var hub_pt := Vector3(0, cos(a) * hub_r * 0.65, sin(a) * hub_r * 0.65)
		var side := 0.028 if (i % 2 == 0) else -0.028
		_bone(b, hub_pt + Vector3(side, 0, 0), rim_pt + Vector3(side * 0.2, 0, 0), 0.0055, CHROME)
	if is_front:
		b.add_cylinder(Transform3D(lie, Vector3(0.068, 0, 0)), WHEEL_R * 0.55, 0.010, 20, ALUM)
		b.add_cylinder(Transform3D(lie, Vector3(0.072, 0, 0)), WHEEL_R * 0.20, 0.012, 12, ALUM_D)
	else:
		b.add_cylinder(Transform3D(lie, Vector3(-0.074, 0, 0)), WHEEL_R * 0.36, 0.012, 18, ALUM_D)
		b.add_cylinder(Transform3D(lie, Vector3(-0.078, 0, 0)), WHEEL_R * 0.16, 0.014, 12, BLACK_S)
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
