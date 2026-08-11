extends Node3D
## Café racer. Faces +Z, tyres on y = 0.
##
## One tubular chassis: every part hangs off a joint. Forks run to the front
## axle, the swingarm runs to the rear, the tank sits on the top tube. That is
## what stops it reading as a pile of primitives parked next to each other.

const LowPoly := preload("res://scripts/low_poly.gd")
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
const MIRROR := Color("9fb2c4")
const SHELL := Color("3b4450")

const METALS: Array[Color] = [ALUM, ALUM_D, CHROME, COPPER, COPPER_D]
const PAINTED: Array[Color] = [PAINT, PAINT_D, CREAM, BLUE, BLUE_D, GOLD, GOLD_D]

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
var _body_shell: MeshInstance3D
var _kit_parts: Array = [[], []]
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
	_bike_style = clampi(style, 0, 2)
	_dial_top_speed = [62.0, 68.0, 76.0][_bike_style]
	if _body_shell:
		_body_shell.visible = _bike_style == 0
	for i in _kit_parts.size():
		for node in _kit_parts[i]:
			(node as Node3D).visible = i == _bike_style - 1
	for i in _fenders.size():
		_fenders[i].visible = i == _bike_style


func _build_bike_variants() -> void:
	## Same café: round lamp, clip-ons, teardrop tank, hump tail. The unlocked
	## bikes change the tank and the tail, not the kind of motorcycle.
	_build_sabre()
	_build_tempest()


func _build_sabre() -> void:
	## Longer café. Slimmer tank, tucked seat, stretched hump.
	var kit := Node3D.new()
	kit.name = "SabreKit"
	add_child(kit)
	_kit_parts[0].append(kit)

	var body := LowPoly.new()
	body.smooth = true
	_loft(
		body,
		[
			Vector3(0, 0.87, 0.62),
			Vector3(0, 0.85, 0.44),
			Vector3(0, 0.83, 0.22),
			Vector3(0, 0.82, 0.00),
			Vector3(0, 0.83, -0.20),
			Vector3(0, 0.85, -0.36),
		],
		[
			Vector2(0.062, 0.048),
			Vector2(0.108, 0.076),
			Vector2(0.158, 0.100),
			Vector2(0.168, 0.102),
			Vector2(0.128, 0.082),
			Vector2(0.080, 0.056),
		],
		BLUE
	)
	_sphere(body, Vector3(0, 0.87, 0.64), 0.048, BLUE)
	_loft(
		body,
		[
			Vector3(0, 0.76, 0.44),
			Vector3(0, 0.74, 0.18),
			Vector3(0, 0.735, -0.04),
			Vector3(0, 0.75, -0.22),
		],
		[Vector2(0.082, 0.038), Vector2(0.132, 0.046), Vector2(0.138, 0.044), Vector2(0.090, 0.034)],
		CREAM,
		12
	)
	_capsule(body, Vector3(0, 0.930, 0.10), 0.013, 0.70, CREAM, Vector3(90, 0, 0))
	for s in [-1.0, 1.0]:
		_capsule(body, Vector3(s * 0.028, 0.928, 0.10), 0.005, 0.72, COPPER, Vector3(90, 0, 0))
		_cyl(body, Vector3(s * 0.162, 0.812, 0.06), 0.024, 0.008, CHROME, Vector3(0, 0, 90))
	_cyl(body, Vector3(0, 0.942, -0.16), 0.036, 0.020, ALUM, Vector3(0, 0, 0))
	_cyl(body, Vector3(0, 0.956, -0.16), 0.024, 0.010, CHROME, Vector3(0, 0, 0))
	_capsule(body, Vector3(0, 0.78, -0.40), 0.062, 0.30, LEATHER, Vector3(90, 0, 0))
	_sphere(body, Vector3(0, 0.80, -0.26), 0.054, LEATHER)
	_loft(
		body,
		[
			Vector3(0, 0.82, -0.50),
			Vector3(0, 0.86, -0.66),
			Vector3(0, 0.88, -0.82),
			Vector3(0, 0.84, -0.96),
		],
		[
			Vector2(0.088, 0.046),
			Vector2(0.074, 0.040),
			Vector2(0.054, 0.032),
			Vector2(0.032, 0.022),
		],
		BLUE
	)
	_sphere(body, Vector3(0, 0.84, -0.98), 0.030, BLUE)
	_sphere(body, Vector3(0, 0.80, -1.00), 0.024, TAIL, true)
	_bone(body, SEAT_J, Vector3(0, 0.84, -0.54), 0.012, BLACK_S)
	_attach(kit, body, "SabreBody")


func _build_tempest() -> void:
	## Big-tank café. Fatter teardrop, cream and gold, taller hump.
	var kit := Node3D.new()
	kit.name = "TempestKit"
	add_child(kit)
	_kit_parts[1].append(kit)

	var body := LowPoly.new()
	body.smooth = true
	_loft(
		body,
		[
			Vector3(0, 0.88, 0.56),
			Vector3(0, 0.86, 0.40),
			Vector3(0, 0.84, 0.18),
			Vector3(0, 0.83, -0.02),
			Vector3(0, 0.84, -0.18),
			Vector3(0, 0.86, -0.30),
		],
		[
			Vector2(0.085, 0.060),
			Vector2(0.145, 0.095),
			Vector2(0.205, 0.125),
			Vector2(0.215, 0.128),
			Vector2(0.160, 0.100),
			Vector2(0.100, 0.070),
		],
		CREAM
	)
	_sphere(body, Vector3(0, 0.88, 0.58), 0.058, CREAM)
	_loft(
		body,
		[
			Vector3(0, 0.76, 0.40),
			Vector3(0, 0.73, 0.16),
			Vector3(0, 0.725, -0.04),
			Vector3(0, 0.75, -0.18),
		],
		[Vector2(0.100, 0.044), Vector2(0.160, 0.054), Vector2(0.168, 0.052), Vector2(0.110, 0.040)],
		GOLD,
		12
	)
	_capsule(body, Vector3(0, 0.948, 0.12), 0.016, 0.58, GOLD, Vector3(90, 0, 0))
	for s in [-1.0, 1.0]:
		_capsule(body, Vector3(s * 0.032, 0.945, 0.12), 0.005, 0.60, COPPER, Vector3(90, 0, 0))
		_cyl(body, Vector3(s * 0.208, 0.825, 0.08), 0.028, 0.008, CHROME, Vector3(0, 0, 90))
	_cyl(body, Vector3(0, 0.958, -0.10), 0.042, 0.024, ALUM, Vector3(0, 0, 0))
	_cyl(body, Vector3(0, 0.974, -0.10), 0.028, 0.012, CHROME, Vector3(0, 0, 0))
	_capsule(body, Vector3(0, 0.82, -0.32), 0.074, 0.26, LEATHER, Vector3(90, 0, 0))
	_sphere(body, Vector3(0, 0.84, -0.22), 0.062, LEATHER)
	_loft(
		body,
		[
			Vector3(0, 0.86, -0.44),
			Vector3(0, 0.92, -0.58),
			Vector3(0, 0.96, -0.72),
			Vector3(0, 0.90, -0.86),
		],
		[
			Vector2(0.105, 0.054),
			Vector2(0.090, 0.050),
			Vector2(0.068, 0.042),
			Vector2(0.040, 0.030),
		],
		GOLD
	)
	_sphere(body, Vector3(0, 0.90, -0.88), 0.034, GOLD)
	_sphere(body, Vector3(0, 0.86, -0.90), 0.026, TAIL, true)
	_bone(body, SEAT_J, Vector3(0, 0.86, -0.50), 0.012, BLACK_S)
	_attach(kit, body, "TempestBody")


func _build_body() -> void:
	var shell := LowPoly.new()
	shell.smooth = true
	_build_tank(shell)
	_build_cowl(shell)
	_body_shell = _commit(shell, "BodyShell")

	var hard := LowPoly.new()
	_build_chassis(hard)
	_build_engine(hard)
	_build_exhaust(hard)
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
	_bx(b, Vector3(0, 0.56, REAR_Z + 0.04), Vector3(0.16, 0.03, 0.26), BLACK, 0.02)


func _build_tank(b: LowPoly) -> void:
	## Sits on the top tube. The loft is centred on that bone so the tank and
	## the frame occupy the same space rather than hovering over it.
	var centers := PackedVector3Array(
		[
			Vector3(0, 0.86, 0.58),
			Vector3(0, 0.84, 0.42),
			Vector3(0, 0.82, 0.22),
			Vector3(0, 0.81, 0.02),
			Vector3(0, 0.82, -0.16),
			Vector3(0, 0.84, -0.28),
		]
	)
	var radii := PackedVector2Array(
		[
			Vector2(0.070, 0.052),
			Vector2(0.120, 0.082),
			Vector2(0.175, 0.110),
			Vector2(0.185, 0.112),
			Vector2(0.140, 0.090),
			Vector2(0.090, 0.065),
		]
	)
	b.channel = LowPoly.PAINT
	b.add_loft(centers, radii, SIDES, PAINT)
	_sphere(b, Vector3(0, 0.86, 0.60), 0.052, PAINT)
	var belly := PackedVector3Array(
		[
			Vector3(0, 0.76, 0.42),
			Vector3(0, 0.74, 0.18),
			Vector3(0, 0.735, -0.02),
			Vector3(0, 0.75, -0.18),
		]
	)
	var belly_r := PackedVector2Array(
		[Vector2(0.090, 0.042), Vector2(0.145, 0.050), Vector2(0.150, 0.048), Vector2(0.100, 0.038)]
	)
	b.add_loft(belly, belly_r, 12, CREAM)
	_capsule(b, Vector3(0, 0.925, 0.12), 0.015, 0.62, CREAM, Vector3(90, 0, 0))
	for s in [-1.0, 1.0]:
		_capsule(b, Vector3(s * 0.030, 0.922, 0.12), 0.005, 0.64, COPPER, Vector3(90, 0, 0))
		_cyl(b, Vector3(s * 0.178, 0.815, 0.08), 0.026, 0.008, CHROME, Vector3(0, 0, 90))
	_cyl(b, Vector3(0, 0.940, -0.12), 0.038, 0.022, ALUM, Vector3(0, 0, 0))
	_cyl(b, Vector3(0, 0.954, -0.12), 0.026, 0.012, CHROME, Vector3(0, 0, 0))


func _build_cowl(b: LowPoly) -> void:
	_capsule(b, Vector3(0, 0.80, -0.34), 0.068, 0.28, LEATHER, Vector3(90, 0, 0))
	_sphere(b, Vector3(0, 0.82, -0.24), 0.058, LEATHER)
	var tail := PackedVector3Array(
		[
			Vector3(0, 0.84, -0.46),
			Vector3(0, 0.88, -0.60),
			Vector3(0, 0.90, -0.74),
			Vector3(0, 0.86, -0.86),
		]
	)
	var tail_r := PackedVector2Array(
		[Vector2(0.095, 0.050), Vector2(0.082, 0.046), Vector2(0.062, 0.038), Vector2(0.038, 0.028)]
	)
	b.channel = LowPoly.PAINT
	b.add_loft(tail, tail_r, 12, PAINT)
	_sphere(b, Vector3(0, 0.86, -0.88), 0.032, PAINT.lightened(0.05))
	_sphere(b, Vector3(0, 0.82, -0.90), 0.026, TAIL, true)
	_bone(b, SEAT_J, Vector3(0, 0.84, -0.50), 0.012, BLACK_S)


func _build_engine(b: LowPoly) -> void:
	## Fills the frame diamond so the cases touch the down tube and the pivot.
	_bx(b, ENGINE, Vector3(0.28, 0.20, 0.36), ALUM, 0.04)
	_bx(b, ENGINE + Vector3(0, -0.02, 0), Vector3(0.32, 0.10, 0.30), ALUM_D, 0.025)
	for i in 2:
		var z: float = ENGINE.z + 0.10 - float(i) * 0.20
		for f in 6:
			_cyl(b, Vector3(0, ENGINE.y + 0.08 + float(f) * 0.015, z), 0.088, 0.011, ALUM_D, Vector3(8, 0, 0))
		_bx(b, Vector3(0, ENGINE.y + 0.20, z - 0.02), Vector3(0.16, 0.06, 0.14), ALUM, 0.016)
	for s in [-1.0, 1.0]:
		_cyl(b, ENGINE + Vector3(s * 0.145, 0, 0), 0.070, 0.032, CHROME, Vector3(0, 0, 90))


func _build_exhaust(b: LowPoly) -> void:
	## Headers leave the heads and run into the megaphones — one continuous pipe.
	var head_a := Vector3(0.08, ENGINE.y + 0.18, ENGINE.z + 0.10)
	var head_b := Vector3(0.08, ENGINE.y + 0.18, ENGINE.z - 0.10)
	var join := Vector3(0.20, 0.36, 0.02)
	var mid := Vector3(0.24, 0.38, -0.36)
	var tip := Vector3(0.26, 0.50, -0.72)
	_bone(b, head_a, join, 0.022, CHROME)
	_bone(b, head_b, join, 0.022, CHROME)
	_bone(b, join, mid, 0.026, CHROME)
	_bone(b, mid, tip, 0.042, ALUM_D)
	_cyl(b, tip, 0.050, 0.036, CHROME, Vector3(108, 6, 0))


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
	var colors: Array[Color] = [PAINT, BLUE, GOLD]
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
	b.add_cylinder(Transform3D(lie, Vector3.ZERO), 0.06, width * 1.12, 10, ALUM)
	if is_front:
		b.add_cylinder(Transform3D(lie, Vector3(0.068, 0, 0)), WHEEL_R * 0.64, 0.010, 18, ALUM)
	for i in 8:
		var a := TAU * float(i) / 8.0
		b.add_cylinder(Transform3D(Basis(Vector3.RIGHT, a), Vector3.ZERO), 0.007, WHEEL_R * 1.50, 6, CHROME)
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
	_hero_cam.far = 2200.0
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
