extends SceneTree
## Dome-colour bisect at the road camera. Parks at z=470 with the normal rider
## camera, previews day, then samples the top-of-frame sky while each stage is
## toggled — the stage that changes the pixel is the one tinting the dome.

func _initialize() -> void:
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	var runner := Runner.new()
	runner.tree_ref = self
	root.add_child(runner)


class Runner:
	extends Node

	var tree_ref: SceneTree
	var _env: Environment
	var _sky_mat: Material
	var _player: Node
	var _grade: CanvasItem
	var _main: Node
	var _t := 0.0
	var _step := 0
	var _sample_x := [80, 400, 640, 900, 1200]
	var _sample_y := [15, 60, 120, 180]

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		var hud := get_tree().root.find_child("HUD", true, false)
		if hud and hud.has_method("_start_ride"):
			hud.call("_start_ride")
			hud.visible = false
		var path := get_tree().root.get_node("RoadPath")
		path.call("set_world_seed", 2)
		_player = get_tree().root.find_child("Player", true, false)
		_player.track_z = 470.0
		_player.speed = 0.0
		_player.lat_vel = 0.0
		_player.call("_place")
		_main = get_tree().root.find_child("Main", true, false)
		_main.set("rain", 0.0)
		_main.call("preview_mood", 1)
		var world_env := get_tree().root.find_child("WorldEnvironment", true, false) as WorldEnvironment
		_env = world_env.environment
		_sky_mat = _env.sky.sky_material
		_grade = get_tree().root.find_child("GradeRect", true, false)

	func _process(delta: float) -> void:
		_t += delta
		_main.set("rain", 0.0)
		if _t < 4.0:
			return
		match _step:
			0:
				_sample("baseline")
			1:
				_env.adjustment_enabled = false
				_sample("adjustment OFF")
			2:
				_env.adjustment_enabled = true
				if is_instance_valid(_grade):
					_grade.visible = false
				_sample("grade OFF")
			3:
				_env.glow_enabled = false
				_sample("glow OFF")
			4:
				_env.fog_enabled = false
				_sample("fog OFF")
			5:
				_sky_mat.set("shader_parameter/cloud_opacity", 0.0)
				_sky_mat.set("shader_parameter/bank_opacity", 0.0)
				_sample("clouds+bank OFF")
			6:
				_sky_mat.set("shader_parameter/sun_halo", 0.0)
				_sky_mat.set("shader_parameter/sun_disc", 0.0)
				_sky_mat.set("shader_parameter/horizon_glow", 0.0)
				_sample("sun+glow OFF")
			7:
				_env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
				_sample("linear tonemap")
			8:
				tree_ref.quit(0)
				return
		_step += 1
		_t = 3.4

	func _sample(label: String) -> void:
		var img := get_viewport().get_texture().get_image()
		print("== %s" % label)
		for y in _sample_y:
			var row := "  y=%3d  " % y
			for x in _sample_x:
				var c := img.get_pixel(x, y)
				row += "%02x%02x%02x " % [int(c.r8), int(c.g8), int(c.b8)]
			print(row)
