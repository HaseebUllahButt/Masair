extends SceneTree
## Dev probe: what does corridor commit hide or free on a spur chunk?
##
##   godot --headless --path . --script res://tools/probe_corridor.gd -- --seed=1

const RoadChunkGD: GDScript = preload("res://scripts/road_chunk.gd")
const RoadPathGD: GDScript = preload("res://scripts/road_path.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var seed := 1
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=", true, 1)
		if kv.size() == 2 and kv[0] == "seed":
			seed = int(kv[1])
	var path: Node = get_root().get_node_or_null("RoadPath")
	if path == null:
		path = RoadPathGD.new()
		path.name = "RoadPath"
		get_root().add_child(path)
	path.call("set_world_seed", seed)

	var centre: float = path.call("viewpoint_centre_for", 800.0)
	var index := int(floor((centre - 800.0) / RoadChunkGD.LENGTH))
	var chunk: Node3D = RoadChunkGD.new()
	get_root().add_child(chunk)
	var theme_id: int = int(path.call("theme_for_chunk", index))
	chunk.call("setup", index, theme_id)

	var report := func(tag: String) -> void:
		var hidden_scenic := 0
		var hidden_highway := 0
		var freed_ribbon := 0
		for child in chunk.get_children():
			var ctag := str(child.get_meta("corridor", ""))
			var is_ribbon := bool(child.get_meta("ribbon", false))
			if not (child as Node3D).visible:
				if ctag == "scenic":
					hidden_scenic += 1
					if is_ribbon:
						freed_ribbon += 1
				elif ctag == "highway":
					hidden_highway += 1
		var surface := chunk.get_node_or_null("SpurSurface")
		print(
			"%s: hidden_scenic=%d hidden_highway=%d spur_ribbon_hidden=%s children=%d" % [
				tag, hidden_scenic, hidden_highway,
				str(surface != null and not surface.visible), chunk.get_child_count(),
			]
		)

	report.call("before")
	chunk.call("apply_corridor", false, true, true)  # rider committed to the highway
	report.call("highway-committed")
	chunk.call("apply_corridor", false, false)
	report.call("uncommitted-again")
	chunk.call("apply_corridor", true, true, true)   # rider committed to the spur
	report.call("spur-committed")
	quit(0)
