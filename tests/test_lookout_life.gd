extends SceneTree
## Warmup has to draw the material objects the bench will actually use, not a
## throwaway copy. The laptop stall was invisible to a simple shader-path test.

var _failed: int = 0

func _initialize() -> void:
	_run.call_deferred()

func _expect(ok: bool, label: String) -> void:
	if not ok:
		_failed += 1
		push_error(label)

func _run() -> void:
	var life_script: GDScript = load("res://scripts/lookout_life.gd")
	var preview := Node3D.new()
	root.add_child(preview)
	life_script.warm_into(preview)
	var previous: StandardMaterial3D
	for slot: int in 3:
		var mat: StandardMaterial3D = life_script.balloon_material(slot)
		var drawn: bool = false
		for node: Node in preview.get_children():
			if node is MeshInstance3D and (node as MeshInstance3D).material_override == mat:
				drawn = true
		_expect(drawn, "warmup must draw envelope material %d" % slot)
		_expect(mat == life_script.balloon_material(slot), "reseating must reuse envelope material %d" % slot)
		_expect(mat != previous, "each envelope needs its own burner")
		previous = mat
	_expect(life_script.star_material() == life_script.star_material(), "shooting stars reuse their warmed material")
	preview.queue_free()
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	await process_frame
	root.find_child("HUD", true, false).call("_start_ride")
	var path: Node = root.get_node("RoadPath")
	path.call("set_world_seed", 2)
	var player: Node = main.get_node("Player")
	var centre: float = path.call("viewpoint_centre_for", 2800.0)
	var side: float = path.call("viewpoint_side_for", centre)
	player.set("track_z", centre)
	player.set("lateral", side * (float(path.call("spur_offset", centre)) + float(path.get("PLATFORM_HALF_WIDTH")) - 3.5))
	player.set("speed", 0.0)
	player.set("lat_vel", 0.0)
	player.set("_invuln", 60.0)
	main.get_node("TrafficManager").set("max_active", 0)
	player.set("_committed_to_spur", true)
	player.call("_place")
	_expect(bool(player.call("can_sit")), "fixture parks the bike before pressing F")
	player.call("_toggle_seat")
	var life: Node = main.get_node("LookoutLife")
	for i: int in 12:
		await process_frame
	var opening_root: Node3D = life.get("_root")
	_expect(is_instance_valid(opening_root), "sit creates the life view")
	player.call("_toggle_seat")
	await process_frame
	await process_frame
	_expect(life.get("_root") == null, "standing releases the life view")
	_expect((life.get("_actors") as Array).is_empty(), "standing cancels actors")
	print("test_lookout_life: %d failures" % _failed)
	quit(1 if _failed else 0)
