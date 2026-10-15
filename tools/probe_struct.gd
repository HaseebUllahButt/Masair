extends SceneTree
## Dev probe: where the roadside structures are on a seed — guardrail runs
## (and which ends get a terminal), switchbacks, field-boundary themes — so a
## parked QA shot can be aimed at one instead of guessed.
##
##   godot --headless --path . --audio-driver Dummy --script res://tools/probe_struct.gd -- --seed=1

const RoadChunkGD: GDScript = preload("res://scripts/road_chunk.gd")
const RoadPathGD: GDScript = preload("res://scripts/road_path.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var seed := 1
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seed="):
			seed = int(arg.trim_prefix("--seed="))
	var path: Node = RoadPathGD.new()
	path.name = "RoadPath"
	get_root().add_child(path)
	path.call("set_world_seed", seed)
	var probe: Node3D = RoadChunkGD.new()
	get_root().add_child(probe)
	probe.call("setup", 10, int(path.call("theme_for_chunk", 10)))
	var line := ""
	for index in range(0, 90):
		# Never "this chunk": every index then takes the neighbour branch,
		# which is the rule the chunk itself mirrors.
		probe.set("chunk_index", -999)
		var side: float = probe.call("_guardrail_side_for", index)
		var tag := "."
		if side != 0.0:
			tag = "L" if side < 0.0 else "R"
		line += tag
		if side != 0.0 and float(probe.call("_guardrail_side_for", index - 1)) != side:
			print("rail starts z=%d side=%s theme=%d switchback=%s" % [
				index * 40, tag, int(path.call("theme_for_chunk", index)),
				str(int(path.call("theme_for_chunk", index)) == RoadChunkGD.Env.MOUNTAIN and index % 4 == 1)
			])
	print("rails: ", line)
	quit()
