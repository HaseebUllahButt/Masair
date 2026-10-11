extends SceneTree
## What the lookout costs once built: node counts by class, MultiMesh
## instance totals, real lights, the wall-clock of sitting down, and seated
## frame medians — the numbers that decide whether the Iris Xe stays smooth
## while parked, that a headless fps figure cannot show.
##
##   godot --headless --path . --script res://tools/probe_lookout_cost.gd


func _initialize() -> void:
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	await process_frame
	var path: Node = root.get_node_or_null("RoadPath")
	var player: Node = root.find_child("Player", true, false)
	var streamer: Node = root.find_child("RoadStreamer", true, false)
	var hud := root.find_child("HUD", true, false)
	# Same setup as profile_scenic.gd: pin the world, jump into the committed
	# spur near the top, then let the streamer build the lookout chunks.
	if path == null or player == null or streamer == null:
		print("PROBE FAIL: missing path/player/streamer")
		return
	var warmup := root.find_child("ScenicWarmup", true, false)
	var waited := 0
	while warmup and is_instance_valid(warmup) and waited < 600:
		waited += 1
		await process_frame
	if hud and hud.has_method("_start_ride"):
		hud.call("_start_ride")
	path.call("set_world_seed", 72117)
	var viewpoint := float(path.call("viewpoint_centre_for", 2800.0))
	var side := float(path.call("viewpoint_side_for", viewpoint))
	player.set("track_z", viewpoint - 1320.0)
	player.set("lateral", side * float(path.call("spur_offset", viewpoint - 1320.0)))
	player.set("_committed_to_spur", true)
	player.set("speed", 0.0)
	player.set("_invuln", 600.0)
	player.call("_place")
	player.reset_physics_interpolation()
	streamer.call("reset_world")
	for i in 200:
		await process_frame
	_report("approach (z=%.0f)" % float(player.get("track_z")))
	# Park and seat.
	player.set("track_z", viewpoint)
	var apron: float = float(path.get("PLATFORM_HALF_WIDTH"))
	player.set("lateral", side * (float(path.call("spur_offset", viewpoint)) + apron - 3.5))
	player.set("_committed_to_spur", true)
	player.call("_place")
	player.reset_physics_interpolation()
	# Let the streamer finish the overlook before measuring the stay.
	for i in 1200:
		await process_frame
		if i % 60 == 59 and _streamer_idle(streamer):
			break
	_report("parked at overlook")
	var t0 := Time.get_ticks_usec()
	player.set("seated", true)
	var per_frame := PackedStringArray()
	for i in 10:
		var a := Time.get_ticks_usec()
		await process_frame
		per_frame.append("%.1f" % ((Time.get_ticks_usec() - a) / 1000.0))
	print("sit-down spread over 10 frames (total %.1f ms): %s" % [
		(Time.get_ticks_usec() - t0) / 1000.0, " ".join(per_frame)])
	for i in 90:
		await process_frame
	_report("seated")
	var life: Node = root.find_child("LookoutLife", true, false)
	if life:
		var actors: Array = life.get("_actors")
		print("life: actors=%d" % actors.size())
		var by_node := {}
		for a in actors:
			var n: Node = a.get("node")
			var k: String = (n.name if n else "?")
			by_node[k] = int(by_node.get(k, 0)) + 1
		print("life actors by node: %s" % str(by_node))
	var samples := PackedFloat32Array()
	for i in 120:
		var a := Time.get_ticks_usec()
		await process_frame
		samples.append((Time.get_ticks_usec() - a) / 1000.0)
	samples.sort()
	print("seated frame ms: median=%.2f p95=%.2f worst=%.2f" % [samples[60], samples[113], samples[119]])


func _report(tag: String) -> void:
	var counts := {}
	var mm_instances := 0
	var mm_nodes := 0
	var plain_mesh := 0
	var lights := 0
	var anim := 0
	var queue: Array[Node] = [root]
	while not queue.is_empty():
		var n: Node = queue.pop_back()
		for c in n.get_children():
			queue.append(c)
		if n is MultiMeshInstance3D:
			mm_nodes += 1
			var mm: MultiMesh = (n as MultiMeshInstance3D).multimesh
			if mm:
				mm_instances += mm.instance_count
		elif n is MeshInstance3D:
			plain_mesh += 1
		elif n is Light3D:
			lights += 1
		elif n is AnimationPlayer:
			anim += 1
		var cls := n.get_class()
		counts[cls] = int(counts.get(cls, 0)) + 1
	var total := 0
	var top: Array = []
	for k in counts:
		total += int(counts[k])
		top.append([int(counts[k]), k])
	top.sort()
	top.reverse()
	var parts: Array[String] = []
	for row: Array in top.slice(0, 10):
		parts.append("%s=%d" % [row[1], row[0]])
	print("%s: nodes=%d plainMesh=%d mmNodes=%d mmInstances=%d lights=%d anims=%d | %s" % [
		tag, total, plain_mesh, mm_nodes, mm_instances, lights, anim, " ".join(parts)])
	var s := root.find_child("RoadStreamer", true, false)
	if s and s.has_method("debug_state"):
		print("  streamer: %s" % str(s.call("debug_state")))


func _streamer_idle(s: Node) -> bool:
	for q: String in ["_ribbon_queue", "_props_queue", "_scenic_queue", "_highway_queue", "_unload_queue"]:
		if not (s.get(q) as Array).is_empty():
			return false
	for f: String in ["_build_in_flight", "_props_in_flight", "_scenic_in_flight", "_highway_in_flight"]:
		if bool(s.get(f)):
			return false
	return true
