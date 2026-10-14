extends SceneTree
## A flat, wide test ribbon removes scenery, banking and edge assistance from
## the comparison. Radius is measured after roll-in, before the playable
## heading cap; a held bar cannot describe a circle on an endless road strip.
## Uses the actual input actions and stock Mesa profile, independent of saves.
## --check adds grip, gearbox, recovery and camera-hitch regression checks.
## --hz=30|60|120 compares frame-rate behaviour; --bike-script=<path> measures
## a saved baseline script with exactly the same inputs and road seed.

var _step: float = 1.0 / 60.0
var _hz: int = 60
var _failures: int = 0
var _check: bool = false
var _script_path: String = "res://scripts/motorcycle.gd"
var _turns: Array[Dictionary] = []
var _ran: bool = false
var _bike: Node3D
var _flat: Node
var _weather: Node


class Weather:
	extends Node
	var rain: float = 0.0


class FlatRibbon:
	extends Node
	func curvature_at(_z: float) -> float:
		return 0.0
	func pitch_at(_z: float) -> float:
		return 0.0
	func spur_interval(_z: float) -> Vector2:
		return Vector2.ZERO
	func road_bounds_at(_z: float, _x: float, _margin: float, _spur: bool) -> Vector2:
		return Vector2(-1000.0, 1000.0)


func _process(_delta: float) -> bool:
	if _ran:
		return false
	_ran = true
	var road: Node = root.get_node("RoadPath")
	road.call("set_world_seed", 2)
	var best_z: float = 0.0
	var bend: float = 0.0
	for z in range(300, 2400, 25):
		var curvature: float = absf(float(road.call("curvature_at", float(z))))
		if curvature > bend:
			bend = curvature
			best_z = float(z)
	print("curve: seed=2 z=%.0f curvature=%.5f/m" % [best_z, bend])
	_check = "--check" in OS.get_cmdline_user_args()
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--hz="):
			_hz = maxi(20, int(arg.trim_prefix("--hz=")))
		elif arg.begins_with("--bike-script="):
			_script_path = arg.trim_prefix("--bike-script=")
	_step = 1.0 / float(_hz)
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
	_flat = FlatRibbon.new()
	root.add_child(_flat)
	_weather = Weather.new()
	root.add_child(_weather)
	for v: float in [4.0, 12.0, 25.0, 40.0]:
		_turn(v, 0.35)
	_launch()
	_stop()
	_slalom()
	if _check:
		_assert(float(_turns[0]["lean"]) < 4.0, "parking turns with little lean")
		_assert(float(_turns[1]["lean"]) < float(_turns[2]["lean"]), "speed asks for more lean")
		_assert(float(_turns[2]["lean"]) < float(_turns[3]["lean"]), "high-speed lean follows turn radius")
		for turn: Dictionary in _turns:
			_assert(float(turn["t90"]) <= 0.32, "quick roll-in at %s m/s" % turn["speed"])
			_assert(absf(float(turn["residual"])) < 0.10, "release catches the lateral motion")
		_assert(absf(float(_turns[2]["radius"]) / float(_turns[3]["radius"]) - 1.0) < 0.15, "same partial bar input holds a similar radius at 90/144 km/h")
		_grip_and_gears()
		print("bike physics self-check @%d Hz: %d failures" % [_hz, _failures])
	_bike.free()
	_flat.free()
	_weather.free()
	quit(1 if _failures > 0 else 0)
	return true


func _reset(v: float) -> void:
	for action: String in ["throttle", "brake", "steer_left", "steer_right"]:
		Input.action_release(action)
	_bike.set("_path", root.get_node("RoadPath"))
	_bike.call("reset_run")
	var catalog: GDScript = load("res://scripts/bike_catalog.gd")
	_bike.call("apply_bike_profile", 0, catalog.stats(0, {}))
	_bike.set("_path", _flat)
	_bike.set("speed", v)
	_bike.set("_road_pitch", 0.0)
	_bike.set("_long_accel", 0.0)
	if _check:
		_weather.set("rain", 0.0)
		_bike.set("_weather", _weather)


func _turn(v: float, input: float) -> void:
	_reset(v)
	Input.action_press("steer_left", input)
	var heading_before: float = 0.0
	var heading_after: float = 0.0
	var steady_before: float = 0.0
	var steady_after: float = 0.0
	var t90: float = -1.0
	var trace: Array[float] = []
	for tick in int(1.5 * _hz):
		_bike.call("_steer", _step)
		trace.append(absf(float(_bike.get("lean"))))
		if tick == int(0.5 * _hz) - 1:
			heading_before = atan2(float(_bike.get("lat_vel")), v)
		if tick == int(0.7 * _hz) - 1:
			heading_after = atan2(float(_bike.get("lat_vel")), v)
		if tick == int(1.1 * _hz) - 1:
			steady_before = atan2(float(_bike.get("lat_vel")), v)
		if tick == int(1.3 * _hz) - 1:
			steady_after = atan2(float(_bike.get("lat_vel")), v)
	var settled: float = trace.back()
	for tick in trace.size():
		if trace[tick] >= settled * 0.9:
			t90 = (tick + 1) * _step
			break
	var yaw_rate: float = (heading_after - heading_before) / (float(int(0.7 * _hz) - int(0.5 * _hz)) * _step)
	var radius: float = v / maxf(absf(yaw_rate), 0.000001)
	var steady_rate: float = (steady_after - steady_before) / (float(int(1.3 * _hz) - int(1.1 * _hz)) * _step)
	var steady_radius: float = v / maxf(absf(steady_rate), 0.000001)
	Input.action_release("steer_left")
	var recovery: float = -1.0
	for tick in 2 * _hz:
		_bike.call("_steer", _step)
		if recovery < 0.0 and absf(float(_bike.get("lean"))) < deg_to_rad(1.0):
			recovery = (tick + 1) * _step
	_turns.append({"speed": v, "lean": rad_to_deg(settled), "radius": steady_radius, "t90": t90, "residual": float(_bike.get("lat_vel"))})
	print("turn: v=%.0f input=%.2f lean=%.2fdeg t90=%.0fms rollin_radius=%.1fm steady_radius=%.1fm upright=%.0fms residual=%.3fm/s" % [v, input, rad_to_deg(settled), t90 * 1000.0, radius, steady_radius, recovery * 1000.0, float(_bike.get("lat_vel"))])


func _launch() -> void:
	_reset(0.0)
	Input.action_press("throttle")
	var elapsed: float = 0.0
	while float(_bike.get("speed")) < 100.0 / 3.6 and elapsed < 20.0:
		_bike.call("_drive", _step)
		elapsed += _step
	print("launch: 0-100=%.3fs" % elapsed)
	_assert(elapsed > 3.0 and elapsed < 4.5, "the stock 400 has a lively, believable launch")


func _stop() -> void:
	_reset(100.0 / 3.6)
	Input.action_press("brake")
	var distance: float = 0.0
	var elapsed: float = 0.0
	while float(_bike.get("speed")) > 0.01 and elapsed < 20.0:
		var previous: float = float(_bike.get("speed"))
		_bike.call("_drive", _step)
		distance += (previous + float(_bike.get("speed"))) * 0.5 * _step
		elapsed += _step
	print("stop: 100-0=%.2fm time=%.3fs" % [distance, elapsed])
	_assert(distance > 30.0 and distance < 42.0, "dry emergency stop spends a tyre-scale grip budget")


func _slalom() -> void:
	_reset(25.0)
	var peak: float = 0.0
	var max_roll: float = 0.0
	for tick in 8 * _hz:
		Input.action_release("steer_left")
		Input.action_release("steer_right")
		if tick < 6 * _hz:
			Input.action_press("steer_left" if (tick / int(0.75 * _hz)) % 2 == 0 else "steer_right", 0.35)
		_bike.call("_steer", _step)
		peak = maxf(peak, absf(float(_bike.get("lateral"))))
		max_roll = maxf(max_roll, absf(float(_bike.get("lean"))))
	print("slalom: 8 half-turns peak_offset=%.2fm peak_lean=%.2fdeg residual=%.3fm/s" % [peak, rad_to_deg(max_roll), float(_bike.get("lat_vel"))])


func _assert(ok: bool, message: String) -> void:
	if _check and not ok:
		_failures += 1
		print("FAIL: ", message)


func _grip_and_gears() -> void:
	_reset(40.0)
	Input.action_press("steer_left", 0.7)
	for _tick in _hz:
		_bike.call("_steer", _step)
	var dry_rate: float = absf(float(_bike.get("turn_rate")))
	var dry_lean: float = absf(float(_bike.get("lean")))
	# Keep the same roll and speed while the fork is loaded, so this measures
	# line widening rather than the smaller radius caused by slowing down.
	Input.action_press("brake", 0.25)
	for _tick in _hz:
		_bike.set("speed", 40.0)
		_bike.call("_drive", _step)
		_bike.set("speed", 40.0)
		_bike.call("_steer", _step)
	var brake_rate: float = absf(float(_bike.get("turn_rate")))
	_assert(absf(float(_bike.get("lean"))) < dry_lean, "front brake tends to stand the frame up")
	_assert(brake_rate < dry_rate, "braking while leaned opens the line")
	_weather.set("rain", 1.0)
	for _tick in _hz:
		_bike.set("speed", 40.0)
		_bike.call("_drive", _step)
		_bike.set("speed", 40.0)
		_bike.call("_steer", _step)
	var wet_rate: float = absf(float(_bike.get("turn_rate")))
	_assert(wet_rate < brake_rate, "rain reduces corner grip under braking")
	print("grip: dry=%.3frad/s braking=%.3frad/s wet_braking=%.3frad/s" % [dry_rate, brake_rate, wet_rate])
	_reset(20.0)
	Input.action_press("throttle")
	Input.action_press("brake")
	_bike.call("_drive", _step)
	_assert(float(_bike.get("speed")) < 20.0, "brake wins over a held touch throttle")
	_reset(0.0)
	Input.action_press("throttle")
	var changes: int = 0
	var previous: int = 1
	for _tick in 8 * _hz:
		_bike.call("_drive", _step)
		var current: int = int(_bike.get("gear"))
		if current != previous:
			changes += 1
			_assert(float(_bike.get("_shift_timer")) > 0.0, "upshift cuts torque for a beat")
			_assert(float(_bike.get("engine_rpm")) < 0.5, "upshift drops the shared crank speed")
		previous = current
	_assert(changes >= 3, "acceleration moves through the automatic gears")
	var gear_now: int = int(_bike.get("gear"))
	var span: float = float(_bike.get("top_speed")) / float(_bike.get("_gears"))
	for tick in 30:
		_bike.set("speed", span * float(gear_now - 1) + (0.05 if tick % 2 == 0 else -0.05))
		_bike.call("_update_gearbox", _step)
	_assert(int(_bike.get("gear")) == gear_now, "gear hysteresis avoids shift chatter at a threshold")
	_reset(35.0)
	Input.action_press("steer_left")
	_bike.set("_long_accel", -10.0)
	for tick in 120:
		var delta: float = 0.25 if tick % 15 == 0 else _step
		_bike.call("_steer", delta)
		_bike.call("_update_view", delta)
		_assert(absf(float(_bike.get("_transfer"))) < deg_to_rad(6.0), "a 250ms hitch cannot fling the fork")
		_assert(absf(float(_bike.get("_head_roll"))) < deg_to_rad(17.0), "head stays more upright than the frame through a hitch")
	_bike.set("_steer_input", 1.0)
	_bike.set("_path", root.get_node("RoadPath"))
	_bike.call("reset_run")
	_assert(is_zero_approx(float(_bike.get("_steer_input"))) and int(_bike.get("gear")) == 1, "restart clears steering and drivetrain memory")
