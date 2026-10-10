extends SceneTree
## Diag: build overlook-stretch chunks the way a highway rider gets them and
## count what the scenery passes actually emit.
##
##   godot --headless --path . --script res://tools/probe_flats.gd -- --seed=2 --z0=2080 --z1=2560 [--scenic]

const RoadChunkGD: GDScript = preload("res://scripts/road_chunk.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var opts := {}
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
		elif kv.size() == 1 and kv[0] != "":
			opts[kv[0]] = "1"
	var seed: int = int(opts.get("seed", 2))
	var z0: float = float(opts.get("z0", 2080.0))
	var z1: float = float(opts.get("z1", 2560.0))
	var scenic: bool = opts.has("scenic")
	var path: Node = root.get_node("RoadPath")
	path.call("set_world_seed", seed)
	var i0 := int(floor(z0 / 40.0))
	var i1 := int(floor(z1 / 40.0))
	for index in range(i0, i1 + 1):
		var theme_id: int = int(path.call("theme_for_chunk", index))
		var chunk: Node3D = RoadChunkGD.new() as Node3D
		root.add_child(chunk)
		chunk.call("setup", index, theme_id, scenic, true)
		var zc := index * 40
		print(
			(
				"idx %d z=%d..%d theme=%d vp_side=%.0f on_spur=%s on_lake=%s "
				+ "trunks=%d conifers=%d crowns=%d leaves=%d grass=%d cubes=%d blobs=%d"
			)
			% [
				index,
				zc,
				zc + 40,
				theme_id,
				float(chunk.get("_vp_side")),
				str(bool(chunk.get("_on_spur"))),
				str(bool(chunk.get("_on_lake"))),
				(chunk.get("_trunks") as Array).size(),
				(chunk.get("_conifers") as Array).size(),
				(chunk.get("_crowns") as Array).size(),
				(chunk.get("_leaves") as Array).size(),
				(chunk.get("_grass") as Array).size(),
				(chunk.get("_cubes") as Array).size(),
				(chunk.get("_blobs") as Array).size(),
			]
		)
		chunk.free()
	quit(0)
