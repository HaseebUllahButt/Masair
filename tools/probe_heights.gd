extends SceneTree
## Road and overlook-water heights along the route, per seed — for pitching
## height fog so mist settles in the valleys without drowning the road.

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var path: Node = root.get_node("/root/RoadPath")
	for s in [1, 2, 4]:
		path.call("set_world_seed", s)
		var lo := 1e9
		var hi := -1e9
		for i in 400:
			var z := float(i) * 25.0
			var y: float = path.call("height_at", z)
			lo = minf(lo, y)
			hi = maxf(hi, y)
		var vc: float = path.call("viewpoint_centre_for", 2800.0)
		print("seed %d road y %.1f..%.1f  vp %.0f water %.1f seat %.1f" % [s, lo, hi, vc,
			float(path.call("viewpoint_water_y", vc)), (path.call("viewpoint_seat", vc) as Transform3D).origin.y])
	quit()
