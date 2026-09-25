extends SceneTree
## Deterministic geometry census for the painted mountain ring.
##
##   godot --path . --script res://tools/audit_horizon.gd
##
## Frame time is the wrong instrument for judging a change to the ring: it
## covers a small slice of the screen at the far end of the road, and on this
## scene its per-frame cost sits under the run-to-run spread of the measurement
## itself. Triangle count does not move when the machine gets busy, so it is
## what a change to the ring should be argued from.
##
## Run this on two trees and diff the totals. Every number here is a property of
## the constants in horizon_mountains.gd, so the same two trees give the same
## two answers on any machine.

const MainScene := preload("res://scenes/main.tscn")

var _failures: int = 0


func _initialize() -> void:
	# The ring is built in _ready, and _ready does not fire until the tree is
	# actually iterating — so the audit has to be driven from a node, not run
	# inline here. Probing from _initialize sees a scene that has not built yet
	# and reports zero triangles on a perfectly healthy ring.
	var runner := Runner.new()
	runner.tree_ref = self
	root.add_child(runner)


func audit(mountains: Node) -> void:
	var total_verts := 0
	var total_tris := 0
	var total_surfaces := 0
	var layers := 0

	print("audit: mountain ring")
	for child in mountains.get_children():
		if not (child is MeshInstance3D):
			continue
		var mesh := (child as MeshInstance3D).mesh
		if mesh == null:
			continue
		var verts := 0
		var tris := 0
		for s in mesh.get_surface_count():
			var arrays := (mesh as ArrayMesh).surface_get_arrays(s)
			var vertex_array: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX] if arrays[Mesh.ARRAY_VERTEX] != null else PackedVector3Array()
			var index_array: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			verts += vertex_array.size()
			# SurfaceTool.commit() without generate_index() gives a triangle soup,
			# so the vertex count is already the triangle count times three.
			tris += index_array.size() / 3 if index_array.size() > 0 else vertex_array.size() / 3
		print("audit:   %-8s surfaces %2d  verts %7d  tris %7d" % [child.name, mesh.get_surface_count(), verts, tris])
		total_verts += verts
		total_tris += tris
		total_surfaces += mesh.get_surface_count()
		layers += 1

	# The summit wisps are one MultiMesh; instance count is the whole cost.
	var clouds := _find_multimesh(mountains)
	if clouds != null:
		print("audit:   %-8s instances %d" % [clouds.name, clouds.multimesh.instance_count])
	else:
		print("audit:   clouds   none")

	print("audit: TOTAL layers %d, surfaces %d, verts %d, tris %d" % [layers, total_surfaces, total_verts, total_tris])

	# The ring is drawn every frame with the camera inside it, so nothing here is
	# culled away in the normal case. A ring that has quietly stopped being built
	# would also pass a "count went down" reading, so assert it is still there.
	if total_tris <= 0:
		print("audit: FAIL the ring built no triangles")
		_failures += 1
	elif layers < 4:
		print("audit: FAIL only %d of 4 layers built" % layers)
		_failures += 1


func _find_multimesh(node: Node) -> MultiMeshInstance3D:
	for child in node.get_children():
		if child is MultiMeshInstance3D:
			return child
	return null


class Runner:
	extends Node

	var tree_ref: SceneTree
	var _frame: int = 0
	var _scene: Node = null

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS

	func _process(_delta: float) -> void:
		if _frame == 0:
			_scene = MainScene.instantiate()
			get_tree().root.add_child(_scene)
		_frame += 1
		# Two frames: the first puts the scene in the tree and runs every _ready,
		# the second is where a build that needed a frame has landed.
		if _frame < 2:
			return
		var mountains := get_tree().root.find_child("HorizonMountains", true, false)
		if mountains == null:
			print("audit: FAIL no HorizonMountains in the scene")
			get_tree().quit(1)
			return
		tree_ref.call("audit", mountains)
		get_tree().quit(1 if tree_ref.get("_failures") > 0 else 0)
