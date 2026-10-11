extends SceneTree
## Steering-feel probe: rides scripted inputs at fixed speeds and reports the
## lean response as numbers — peak/settled lean, time-to-lean, the lateral
## dip a counter-steer kick produces, and how fast the bike stands back up.
## Run it before and after a handling change and the diff is the review.
##
##   godot --headless --path . --audio-driver Dummy --script res://tools/probe_steer.gd
##
## track_z and lateral are pinned while measuring so road curvature and edge
## recovery stay a constant bias between runs; lat_vel itself is left free —
## that velocity is what the steering model produces.

const HOLD_SPEEDS: Array[float] = [12.0, 25.0, 35.0, 50.0]
const SETTLE_S := 0.7
const PRESS_S := 1.4
const RELEASE_S := 1.6
const TRACE_EVERY := 3 ## ticks (~20 Hz)

var _runner: Node


func _initialize() -> void:
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	var runner := Runner.new()
	runner.tree_ref = self
	root.add_child(runner)


class Runner:
	extends Node

	var tree_ref: SceneTree
	var _player: Node3D
	var _tick := 0
	var _phase := 0
	var _phase_t := 0.0
	var _trace_tick := 0
	# Per-phase measurements.
	var _peak_lean := 0.0
	var _ss_samples: Array[float] = []
	var _dip_lv := 0.0
	var _peak_head := 0.0
	var _lean_at_press := 0.0
	var _lean_trace: Array[Vector2] = []
	var _t90 := -1.0
	var _settle := -1.0
	var _settle_clock := 0.0

	const PHASES := ["hold12", "hold25", "hold35", "hold50", "flick30"]

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		var hud := get_tree().root.find_child("HUD", true, false)
		if hud and hud.has_method("_start_ride"):
			hud.call("_start_ride")
		var traffic := get_tree().root.find_child("TrafficManager", true, false)
		if traffic:
			traffic.set("max_active", 0)
			traffic.call("reset_world")
		_player = get_tree().root.find_child("Player", true, false)
		_player.set("_invuln", 1e9)
		set_physics_process(true)

	func _speed_for(phase: int) -> float:
		if phase < HOLD_SPEEDS.size():
			return HOLD_SPEEDS[phase]
		return 30.0 ## flick30

	func _press_for(phase: int) -> float:
		return 0.28 if phase == PHASES.size() - 1 else PRESS_S

	func _physics_process(delta: float) -> void:
		_tick += 1
		_phase_t += delta
		var v := _speed_for(_phase)
		_player.set("speed", v)
		# Constant road load and no edge interference: pinned lateral keeps the
		# recovery force silent, pinned z keeps curvature identical across runs.
		_player.set("track_z", 500.0)
		_player.set("lateral", 0.0)

		var pressing := _phase_t > SETTLE_S and _phase_t <= SETTLE_S + _press_for(_phase)
		var released := _phase_t > SETTLE_S + _press_for(_phase)
		if pressing:
			if Input.get_action_strength("steer_right") < 0.5:
				Input.action_press("steer_right")
				_lean_at_press = float(_player.get("lean"))
				_peak_lean = 0.0
				_dip_lv = 0.0
				_t90 = -1.0
		else:
			Input.action_release("steer_right")

		var lean_deg := rad_to_deg(float(_player.get("lean")))
		var lv := float(_player.get("lat_vel"))
		var head_deg := rad_to_deg(float(_player.get("_heading")))
		_lean_trace.append(Vector2(_phase_t, lean_deg))
		_peak_lean = maxf(_peak_lean, absf(lean_deg))
		_peak_head = maxf(_peak_head, absf(head_deg))
		var press_t := _phase_t - SETTLE_S
		if pressing:
			# The counter-steer dip: the biggest *positive* sideways velocity in
			# the first beat of a right press, before the lean force takes over.
			if press_t < 0.30:
				_dip_lv = maxf(_dip_lv, lv)
			if press_t > _press_for(_phase) - 0.4:
				_ss_samples.append(lv)
		elif released and _settle < 0.0:
			_settle_clock += delta
			if absf(lean_deg) < 3.0:
				_settle = _settle_clock

		var counter_raw: Variant = _player.get("counter_steer")
		var counter: float = counter_raw if counter_raw is float else 0.0
		if _trace_tick <= 0 and _phase in [1, 4]:
			print(
				"trace %s t=%.2f lean=%.1f lv=%.2f head=%.1f ctr=%.2f"
				% [PHASES[_phase], _phase_t, lean_deg, lv, head_deg, counter]
			)
			_trace_tick = TRACE_EVERY
		_trace_tick -= 1

		if _phase_t > SETTLE_S + _press_for(_phase) + RELEASE_S:
			var ss := 0.0
			for s in _ss_samples:
				ss += s
			if not _ss_samples.is_empty():
				ss /= _ss_samples.size()
			# t90 against the settled lean of this phase, not a fixed angle.
			var lean_final := 0.0
			var n := 0
			for s in _lean_trace:
				if s.x > SETTLE_S + _press_for(_phase) - 0.3 and s.x <= SETTLE_S + _press_for(_phase):
					lean_final += s.y
					n += 1
			if n > 0:
				lean_final /= n
			for s in _lean_trace:
				if s.x > SETTLE_S and _t90 < 0.0 and absf(s.y - _lean_at_press) > 0.9 * absf(lean_final - _lean_at_press):
					_t90 = s.x - SETTLE_S
			print(
				(
					"hold v=%.0f | peak_lean=%.1fdeg t90=%dms ss_lv=%.2f dip_lv=%.2f settle=%dms peak_head=%.1fdeg"
					% [v, _peak_lean, int(_t90 * 1000.0), ss, _dip_lv, int(_settle * 1000.0), _peak_head]
				)
			)
			_phase += 1
			_phase_t = 0.0
			_ss_samples.clear()
			_lean_trace.clear()
			_dip_lv = 0.0
			_peak_lean = 0.0
			_peak_head = 0.0
			_t90 = -1.0
			_settle = -1.0
			_settle_clock = 0.0
			Input.action_release("steer_right")
			if _phase >= PHASES.size():
				print("PROBE DONE")
				tree_ref.quit(0)
