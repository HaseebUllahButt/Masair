extends SceneTree
## What one physics tick costs while riding with traffic, split between the
## bike and the cars — the tick runs twice after any slow frame, so its cost
## doubles exactly when the frame can least afford it.

var _main: Node
var _player: Node3D
var _manager: Node


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)
	current_scene = _main
	await process_frame
	root.find_child("HUD", true, false).call("_start_ride")
	_main.call("begin_ride", 2, 1)
	root.get_node("RoadPath").call("set_world_seed", 1)
	_player = root.find_child("Player", true, false)
	_player.set("_invuln", 9999.0)
	root.find_child("RoadStreamer", true, false).call("reset_world")
	_manager = root.find_child("TrafficManager", true, false)
	_manager.call("reset_world")
	Input.action_press("throttle")
	for i in 900:
		_player.set("_invuln", 9999.0)
		await physics_frame
	var cars: Array = _manager.get("_cars")
	var car_us := 0
	var bike_us := 0
	var ticks := 120
	var dt := 1.0 / float(Engine.physics_ticks_per_second)
	for c: Node in cars:
		c.set_physics_process(false)
	_player.set_physics_process(false)
	for t in ticks:
		var a := Time.get_ticks_usec()
		_player.call("_physics_process", dt)
		var b := Time.get_ticks_usec()
		for c: Node in cars:
			if is_instance_valid(c):
				c.call("_physics_process", dt)
		var e := Time.get_ticks_usec()
		bike_us += b - a
		car_us += e - b
		await process_frame
	print("physics tick: bike %.2f ms, %d cars %.2f ms (%.3f ms/car)" % [
		bike_us / 1000.0 / ticks, cars.size(), car_us / 1000.0 / ticks, car_us / 1000.0 / ticks / maxf(cars.size(), 1)])
	quit()
