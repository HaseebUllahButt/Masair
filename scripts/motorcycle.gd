extends Node3D
## First-person arcade motorcycle.
##
## Longitudinal: engine force that falls away as speed rises, quadratic-ish drag,
## gravity on grades. Terminal speed falls out of the balance instead of being a
## clamp, so the last 20 km/h take real effort.
##
## Lateral: steering sets a *lean target*. The bike takes time to fall into the
## lean, the lean produces sideways acceleration, and lateral velocity carries
## and has to be caught. That delay is the whole difference between "wonky" and
## "planted" — the old model wrote lateral velocity straight from the keypress,
## so the bike teleported sideways and the lean was pure decoration.

signal crashed_into_traffic

const AudioGD := preload("res://scripts/audio.gd")
const HorizonMountainsGD := preload("res://scripts/horizon_mountains.gd")

# Longitudinal
@export var top_speed: float = 55.5556 # 200 km/h
@export var engine_accel: float = 12.0
@export var brake_accel: float = 16.0
@export var engine_brake: float = 3.2
@export var roll_drag: float = 0.03
@export var start_speed: float = 16.0

# Lateral
## 45° is racetrack-on-slicks angle and looks absurd on a road bike.
@export var max_lean_deg: float = 32.0
## About a fifth of a second to full lean, standing up a shade quicker. Faster
## than this and the bike does not tip into a corner, it cuts to it — the frame
## arrives before the rider has weighted anything, and every steering input
## reads on screen as a jolt rather than as a movement.
@export var lean_in_rate_deg: float = 175.0
@export var lean_out_rate_deg: float = 215.0
## How much of that rate survives at speed. A bike at 180 km/h does not flick:
## the faster the wheels turn the more they resist being tipped, which is why
## motorway lane changes are made with a lean you hold rather than a stab. This
## is also most of what stops the view snapping about at the top end.
@export var high_speed_lean_rate: float = 0.55
## Lateral accel per unit tan(lean). Physically this is g, and a road bike makes
## a bit over one of them; this is a road game, not a simulator, so it is nearer
## four. Coming down from 50 is what took the skate out of the steering.
@export var lean_grip: float = 38.0
## Fraction of the corner's real centrifugal load you have to hold with lean.
## The road never steers itself — you do — but this stays well under 1.0 so a
## corner costs part of your lean budget instead of all of it.
@export var corner_load: float = 0.5
@export var grip_damp: float = 2.2
## Absolute sideways speed cap, on top of the heading limit below. This is the
## number that decides how far you can actually place the bike.
@export var max_lat_speed: float = 13.0
@export var steer_authority_speed: float = 9.0
	## Usable road width leaves a little room for the tyre and shoulder. The path
	## can widen this boundary for an authored scenic pull-off.
@export var road_edge_margin: float = 0.38
@export var edge_recovery_zone: float = 1.2
@export var edge_recovery_force: float = 28.0

# Wheelie
@export var wheelie_pitch_deg: float = 32.0
@export var wheelie_min_speed: float = 14.0

# Hitbox
@export var half_width: float = 0.42
@export var half_length: float = 1.05
@export var forgiveness: float = 0.82
@export var near_miss_width: float = 2.4
@export var near_miss_length: float = 3.2
@export var invuln_time: float = 1.0

## Body +X is on the LEFT of the screen: the camera pivot is yawed 180° so it
## looks along the travel axis (+Z). Flip the raw axis once, here, and every
## downstream sign is in body space.
const BODY_X_FROM_SCREEN := -1.0

## How much more upright the rider's head stays than the frame. 0 = head bolted
## rigid (onboard-camera look, the whole world rolling 32 degrees under you),
## 1 = head stays level and the bike swings across the screen on its own. A real
## rider is somewhere in the middle and much nearer level than rigid: the neck
## is doing the work, and the eyes are on the exit of the corner, not on the
## tank. This also sets how far the eye swings sideways with the lean.
const HEAD_UPRIGHT := 0.56
## How much of the lean the visible bike takes. What the rider actually sees bank
## is the difference between this and HEAD_UPRIGHT — at 1.0 that difference is
## fourteen degrees, which was fine under a full cockpit and is far too much for
## a lone headlight half a metre in front of the lens, where it swings a third of
## the way across the frame on every lane change. Physically the frame still
## leans the whole amount; only what is drawn is damped.
const VISUAL_LEAN := 0.72
const LOOK_YAW := deg_to_rad(62.0)
const PARKED_SPEED := 2.0
## How far the nose swings toward the direction the bike is actually travelling.
## On the carriageway this is a few degrees of drift; on the spur, where the
## road runs across the route at up to thirty degrees, it is the difference
## between riding the detour and crabbing sideways down it.
const MAX_HEADING := deg_to_rad(38.0)

var track_z: float = 0.0
var speed: float = 0.0
var lateral: float = 0.0
var lat_vel: float = 0.0
var lean: float = 0.0
var wheelie: float = 0.0
var alive: bool = true
var max_lateral: float = 7.1
## Sitting on the bench at an overlook: the bike is parked and the view is the
## rider's own, free to turn.
var seated: bool = false

var _invuln: float = 0.0
var _fall_dir: float = 1.0
var _road_pitch: float = 0.0
var _shake: float = 0.0
var _bob: float = 0.0
var _cam_base: Vector3
## The camera's own resting orientation in the rig. The seat blend needs a fixed
## thing to come back to; without one the ride has no defined camera rotation at
## all and standing up leaves the eye wherever the blend stopped.
var _cam_basis: Basis
var _ride_fov: float = 76.0
var _pivot_base: Vector3
var _game: Node
var _path: Node
var _horn: AudioStreamPlayer
var _engine: AudioStreamPlayer
var _look_yaw: float = 0.0
var _heading: float = 0.0
var _seat_blend: float = 0.0
var _seat_yaw: float = 0.0
var _seat_pitch: float = 0.0
## Fork choice is state, not a nearest-surface query. Once the bike crosses the
## lead-off mouth, keep it on that ribbon while the gore widens beneath it.
var _committed_to_spur: bool = false

@onready var visual: Node3D = $Visual
@onready var camera: Camera3D = $CameraPivot/Camera3D
@onready var camera_pivot: Node3D = $CameraPivot


func _ready() -> void:
	_game = get_node_or_null("/root/GameManager")
	_path = get_node("/root/RoadPath")
	if _game:
		_game.bind_player(self)
	# Keep the complete bike on the authored tarmac. Ask RoadPath for the bounds
	# so a future map can narrow or widen the playable ribbon without changing the
	# rider. RIDEABLE_HALF_WIDTH is a scenery envelope, never a driving boundary.
	var road_bounds: Vector2 = _path.road_bounds_at(0.0)
	max_lateral = maxf(0.0, minf(-road_bounds.x, road_bounds.y) - half_width - road_edge_margin)
	speed = start_speed
	_invuln = invuln_time
	_cam_base = camera.position
	_cam_basis = camera.transform.basis
	_ride_fov = camera.fov
	_pivot_base = camera_pivot.position
	camera_pivot.rotation.y = PI
	_setup_audio()
	_place()


func _setup_audio() -> void:
	# Doppler on the listener as well as on the sources: the shift as a car goes
	# past is the difference between the two, and with a stationary listener a
	# pass at a 40 km/h closing speed barely bends at all.
	camera.doppler_tracking = Camera3D.DOPPLER_TRACKING_PHYSICS_STEP
	_horn = AudioStreamPlayer.new()
	_horn.stream = AudioGD.horn()
	_horn.volume_db = -2.0
	add_child(_horn)

	_engine = AudioStreamPlayer.new()
	_engine.stream = AudioGD.engine()
	_engine.volume_db = -12.0
	add_child(_engine)
	_engine.play()


func preview_bike(bike_id: int) -> void:
	if visual and visual.has_method("set_bike_style"):
		visual.call("set_bike_style", bike_id)


func apply_bike_profile(bike_id: int, stats: Dictionary) -> void:
	top_speed = float(stats["top_speed"])
	engine_accel = float(stats["engine_accel"])
	brake_accel = float(stats["brake_accel"])
	lean_grip = float(stats["lean_grip"])
	high_speed_lean_rate = float(stats["high_speed_lean_rate"])
	max_lat_speed = float(stats["max_lat_speed"])
	lean_in_rate_deg = float(stats["lean_in_rate_deg"])
	lean_out_rate_deg = float(stats["lean_out_rate_deg"])
	start_speed = float(stats["start_speed"])
	preview_bike(bike_id)


# ------------------------------------------------------------------- physics


func _physics_process(delta: float) -> void:
	_invuln = maxf(0.0, _invuln - delta)
	_shake = maxf(0.0, _shake - delta * 2.5)

	if Input.is_action_just_pressed("restart") and _game:
		_game.restart()
		_update_view(delta)
		_update_audio(delta)
		## `_update_view` writes the rig after the teleport. Reset again so
		## those local camera writes cannot interpolate from the bench pose.
		reset_physics_interpolation()
		return

	if Input.is_action_just_pressed("sit"):
		_toggle_seat()

	if alive and not seated:
		if Input.is_action_just_pressed("horn"):
			_sound_horn()
		_drive(delta)
		_steer(delta)
		var previous_z := track_z
		track_z = _path.advance(track_z, speed * delta)
		# `lateral` is measured from the main route, but a committed lead-off
		# centreline moves sideways as z advances. Carry the bike by that frame
		# motion so a neutral steering input holds its chosen line on the spur.
		var surface_lat_vel := _follow_committed_surface(previous_z, track_z, delta)
		# The surface under the rider, which on an overlook spur is climbing a
		# hillside rather than following the carriageway's own grade.
		_road_pitch = _path.surface_pitch_at(track_z, lateral)
		_heading = move_toward(
			_heading,
			clampf(atan2(lat_vel + surface_lat_vel, maxf(speed, 9.0)), -MAX_HEADING, MAX_HEADING),
			delta * 2.4
		)
	elif seated:
		speed = 0.0
		lat_vel = 0.0
		lean = 0.0
	elif not alive:
		# Stop dead where the impact happened — no coasting on through the car.
		lean = lerpf(lean, deg_to_rad(58.0) * _fall_dir, 1.0 - exp(-4.0 * delta))
	_place()

	if alive:
		_check_traffic()
	_update_view(delta)
	_update_audio(delta)


func _sound_horn() -> void:
	_horn.play()
	# Only the nearest aligned driver ahead treats the horn as a request to make
	# room. Broadcasting a lane-change command to a whole queue made traffic look
	# startled rather than human.
	var closest: Node3D
	var closest_gap := INF
	for car in get_tree().get_nodes_in_group("traffic"):
		var vehicle := car as Node3D
		if vehicle == null or not vehicle.has_method("can_hear_horn"):
			continue
		var gap: float = float(vehicle.track_z) - track_z
		if gap < closest_gap and bool(vehicle.call("can_hear_horn", track_z, lateral)):
			closest = vehicle
			closest_gap = gap
	if closest != null:
		closest.call("hear_horn", track_z, lateral)


func _drive(delta: float) -> void:
	var throttle := Input.get_action_strength("throttle")
	var brake := Input.get_action_strength("brake")

	var a := 0.0
	if throttle > 0.0:
		# Falls off toward top_speed instead of a hard clamp: the top end feels earned.
		a += engine_accel * throttle * maxf(1.0 - pow(speed / top_speed, 2.0), 0.0)
	else:
		a -= engine_brake
	a -= brake_accel * brake
	a -= roll_drag * speed
	a -= 9.81 * sin(_road_pitch) * 0.75  # hills cost and pay back

	# Keep the authored 55.5556 m/s (200 km/h) ceiling exact, including on a
	# downhill. The engine curve still makes the final kilometres per hour feel
	# earned instead of relying on a visible speed limiter.
	speed = clampf(speed + a * delta, 0.0, top_speed)


func _steer(delta: float) -> void:
	var steer := Input.get_axis("steer_left", "steer_right") * BODY_X_FROM_SCREEN
	var want_wheelie := Input.is_action_pressed("wheelie")
	var throttle := Input.get_action_strength("throttle")

	# A stationary bike cannot be leaned into a turn, and a bike on its back
	# wheel steers badly.
	var authority := clampf(speed / steer_authority_speed, 0.0, 1.0) * (1.0 - wheelie * 0.75)

	var target_lean := steer * deg_to_rad(max_lean_deg) * authority
	var rate := lean_in_rate_deg if absf(target_lean) > absf(lean) else lean_out_rate_deg
	rate *= lerpf(1.0, high_speed_lean_rate, smoothstep(20.0, 48.0, speed))
	lean = move_toward(lean, target_lean, deg_to_rad(rate) * delta)

	# Lean generates side force; the road's own curve throws you the other way.
	var a_lat := lean_grip * tan(lean)
	a_lat -= _path.curvature_at(track_z) * speed * speed * corner_load
	# A soft edge force gives the rider a readable warning. The rideable surface
	# is not one fixed strip — a spur road runs beside it at every overlook — so
	# query the authored bounds rather than a stored half-width.
	# Ask for the surface the rider is *on*. At an overlook the carriageway and
	# the spur are two separate ribbons, and this is what lets the bike steer off
	# onto the detour at the junction and then be held on it by the same edge
	# forces that hold it on the road.
	_update_road_choice()
	var bounds: Vector2 = _path.road_bounds_at(
		track_z, lateral, half_width + road_edge_margin, _committed_to_spur
	)
	var safe_left := bounds.x + half_width + road_edge_margin
	var safe_right := bounds.y - half_width - road_edge_margin
	var edge_t := 0.0
	if lateral < safe_left + edge_recovery_zone:
		edge_t = clampf((safe_left + edge_recovery_zone - lateral) / maxf(edge_recovery_zone, 0.01), 0.0, 1.0)
		a_lat += edge_recovery_force * edge_t * edge_t
	elif lateral > safe_right - edge_recovery_zone:
		edge_t = clampf((lateral - safe_right + edge_recovery_zone) / maxf(edge_recovery_zone, 0.01), 0.0, 1.0)
		a_lat -= edge_recovery_force * edge_t * edge_t
	lat_vel += a_lat * delta
	lat_vel *= exp(-grip_damp * delta)
	var lat_cap := lateral_speed_limit()
	lat_vel = clampf(lat_vel, -lat_cap, lat_cap)
	lateral += lat_vel * delta

	if lateral < safe_left or lateral > safe_right:
		# No off-road state: the road edge catches the tyres and bleeds speed.
		lateral = clampf(lateral, safe_left, safe_right)
		lat_vel = 0.0
		speed = maxf(speed - 20.0 * delta, 0.0)
		_shake = maxf(_shake, 0.35)

	var target_wheelie := 0.0
	if want_wheelie and speed >= wheelie_min_speed and throttle > 0.4:
		target_wheelie = clampf((speed - wheelie_min_speed) / 18.0, 0.35, 1.0)
	wheelie = lerpf(wheelie, target_wheelie, 1.0 - exp(-6.0 * delta))


func lateral_speed_limit() -> float:
	## A bike moves sideways by pointing slightly across the road, not by sliding,
	## so its sideways speed is its forward speed times the tangent of that angle.
	##
	## Under a flat cap a bike at walking pace could cross a lane faster than it
	## was travelling forward, which is where the skating came from — and it is
	## worst exactly where it is most visible, pulling away from a standstill on
	## an overlook platform. MAX_HEADING is the same angle the nose is allowed to
	## swing to, so the bike is never asked to travel further across than it is
	## pointing.
	return minf(max_lat_speed, maxf(speed, 2.5) * tan(MAX_HEADING))


func _place() -> void:
	# road_transform_at() is the map-owned safe surface query; its edge margin
	# keeps the entire hitbox on tarmac, including if another system writes a
	# lateral value between physics ticks.
	_update_road_choice()
	lateral = _path.clamp_road_lateral(
		lateral, half_width + road_edge_margin, track_z, _committed_to_spur
	)
	var placed: Transform3D = _path.road_transform_at(
		track_z, lateral, half_width + road_edge_margin, _committed_to_spur
	)
	# Point the bike where it is going. Rotating about the surface normal keeps
	# the wheels on the road on a banked corner or a climbing spur.
	placed.basis = placed.basis.rotated(placed.basis.y, _heading)
	global_transform = placed


func _update_road_choice() -> void:
	var spur: Vector2 = _path.spur_interval(track_z)
	if spur == Vector2.ZERO:
		_committed_to_spur = false
		return
	if _committed_to_spur:
		return
	var side: float = _path.viewpoint_side_for(_path.viewpoint_centre_for(track_z))
	if lateral * side > float(_path.HALF_WIDTH):
		_committed_to_spur = true


func _follow_committed_surface(from_z: float, to_z: float, delta: float) -> float:
	## Preserve the bike's offset from the scenic road centreline as that road
	## peels away from or rejoins the main route. `lat_vel` remains the rider's
	## steering velocity relative to the chosen surface; the returned velocity is
	## only used to point the bike along the direction the surface itself travels.
	if not _committed_to_spur:
		return 0.0
	var before: Vector2 = _path.spur_interval(from_z)
	var after: Vector2 = _path.spur_interval(to_z)
	if before == Vector2.ZERO or after == Vector2.ZERO:
		return 0.0
	var before_centre := (before.x + before.y) * 0.5
	var after_centre := (after.x + after.y) * 0.5
	var shift := after_centre - before_centre
	lateral += shift
	return shift / maxf(delta, 0.0001)


func can_sit(  ) -> bool:
	## Off the bike is only offered where there is something to sit on: stopped,
	## alive, and standing on an overlook platform.
	return alive and speed < PARKED_SPEED and bool(_path.at_platform(track_z, lateral))


func _toggle_seat() -> void:
	if seated:
		seated = false
		return
	if not can_sit():
		return
	seated = true
	speed = 0.0
	lat_vel = 0.0
	_seat_yaw = 0.0
	_seat_pitch = 0.0


# ------------------------------------------------------------------- traffic


func _check_traffic() -> void:
	if _invuln > 0.0:
		return
	var inv := global_transform.basis.inverse()
	for car in get_tree().get_nodes_in_group("traffic"):
		var other := car as Node3D
		if other == null:
			continue
		var local: Vector3 = inv * (other.global_position - global_position)
		if absf(local.y) > 3.0:
			continue
		var hw: float = (half_width + other.get_half_width()) * forgiveness
		var hl: float = (half_length + other.get_half_length()) * forgiveness
		if absf(local.x) <= hw and absf(local.z) <= hl:
			kill()
			return
		if absf(local.x) <= near_miss_width and absf(local.z) <= near_miss_length:
			other.register_near_miss()
			_shake = maxf(_shake, 0.12)


func get_half_length() -> float:
	## Traffic treats whatever it is following as a vehicle, and that includes the
	## player. Without this, every follow and gap check against the bike threw,
	## several times a frame.
	return half_length


func kill() -> void:
	if not alive:
		return
	alive = false
	speed = 0.0
	lat_vel = 0.0
	_shake = 1.0
	_fall_dir = signf(lean) if absf(lean) > 0.02 else 1.0
	crashed_into_traffic.emit()
	if _game:
		_game.crash()


func reset_run() -> void:
	## In-place reset avoids reloading the scene and regenerating audio/resources.
	track_z = 0.0
	speed = start_speed
	lateral = 0.0
	lat_vel = 0.0
	lean = 0.0
	wheelie = 0.0
	alive = true
	seated = false
	_seat_blend = 0.0
	_heading = 0.0
	_look_yaw = 0.0
	_seat_yaw = 0.0
	_seat_pitch = 0.0
	_committed_to_spur = false
	_invuln = invuln_time
	_shake = 0.0
	_road_pitch = _path.pitch_at(0.0)
	camera_pivot.position = _pivot_base
	camera_pivot.rotation = Vector3(0.0, PI, 0.0)
	camera.transform = Transform3D(_cam_basis, _cam_base)
	camera.make_current()
	visual.rotation = Vector3.ZERO
	_place()
	# The bike is kinematic; Godot still interpolates Node3D poses. A restart is
	# a teleport, and without this the rendered camera eases from the old pose —
	# the overlook bench, a crash, halfway down the route — to kilometre zero,
	# which is the flight across the lake.
	reset_physics_interpolation()


func set_night_lighting(darkness: float) -> void:
	## 0 at noon, 1 at the darkest hour. A fraction rather than a switch: the clock
	## is between two moods most of the time, and a beam that snaps on at a
	## threshold announces the threshold.
	if visual.has_method("set_night_lighting"):
		visual.call("set_night_lighting", darkness)


# --------------------------------------------------------------- presentation


func _update_view(delta: float) -> void:
	var frame_pitch := -wheelie * deg_to_rad(wheelie_pitch_deg)
	visual.rotation.z = -lean * VISUAL_LEAN  # +lean is toward body +X; +Z roll tilts up toward -X
	visual.rotation.x = frame_pitch

	var k := 1.0 - exp(-9.0 * delta)
	var cam_pitch := frame_pitch * 0.86 - _road_pitch * 0.2
	# Q/E is independent head movement: steer one way while looking the other.
	# Sixty-two degrees is a hard look at the verge that still keeps the road
	# stretching forward in the frame. Ninety turned the world into stacked
	# ribbons of tarmac, rail and sky.
	var look_input := Input.get_axis("look_left", "look_right")
	var target_look := look_input * LOOK_YAW if absf(look_input) > 0.01 else lean * 0.18
	_look_yaw = lerpf(_look_yaw, target_look, 1.0 - exp(-7.0 * delta))
	var look_amount: float = clampf(absf(_look_yaw) / LOOK_YAW, 0.0, 1.0)
	# Looking aside, the neck also lifts. The authored lens already pitches five
	# degrees down at the tank; held through a side glance that is a photograph
	# of the kerb. Pitch up and sit taller so the verge fills the frame.
	camera_pivot.rotation.x = lerpf(
		camera_pivot.rotation.x, cam_pitch - look_amount * deg_to_rad(9.0), k
	)
	# The rider's head is one rigid thing, so the roll of the view and the swing
	# of the eye come from the same angle. Rolling the horizon by 0.85 of the lean
	# while orbiting the eye by the whole of it is two different heads, and the
	# disagreement is felt as the world sliding under you in every corner.
	#
	# That angle is a good deal less than the bike's. A rider looks where they are
	# going and their neck does most of the work of keeping the horizon level: the
	# frame goes over 32 degrees, the eye about fourteen. Bolting the view to the
	# frame is technically what a helmet cam sees and is unwatchable for an hour,
	# which is the complaint this number answers.
	var head_lean := lean * (1.0 - HEAD_UPRIGHT)
	var frame_basis := Basis(Vector3.RIGHT, frame_pitch) * Basis(Vector3.BACK, -head_lean)
	camera_pivot.position = frame_basis * (_pivot_base + Vector3(0.0, look_amount * 0.28, 0.0))
	# Slower than the rest of the rig on purpose: the neck settles into a corner
	# rather than snapping to it, and it is the snap that reads as camera shake.
	camera_pivot.rotation.z = lerpf(camera_pivot.rotation.z, head_lean, 1.0 - exp(-6.0 * delta))
	camera_pivot.rotation.y = PI + _look_yaw

	# Speed still opens the lens, but less far than it did. Fourteen degrees of
	# swing stretches the edges of the frame exactly when the bike is moving
	# across it fastest, and the two motions compound.
	var v := speed / top_speed
	_ride_fov = lerpf(_ride_fov, 76.0 + v * 9.0, 1.0 - exp(-4.0 * delta))
	camera.fov = _ride_fov
	var scenic := seated or (_path != null and bool(_path.at_platform(track_z, lateral)))
	## Riding stays at the horizon clip so the spur does not draw three
	## kilometres of trees. The skyline sits inside that window; the bench
	## opens to 5200 m for the authored lake ranges.
	camera.far = 5200.0 if scenic else HorizonMountainsGD.CLIP_FAR

	_bob += delta * (6.0 + speed * 0.5)
	var jitter := Vector3.ZERO
	if _shake > 0.0:
		jitter = Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), 0.0) * _shake * 0.12
	camera.position = _cam_base + Vector3(0.0, sin(_bob) * 0.006 * (0.3 + v), 0.0) + jitter
	_update_seat(delta)


func _update_seat(delta: float) -> void:
	## Off the bike and on the bench. The camera leaves the rig entirely and
	## becomes a pair of eyes on the seat: A/D turn, W/S look up and down, and
	## nothing else in the world is touched — the bike stays parked exactly where
	## it was left.
	##
	## Both ends of the blend are absolute. It used to interpolate the camera's
	## *current* transform toward the bench every frame, which is a filter, not a
	## blend: the rig only ever wrote the camera's position, so its rotation had
	## nowhere to come back from. Standing up left the eye pointing at wherever
	## the blend had got to, permanently, and the ride continued sideways.
	_seat_blend = move_toward(_seat_blend, 1.0 if seated else 0.0, delta * 1.6)
	var ride := Transform3D(_cam_basis, camera.position)
	if _seat_blend <= 0.0:
		camera.transform = ride
		return
	if seated:
		_seat_yaw = clampf(_seat_yaw + Input.get_axis("steer_left", "steer_right") * delta * 1.5, -PI, PI)
		_seat_pitch = clampf(
			_seat_pitch + Input.get_axis("throttle", "brake") * delta * 0.9, deg_to_rad(-38.0), deg_to_rad(30.0)
		)
	var seat: Transform3D = _path.viewpoint_seat(track_z)
	var look := seat.basis * Basis(Vector3.UP, _seat_yaw) * Basis(Vector3.RIGHT, _seat_pitch)
	# Taken back into the camera's own parent so the whole blend is one local
	# transform. Written as a global transform it fought the rig, which sets the
	# camera's position from the lean every frame.
	var parent := camera.get_parent() as Node3D
	var target: Transform3D = parent.global_transform.affine_inverse() * Transform3D(look, seat.origin)
	# Ease between saddle and bench rather than cutting: standing up off a bike
	# is a movement, and the cut version reads as a camera bug.
	var eased: float = smoothstep(0.0, 1.0, _seat_blend)
	camera.transform = ride.interpolate_with(target, eased)
	# Tighter than the ride, not wider.
	#
	# 78° vertical on a 16:9 frame is 110° across — a lens nobody would put on a
	# landscape, and the reason a range of mountains two kilometres out read as a
	# low bump on a very wide horizon. Sitting down is the one moment the game
	# asks the player to *look* at something rather than to watch the road and the
	# verges at once, so the frame should close in and the peaks should get big.
	camera.fov = lerpf(_ride_fov, 62.0, eased)
	# The authored range sits two to three kilometres out. The ride clips at
	# 2.2 km; sitting down has to see the far peaks or the detour is a pond.


func _update_audio(delta: float) -> void:
	# Six fake gears: pitch climbs through each and drops on the shift.
	var span := top_speed / 6.0
	var frac := fposmod(speed, span) / span
	var target := 0.55 + frac * 1.25 + minf(speed / top_speed, 1.0) * 0.25
	if speed < 4.0:
		target = 0.5
	_engine.pitch_scale = lerpf(_engine.pitch_scale, target, 1.0 - exp(-14.0 * delta))
	var load := Input.get_action_strength("throttle") if alive else 0.0
	_engine.volume_db = lerpf(_engine.volume_db, -19.0 + load * 8.0 + minf(speed / top_speed, 1.0) * 6.0, 1.0 - exp(-6.0 * delta))
