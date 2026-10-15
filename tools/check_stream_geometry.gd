extends SceneTree
## Hash completed streamed chunks in the baseline and candidate. A scheduling
## fix must keep every triangle, instance and transform, including the unused
## spur liner; photographs alone can miss a displaced clump off camera.

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var chunk_script: GDScript = load("res://scripts/road_chunk.gd")
	var path: Node = root.get_node("RoadPath")
	for world_seed: int in [1, 2, 4]:
		path.call("set_world_seed", world_seed)
		for index: int in [10, 40, 63, 86]:
			var chunk: Node3D = chunk_script.new()
			root.add_child(chunk)
			var began: int = Time.get_ticks_usec()
			await chunk.call("setup_ribbon_incremental", index, path.call("theme_for_chunk", index))
			await chunk.call("setup_props_incremental")
			var elapsed: float = float(Time.get_ticks_usec() - began) / 1000.0
			var state: Array = []
			_collect(chunk, state)
			var digest := HashingContext.new()
			digest.start(HashingContext.HASH_SHA256)
			digest.update(var_to_bytes(state))
			print("geometry: seed=%d chunk=%d entries=%d sha256=%s build_ms=%.2f" % [world_seed, index, state.size(), digest.finish().hex_encode(), elapsed])
			chunk.free()
	quit()


func _collect(node: Node, state: Array) -> void:
	if node is Node3D:
		state.append([String(node.name), (node as Node3D).transform])
	if node is MeshInstance3D:
		var mesh: Mesh = (node as MeshInstance3D).mesh
		for surface: int in mesh.get_surface_count():
			state.append(mesh.surface_get_arrays(surface))
	if node is MultiMeshInstance3D:
		var mm: MultiMesh = (node as MultiMeshInstance3D).multimesh
		state.append(mm.buffer)
	for child: Node in node.get_children():
		_collect(child, state)
