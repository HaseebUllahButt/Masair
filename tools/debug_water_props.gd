extends SceneTree
## Debug: boot a seed, park at the overlook (same recipe as
## tools/screenshot.gd's _park_at_viewpoint), let the basin build, then report
## which ViewpointLake meshes exist near the platform and what sky_mirror the
## water materials carry, plus MultiMesh instances below the water plane.
## One-shot diagnostic — not part of the suite.

var _seed := 3


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("seed="):
			_seed = int(arg.split("=")[1])
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	var hud := root.find_child("HUD", true, false)
	if hud and hud.has_method("_start_ride"):
		hud.call("_start_ride")
	var path := root.get_node("RoadPath")
	path.call("set_world_seed", _seed)
	var streamer := root.find_child("RoadStreamer", true, false)
	if streamer and streamer.has_method("reset_world"):
		streamer.call("reset_world")
	# The bike's own _ready chain needs a few frames before _place works.
	for _i in 6:
		await process_frame
	var centre: float = path.call("viewpoint_centre_for", 800.0)
	var side: float = path.call("viewpoint_side_for", centre)
	var water_y: float = path.call("viewpoint_water_y", centre)
	var player := root.find_child("Player", true, false)
	player.set("track_z", centre)
	player.set("lateral", side * (float(path.call("spur_offset", centre)) + 9.0))
	player.set("speed", 0.0)
	player.set("lat_vel", 0.0)
	player.set("_committed_to_spur", true)
	player.call("_place")
	if streamer and streamer.has_method("reset_world"):
		streamer.call("reset_world")
	await create_timer(22.0).timeout
	print("seed=%d centre=%.0f water_y=%.2f" % [_seed, centre, water_y])
	for dz in [-200.0, -80.0, 0.0, 80.0, 200.0]:
		var zz: float = centre + dz
		var h := float(path.call("height_at", zz))
		var crest := float(path.call("headland_crest", zz))
		var near := float(path.call("viewpoint_near_shore", zz))
		var row := "z%+.0f road=%.1f crest=%.0f near=%.0f |" % [dz, h, crest, near]
		for lat in [60.0, 120.0, 160.0, 200.0, 240.0, 280.0]:
			var drop := float(path.call("terrain_drop", lat, zz))
			row += " %.0f:%.1f" % [lat, h - drop]
		print(row)
	var found := 0
	var lakes := 0
	for c in root.find_children("Chunk*", "Node3D", true, false):
		for child in c.get_children():
			if child is MeshInstance3D and String(child.name).contains("ViewpointLake"):
				lakes += 1
				var mi := child as MeshInstance3D
				var aabb: AABB = mi.get_aabb()
				var mat: Material = mi.material_override
				var sky := "?"
				if mat is ShaderMaterial:
					sky = str((mat as ShaderMaterial).get_shader_parameter("sky_mirror"))
				print(
					"  %s/Lake aabb=%s sky_mirror=%s"
					% [c.name, aabb, sky]
				)
			if not (child is MultiMeshInstance3D):
				continue
			var mm: MultiMesh = (child as MultiMeshInstance3D).multimesh
			if mm == null or mm.instance_count == 0:
				continue
			var under := 0
			var min_y := INF
			var sample := Vector3.ZERO
			for i in mm.instance_count:
				var t: Transform3D = mm.get_instance_transform(i)
				var wy: float = c.to_global(t.origin).y
				if wy < min_y:
					min_y = wy
					sample = c.to_global(t.origin)
				if wy < water_y - 0.4:
					under += 1
			if under > 0:
				found += under
				print(
					"  %s/%s: %d/%d under water, min_y=%.1f (water %.1f) at %s"
					% [c.name, child.name, under, mm.instance_count, min_y, water_y, sample]
				)
	print("lake meshes: %d, total under water: %d" % [lakes, found])
	quit(0)
