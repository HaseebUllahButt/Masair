extends SceneTree
## Wall-clock the pieces of a sit-down: materials, pools, ambient actors and
## each _water_spot call — to prove where the 40 ms goes.

const LifeGD: GDScript = preload("res://scripts/lookout_life.gd")


func _initialize() -> void:
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	await process_frame
	var path: Node = root.get_node_or_null("RoadPath")
	var player: Node = root.find_child("Player", true, false)
	var streamer: Node = root.find_child("RoadStreamer", true, false)
	var hud := root.find_child("HUD", true, false)
	if hud and hud.has_method("_start_ride"):
		hud.call("_start_ride")
	path.call("set_world_seed", 72117)
	var viewpoint := float(path.call("viewpoint_centre_for", 2800.0))
	var side := float(path.call("viewpoint_side_for", viewpoint))
	player.set("track_z", viewpoint - 1320.0)
	player.set("lateral", side * float(path.call("spur_offset", viewpoint - 1320.0)))
	player.set("_committed_to_spur", true)
	player.call("_place")
	streamer.call("reset_world")
	for i in 200:
		await process_frame
	player.set("track_z", viewpoint)
	var apron: float = float(path.get("PLATFORM_HALF_WIDTH"))
	player.set("lateral", side * (float(path.call("spur_offset", viewpoint)) + apron - 3.5))
	player.call("_place")
	for i in 200:
		await process_frame
	# Instrument the life node directly.
	var life: Node = root.find_child("LookoutLife", true, false)
	if life == null:
		print("PROBE FAIL: no LookoutLife")
		return
	var t0 := Time.get_ticks_usec()
	player.set("seated", true)
	await process_frame
	print("seat frame total: %.1f ms" % ((Time.get_ticks_usec() - t0) / 1000.0))
	# Now call _water_spot variants directly on the built state.
	for args in [[70.0, 190.0, 40.0, 14.0], [110.0, 300.0, 40.0, 25.0], [110.0, 210.0, 22.0, 30.0]]:
		var a := Time.get_ticks_usec()
		var spot: Vector3 = life.call("_water_spot", args[0], args[1], args[2], args[3])
		print("water_spot %s -> %.1f ms (hit=%s)" % [str(args), (Time.get_ticks_usec() - a) / 1000.0, str(spot != Vector3.INF)])
	# A full mist build and a fish-jump-style build.
	var a2 := Time.get_ticks_usec()
	life.call("_mist", 6, life.get("_root"))
	print("_mist(6) call: %.1f ms (coroutine — frames still follow)" % ((Time.get_ticks_usec() - a2) / 1000.0))
	var a3 := Time.get_ticks_usec()
	life.call("_fish_jump")
	print("_fish_jump: %.1f ms" % ((Time.get_ticks_usec() - a3) / 1000.0))
	var a4 := Time.get_ticks_usec()
	life.call("_make_spray")
	life.call("_make_rings")
	print("_make_spray+_make_rings: %.1f ms" % ((Time.get_ticks_usec() - a4) / 1000.0))
	# Per-frame _step cost with a busy scene.
	life.call("_crossing", 18, Color.BLACK, 1.4, 100.0, 5.0, 12.0, false)
	life.call("_birds_burst")
	for i in 3:
		await process_frame
	var samples := PackedFloat32Array()
	for i in 60:
		var s := Time.get_ticks_usec()
		life.call("_step", 1.0 / 60.0)
		samples.append((Time.get_ticks_usec() - s) / 1000.0)
	samples.sort()
	print("_step busy: median=%.2f p95=%.2f worst=%.2f ms, actors=%d" % [samples[30], samples[56], samples[59], (life.get("_actors") as Array).size()])
