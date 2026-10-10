extends SceneTree
## Time setup_ribbon_fast's parts on a scenic (spur) chunk vs an ordinary one.

const RoadChunkGD: GDScript = preload("res://scripts/road_chunk.gd")
const LowPoly: GDScript = preload("res://scripts/low_poly.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var path: Node = root.get_node_or_null("RoadPath")
	if path != null:
		path.call("set_world_seed", 1)
	for index in [70, 71, 30]:
		var chunk: Node3D = RoadChunkGD.new() as Node3D
		root.add_child(chunk)
		var t := Time.get_ticks_usec()
		chunk.call("setup_ribbon_fast", index, 4)
		var total := float(Time.get_ticks_usec() - t) / 1000.0
		var on_spur: bool = bool(chunk.get("_on_spur"))
		print("idx %d: setup_ribbon_fast=%.1f ms on_spur=%s" % [index, total, on_spur])
		chunk.free()
	# Split the spur commit cost on the platform chunk.
	var chunk2: Node3D = RoadChunkGD.new() as Node3D
	root.add_child(chunk2)
	chunk2.call("_configure", 70, 4)
	var z0: float = 70.0 * 40.0
	var t0 := Time.get_ticks_usec()
	var spur_hard: RefCounted = LowPoly.new()
	var spur_road: RefCounted = LowPoly.new()
	chunk2.call("_build_spur_ribbon", spur_hard, spur_road, z0, 0, 10, false)
	print("idx 70: spur_ribbon rows=%.1f ms" % (float(Time.get_ticks_usec() - t0) / 1000.0))
	t0 = Time.get_ticks_usec()
	chunk2.call("_build_platform_bays", spur_hard, z0)
	print("idx 70: platform_bays=%.1f ms" % (float(Time.get_ticks_usec() - t0) / 1000.0))
	t0 = Time.get_ticks_usec()
	chunk2.call("_build_spur_barrier", spur_hard, z0)
	print("idx 70: spur_barrier=%.1f ms" % (float(Time.get_ticks_usec() - t0) / 1000.0))
	chunk2.free()
	quit(0)
