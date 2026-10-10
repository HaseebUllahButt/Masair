extends SceneTree
## Dev probe: per-chunk tree census along the scenic spur.
##
##   godot --headless --path . --script res://tools/probe_spur_trees.gd -- --seed=1
##
## Builds every spur chunk synchronously the way tests do, then reports how
## many planted trees/bushes survive the corridor sweep in each 40 m chunk and
## where they sit relative to the spur centreline. Riding shots mix streaming
## lag with planting output; this isolates the planting half.

const RoadChunkGD: GDScript = preload("res://scripts/road_chunk.gd")
const RoadPathGD: GDScript = preload("res://scripts/road_path.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var seed := 1
	var phase := -1
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=", true, 1)
		if kv.size() == 2 and kv[0] == "seed":
			seed = int(kv[1])
		if kv.size() == 2 and kv[0] == "phase":
			phase = int(kv[1])
	var path: Node = get_root().get_node_or_null("RoadPath")
	if path == null:
		path = RoadPathGD.new()
		path.name = "RoadPath"
		get_root().add_child(path)
	path.call("set_world_seed", seed)

	var centre: float = path.call("viewpoint_centre_for", 800.0)
	var side: float = path.call("viewpoint_side_for", centre)
	var half_span: float = RoadPathGD.SPUR_HALF_SPAN
	var first_chunk := int(floor((centre - half_span) / RoadChunkGD.LENGTH))
	var last_chunk := int(floor((centre + half_span - 1.0) / RoadChunkGD.LENGTH))
	print("centre=%.0f side=%.0f chunks=%d..%d" % [centre, side, first_chunk, last_chunk])
	print("chunk z0 div half trees crowns conifers trunks leaves minlat maxlat")

	var total_trees := 0
	var bare_chunks: Array = []
	for index in range(first_chunk, last_chunk + 1):
		var chunk: Node3D = RoadChunkGD.new()
		get_root().add_child(chunk)
		var theme_id: int = int(path.call("theme_for_chunk", index))
		if phase < 0:
			chunk.call("setup", index, theme_id)
		else:
			chunk.call("_configure", index, theme_id)
			chunk.call("_build_spur_woodland", 0, 5, phase)
		var z0 := float(index) * RoadChunkGD.LENGTH
		var zmid := z0 + RoadChunkGD.LENGTH * 0.5
		var div: float = float(path.call("spur_divergence", zmid))
		var half: float = float(path.call("spur_half_width", zmid))
		var crowns: Array = chunk.get("_crowns")
		var conifers: Array = chunk.get("_conifers")
		var trunks: Array = chunk.get("_trunks")
		var leaves: Array = chunk.get("_leaves")
		var origin: Vector3 = chunk.get("_origin")
		var n_trees := conifers.size()
		var min_lat := INF
		var max_lat := -INF
		var n_inner := 0
		var n_outer := 0
		for bucket in [crowns, conifers]:
			for xform in bucket:
				var wz: float = (xform as Transform3D).origin.z + origin.z
				var centreline: Vector3 = path.call("center_at", wz)
				var right: Vector3 = (path.call("frame_flat_at", wz) as Basis).x
				var slat: float = ((xform as Transform3D).origin + origin - centreline).dot(right)
				var spur_lat: float = side * float(path.call("spur_offset", wz))
				# Liner census: trees standing within 25 m of the spur centre,
				# split by which flank they are on (toward the highway vs out).
				if absf(slat - spur_lat) < 25.0:
					if (slat - spur_lat) * side < 0.0:
						n_inner += 1
					else:
						n_outer += 1
				min_lat = minf(min_lat, slat)
				max_lat = maxf(max_lat, slat)
		# conifer instances are one-per-tree; broadleaf = crown count is a fair
		# proxy for trees (one canopy each); trunks overcount (limbs).
		var approx_trees := conifers.size() + crowns.size()
		total_trees += approx_trees
		if approx_trees == 0 and leaves.size() == 0:
			bare_chunks.append(index)
		print(
			"%d %.0f %.3f %.1f %d %d %d %d %d %.1f %.1f in=%d out=%d" % [
				index, z0, div, half, approx_trees, crowns.size(), conifers.size(),
				trunks.size(), leaves.size(),
				min_lat if min_lat != INF else -999.0,
				max_lat if max_lat != -INF else -999.0,
				n_inner, n_outer,
			]
		)
		chunk.free()
	print("total approx trees: %d" % total_trees)
	print("bare chunks (no trees, no leaves): %s" % str(bare_chunks))
	quit(0)
