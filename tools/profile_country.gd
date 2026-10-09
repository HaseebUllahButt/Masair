extends SceneTree
## Scratch QA profiler: plain country highway chunk timing, per stage.
##
##   godot --headless --path . --script res://tools/profile_country.gd

const RoadChunkGD: GDScript = preload("res://scripts/road_chunk.gd")
const RoadPathGD: GDScript = preload("res://scripts/road_path.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var path: Node = get_root().get_node_or_null("RoadPath")
	if path == null:
		path = RoadPathGD.new()
		path.name = "RoadPath"
		get_root().add_child(path)
	path.call("set_world_seed", 2)
	# A few ordinary country chunks: away from the first overlook window
	# (centre 2800, half-span 1680 -> chunks 28..112) and inside biome 0.
	for index in [6, 10, 140, 180, 220]:
		if int(path.call("theme_for_chunk", index)) != RoadChunkGD.Env.COUNTRY:
			continue
		_run_chunk(index, "country")
	# And the spur-side window, where the scenery still runs beside the junction.
	for index in [40, 60, 90]:
		_run_chunk(index, "country-spur")
	quit(0)


func _run_chunk(index: int, tag: String) -> void:
	var chunk: Node3D = RoadChunkGD.new() as Node3D
	root.add_child(chunk)
	_measure(chunk, tag, "configure", "_configure", [index, RoadChunkGD.Env.COUNTRY])
	_measure(chunk, tag, "ribbon", "_build_ribbon")
	_measure(chunk, tag, "furniture", "_build_furniture")
	_measure(chunk, tag, "theme scenery", "_build_theme_scenery")
	_measure(chunk, tag, "distant scenery", "_build_distant_scenery")
	_measure(chunk, tag, "set piece", "_build_set_piece")
	_measure(chunk, tag, "multimesh commit", "_commit_props")
	print(
		"%s idx %d theme %d  trunks=%d conifers=%d crowns=%d leaves=%d leafcubes=%d grass=%d cubes=%d hay=%d blobs=%d ridges=%d"
		% [
			tag,
			index,
			int(chunk.get("theme")),
			(chunk.get("_trunks") as Array).size(),
			(chunk.get("_conifers") as Array).size(),
			(chunk.get("_crowns") as Array).size(),
			(chunk.get("_leaves") as Array).size(),
			(chunk.get("_leaf_cubes") as Array).size(),
			(chunk.get("_grass") as Array).size(),
			(chunk.get("_cubes") as Array).size(),
			(chunk.get("_hay") as Array).size(),
			(chunk.get("_blobs") as Array).size(),
			(chunk.get("_ridges") as Array).size(),
		]
	)
	chunk.free()


func _measure(target: Object, tag: String, label: String, method: String, args: Array = []) -> void:
	var started := Time.get_ticks_usec()
	target.callv(method, args)
	print(
		"%-16s %-18s %7.2f ms"
		% [tag, label, float(Time.get_ticks_usec() - started) / 1000.0]
	)
