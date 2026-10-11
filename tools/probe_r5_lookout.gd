extends SceneTree

## Round-5 lookout probe: build the platform-owner chunk for a seed and report
## whether the composed vista landmarks emitted, plus their world AABBs.
##   godot --headless --path . --script res://tools/probe_r5_lookout.gd -- --seed=1

const RoadChunkGD: GDScript = preload("res://scripts/road_chunk.gd")
const RoadPathGD: GDScript = preload("res://scripts/road_path.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var opts := {}
	for i in OS.get_cmdline_user_args():
		var a := String(i)
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			opts[kv[0]] = kv[1] if kv.size() > 1 else true
	var seed := int(opts.get("seed", 1))
	var path: Node = get_root().get_node_or_null("RoadPath")
	if path == null:
		path = RoadPathGD.new()
		path.name = "RoadPath"
		get_root().add_child(path)
	path.call("set_world_seed", seed)
	var centre: float = path.call("viewpoint_centre_for", 800.0)
	var index := int(path.call("viewpoint_index_for", centre))
	var theme := int(path.call("theme_for_chunk", index))
	print("probe: seed=", seed, " centre=", centre, " chunk_index=", index, " theme=", theme)
	var chunk: Node3D = RoadChunkGD.new()
	chunk.name = "PlatformProbe"
	get_root().add_child(chunk)
	chunk.call("setup", index, theme)
	var origin: Vector3 = chunk.get("_origin")
	print("probe: owns_platform=", chunk.get("_owns_platform"), " vp_theme=", chunk.get("_vp_theme"),
		" vp_side=", chunk.get("_vp_side"), " water_y=", chunk.get("_vp_water_y"))
	for want in ["ViewpointIslet", "ViewpointSpires", "ViewpointBastion", "ViewpointPath",
			"ViewpointCairn", "ViewpointWall"]:
		var n := chunk.find_child(want, false, false)
		if n == null:
			print("probe: ", want, " MISSING")
			continue
		if n is MeshInstance3D:
			var aabb: AABB = (n as MeshInstance3D).get_aabb()
			var wpos: Vector3 = origin + aabb.get_center()
			print("probe: ", want, " aabb_size=", aabb.size, " world_centre=", wpos,
				" world_y_range=[", origin.y + aabb.position.y, ",",
				origin.y + aabb.end.y, "]")
		else:
			print("probe: ", want, " present (node, not mesh)")
	quit()
