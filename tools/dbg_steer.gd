extends SceneTree
## Scratch debug: drive _steer directly and print internals.
const RoadPathGD := preload("res://scripts/road_path.gd")
const MotorcycleGD := preload("res://scripts/motorcycle.gd")

var _ran := false
var bike: Node3D


func _process(_d: float) -> bool:
	if _ran:
		return true
	_ran = true
	var path: Node = root.get_node_or_null("RoadPath")
	if path == null:
		path = RoadPathGD.new()
		path.name = "RoadPath"
		root.add_child(path)
	path.call("set_world_seed", 72117)
	bike = MotorcycleGD.new()
	var visual := Node3D.new()
	visual.name = "Visual"
	bike.add_child(visual)
	var pivot := Node3D.new()
	pivot.name = "CameraPivot"
	bike.add_child(pivot)
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	pivot.add_child(camera)
	root.add_child(bike)
	bike.set_physics_process(false)
	bike.speed = 25.0
	bike.track_z = 500.0
	bike.set("_road_pitch", 0.0)
	var dt := 1.0 / 60.0
	for i in 40:
		bike.call("_steer", dt)
	Input.action_press("steer_right")
	for i in 90:
		bike.call("_steer", dt)
		if i % 3 == 0:
			print(
				"t=%.2f steer=%.2f ctr=%.2f lean=%.1f lv=%.2f leanv=%.2f"
				% [
					i * dt, Input.get_axis("steer_left", "steer_right"),
					float(bike.get("counter_steer")), rad_to_deg(float(bike.lean)),
					float(bike.lat_vel), float(bike.get("_lean_vel")),
				]
			)
	quit(0)
	return true
