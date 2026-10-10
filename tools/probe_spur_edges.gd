extends SceneTree
## Dev probe: where liner trees actually stand relative to the spur's edges.
##
##   godot --headless --path . --script res://tools/probe_spur_edges.gd -- --seed=1
##
## For every 40 m of spur, buckets planted trees by their distance past the
## road edge on each side (inner = toward the highway, outer = toward the
## view), and flags stretches where a side has no near tree at all.

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
	var side: float = path.call("viewpoint_side_for", centre)
	var half_span: float = RoadPathGD.SPUR_HALF_SPAN
	var first_chunk := int(floor((centre - half_span) / RoadChunkGD.LENGTH))
	var last_chunk := int(floor((centre + half_span - 1.0) / RoadChunkGD.LENGTH))
	print("centre=%.0f side=%.0f" % [centre, side])
	# Per-40 m column of liner census: [zmid, inner:<12m, inner:12-25m,
	# outer:<12m, outer:12-25m]. A colonnade keeps the <12m cells nonzero.
	var rows: Array = []
	for index in range(first_chunk, last_chunk + 1):
		var chunk: Node3D = RoadChunkGD.new()
		get_root().add_child(chunk)
		var theme_id: int = int(path.call("theme_for_chunk", index))
		chunk.call("setup", index, theme_id)
		var origin: Vector3 = chunk.get("_origin")
		var cells := {}
		for bucket in ["_crowns", "_conifers"]:
			for xform in chunk.get(bucket):
				var world: Vector3 = (xform as Transform3D).origin + origin
				var wz: float = world.z
				var spur: Vector2 = path.call("spur_interval", wz)
				if spur == Vector2.ZERO:
					continue
				var slat: float = (world - path.call("center_at", wz)).dot(
					(path.call("frame_flat_at", wz) as Basis).x
				)
				var mid := int(floor(wz / 40.0))
				if not cells.has(mid):
					cells[mid] = [0, 0, 0, 0]
				var inner_edge: float = minf(spur.x, spur.y) if side > 0.0 else maxf(spur.x, spur.y)
				var outer_edge: float = maxf(spur.x, spur.y) if side > 0.0 else minf(spur.x, spur.y)
				var c: Array = cells[mid]
				if side > 0.0 and slat < inner_edge:
					if inner_edge - slat < 12.0:
						c[0] += 1
					elif inner_edge - slat < 25.0:
						c[1] += 1
				elif side > 0.0 and slat > outer_edge:
					if slat - outer_edge < 12.0:
						c[2] += 1
					elif slat - outer_edge < 25.0:
						c[3] += 1
				elif side < 0.0 and slat > inner_edge:
					if slat - inner_edge < 12.0:
						c[0] += 1
					elif slat - inner_edge < 25.0:
						c[1] += 1
				elif side < 0.0 and slat < outer_edge:
					if outer_edge - slat < 12.0:
						c[2] += 1
					elif outer_edge - slat < 25.0:
						c[3] += 1
		rows.append([index, cells])
		chunk.free()
	# Report: one line per 40 m column of route distance (not chunk) — same
	# column may collect trees from two chunks. z | in<12 in<25 | out<12 out<25
	var merged := {}
	for row in rows:
		for mid in (row[1] as Dictionary).keys():
			if not merged.has(mid):
				merged[mid] = [0, 0, 0, 0]
			var a: Array = merged[mid]
			var b: Array = (row[1] as Dictionary)[mid]
			for i in 4:
				a[i] += b[i]
	for mid in merged.keys():
		var c: Array = merged[mid]
		print(
			"z=%4d..%-4d dist=%4d | inner %2d %2d | outer %2d %2d %s" % [
				mid * 40, mid * 40 + 40, int(absf(mid * 40 + 20.0 - centre)),
				c[0], c[1], c[2], c[3],
				"  <-- BARE" if c[0] + c[2] == 0 else "",
			]
		)
	quit(0)
