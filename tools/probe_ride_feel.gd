extends SceneTree
## Rides the real road with a keyboard-like rider and reports how the steering
## feels in numbers: how long a lane change takes, how far it overshoots, how
## much a short tap moves the bike, and how much work it is to hold a lane
## through the twistiest stretch of a seed.
##
## The rider is digital, like a keyboard: a key is either down or up. It looks
## a little ahead and reacts a little late, the way a person does, so a bike
## that is too twitchy shows up as overshoot and key chatter, and a bike that
## is too lazy shows up as slow lane changes and a wide line.
##
##   godot --headless --path . --audio-driver Dummy --script res://tools/probe_ride_feel.gd -- [--seed=2] [--bike-script=res://...]

const REACTION := 0.12   ## s between seeing the bike move and the finger moving
const LOOKAHEAD := 0.30  ## s the rider anticipates the drift
const PRESS_AT := 0.30   ## m of predicted error before a key goes down
const RELEASE_AT := 0.10 ## m of predicted error where it comes back up

var _step: float = 1.0 / 60.0
var _bike: Node3D
var _road: Node
var _seed: int = 2
var _script_path: String = "res://scripts/motorcycle.gd"
var _ran: bool = false
var _history: Array[Vector2] = []
var _key: int = 0
var _presses: int = 0


func _process(_delta: float) -> bool:
	if _ran:
		return false
	_ran = true
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--seed="):
			_seed = int(arg.trim_prefix("--seed="))
		elif arg.begins_with("--bike-script="):
			_script_path = arg.trim_prefix("--bike-script=")
	_road = root.get_node("RoadPath")
	_road.call("set_world_seed", _seed)
	_bike = load(_script_path).new()
	var visual := Node3D.new()
	visual.name = "Visual"
	_bike.add_child(visual)
	var pivot := Node3D.new()
	pivot.name = "CameraPivot"
	_bike.add_child(pivot)
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	pivot.add_child(camera)
	root.add_child(_bike)
	_bike.set_physics_process(false)
	var lane_w: float = float(_road.get("HALF_WIDTH")) * 2.0 / 3.0
	var twisty := _twistiest(400.0, 2600.0, 600.0)
	print("feel: %s seed=%d lane=%.2fm twisty z=%.0f peak_curv=%.4f/m (R=%.0fm)" % [
		_script_path.get_file(), _seed, lane_w, twisty.x, twisty.y, 1.0 / maxf(twisty.y, 0.00001),
	])
	for kmh: float in [40.0, 70.0, 100.0, 140.0]:
		var v := kmh / 3.6
		var tap := _tap(v, 0.15)
		var tap3 := _tap(v, 0.30)
		var lc := _lane_change(v, 300.0, lane_w)
		var flick := _flick(v, 300.0, lane_w)
		var hold := _hold(v, twisty.x - 300.0, 900.0, lane_w)
		print(
			"  %3.0f km/h | tap150=%.2fm tap300=%.2fm | lane %.2fs over=%.2fm keys=%d | flick %.2fs over=%.2fm | hold rms=%.2fm max=%.2fm keys/s=%.2f peak_lean=%.0fdeg"
			% [kmh, tap.x, tap3.x, lc.x, lc.y, int(lc.z), flick.x, flick.y,
				hold.x, hold.y, hold.z, _peak_lean]
		)
	_bike.free()
	quit(0)
	return true


var _peak_lean: float = 0.0


func _twistiest(from_z: float, to_z: float, window: float) -> Vector2:
	var best_z := from_z
	var best := -1.0
	var peak := 0.0
	var z := from_z
	while z < to_z:
		var sum := 0.0
		var local_peak := 0.0
		var s := 0.0
		while s < window:
			var c := absf(float(_road.call("curvature_at", z + s)))
			sum += c
			local_peak = maxf(local_peak, c)
			s += 10.0
		if sum > best:
			best = sum
			best_z = z
			peak = local_peak
		z += 50.0
	return Vector2(best_z, peak)


func _reset(v: float, z: float, lateral: float) -> void:
	_release()
	_bike.call("reset_run")
	var catalog: GDScript = load("res://scripts/bike_catalog.gd")
	_bike.call("apply_bike_profile", 0, catalog.stats(0, {}))
	_bike.set("track_z", z)
	_bike.set("lateral", lateral)
	_bike.set("speed", v)
	_bike.set("_long_accel", 0.0)
	_history.clear()
	_key = 0
	_presses = 0
	_peak_lean = 0.0


func _release() -> void:
	Input.action_release("steer_left")
	Input.action_release("steer_right")


func _tick(v: float) -> void:
	_bike.set("speed", v)
	_bike.call("_steer", _step)
	_bike.set("track_z", float(_road.call("advance", float(_bike.get("track_z")), v * _step)))
	_peak_lean = maxf(_peak_lean, rad_to_deg(absf(float(_bike.get("lean")))))
	_history.append(Vector2(float(_bike.get("lateral")), float(_bike.get("lat_vel"))))


func _drive_to(target: float) -> void:
	## The keyboard rider: acts on what it saw REACTION ago, projected forward.
	var lag := int(REACTION / _step)
	var seen := _history[maxi(0, _history.size() - 1 - lag)] if not _history.is_empty() else \
		Vector2(float(_bike.get("lateral")), 0.0)
	var predicted := seen.x + seen.y * (REACTION + LOOKAHEAD)
	var err := target - predicted
	var want := _key
	if _key == 0 and absf(err) > PRESS_AT:
		want = 1 if err > 0.0 else -1
	elif _key != 0 and (err * float(_key) < RELEASE_AT):
		want = 0
	if want != _key:
		_release()
		if want != 0:
			_presses += 1
			# Body +X (positive lateral) is steer_left; see BODY_X_FROM_SCREEN.
			Input.action_press("steer_left" if want > 0 else "steer_right")
		_key = want


func _tap(v: float, hold: float) -> Vector2:
	## Lateral offset left by one short key tap, measured once it has settled.
	_reset(v, 300.0, 0.0)
	_bike.set("_path", _straight())
	Input.action_press("steer_left")
	for i in int(2.5 / _step):
		if i == int(hold / _step):
			_release()
		_tick(v)
	_bike.set("_path", _road)
	return Vector2(absf(float(_bike.get("lateral"))), 0.0)


func _lane_change(v: float, z: float, lane_w: float) -> Vector3:
	## One lane across on a straight: time until it is within 0.35 m and stays
	## there for half a second, and how far past the lane it swung.
	_reset(v, z, 0.0)
	_bike.set("_path", _straight())
	var done := -1.0
	var inside := 0.0
	var over := 0.0
	for i in int(5.0 / _step):
		_drive_to(lane_w)
		_tick(v)
		var lat := float(_bike.get("lateral"))
		over = maxf(over, lat - lane_w)
		if absf(lat - lane_w) < 0.35:
			inside += _step
			if inside >= 0.5 and done < 0.0:
				done = (i + 1) * _step - inside
		else:
			inside = 0.0
	_release()
	_bike.set("_path", _road)
	return Vector3(done, over, _presses)


func _flick(v: float, z: float, lane_w: float) -> Vector2:
	## Two lanes across, the quick swerve round a car: right lane to left lane.
	_reset(v, z, -lane_w)
	_bike.set("_path", _straight())
	var done := -1.0
	var inside := 0.0
	var over := 0.0
	for i in int(6.0 / _step):
		_drive_to(lane_w)
		_tick(v)
		var lat := float(_bike.get("lateral"))
		over = maxf(over, lat - lane_w)
		if absf(lat - lane_w) < 0.35:
			inside += _step
			if inside >= 0.5 and done < 0.0:
				done = (i + 1) * _step - inside
		else:
			inside = 0.0
	_release()
	_bike.set("_path", _road)
	return Vector2(done, over)


func _hold(v: float, z: float, distance: float, lane_w: float) -> Vector4:
	## Hold the outer lane through the twistiest stretch. Lane changes every
	## few seconds so the stretch also shows a change made mid-corner.
	_reset(v, z, lane_w)
	var sq := 0.0
	var worst := 0.0
	var n := 0
	var t := 0.0
	var travelled := 0.0
	while travelled < distance:
		var target := lane_w if int(t / 4.0) % 2 == 0 else 0.0
		_drive_to(target)
		_tick(v)
		t += _step
		travelled += v * _step
		# Only score the settled part of each four-second leg.
		if fmod(t, 4.0) > 2.0:
			var err := absf(float(_bike.get("lateral")) - target)
			sq += err * err
			worst = maxf(worst, err)
			n += 1
	_release()
	return Vector4(sqrt(sq / maxf(n, 1)), worst, float(_presses) / maxf(t, 0.01), 0.0)


var _flat: Node


func _straight() -> Node:
	if _flat == null:
		_flat = FlatRoad.new()
		root.add_child(_flat)
	return _flat


class FlatRoad:
	extends Node
	func curvature_at(_z: float) -> float:
		return 0.0
	func pitch_at(_z: float) -> float:
		return 0.0
	func spur_interval(_z: float) -> Vector2:
		return Vector2.ZERO
	func road_bounds_at(_z: float, _x: float = 0.0, _margin: float = 0.0, _spur: bool = false) -> Vector2:
		return Vector2(-8.0, 8.0)
	func advance(z: float, metres: float) -> float:
		return z + metres
