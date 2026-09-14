extends SceneTree
## Probe: is the distance counter wired? Boots the real scene, starts a ride,
## holds throttle, prints GameManager.distance_m vs DistanceLabel text.

var _t := 0.0
var _scene: Node
var _phase := 0


func _initialize() -> void:
	_scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(_scene)


func _process(_delta: float) -> bool:
	_t += _delta
	if _phase == 0 and _t > 1.0:
		_scene.get_node("HUD").call("_start_ride")
		Input.action_press("throttle")
		_phase = 1
	elif _phase == 1 and _t > 4.5:
		var game: Node = root.get_node("GameManager")
		var player: Node = _scene.get_node("Player")
		var label: Label = _scene.get_node("HUD/Root/DistanceLabel")
		print(
			"PROBE dist_m=%.1f track_z=%.1f label='%s' root_visible=%s paused=%s" % [
				game.distance_m, player.track_z, label.text,
				_scene.get_node("HUD/Root").visible, paused]
		)
		game.crash()
		_phase = 2
	elif _phase == 2 and _t > 6.0:
		var game: Node = root.get_node("GameManager")
		game.restart()
		_phase = 3
	elif _phase == 3 and _t > 9.5:
		var game: Node = root.get_node("GameManager")
		var label: Label = _scene.get_node("HUD/Root/DistanceLabel")
		var ok: bool = game.distance_m > 10.0 and label.text == "%d m" % int(game.distance_m)
		print("PROBE after restart: dist_m=%.1f label='%s' -> %s" % [
			game.distance_m, label.text, "OK" if ok else "STUCK"])
		quit(0 if ok else 1)
		return true
	if _t > 20.0:
		printerr("PROBE timeout")
		quit(2)
		return true
	return false
