extends Node3D
## One traffic vehicle. Rides the road frame, occasionally changes lane.
##
## Plain Node3D on purpose: nothing here ever used the physics server — the bike
## does its own box overlap test — so a CharacterBody3D + CollisionShape3D per car
## was pure overhead.

const LowPoly := preload("res://scripts/low_poly.gd")
const CONTACT_SHADOW_SHADER: Shader = preload("res://shaders/contact_shadow.gdshader")

enum Kind { SEDAN, HATCH, COUPE, PICKUP, VAN, TRUCK, BUS }

## (half width, half length) per kind, for the bike's overlap test.
const DIMS := [
	Vector2(0.95, 2.1),
	Vector2(0.9, 1.75),
	Vector2(0.95, 2.05),
	Vector2(1.02, 2.8),
	Vector2(1.05, 2.3),
	Vector2(1.2, 3.3),
	Vector2(1.25, 3.5),
]
const BODY_COLORS: Array[Color] = [
	Color("c0392b"),
	Color("2f6fa8"),
	Color("27ae60"),
	Color("e79c1c"),
	Color("7d4aa8"),
	Color("e8ecef"),
	Color("18a58c"),
	Color("d2621d"),
	Color("36485c"),
	Color("d96a94"),
]
const LANE_CLEARANCE_AHEAD := 15.0
const LANE_CLEARANCE_BEHIND := 12.0
const MIN_FOLLOW_GAP := 7.0
const FOLLOW_TIME := 1.05
## A lane change is a manoeuvre, not a sideways translation. The old fixed
## 3.2 m/s step crossed one of these wide lanes in about 1.7 seconds and began
## at full lateral speed on the decision frame, which made cars scurry aside.
const LANE_CHANGE_MIN_DURATION := 2.6
const LANE_CHANGE_MAX_DURATION := 3.4
const SIGNAL_LEAD_MIN := 0.45
const SIGNAL_LEAD_MAX := 0.75
const HORN_HEARING_DISTANCE := 72.0
const HORN_ALIGNMENT := 2.6
const HORN_REACTION_MIN := 0.45
const HORN_REACTION_MAX := 0.95
const HORN_COOLDOWN := 2.5

static var _mesh_cache: Dictionary = {}
static var _brake_cache: Dictionary = {}
static var _blinker_cache: Dictionary = {}
static var _contact_shadow_mesh: QuadMesh
static var _contact_shadow_material: ShaderMaterial

## Blinks per second, both indicators and the pause between them.
const BLINK_RATE := 1.6
## Lateral error that still counts as "changing lane", so the indicator is on for
## the whole manoeuvre rather than flickering out as the car settles.
const SIGNAL_EPSILON := 0.06

var kind: int = Kind.SEDAN
var track_z: float = 0.0
var speed: float = 14.0
var base_speed: float = 14.0
var lane: int = 1
var lateral: float = 0.0

var _target_lateral: float = 0.0
var _lane_timer: float = 6.0
var _lane_change_lock: float = 0.0
var _pending_lane: int = -1
var _signal_lateral: float = 0.0
var _signal_lead_timer: float = 0.0
var _lane_change_active: bool = false
var _lane_change_from: float = 0.0
var _lane_change_elapsed: float = 0.0
var _lane_change_duration: float = 3.0
var _horn_reaction_timer: float = -1.0
var _horn_from_lateral: float = 0.0
var _horn_cooldown: float = 0.0
var _player: Node3D
var _half_w: float = 0.95
var _half_len: float = 2.1
var _near_miss_given: bool = false
var _path: Node
var _game: Node
var _mesh_instance: MeshInstance3D
var _contact_shadow: MeshInstance3D
## Lamps that are not always on get their own child mesh, hidden until they fire.
## A hidden MeshInstance3D costs nothing to draw, and this is the only way to
## light one car's brakes when every car of that colour shares one baked mesh.
var _brake_lamps: MeshInstance3D
var _blinkers: Array[MeshInstance3D] = []
var _blink_phase: float = 0.0


func setup(vehicle_kind: int, start_lane: int, z: float, cruise: float, color_index: int) -> void:
	kind = vehicle_kind
	lane = start_lane
	track_z = z
	speed = maxf(cruise, 2.0)
	base_speed = speed
	_path = get_node("/root/RoadPath")
	_game = get_node_or_null("/root/GameManager")
	lateral = _path.lane_x(lane)
	_target_lateral = lateral
	_signal_lateral = lateral
	_half_w = DIMS[kind].x
	_half_len = DIMS[kind].y
	_lane_timer = randf_range(4.0, 12.0)
	_lane_change_lock = 0.0
	_pending_lane = -1
	_signal_lead_timer = 0.0
	_lane_change_active = false
	_lane_change_elapsed = 0.0
	_horn_reaction_timer = -1.0
	_horn_cooldown = 0.0
	_near_miss_given = false

	_blink_phase = randf()

	if _mesh_instance == null:
		_mesh_instance = MeshInstance3D.new()
		_mesh_instance.name = "VehicleMesh"
		# Traffic silhouettes are readable from colour and shape. Real-time shadow
		# maps produced a dotted screen-door pattern on the tarmac and rendered every
		# car again for each sun cascade.
		_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_mesh_instance)
	_mesh_instance.mesh = _mesh_for(kind, color_index)
	if _contact_shadow == null:
		_contact_shadow = _make_contact_shadow()
	_contact_shadow.scale = Vector3(_half_w * 1.12, _half_len * 1.05, 1.0)
	if _brake_lamps == null:
		_brake_lamps = _lamp_child("BrakeLamps")
		for side in [-1.0, 1.0]:
			_blinkers.append(_lamp_child("Indicator%s" % ("L" if side < 0.0 else "R")))
	_brake_lamps.mesh = _brake_mesh(kind)
	_brake_lamps.visible = false
	for i in 2:
		_blinkers[i].mesh = _blinker_mesh(kind, -1.0 if i == 0 else 1.0)
		_blinkers[i].visible = false
	add_to_group("traffic")
	_place()


static func _shared_contact_shadow_mesh() -> QuadMesh:
	if _contact_shadow_mesh == null:
		_contact_shadow_mesh = QuadMesh.new()
		_contact_shadow_mesh.size = Vector2(2.0, 2.0)
	return _contact_shadow_mesh


static func _shared_contact_shadow_material() -> ShaderMaterial:
	if _contact_shadow_material == null:
		_contact_shadow_material = ShaderMaterial.new()
		_contact_shadow_material.shader = CONTACT_SHADOW_SHADER
	return _contact_shadow_material


func _make_contact_shadow() -> MeshInstance3D:
	var shadow := MeshInstance3D.new()
	shadow.name = "ContactShadow"
	shadow.mesh = _shared_contact_shadow_mesh()
	shadow.material_override = _shared_contact_shadow_material()
	shadow.position.y = 0.035
	shadow.rotation.x = -PI * 0.5
	shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	shadow.visibility_range_end = 145.0
	add_child(shadow)
	return shadow


func _lamp_child(node_name: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


func set_player(player: Node3D) -> void:
	## The player is treated as a moving obstacle during a lane change/follow
	## decision, but never gets a physics body of its own.
	_player = player


func can_hear_horn(rider_z: float, rider_lateral: float) -> bool:
	## A horn is useful to the driver directly ahead, not a magic command for
	## every visible car. Cars already committed to a manoeuvre keep doing it.
	var gap := track_z - rider_z
	return (
		gap >= 4.0
		and gap <= HORN_HEARING_DISTANCE
		and absf(rider_lateral - lateral) <= HORN_ALIGNMENT
		and _horn_cooldown <= 0.0
		and _horn_reaction_timer < 0.0
		and _pending_lane < 0
		and not _lane_change_active
		and _lane_change_lock <= 0.0
	)


func hear_horn(rider_z: float, rider_lateral: float) -> bool:
	if not can_hear_horn(rider_z, rider_lateral):
		return false
	_horn_from_lateral = rider_lateral
	_horn_reaction_timer = randf_range(HORN_REACTION_MIN, HORN_REACTION_MAX)
	_horn_cooldown = HORN_COOLDOWN
	return true


func _physics_process(delta: float) -> void:
	if _path == null:
		return
	_lane_timer -= delta
	_lane_change_lock = maxf(0.0, _lane_change_lock - delta)
	_horn_cooldown = maxf(0.0, _horn_cooldown - delta)
	_update_horn_response(delta)
	_update_lane_plan(delta)

	var lead := _nearest_lead()
	if lead != null and _can_plan_lane_change():
		var gap: float = float(lead.track_z) - track_z - float(lead.get_half_length()) - _half_len
		if gap < speed * FOLLOW_TIME + MIN_FOLLOW_GAP and _try_escape_lane():
			lead = _nearest_lead()

	# A tiny amount of natural drift keeps a sparse road from looking frozen, but
	# lane changes only happen when the full vehicle footprint has a safe gap.
	if _can_plan_lane_change():
		_lane_timer = randf_range(5.0, 14.0)
		if randf() < 0.12:
			_try_escape_lane()

	var target_speed := base_speed
	if lead != null:
		var gap: float = float(lead.track_z) - track_z - float(lead.get_half_length()) - _half_len
		var safe_gap := MIN_FOLLOW_GAP + speed * FOLLOW_TIME
		if gap < safe_gap:
			# Braking is proportional to the closing gap and the lead's speed. This
			# keeps a truck from abruptly stopping while still preventing pile-ups.
			target_speed = maxf(2.0, float(lead.speed) - maxf(0.0, safe_gap - gap) * 1.7)
		elif gap < safe_gap + 30.0:
			target_speed = minf(target_speed, float(lead.speed) + (gap - safe_gap) * 0.22)
	if _player != null and _player.alive:
		var player_gap: float = float(_player.track_z) - track_z - _half_len - float(_player.half_length)
		if player_gap > 0.0 and absf(float(_player.lateral) - lateral) < 2.25:
			var player_safe := MIN_FOLLOW_GAP + speed * FOLLOW_TIME
			if player_gap < player_safe:
				target_speed = minf(target_speed, maxf(2.0, float(_player.speed) - (player_safe - player_gap) * 1.7))

	# Tight curves ask traffic to shed a little speed too; this makes blind bends
	# readable and creates a natural opening for the rider to filter through.
	var curvature_load := absf(_path.curvature_at(track_z)) * speed * speed
	if curvature_load > 2.5:
		target_speed = minf(target_speed, sqrt(maxf(4.0, 24.0 / maxf(absf(_path.curvature_at(track_z)), 0.0001))))
	var rate := 11.0 if target_speed < speed else 4.0
	# Brake lights come from the demand, not from the achieved speed: they light as
	# the car decides to slow, which is the half second of warning that makes
	# traffic ahead readable instead of a wall that appears.
	_brake_lamps.visible = target_speed < speed - 0.4
	speed = move_toward(speed, target_speed, rate * delta)
	track_z = _path.advance(track_z, speed * delta)

	var before := lateral
	_advance_lane_change(delta)
	_signal(delta)
	_place((lateral - before) / maxf(speed * delta, 0.25))


func _can_plan_lane_change() -> bool:
	return (
		_lane_timer <= 0.0
		and _lane_change_lock <= 0.0
		and _pending_lane < 0
		and not _lane_change_active
		and _horn_reaction_timer < 0.0
	)


func _update_horn_response(delta: float) -> void:
	if _horn_reaction_timer < 0.0:
		return
	_horn_reaction_timer -= delta
	if _horn_reaction_timer > 0.0:
		return
	_horn_reaction_timer = -1.0
	# Prefer the lane that creates the most room from where the horn came from.
	# If neither adjacent lane is safe, the driver holds course instead of
	# swerving into another vehicle.
	_try_escape_lane(_horn_from_lateral)


func _update_lane_plan(delta: float) -> void:
	if _pending_lane < 0:
		return
	_signal_lead_timer -= delta
	if _signal_lead_timer > 0.0:
		return
	var next := _pending_lane
	_pending_lane = -1
	if not _lane_is_clear(next):
		_signal_lateral = lateral
		_lane_timer = randf_range(1.5, 2.5)
		return
	_begin_lane_change(next)


func _advance_lane_change(delta: float) -> void:
	if not _lane_change_active:
		return
	_lane_change_elapsed = minf(_lane_change_elapsed + delta, _lane_change_duration)
	var t := _lane_change_elapsed / _lane_change_duration
	# Smoothstep starts and ends with zero lateral speed, like steering into and
	# then unwinding a lane change rather than being shoved across the road.
	var eased := t * t * (3.0 - 2.0 * t)
	lateral = lerpf(_lane_change_from, _target_lateral, eased)
	if t >= 1.0:
		lateral = _target_lateral
		_lane_change_active = false
		_signal_lateral = lateral


func _signal(delta: float) -> void:
	## Indicator on the side the car is moving toward, for the whole manoeuvre.
	## Filtering through traffic at 200 km/h needs one bit of intent from the car
	## in front, and this is it.
	_blink_phase = fposmod(_blink_phase + delta * BLINK_RATE, 1.0)
	var drift := _signal_lateral - lateral
	var lit := absf(drift) > SIGNAL_EPSILON and _blink_phase < 0.55
	_blinkers[0].visible = lit and drift < 0.0
	_blinkers[1].visible = lit and drift > 0.0


func _nearest_lead() -> Node3D:
	var closest: Node3D
	var closest_gap := INF
	# During a gradual lane change the car still occupies the strip it is
	# physically crossing. Following its destination lane immediately would let
	# it accelerate through the slower vehicle it has only just started passing.
	var lane_centre: float = lateral
	for other in get_tree().get_nodes_in_group("traffic"):
		var vehicle := other as Node3D
		if vehicle == null or vehicle == self or not ("track_z" in vehicle):
			continue
		if absf(float(vehicle.lateral) - lane_centre) > 2.25:
			continue
		var gap: float = float(vehicle.track_z) - track_z
		if gap > 0.0 and gap < closest_gap:
			closest = vehicle
			closest_gap = gap
	if _player != null and _player.alive and absf(float(_player.lateral) - lane_centre) <= 2.25:
		var player_gap: float = float(_player.track_z) - track_z
		if player_gap > 0.0 and player_gap < closest_gap:
			closest = _player
	return closest


func _try_escape_lane(preferred_away_from: float = NAN) -> bool:
	if _pending_lane >= 0 or _lane_change_active:
		return false
	var candidates: Array[int] = []
	if lane > 0:
		candidates.append(lane - 1)
	if lane < _path.LANE_COUNT - 1:
		candidates.append(lane + 1)
	if candidates.size() > 1:
		if is_nan(preferred_away_from):
			if randf() < 0.5:
				candidates.reverse()
		elif absf(_path.lane_x(candidates[1]) - preferred_away_from) > absf(_path.lane_x(candidates[0]) - preferred_away_from):
			candidates.reverse()
	for next in candidates:
		if _lane_is_clear(next):
			_pending_lane = next
			_signal_lateral = _path.lane_x(next)
			_signal_lead_timer = randf_range(SIGNAL_LEAD_MIN, SIGNAL_LEAD_MAX)
			return true
	return false


func _begin_lane_change(next: int) -> void:
	lane = next
	_target_lateral = _path.lane_x(lane)
	_signal_lateral = _target_lateral
	_lane_change_from = lateral
	_lane_change_elapsed = 0.0
	_lane_change_duration = randf_range(LANE_CHANGE_MIN_DURATION, LANE_CHANGE_MAX_DURATION)
	_lane_change_active = true
	_lane_change_lock = _lane_change_duration + 1.25
	_lane_timer = randf_range(6.0, 12.0)


func _lane_is_clear(candidate: int) -> bool:
	if candidate < 0 or candidate >= _path.LANE_COUNT:
		return false
	var lane_centre: float = _path.lane_x(candidate)
	for other in get_tree().get_nodes_in_group("traffic"):
		var vehicle := other as Node3D
		if vehicle == null or vehicle == self or not ("track_z" in vehicle):
			continue
		var committed_here := (
			int(vehicle.get("_pending_lane")) == candidate
			or (bool(vehicle.get("_lane_change_active")) and int(vehicle.lane) == candidate)
		)
		if absf(float(vehicle.lateral) - lane_centre) > 2.15 and not committed_here:
			continue
		var dz: float = float(vehicle.track_z) - track_z
		var clearance := LANE_CLEARANCE_AHEAD if dz >= 0.0 else LANE_CLEARANCE_BEHIND
		if absf(dz) < clearance + _half_len + float(vehicle.get_half_length()):
			return false
	if _player != null and _player.alive and absf(float(_player.lateral) - lane_centre) <= 2.15:
		var dz_player: float = float(_player.track_z) - track_z
		var player_clearance := LANE_CLEARANCE_AHEAD if dz_player >= 0.0 else LANE_CLEARANCE_BEHIND
		if absf(dz_player) < player_clearance + _half_len + float(_player.half_length):
			return false
	return true


func can_change_to_lane(candidate: int) -> bool:
	## Public read-only query for the manager and focused headless tests.
	return _lane_is_clear(candidate)


func _place(drift: float = 0.0) -> void:
	# Traffic uses the same map-owned tarmac query as the rider. Lane centres are
	# already inset, but the API keeps future map profiles from placing a large
	# bus beyond a narrowed road edge.
	var road_transform: Transform3D = _path.road_transform_at(track_z, lateral, _half_w)
	road_transform.basis = road_transform.basis.rotated(road_transform.basis.y, atan(clampf(drift * 1.25, -0.42, 0.42)))
	global_transform = road_transform


func get_half_width() -> float:
	return _half_w


func get_half_length() -> float:
	return _half_len


func register_near_miss() -> void:
	if _near_miss_given:
		return
	_near_miss_given = true
	if _game:
		_game.register_near_miss()


# ------------------------------------------------------------------- meshes


static func _mesh_for(vehicle_kind: int, color_index: int) -> ArrayMesh:
	## One mesh per (kind, colour), built on demand and shared by every car after
	## that.
	var key := vehicle_kind * 100 + color_index
	if _mesh_cache.has(key):
		return _mesh_cache[key]
	var body := BODY_COLORS[color_index % BODY_COLORS.size()]
	var b := LowPoly.new()
	match vehicle_kind:
		Kind.HATCH:
			_build_hatch(b, body)
		Kind.COUPE:
			_build_coupe(b, body)
		Kind.PICKUP:
			_build_pickup(b, body)
		Kind.VAN:
			_build_van(b, body)
		Kind.TRUCK:
			_build_truck(b, body)
		Kind.BUS:
			_build_bus(b, body)
		_:
			_build_sedan(b, body)
	var mesh := b.commit()
	_mesh_cache[key] = mesh
	return mesh


const GLASS := Color("2b3a4e")  # dark tinted at dusk; a pale blue slab reads as a hole
const GLASS_TOP := Color("4d6d8c")
const TYRE := Color("14141a")
const RIM := Color("8b929b")
const TRIM := Color("1b1e24")  # arches, sills, bumper rubber
const PLATE := Color("d8d9cf")
## Soft HDR preserves the lamp colour at distance instead of collapsing each
## fixture into a harsh white/red pixel under the tonemapper.
const HEADLIGHT := Color(1.85, 1.68, 1.32)
const TAILLIGHT := Color(1.9, 0.28, 0.22)
const BRAKELIGHT := Color(4.2, 0.4, 0.26)  # the same lens with the pedal down
const INDICATOR := Color(3.4, 1.5, 0.18)
const MARKER := Color(1.65, 1.0, 0.3)

## Lamp positions per kind: [half_x, y, front_z, rear_z, width]. The baked
## head/tail lamps, the brake overlay and the indicators all read this one row,
## so a reshaped nose can never leave the indicators hanging in mid-air.
const LAMPS := {
	Kind.SEDAN: [0.66, 0.74, 2.11, -2.11, 0.46],
	Kind.HATCH: [0.6, 0.72, 1.77, -1.76, 0.42],
	Kind.COUPE: [0.68, 0.66, 2.06, -2.06, 0.44],
	# The pickup's lamps clear its own bumper and tailgate, which reach further
	# out than the body sides do.
	Kind.PICKUP: [0.76, 1.02, 2.74, -2.88, 0.46],
	Kind.VAN: [0.74, 0.72, 2.12, -2.32, 0.46],
	Kind.TRUCK: [0.84, 0.62, 3.11, -3.64, 0.48],
	Kind.BUS: [0.88, 0.66, 3.47, -3.47, 0.48],
}
## Height of the high-mounted third brake light, per kind: the top of the rear
## panel in each case. On the boxy vehicles that is roof level, which is the only
## part of them a rider tucked in close behind can still see.
const HIGH_BRAKE := {
	Kind.SEDAN: 1.06,
	Kind.HATCH: 1.5,
	Kind.COUPE: 0.96,
	Kind.PICKUP: 1.46,
	Kind.VAN: 2.1,
	Kind.TRUCK: 2.8,
	Kind.BUS: 2.72,
}


static func _bx(b: LowPoly, pos: Vector3, size: Vector3, col: Color, glow: bool = false) -> void:
	b.add_box(Transform3D(Basis.IDENTITY, pos), size, col, glow)


static func _rbx(
	b: LowPoly, pos: Vector3, size: Vector3, col: Color, bevel: float = 0.07, tilt: float = 0.0, glow: bool = false
) -> void:
	## Chamfered, optionally tipped about X. The bevel is the point: it catches a
	## different shade on every edge, which is what separates a car from a brick.
	b.add_rounded_box(Transform3D(Basis.from_euler(Vector3(tilt, 0, 0)), pos), size, bevel, col, glow)


static func _wheels(b: LowPoly, radius: float, half_track: float, zs: Array) -> void:
	var lie := Basis.from_euler(Vector3(0, 0, PI * 0.5))
	for z in zs:
		for side in [-1.0, 1.0]:
			var x: float = side * half_track
			b.add_cylinder(Transform3D(lie, Vector3(x, radius, float(z))), radius, 0.26, 10, TYRE)
			b.add_cylinder(
				Transform3D(lie, Vector3(x * 1.02, radius, float(z))), radius * 0.58, 0.28, 8, RIM
			)


static func _arches(b: LowPoly, radius: float, flank: float, zs: Array, thickness: float) -> void:
	## A dark blister over each wheel, sitting on the flank. Without one the wheels
	## look bolted to a floating slab; with it the tyre sits under an eyebrow that
	## catches its own shade. Beside the wheel it would only read as a mudflap, so
	## it goes above the tyre, not next to it.
	for z in zs:
		for side in [-1.0, 1.0]:
			_rbx(
				b,
				Vector3(side * flank, radius * 1.62, float(z)),
				Vector3(thickness, radius * 0.36, radius * 2.7),
				TRIM,
				0.04
			)


static func _plates(b: LowPoly, y: float, front_z: float, rear_z: float) -> void:
	_bx(b, Vector3(0, y, front_z), Vector3(0.46, 0.13, 0.03), PLATE)
	_bx(b, Vector3(0, y, rear_z), Vector3(0.46, 0.13, 0.03), PLATE)


static func _exhaust(b: LowPoly, x: float, y: float, z: float, radius: float = 0.055) -> void:
	var lie := Basis.from_euler(Vector3(PI * 0.5, 0, 0))  # cylinder axis Y -> Z
	b.add_cylinder(Transform3D(lie, Vector3(x, y, z)), radius, 0.34, 7, Color("6a6f76"))


static func _lights(b: LowPoly, vehicle_kind: int) -> void:
	## Headlamp pair, tail pair, and a dim bar joining the tails — the bar is what
	## makes a car readable as a car at 150 m in the dark.
	var row: Array = LAMPS[vehicle_kind]
	var half_x: float = row[0]
	var y: float = row[1]
	var front_z: float = row[2]
	var rear_z: float = row[3]
	var w: float = row[4]
	for side in [-1.0, 1.0]:
		_rbx(b, Vector3(side * half_x, y, front_z), Vector3(w, 0.17, 0.1), HEADLIGHT, 0.03, 0.0, true)
		_rbx(b, Vector3(side * half_x, y + 0.06, rear_z), Vector3(w * 0.9, 0.19, 0.1), TAILLIGHT, 0.03, 0.0, true)
		# Amber lens, dark until the car actually signals — see _blinker_mesh.
		_rbx(b, Vector3(side * (half_x + w * 0.62), y, front_z - 0.02), Vector3(w * 0.34, 0.13, 0.09), MARKER.darkened(0.72), 0.02)
		_rbx(b, Vector3(side * (half_x + w * 0.62), y + 0.06, rear_z + 0.02), Vector3(w * 0.34, 0.13, 0.09), MARKER.darkened(0.72), 0.02)
	_bx(b, Vector3(0, y + 0.06, rear_z + 0.01), Vector3(half_x * 1.6, 0.06, 0.07), TAILLIGHT.darkened(0.55), true)


static func _brake_mesh(vehicle_kind: int) -> ArrayMesh:
	## The overlay that lights when the car brakes: the tail lenses again, hotter,
	## plus a high-mounted third lamp on anything with a roof worth using.
	if _brake_cache.has(vehicle_kind):
		return _brake_cache[vehicle_kind]
	var row: Array = LAMPS[vehicle_kind]
	var half_x: float = row[0]
	var y: float = row[1] + 0.06
	var rear_z: float = row[3]
	var w: float = row[4]
	var b := LowPoly.new()
	for side in [-1.0, 1.0]:
		_rbx(b, Vector3(side * half_x, y, rear_z - 0.02), Vector3(w * 0.94, 0.21, 0.1), BRAKELIGHT, 0.03, 0.0, true)
	_bx(b, Vector3(0, HIGH_BRAKE[vehicle_kind], rear_z - 0.04), Vector3(half_x * 1.0, 0.09, 0.08), BRAKELIGHT, true)
	var mesh := b.commit()
	_brake_cache[vehicle_kind] = mesh
	return mesh


static func _blinker_mesh(vehicle_kind: int, side: float) -> ArrayMesh:
	## Indicators for one side, front and rear, lit over the dark amber lenses
	## baked into the body.
	var key := vehicle_kind * 10 + (0 if side < 0.0 else 1)
	if _blinker_cache.has(key):
		return _blinker_cache[key]
	var row: Array = LAMPS[vehicle_kind]
	var half_x: float = row[0]
	var y: float = row[1]
	var front_z: float = row[2]
	var rear_z: float = row[3]
	var w: float = row[4]
	var x: float = side * (half_x + w * 0.62)
	var b := LowPoly.new()
	_rbx(b, Vector3(x, y, front_z - 0.03), Vector3(w * 0.36, 0.15, 0.09), INDICATOR, 0.02, 0.0, true)
	_rbx(b, Vector3(x, y + 0.06, rear_z + 0.03), Vector3(w * 0.36, 0.15, 0.09), INDICATOR, 0.02, 0.0, true)
	var mesh := b.commit()
	_blinker_cache[key] = mesh
	return mesh


static func _build_sedan(b: LowPoly, c: Color) -> void:
	var dark := c.darkened(0.45)
	_rbx(b, Vector3(0, 0.42, 0), Vector3(1.86, 0.34, 4.16), dark, 0.08)  # sill
	_rbx(b, Vector3(0, 0.74, -0.05), Vector3(1.94, 0.46, 4.2), c, 0.1)  # main body
	_rbx(b, Vector3(0, 0.96, 1.34), Vector3(1.78, 0.2, 1.5), c, 0.08, -0.06)  # bonnet
	_rbx(b, Vector3(0, 0.95, -1.62), Vector3(1.76, 0.2, 1.0), c, 0.08, 0.05)  # boot
	_rbx(b, Vector3(0, 1.2, -0.2), Vector3(1.66, 0.44, 2.0), c.darkened(0.12), 0.12)  # cabin
	_rbx(b, Vector3(0, 1.42, -0.3), Vector3(1.44, 0.08, 1.7), c.lightened(0.06), 0.04)  # roof
	_rbx(b, Vector3(0, 1.19, 0.86), Vector3(1.54, 0.5, 0.12), GLASS_TOP, 0.03, 0.5)  # screen
	_rbx(b, Vector3(0, 1.17, -1.24), Vector3(1.48, 0.46, 0.12), GLASS, 0.03, -0.42)
	for side in [-1.0, 1.0]:
		_bx(b, Vector3(side * 0.84, 1.2, -0.2), Vector3(0.06, 0.34, 1.72), GLASS)
		_bx(b, Vector3(side * 0.92, 1.24, 0.72), Vector3(0.14, 0.09, 0.2), c.darkened(0.3))  # mirror
	_bx(b, Vector3(0, 0.72, 2.11), Vector3(0.9, 0.2, 0.06), dark)  # grille
	_lights(b, Kind.SEDAN)
	_plates(b, 0.56, 2.12, -2.12)
	_exhaust(b, -0.5, 0.34, -2.16)
	_arches(b, 0.33, 0.97, [1.32, -1.3], 0.16)
	_wheels(b, 0.33, 0.86, [1.32, -1.3])


static func _build_hatch(b: LowPoly, c: Color) -> void:
	var dark := c.darkened(0.45)
	_rbx(b, Vector3(0, 0.4, 0.05), Vector3(1.76, 0.32, 3.46), dark, 0.08)
	_rbx(b, Vector3(0, 0.72, 0.05), Vector3(1.84, 0.46, 3.5), c, 0.1)
	_rbx(b, Vector3(0, 0.94, 1.1), Vector3(1.7, 0.2, 1.2), c, 0.08, -0.09)
	_rbx(b, Vector3(0, 1.2, -0.34), Vector3(1.62, 0.5, 2.1), c.darkened(0.1), 0.14)
	_rbx(b, Vector3(0, 1.45, -0.42), Vector3(1.4, 0.08, 1.8), c.lightened(0.06), 0.04)
	_rbx(b, Vector3(0, 1.2, 0.7), Vector3(1.5, 0.54, 0.12), GLASS_TOP, 0.03, 0.55)
	_rbx(b, Vector3(0, 1.24, -1.34), Vector3(1.44, 0.56, 0.12), GLASS, 0.03, -0.28)
	for side in [-1.0, 1.0]:
		_bx(b, Vector3(side * 0.82, 1.2, -0.34), Vector3(0.06, 0.38, 1.8), GLASS)
		_bx(b, Vector3(side * 0.9, 1.22, 0.58), Vector3(0.14, 0.09, 0.2), c.darkened(0.3))
	_bx(b, Vector3(0, 0.7, 1.76), Vector3(0.8, 0.18, 0.06), dark)
	_lights(b, Kind.HATCH)
	_plates(b, 0.55, 1.77, -1.77)
	# Hatch tails run up the corners.
	for side in [-1.0, 1.0]:
		_rbx(b, Vector3(side * 0.66, 1.05, -1.75), Vector3(0.24, 0.5, 0.09), TAILLIGHT, 0.03, 0.0, true)
	_rbx(b, Vector3(0, 1.62, -1.3), Vector3(0.9, 0.06, 0.5), c.darkened(0.3), 0.03)  # roof spoiler
	_arches(b, 0.31, 0.92, [1.12, -1.1], 0.16)
	_wheels(b, 0.31, 0.82, [1.12, -1.1])


static func _build_coupe(b: LowPoly, c: Color) -> void:
	## Low fastback: long bonnet, roof falling straight into a ducktail, wide
	## arches. The one vehicle out there that is quicker than the rest of traffic,
	## so it needs to look it from behind at 200 km/h.
	var dark := c.darkened(0.5)
	_rbx(b, Vector3(0, 0.36, 0), Vector3(1.9, 0.3, 4.02), dark, 0.07)  # sill
	_rbx(b, Vector3(0, 0.62, -0.05), Vector3(1.94, 0.42, 4.1), c, 0.12)  # main body
	_rbx(b, Vector3(0, 0.84, 1.32), Vector3(1.78, 0.16, 1.6), c, 0.09, -0.05)  # long bonnet
	_rbx(b, Vector3(0, 0.98, -0.5), Vector3(1.68, 0.36, 1.9), c.darkened(0.1), 0.16)  # cabin
	_rbx(b, Vector3(0, 1.16, -0.35), Vector3(1.36, 0.08, 1.2), c.lightened(0.04), 0.05)  # roof
	# Fastback glass: one long raked pane from the screen to the tail.
	_rbx(b, Vector3(0, 1.0, 0.62), Vector3(1.5, 0.48, 0.1), GLASS_TOP, 0.03, 0.62)
	_rbx(b, Vector3(0, 1.0, -1.26), Vector3(1.42, 0.62, 0.1), GLASS, 0.03, -0.72)
	for side in [-1.0, 1.0]:
		_bx(b, Vector3(side * 0.84, 1.0, -0.5), Vector3(0.06, 0.28, 1.5), GLASS)
		_bx(b, Vector3(side * 0.92, 1.0, 0.5), Vector3(0.16, 0.07, 0.18), dark)  # mirror
		_bx(b, Vector3(side * 0.74, 0.5, 1.2), Vector3(0.12, 0.1, 0.5), TRIM)  # side vent
	_rbx(b, Vector3(0, 0.9, -2.0), Vector3(1.7, 0.09, 0.42), c.darkened(0.22), 0.04, 0.22)  # ducktail
	_bx(b, Vector3(0, 0.6, 2.03), Vector3(1.1, 0.22, 0.06), TRIM)  # low intake
	_lights(b, Kind.COUPE)
	_plates(b, 0.44, 2.06, -2.06)
	for side in [-1.0, 1.0]:
		_exhaust(b, side * 0.42, 0.3, -2.1, 0.06)
	_arches(b, 0.34, 0.97, [1.3, -1.28], 0.2)
	_wheels(b, 0.34, 0.88, [1.3, -1.28])


static func _build_pickup(b: LowPoly, c: Color) -> void:
	## Working truck: tall cab, open bed with a tailgate, and a load. The high
	## stance and the gap over the bed give it a silhouette nothing else has.
	var dark := c.darkened(0.45)
	var bed := c.darkened(0.16)
	_rbx(b, Vector3(0, 0.62, 0), Vector3(2.0, 0.34, 5.1), dark, 0.07)  # chassis rail
	_rbx(b, Vector3(0, 1.0, 1.28), Vector3(2.04, 0.62, 2.5), c, 0.1)  # cab body
	_rbx(b, Vector3(0, 1.02, 2.48), Vector3(1.96, 0.5, 0.7), c, 0.1, -0.08)  # bonnet
	_rbx(b, Vector3(0, 1.5, 0.95), Vector3(1.88, 0.66, 1.7), c.darkened(0.1), 0.12)  # cabin
	_rbx(b, Vector3(0, 1.82, 0.95), Vector3(1.62, 0.08, 1.5), c.lightened(0.06), 0.04)  # roof
	_rbx(b, Vector3(0, 1.52, 1.82), Vector3(1.74, 0.66, 0.12), GLASS_TOP, 0.03, 0.42)
	_rbx(b, Vector3(0, 1.52, 0.1), Vector3(1.7, 0.6, 0.12), GLASS, 0.03, -0.12)
	for side in [-1.0, 1.0]:
		_bx(b, Vector3(side * 0.94, 1.5, 0.95), Vector3(0.06, 0.44, 1.5), GLASS)
		_bx(b, Vector3(side * 1.06, 1.56, 1.72), Vector3(0.18, 0.16, 0.08), dark)  # mirror
	# Bed: two walls, a tailgate and a headboard, left open in the middle.
	for side in [-1.0, 1.0]:
		_rbx(b, Vector3(side * 0.94, 1.14, -1.5), Vector3(0.16, 0.62, 2.7), bed, 0.05)
	_rbx(b, Vector3(0, 1.14, -2.78), Vector3(2.0, 0.62, 0.14), bed, 0.05)  # tailgate
	_rbx(b, Vector3(0, 1.2, -0.2), Vector3(2.0, 0.74, 0.14), bed, 0.05)  # headboard
	_rbx(b, Vector3(0, 0.86, -1.5), Vector3(1.86, 0.1, 2.6), dark, 0.03)  # bed floor
	# A tied-down load, so the bed is never just an empty box.
	_rbx(b, Vector3(-0.3, 1.16, -1.1), Vector3(1.0, 0.5, 1.1), Color("8a6a44"), 0.05)
	_rbx(b, Vector3(0.5, 1.06, -2.0), Vector3(0.7, 0.32, 0.9), Color("55606b"), 0.05)
	_bx(b, Vector3(0, 1.1, 2.66), Vector3(1.3, 0.26, 0.06), TRIM)  # grille
	_rbx(b, Vector3(0, 0.7, 2.72), Vector3(2.0, 0.24, 0.24), TRIM, 0.05)  # bumper
	_lights(b, Kind.PICKUP)
	_plates(b, 0.72, 2.78, -2.9)
	_exhaust(b, -0.6, 0.5, -2.72, 0.06)
	_arches(b, 0.42, 1.02, [1.7, -1.7], 0.2)
	_wheels(b, 0.42, 0.94, [1.7, -1.7])


static func _build_van(b: LowPoly, c: Color) -> void:
	var dark := c.darkened(0.42)
	_rbx(b, Vector3(0, 0.45, -0.15), Vector3(2.06, 0.36, 4.36), dark, 0.08)
	_rbx(b, Vector3(0, 1.3, -0.45), Vector3(2.12, 1.42, 3.7), c, 0.12)  # box
	_rbx(b, Vector3(0, 1.05, 1.66), Vector3(2.06, 0.94, 0.9), c, 0.14, -0.12)  # nose
	_rbx(b, Vector3(0, 1.66, 1.5), Vector3(1.98, 0.62, 0.9), c.darkened(0.1), 0.1, -0.3)  # cab roof
	_rbx(b, Vector3(0, 1.5, 1.94), Vector3(1.86, 0.66, 0.12), GLASS_TOP, 0.03, 0.35)
	_rbx(b, Vector3(0, 2.06, -0.5), Vector3(2.0, 0.1, 3.5), c.lightened(0.12), 0.04)
	for side in [-1.0, 1.0]:
		_bx(b, Vector3(side * 1.02, 1.5, 1.2), Vector3(0.06, 0.44, 0.7), GLASS)
		_bx(b, Vector3(side * 1.14, 1.6, 1.55), Vector3(0.2, 0.24, 0.08), dark)  # mirror
		_bx(b, Vector3(side * 0.78, 2.14, 1.2), Vector3(0.16, 0.08, 0.16), MARKER, true)
	_bx(b, Vector3(0, 0.86, 2.12), Vector3(1.0, 0.22, 0.06), dark)
	_lights(b, Kind.VAN)
	_plates(b, 0.62, 2.13, -2.33)
	for side in [-1.0, 1.0]:
		_rbx(b, Vector3(side * 0.86, 1.5, -2.32), Vector3(0.22, 0.7, 0.09), TAILLIGHT, 0.03, 0.0, true)
	# Sign-written flank: one lighter panel is enough to say "working vehicle".
	for side in [-1.0, 1.0]:
		_bx(b, Vector3(side * 1.07, 1.42, -0.45), Vector3(0.03, 0.7, 2.2), c.lightened(0.3))
	_exhaust(b, -0.55, 0.36, -2.38)
	_arches(b, 0.34, 1.06, [1.42, -1.5], 0.16)
	_wheels(b, 0.34, 0.94, [1.42, -1.5])


static func _build_truck(b: LowPoly, c: Color) -> void:
	var box_col := c.darkened(0.26)
	var dark := c.darkened(0.5)
	# Cab.
	_rbx(b, Vector3(0, 1.15, 2.05), Vector3(2.24, 1.5, 2.1), c, 0.12)
	_rbx(b, Vector3(0, 2.02, 1.95), Vector3(2.12, 0.36, 1.7), c.lightened(0.1), 0.08)
	_rbx(b, Vector3(0, 1.62, 3.06), Vector3(2.0, 0.72, 0.12), GLASS_TOP, 0.03, 0.28)
	_rbx(b, Vector3(0, 0.55, 3.0), Vector3(2.26, 0.5, 0.4), dark, 0.06)  # bumper
	# Trailer box, with a rib every metre so it is not one flat wall.
	_rbx(b, Vector3(0, 1.55, -0.95), Vector3(2.4, 2.36, 5.4), box_col, 0.06)
	_rbx(b, Vector3(0, 2.8, -0.95), Vector3(2.48, 0.16, 5.48), c.lightened(0.18), 0.04)
	for i in 5:
		_bx(b, Vector3(0, 1.55, 1.0 - float(i) * 1.05), Vector3(2.46, 2.2, 0.07), box_col.darkened(0.18))
	_rbx(b, Vector3(0, 0.5, -1.0), Vector3(2.2, 0.34, 5.2), dark, 0.05)  # skirt
	for side in [-1.0, 1.0]:
		_bx(b, Vector3(side * 1.16, 1.85, 3.0), Vector3(0.22, 0.3, 0.08), dark)  # mirror
		_bx(b, Vector3(side * 0.7, 2.24, 2.95), Vector3(0.16, 0.08, 0.16), MARKER, true)
		_bx(b, Vector3(side * 1.1, 2.92, -0.95), Vector3(0.12, 0.08, 4.4), MARKER.darkened(0.5), true)
	_lights(b, Kind.TRUCK)
	_plates(b, 0.5, 3.12, -3.65)
	# Twin stacks behind the cab: the one silhouette detail that says lorry from
	# any angle, including the mirror.
	for side in [-1.0, 1.0]:
		b.add_cylinder(
			Transform3D(Basis.IDENTITY, Vector3(side * 1.16, 1.75, 1.0)), 0.09, 2.6, 7, Color("70767e")
		)
	_arches(b, 0.42, 1.18, [2.1, -1.4, -2.6], 0.16)
	_wheels(b, 0.42, 1.0, [2.1, -1.4, -2.6])


static func _build_bus(b: LowPoly, c: Color) -> void:
	var dark := c.darkened(0.5)
	_rbx(b, Vector3(0, 1.52, 0), Vector3(2.48, 2.2, 6.9), c, 0.16)
	_rbx(b, Vector3(0, 2.68, 0), Vector3(2.34, 0.18, 6.72), c.lightened(0.15), 0.06)
	_rbx(b, Vector3(0, 0.5, 0), Vector3(2.42, 0.4, 6.7), dark, 0.06)  # skirt
	_rbx(b, Vector3(0, 1.9, 3.44), Vector3(2.24, 1.16, 0.12), GLASS_TOP, 0.03, 0.12)
	_rbx(b, Vector3(0, 1.9, -3.44), Vector3(2.24, 1.0, 0.12), GLASS, 0.03, -0.1)
	# Continuous glazed band, mullions between the panes.
	for i in 4:
		var z := 2.0 - float(i) * 1.5
		for side in [-1.0, 1.0]:
			_bx(b, Vector3(side * 1.25, 1.92, z), Vector3(0.07, 0.86, 1.24), GLASS)
			_bx(b, Vector3(side * 1.26, 1.92, z + 0.68), Vector3(0.08, 0.9, 0.12), c.darkened(0.2))
	# Destination blind over the windscreen.
	_bx(b, Vector3(0, 2.5, 3.45), Vector3(1.5, 0.3, 0.06), Color(2.2, 1.7, 0.6), true)
	for side in [-1.0, 1.0]:
		_bx(b, Vector3(side * 1.3, 2.2, 3.2), Vector3(0.2, 0.26, 0.08), dark)
		_bx(b, Vector3(side * 0.8, 2.8, 3.3), Vector3(0.16, 0.08, 0.16), MARKER, true)
	_lights(b, Kind.BUS)
	_plates(b, 0.52, 3.48, -3.48)
	# Roof vents and a shallow luggage rail break up the long flat top.
	for i in 3:
		_rbx(b, Vector3(0, 2.8, 2.0 - float(i) * 2.0), Vector3(1.1, 0.16, 0.7), c.darkened(0.34), 0.04)
	_exhaust(b, 0.9, 0.42, -3.5, 0.075)
	_arches(b, 0.45, 1.24, [2.3, -2.0], 0.16)
	_wheels(b, 0.45, 1.02, [2.3, -2.0])
