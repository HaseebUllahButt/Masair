extends Node3D
## One traffic vehicle. Follows a gap, reads the road and passes deliberately.
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
## Real traffic is mostly monochrome — silvers, greys, white — with colour as
## the accent, so the back rows outweigh the bright ones.
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
	Color("dfe3e6"),
	Color("b9bfc4"),
	Color("7d848c"),
	Color("3a4048"),
	Color("f4f5f2"),
	Color("5d6d7e"),
]
const MIN_FOLLOW_GAP := 2.8
const FOLLOW_TIME := 1.6
## Braking a driver plans with when closing on a slower car (m/s²).
const COMFORT_DECEL := 2.3
## Seconds to materialise. A car that simply *is* there is a pop; one that
## fades in a few hundred metres out reads as cresting the last dip.
const FADE_IN := 1.5
## Cruise is a band, not a set speed: each driver creeps a couple of percent
## either side of it over tens of seconds, which is what separates a queue of
## cars from a freight train.
const CRUISE_DRIFT := 0.03
## A lane change is a manoeuvre, not a sideways translation. The old fixed
## 3.2 m/s step crossed one of these wide lanes in about 1.7 seconds and began
## at full lateral speed on the decision frame, which made cars scurry aside.
const LANE_CHANGE_MIN_DURATION := 2.6
const LANE_CHANGE_MAX_DURATION := 3.4
const SIGNAL_LEAD_MIN := 1.6
const SIGNAL_LEAD_MAX := 2.5
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
## Every driver scans its neighbours several times a tick. Asking the tree for
## the group each time built a fresh array per scan — dozens per car per frame
## on a busy road — so the roster is taken once per physics frame and shared.
static var _roster: Array[Node] = []
static var _roster_frame: int = -1
## Membership changes mid-frame too — a spawn in the manager, a headless probe
## stepping many ticks inside one frame — so arrivals and exits mark it stale.
static var _roster_stale: bool = true

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
## The traffic/remote-rider contract keeps direction readable, but traffic
## always travels forward — even legacy callers passing an opposing direction.
var direction: int = 1
var acceleration: float = 0.0
var _driver_accel: float = 1.8
var _headway: float = FOLLOW_TIME
var _road_cruise: float = 14.0
var _road_sample_timer: float = 0.0
var _hazards_timer: float = 0.0

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
## In-lane wander — every driver holds a slightly different line, drifting a
## hand's width either way over seconds. Applied to the drawn transform only:
## `lateral` stays the lane logic coordinate so follow and clearance maths are
## never noised by it.
var _wander: float = 0.0
var _wander_t: float = 0.0
var _wander_amp: float = 0.14
var _wander_w1: float = 0.45
var _wander_w2: float = 1.4
var _wander_p1: float = 0.0
var _wander_p2: float = 0.0
var _drawn_lateral: float = 0.0
var _cruise_phase: float = 0.0
var _fade: float = 1.0
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
## The body sits on springs: it dips its nose under braking, squats a touch
## pulling away, and leans out of a bend or a lane change. A degree or two is
## the whole effect — it is what makes a car read as heavy rather than as a
## box sliding on rails. Lamps ride on the body mesh so they move with it.
var _body_pitch: float = 0.0
var _body_roll: float = 0.0
var _prev_lat_vel: float = 0.0
var _road_bend: float = 0.0
var _braking_lit: bool = false
const BODY_PITCH_PER_MS2 := 0.0045
const BODY_ROLL_PER_MS2 := 0.0065
const BODY_PITCH_MAX := 0.02
const BODY_ROLL_MAX := 0.03
## Brake lamps light on the pedal, not on every lift of the throttle. Two
## thresholds stop a car easing along a queue from flickering its tails.
const BRAKE_LIGHT_ON := -0.9
const BRAKE_LIGHT_OFF := -0.45


func setup(vehicle_kind: int, start_lane: int, z: float, cruise: float, color_index: int, _dir: int = 1) -> void:
	kind = vehicle_kind
	lane = start_lane
	track_z = z
	speed = maxf(cruise, 2.0)
	base_speed = speed
	direction = 1
	_path = get_node("/root/RoadPath")
	_game = get_node_or_null("/root/GameManager")
	_driver_accel = randf_range(1.4, 2.1) if kind < Kind.TRUCK else 0.85
	_headway = randf_range(1.35, 1.95) if kind < Kind.TRUCK else 2.0
	acceleration = 0.0
	_road_cruise = base_speed
	_road_sample_timer = 0.0
	_hazards_timer = 0.0
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
	# Wide vehicles hold their lane tighter: a lorry has under a metre to the
	# paint either side, a hatchback has a lane and a half.
	_wander_amp = randf_range(0.07, 0.24) * clampf((1.35 - _half_w) / 0.45, 0.3, 1.0)
	_wander_w1 = randf_range(0.30, 0.62)
	_wander_w2 = randf_range(1.1, 1.9)
	_wander_p1 = randf() * TAU
	_wander_p2 = randf() * TAU
	_wander_t = randf() * 100.0
	_cruise_phase = randf() * TAU
	_update_wander(0.0)
	_drawn_lateral = lateral + _wander
	_fade = 0.0

	if _mesh_instance == null:
		_mesh_instance = MeshInstance3D.new()
		_mesh_instance.name = "VehicleMesh"
		# The sun's shadow box is now a single 110 m ortho, not a horizon-wide
		# cascade, so a car pays one small draw into it and the tarmac stays
		# clean — the dotted screen-door that killed shadow maps the first time
		# was the old kilometre-wide map's texel size, not the cars.
		_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		_mesh_instance.visibility_range_end = 560.0
		LowPoly.cheap_draw(_mesh_instance)
		add_child(_mesh_instance)
	_mesh_instance.mesh = _mesh_for(kind, color_index)
	_mesh_instance.rotation = Vector3.ZERO
	_body_pitch = 0.0
	_body_roll = 0.0
	_prev_lat_vel = 0.0
	_braking_lit = false
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
	_roster_stale = true
	_apply_fade(0.0)
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
	LowPoly.cheap_draw(shadow)
	add_child(shadow)
	return shadow


func _lamp_child(node_name: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visibility_range_end = 560.0
	LowPoly.cheap_draw(mi)
	# On the body, not the car root, so the lamps dip and lean with it.
	_mesh_instance.add_child(mi)
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
		direction > 0
		and gap >= 4.0
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
	_hazards_timer = maxf(0.0, _hazards_timer - delta)
	_update_wander(delta)
	_apply_fade(delta)
	_update_road_cruise(delta)
	_update_horn_response(delta)
	_update_lane_plan(delta)
	if _can_plan_lane_change():
		_lane_timer = randf_range(0.8, 1.6)
		_try_escape_lane()

	var lead: Node3D = _nearest_lead()
	var demand: float = _following_acceleration(lead)
	## IDM produces one continuous demand, instead of alternating between a
	## cruise target and an 11 m/s² brake. Jerk limiting keeps queues supple;
	## a genuinely short closing gap still gets the full emergency brake.
	var emergency: bool = false
	if lead != null:
		var gap: float = _bumper_gap(lead)
		var closing: float = maxf(0.0, speed - float(lead.speed))
		emergency = gap < MIN_FOLLOW_GAP + closing * closing / 10.0 and not (lead == _player and float(lead.speed) > speed)
	acceleration = move_toward(acceleration, demand, (25.0 if emergency else 2.5) * delta)
	speed = maxf(0.0, speed + acceleration * delta)
	if acceleration < BRAKE_LIGHT_ON:
		_braking_lit = true
	elif acceleration > BRAKE_LIGHT_OFF:
		_braking_lit = false
	_brake_lamps.visible = _braking_lit or (speed < 0.3 and lead != null)
	if acceleration < -4.5:
		_hazards_timer = 2.0
	track_z = _path.advance(track_z, speed * delta)

	var before: float = _drawn_lateral
	_advance_lane_change(delta)
	_signal(delta)
	_drawn_lateral = lateral + _wander
	_place((_drawn_lateral - before) / maxf(speed * delta, 0.25))
	_settle_body(delta, (_drawn_lateral - before) / maxf(delta, 0.0001))


func _update_road_cruise(delta: float) -> void:
	_road_sample_timer -= delta
	if _road_sample_timer > 0.0:
		return
	## Road trigonometry is more expensive than the driver maths. Look a few
	## seconds ahead four times a second so braking starts before the corner.
	_road_sample_timer = 0.35
	var ahead: float = track_z + maxf(25.0, speed * 3.0)
	_road_bend = float(_path.curvature_at(track_z))
	var bend: float = maxf(absf(_road_bend), absf(float(_path.curvature_at(ahead))))
	var corner_speed: float = sqrt(3.2 / maxf(bend, 0.0001))
	var cruise: float = base_speed * (1.0 + CRUISE_DRIFT * sin(_wander_t * 0.11 + _cruise_phase))
	var uphill: float = maxf(0.0, sin(float(_path.pitch_at(ahead))))
	cruise *= maxf(0.62, 1.0 - uphill * (3.0 if kind >= Kind.TRUCK else 0.65))
	_road_cruise = maxf(6.0, minf(cruise, corner_speed))


func _settle_body(delta: float, lat_vel: float) -> void:
	## Lateral load is the bend's centripetal pull plus the lane change's own
	## sideways acceleration; the body leans away from both.
	var lat_accel: float = (lat_vel - _prev_lat_vel) / maxf(delta, 0.0001)
	_prev_lat_vel = lat_vel
	var load: float = clampf(_road_bend * speed * speed + lat_accel, -6.0, 6.0)
	var pitch_target: float = clampf(-acceleration * BODY_PITCH_PER_MS2, -BODY_PITCH_MAX * 0.5, BODY_PITCH_MAX)
	var roll_target: float = clampf(load * BODY_ROLL_PER_MS2, -BODY_ROLL_MAX, BODY_ROLL_MAX)
	var k: float = 1.0 - exp(-5.0 * delta)
	_body_pitch = lerpf(_body_pitch, pitch_target, k)
	_body_roll = lerpf(_body_roll, roll_target, k)
	_mesh_instance.rotation = Vector3(_body_pitch, 0.0, _body_roll)


func _bumper_gap(lead: Node3D) -> float:
	return float(lead.track_z) - track_z - _half_len - float(lead.get_half_length())


func _following_acceleration(lead: Node3D) -> float:
	var free: float = _driver_accel * (1.0 - pow(speed / maxf(_road_cruise, 1.0), 4.0))
	if lead == null:
		return clampf(free, -COMFORT_DECEL, _driver_accel)
	var gap: float = maxf(0.1, _bumper_gap(lead))
	var closing: float = speed - float(lead.speed)
	var wanted: float = MIN_FOLLOW_GAP + maxf(0.0, speed * _headway + speed * closing / (2.0 * sqrt(_driver_accel * COMFORT_DECEL)))
	## A bike filtering past is already opening the gap. Ease off to let it
	## settle ahead; demanding a full emergency stop for that instant of tiny
	## headway makes every clean overtake look like a brake-check.
	var brake_limit: float = -1.5 if lead == _player and closing < -0.5 else -7.5
	return clampf(free - _driver_accel * pow(wanted / gap, 2.0), brake_limit, _driver_accel)


func settle_spawn_speed() -> void:
	## The unseen stream is already following. Inserting a 40 m/s driver behind
	## a 15 m/s lorry creates an emergency that no sensible driver would enter.
	_update_road_cruise(1.0)
	speed = minf(speed, _road_cruise)
	var lead: Node3D = _nearest_lead()
	if lead != null:
		speed = minf(speed, maxf(0.0, minf(float(lead.speed), (_bumper_gap(lead) - MIN_FOLLOW_GAP) / _headway)))


func _update_wander(_delta: float) -> void:
	_wander_t += _delta
	# Rolling speed gates the drift — a stationary queue does not wander.
	var settle := smoothstep(2.0, 9.0, speed)
	_wander = _wander_amp * settle * (
		sin(_wander_t * _wander_w1 + _wander_p1) + 0.45 * sin(_wander_t * _wander_w2 + _wander_p2)
	)


func _apply_fade(delta: float) -> void:
	if _fade >= 1.0:
		return
	_fade = minf(_fade + delta / FADE_IN, 1.0)
	var tr := (1.0 - _fade) * 0.85
	_mesh_instance.transparency = tr
	_contact_shadow.transparency = tr
	_brake_lamps.transparency = tr
	for blinker in _blinkers:
		blinker.transparency = tr


func _can_plan_lane_change() -> bool:
	return (
		direction > 0
		and _lane_timer <= 0.0
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
	## Both amber sides flash only for emergency braking; normal braking uses
	## the red tail lamps. Body +X is screen-left on this road frame.
	_blink_phase = fposmod(_blink_phase + delta * BLINK_RATE, 1.0)
	var drift: float = _signal_lateral - lateral
	var lit: bool = _blink_phase < 0.55
	_blinkers[0].visible = lit and (_hazards_timer > 0.0 or drift < -SIGNAL_EPSILON)
	_blinkers[1].visible = lit and (_hazards_timer > 0.0 or drift > SIGNAL_EPSILON)


func _exit_tree() -> void:
	_roster_stale = true


func _traffic() -> Array[Node]:
	var frame := Engine.get_physics_frames()
	if frame != _roster_frame or _roster_stale or not is_inside_tree():
		_roster_frame = frame
		_roster_stale = false
		_roster = get_tree().get_nodes_in_group("traffic") if is_inside_tree() else []
	return _roster


func _lead_at(lane_centre: float, include_target: bool = false) -> Node3D:
	var closest: Node3D
	var strongest_demand: float = INF
	var closest_gap: float = INF
	for other: Node in _traffic():
		var vehicle: Node3D = other as Node3D
		if vehicle == null or vehicle == self or not is_instance_valid(vehicle) or not ("track_z" in vehicle):
			continue
		var width: float = _half_w + float(vehicle.get_half_width()) + 0.6
		var occupies: bool = absf(float(vehicle.lateral) - lane_centre) < width
		if include_target:
			occupies = occupies or absf(float(vehicle.lateral) - _target_lateral) < width
		if not occupies:
			continue
		var gap: float = float(vehicle.track_z) - track_z
		if gap > 0.0:
			var demand: float = _following_acceleration(vehicle)
			if demand < strongest_demand or (is_equal_approx(demand, strongest_demand) and gap < closest_gap):
				closest = vehicle
				strongest_demand = demand
				closest_gap = gap
	if is_instance_valid(_player) and _player.alive:
		var width: float = _half_w + 0.38 + 0.55
		var occupies: bool = absf(float(_player.lateral) - lane_centre) < width
		if include_target:
			occupies = occupies or absf(float(_player.lateral) - _target_lateral) < width
		var gap: float = float(_player.track_z) - track_z
		if occupies and gap > 0.0 and _following_acceleration(_player) < strongest_demand:
			closest = _player
	return closest


func _nearest_lead() -> Node3D:
	## Honor the strongest constraint in both occupied lanes. A fast bike just
	## ahead must not hide a slower queue farther ahead, and a fast target-lane
	## lead must not mask the source lane while the car is still crossing it.
	return _lead_at(lateral, _lane_change_active)


func _try_escape_lane(preferred_away_from: float = NAN) -> bool:
	if _pending_lane >= 0 or _lane_change_active:
		return false
	var current_lead: Node3D = _nearest_lead()
	var current_accel: float = _following_acceleration(current_lead)
	var candidates: Array[int] = []
	if lane > 0:
		candidates.append(lane - 1)
	if lane < int(_path.LANE_COUNT) - 1:
		candidates.append(lane + 1)
	if not is_nan(preferred_away_from) and candidates.size() > 1:
		if absf(_path.lane_x(candidates[1]) - preferred_away_from) > absf(_path.lane_x(candidates[0]) - preferred_away_from):
			candidates.reverse()
	for next: int in candidates:
		if not _lane_is_clear(next):
			continue
		var next_lead: Node3D = _lead_at(float(_path.lane_x(next)))
		var gain: float = _following_acceleration(next_lead) - current_accel
		var keep_right: bool = next < lane and gain > -0.2 and (next_lead == null or float(next_lead.speed) >= speed - 1.0)
		var pass_left: bool = next > lane and current_lead != null and float(current_lead.speed) < _road_cruise - 2.0 and gain > 0.35
		if is_nan(preferred_away_from) and not keep_right and not pass_left:
			continue
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
	_lane_change_lock = _lane_change_duration + 3.0
	_lane_timer = randf_range(6.0, 12.0)


func _safe_merge_gap(vehicle: Node3D) -> bool:
	var dz: float = float(vehicle.track_z) - track_z
	var gap: float = absf(dz) - _half_len - float(vehicle.get_half_length())
	var follower_speed: float = speed if dz >= 0.0 else float(vehicle.speed)
	var closing: float = speed - float(vehicle.speed) if dz >= 0.0 else float(vehicle.speed) - speed
	## Protect the target follower as well as ourselves. A gap that exists now
	## but closes before the indicators finish is not an invitation to merge.
	var required: float = 8.0 + follower_speed * 1.0 + maxf(0.0, closing) * (SIGNAL_LEAD_MAX + LANE_CHANGE_MAX_DURATION)
	return gap > required


func _lane_is_clear(candidate: int) -> bool:
	if candidate < 0 or candidate >= _path.LANE_COUNT or candidate == lane:
		return false
	var lane_centre: float = _path.lane_x(candidate)
	for other: Node in _traffic():
		var vehicle: Node3D = other as Node3D
		if vehicle == null or vehicle == self or not is_instance_valid(vehicle) or not ("track_z" in vehicle):
			continue
		var committed_here: bool = false
		if "_pending_lane" in vehicle:
			committed_here = int(vehicle.get("_pending_lane")) == candidate or (bool(vehicle.get("_lane_change_active")) and int(vehicle.lane) == candidate)
		var width: float = _half_w + float(vehicle.get_half_width()) + 0.65
		if absf(float(vehicle.lateral) - lane_centre) < width or committed_here:
			if not _safe_merge_gap(vehicle):
				return false
	if is_instance_valid(_player) and _player.alive:
		## Include the full swept strip: a rider alongside the source lane must
		## not be clipped while the car is still halfway to its destination.
		var x: float = float(_player.lateral)
		if x > minf(lateral, lane_centre) - _half_w - 0.9 and x < maxf(lateral, lane_centre) + _half_w + 0.9:
			if not _safe_merge_gap(_player):
				return false
	return true


func can_change_to_lane(candidate: int) -> bool:
	## Public read-only query for the manager and focused headless tests.
	return _lane_is_clear(candidate)


func _place(drift: float = 0.0) -> void:
	# Traffic uses the same map-owned tarmac query as the rider. Lane centres are
	# already inset, but the API keeps future map profiles from placing a large
	# bus beyond a narrowed road edge. The drawn lateral carries the in-lane
	# wander; the logical one stays riveted for everyone else's maths.
	var road_transform: Transform3D = _path.road_transform_at(track_z, _drawn_lateral, _half_w)
	road_transform.basis = road_transform.basis.rotated(
		road_transform.basis.y, atan(clampf(drift * 1.25, -0.42, 0.42))
	)
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
	## The eyebrow turns down at both ends into a lip in front of and behind the
	## tyre — an arch, not a bar laid over the wheel — so the wheel sits in a
	## cut-out of the body the way a real one does.
	for z in zs:
		for side in [-1.0, 1.0]:
			_rbx(
				b,
				Vector3(side * flank, radius * 1.62, float(z)),
				Vector3(thickness, radius * 0.36, radius * 1.7),
				TRIM,
				0.04
			)
			for end in [-1.0, 1.0]:
				_rbx(
					b,
					Vector3(side * flank, radius * 1.24, float(z) + end * radius * 1.1),
					Vector3(thickness, radius * 0.34, radius * 0.95),
					TRIM,
					0.04,
					end * 0.95
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
