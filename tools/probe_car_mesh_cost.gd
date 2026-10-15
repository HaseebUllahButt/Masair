extends SceneTree
## How long the first car of each kind/colour costs to build — the traffic
## spawn hitch — split into the GDScript geometry pass and the spawn itself.
## Run it under gamescope too: the renderer's own share only shows on a GPU.

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var car_gd: GDScript = load("res://scripts/traffic_car.gd")
	for kind: int in 7:
		var began := Time.get_ticks_usec()
		car_gd.call("_mesh_for", kind, 3)
		var first := Time.get_ticks_usec() - began
		began = Time.get_ticks_usec()
		car_gd.call("_mesh_for", kind, 4)
		var second := Time.get_ticks_usec() - began
		began = Time.get_ticks_usec()
		car_gd.call("_brake_mesh", kind)
		car_gd.call("_blinker_mesh", kind, -1.0)
		car_gd.call("_blinker_mesh", kind, 1.0)
		var lamps := Time.get_ticks_usec() - began
		print("kind %d: body %.1f ms, second colour %.1f ms, lamps %.1f ms" % [kind, first / 1000.0, second / 1000.0, lamps / 1000.0])
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	for i in 30:
		await process_frame
	var manager: Node = root.find_child("TrafficManager", true, false)
	for kind: int in 7:
		for colour: int in [3, 9]:
			var began := Time.get_ticks_usec()
			var car: Node3D = car_gd.new()
			manager.add_child(car)
			var added := Time.get_ticks_usec() - began
			car.call("setup", kind, 0, 400.0 + kind * 30.0, 25.0, colour)
			var setup := Time.get_ticks_usec() - began
			await process_frame
			var drawn := Time.get_ticks_usec() - began
			print("spawn kind %d colour %d: add %.1f ms, setup %.1f ms, +frame %.1f ms" % [kind, colour, added / 1000.0, setup / 1000.0, drawn / 1000.0])
	quit()
