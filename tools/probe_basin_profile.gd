extends SceneTree
## Diag: profile of view-side ground height vs road height across the overlook
## stretch, so basin dressing can be aimed at ground the rider actually sees.
##
##   godot --headless --path . --script res://tools/probe_basin_profile.gd -- --seed=2


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var opts := {}
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	var seed: int = int(opts.get("seed", 2))
	var path: Node = root.get_node("RoadPath")
	path.call("set_world_seed", seed)
	var centre: float = float(path.call("viewpoint_centre_for", 2800.0))
	var side: float = float(path.call("viewpoint_side_for", centre))
	var water: float = float(path.call("viewpoint_water_y", centre))
	print("centre=%.0f side=%.0f" % [centre, side])
	for z in [centre - 900.0, centre - 750.0, centre - 650.0, centre - 560.0, centre - 450.0, centre - 300.0, centre - 150.0, centre]:
		var road_y: float = (path.call("point_at", z, 0.0) as Vector3).y
		var line := "z=%5.0f dy=%5.1f wy=%5.1f |" % [z, road_y, water]
		var out := 16.0
		while out <= 380.0:
			var h: float = (path.call("ground_at", z, side * out) as Vector3).y
			var rel := h - road_y
			# Mark: letter per height band relative to road level and waterline.
			var c := " "
			var above_water := h > water + 0.6
			if not above_water:
				c = "~"  # under the sheet
			elif rel < -25.0:
				c = "v"  # deep below road
			elif rel < -8.0:
				c = "d"  # dropping basin
			elif rel < 3.0:
				c = "."  # flat at road level
			elif rel < 12.0:
				c = "/"  # rising
			elif rel < 24.0:
				c = "h"  # hill
			else:
				c = "H"  # high headland
			line += c
			out += 8.0
		print(line, " (16..380 out)")
	# Spur position for scale.
	for z in [centre - 650.0, centre - 300.0, centre]:
		var iv: Vector2 = path.call("spur_interval", z)
		var crest: float = float(path.call("headland_crest", z))
		var near: float = float(path.call("viewpoint_near_shore", z))
		print("z=%.0f spur=[%.0f..%.0f] crest=%.0f near_shore=%.0f" % [z, iv.x, iv.y, crest, near])
	quit(0)
