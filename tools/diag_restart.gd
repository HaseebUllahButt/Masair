extends SceneTree
## Stress the restart path: many restarts in quick succession, checking after
## each that the visible road is under the bike and matches the math road.
##
##   godot --headless --path . --script res://tools/diag_restart.gd -- --stress

const MainScene := preload("res://scenes/main.tscn")

var _stress: bool = false


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "--stress":
			_stress = true
	var scene: Node = MainScene.instantiate()
	root.add_child(scene)
	current_scene = scene
	var runner := Runner.new()
	runner.tree_ref = self
	runner.stress = _stress
	root.add_child(runner)


class Runner:
	extends Node

	var tree_ref: SceneTree
	var game: Node
	var player: Node
	var streamer: Node
	var path: Node
	var main: Node
	var frames := 0
	var phase := 0  # 0 riding, 1 stress-restarting, 2 done
	var restarts := 0
	var failures := 0
	var stress := false

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		game = get_tree().root.get_node("GameManager")
		path = get_tree().root.get_node("RoadPath")
		main = get_tree().root.find_child("Main", true, false)
		streamer = get_tree().root.find_child("RoadStreamer", true, false)
		player = get_tree().root.find_child("Player", true, false)
		var hud := get_tree().root.find_child("HUD", true, false)
		if hud and hud.has_method("_start_ride"):
			hud.call("_start_ride")
		Input.action_press("throttle")

	func _process(_delta: float) -> void:
		frames += 1
		match phase:
			0:
				# Let the ride start and stream a while.
				if frames > 120:
					if stress:
						phase = 1
						print("--- stress: restarting every 12 frames")
					else:
						phase = 2
						_finish()
			1:
				# Restart often, checking the chunk under the bike each time.
				if frames % 12 == 0:
					game.restart()
					_check("restart %d" % restarts)
					restarts += 1
					if restarts >= 30:
						phase = 2
						_finish()
			2:
				pass

	func _finish() -> void:
		print("stress diag: %d restarts, %d failures" % [restarts, failures])
		tree_ref.quit(1 if failures > 0 else 0)

	func _check(label: String) -> void:
		var chunks: Dictionary = streamer.get("_chunks") as Dictionary
		var bike: Vector3 = (player as Node3D).global_position
		var z: float = player.track_z
		var lat: float = player.lateral
		var expected: Vector3 = path.call("point_at", z, lat)
		var dy: float = bike.y - expected.y
		var under := floori(z / 40.0)
		if not chunks.has(under):
			print("  [%s] FAIL: chunk %d under bike missing (z=%.1f chunks=%s)" % [label, under, z, chunks.keys()])
			failures += 1
			return
		var chunk: Node = chunks[under]
		var road_mesh := chunk.get_node_or_null("RoadSurface") as MeshInstance3D
		if road_mesh == null or road_mesh.mesh == null:
			print("  [%s] FAIL: chunk %d has no RoadSurface" % [label, under])
			failures += 1
			return
		var sample: Vector3 = _sample_mesh_y(road_mesh)
		var vis_dy: float = bike.y - sample.y
		if absf(vis_dy) > 0.9:
			var visible_center: Vector3 = _visible_center(chunk, road_mesh)
			print(
				"  [%s] FAIL: bike %.2f m off visible road (bike y=%.2f, mesh y=%.2f, z=%.1f; seed=%d expected center=%s, chunk center=%s chunk pos=%s)"
				% [
					label,
					vis_dy,
					bike.y,
					sample.y,
					z,
					int(path.get("world_seed")),
					path.call("center_at", 0.0),
					visible_center,
					chunk.position,
				]
			)
			failures += 1

	func _visible_center(chunk: Node, mi: MeshInstance3D) -> Vector3:
		## The mesh's own centreline at its z=0 end (used to detect a stale seed).
		var mesh: ArrayMesh = mi.mesh as ArrayMesh
		var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var best := Vector3.INF
		var best_d := INF
		var origin: Vector3 = (chunk as Node3D).position
		for v in verts:
			var g: Vector3 = (chunk as Node3D).to_global(v)
			if absf(g.z) > 1.0:
				continue
			var d: float = absf(g.x - origin.x)
			if d < best_d:
				best_d = d
				best = g
		return best

	func _sample_mesh_y(mi: MeshInstance3D) -> Vector3:
		var mesh: ArrayMesh = mi.mesh as ArrayMesh
		var chunk: Node3D = mi.get_parent() as Node3D
		var local: Vector3 = chunk.to_local((player as Node3D).global_position)
		var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var best: Vector3 = local
		var best_d := INF
		for v in verts:
			var d: float = Vector2(v.x, v.z).distance_squared_to(Vector2(local.x, local.z))
			if d < best_d:
				best_d = d
				best = v
		return chunk.to_global(best)
