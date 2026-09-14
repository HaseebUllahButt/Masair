extends SceneTree
## Probe: remote riders are real obstacles. Boot the scene, ride, drop a
## RemoteRider onto the player's lane -> the local rider must crash. Then a
## second pass places one just inside the near-miss band -> near_miss counts.

const RemoteRiderGD := preload("res://scripts/remote_rider.gd")

var _t := 0.0
var _scene: Node
var _phase := 0
var _rider: Node3D
var _fail := false


func _initialize() -> void:
	_scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(_scene)


func _process(delta: float) -> bool:
	_t += delta
	var game: Node = root.get_node("GameManager")
	var player: Node3D = _scene.get_node("Player")
	match _phase:
		0 when _t > 1.0:
			_scene.get_node("HUD").call("_start_ride")
			Input.action_press("throttle")
			_phase = 1
		1 when _t > 3.0:
			# friend parked dead ahead on our lane — should kill us on contact
			_rider = RemoteRiderGD.new()
			_rider.setup("friend", 0)
			_scene.add_child(_rider)
			_rider.apply_pose([player.track_z + 2.0, player.lateral, 0, 0, 0, 0, 1, 0])
			_phase = 2
		2 when _t > 4.5:
			if not game.is_crashed:
				printerr("PROBE FAIL: remote rider overlap did not crash the player")
				_fail = true
			game.restart()
			Input.action_press("throttle")
			_phase = 3
		3 when _t > 6.5:
			# second run: friend sits inside the near-miss band, off the kill box
			_rider = RemoteRiderGD.new()
			_rider.setup("friend2", 0)
			_scene.add_child(_rider)
			_rider.apply_pose([player.track_z + 2.5, player.lateral + 1.6, 0, 0, 0, 0, 1, 0])
			_phase = 4
		4 when _t > 8.0:
			print(
				"PROBE crash=%s near_miss=%d -> %s" % [
					game.is_crashed, game.near_miss_count,
					"PASS" if not _fail and game.near_miss_count > 0 else "CHECK"]
			)
			quit(1 if _fail else 0)
			return true
	if _t > 25.0:
		printerr("PROBE timeout")
		quit(2)
		return true
	return false
