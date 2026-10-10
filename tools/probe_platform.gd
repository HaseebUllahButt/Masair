extends SceneTree

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
	path.call("set_world_seed", 91827)
	var centre := float(RoadPathGD.VIEWPOINT_FIRST)
	var index := int(centre / RoadChunkGD.LENGTH)
	var chunk: Node3D = RoadChunkGD.new()
	chunk.name = "PlatformProbe"
	get_root().add_child(chunk)
	chunk.call("setup", index, RoadChunkGD.Env.COUNTRY)
	var origin: Vector3 = chunk.get("_origin")
	var side: float = float(path.call("viewpoint_side_for", centre))
	var z0: float = float(index) * RoadChunkGD.LENGTH
	var planted: Array = []
	planted.append_array(chunk.get("_conifers") as Array)
	planted.append_array(chunk.get("_trunks") as Array)
	print("platform chunk ", index, " side ", side, " planted ", planted.size())
	for xform in planted:
		var world: Vector3 = origin + xform.origin
		var best_z := z0
		var best_d := INF
		for i in 41:
			var z: float = z0 + float(i)
			var c: Vector3 = path.call("center_at", z)
			var d: float = Vector2(world.x - c.x, world.z - c.z).length()
			if d < best_d:
				best_d = d
				best_z = z
		var at: Vector3 = path.call("center_at", best_z)
		var right: Vector3 = (path.call("frame_flat_at", best_z) as Basis).x
		var lateral: float = (world - at).dot(right)
		if bool(chunk.call("_on_tarmac", best_z, lateral, 0.8)):
			# The chunk window projection can flag a vista tree hundreds of metres
			# off-route; check the real distance to the carriageway over the whole
			# spur span before believing it.
			var gz: float = clampf(world.z, 1000.0, 4600.0)
			var gat: Vector3 = path.call("center_at", gz)
			var gright: Vector3 = (path.call("frame_flat_at", gz) as Basis).x
			var glat: float = (world - gat).dot(gright)
			var gzdist: float = Vector2(world.x - gat.x, world.z - gat.z).length()
			print(
				"  on tarmac: z=%.1f lat=%.2f dist=%.1f world=%v | at-z %.0f: lat=%.2f 2d-dist=%.1f tarmac=%s" % [
					best_z, lateral, best_d, world,
					gz, glat, gzdist,
					str(bool(chunk.call("_on_tarmac", gz, glat, 0.8)))
				]
			)
	quit()
