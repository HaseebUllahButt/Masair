extends SceneTree
## Sky colour probe. Boots the real scene in day mood, parks the bike, tilts
## the rider camera up at the sky, and dumps rendered pixels while each post
## stage is toggled — so the teal cast can be traced to the stage that adds it.
##
##   gamescope -W 1280 -H 720 --backend headless -- \
##       godot --path . --audio-driver Dummy --script res://tools/probe_sky.gd


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
	var _t := 0.0
	var _step := 0
	var _sample_x := [160, 420, 640, 860, 1120]
	var _sample_y := [40, 110, 190, 280, 380]

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		var hud := get_tree().root.find_child("HUD", true, false)
		if hud and hud.has_method("_start_ride"):
			hud.call("_start_ride")
			hud.visible = false
		var path := get_tree().root.get_node("RoadPath")
		path.call("set_world_seed", 2)
		_player = get_tree().root.find_child("Player", true, false)
		_player.track_z = 1600.0
		_player.speed = 0.0
		_player.lat_vel = 0.0
		_player.call("_place")
		var main := get_tree().root.find_child("Main", true, false)
		main.call("preview_mood", 1, true)
		var world_env := get_tree().root.find_child("WorldEnvironment", true, false) as WorldEnvironment
		_env = world_env.environment
		_sky_mat = _env.sky.sky_material
		_grade = get_tree().root.find_child("GradeRect", true, false)

	func _process(delta: float) -> void:
		_t += delta
		# Runs after the player's own frame: lean the head back at the sky.
		_player.camera_pivot.rotation.x = 0.72
		if _t < 4.0:
			return
		match _step:
			0:
				_dump_shader()
				_sample("baseline")
			1:
				_env.adjustment_enabled = false
				_sample("adjustment OFF")
			2:
				_env.adjustment_enabled = true
				_env.fog_sky_affect = 0.0
				_sample("fog_sky OFF")
			3:
				_env.fog_sky_affect = 0.07
				_env.glow_enabled = false
				_sample("glow OFF")
			4:
				_env.glow_enabled = true
				_sky_mat.set("shader_parameter/cloud_opacity", 0.0)
				_sky_mat.set("shader_parameter/bank_opacity", 0.0)
				_sample("clouds OFF")
			5:
				# Restore everything, kill only the grade overlay pass.
				_env.glow_enabled = true
				_sky_mat.set("shader_parameter/cloud_opacity", 0.90)
				_sky_mat.set("shader_parameter/bank_opacity", 0.90)
				_grade = get_tree().root.find_child("GradeRect", true, false)
				if is_instance_valid(_grade):
					_grade.visible = false
				_sample("grade overlay OFF")
			6:
				_env.adjustment_enabled = false
				_env.glow_enabled = false
				_env.fog_sky_affect = 0.0
				_env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
				_sample("ALL OFF (raw shader)")
			7:
				tree_ref.quit(0)
				return
		_step += 1
		_t = 3.4

	func _dump_shader() -> void:
		for k in ["zenith_color", "mid_color", "horizon_color", "cloud_lit", "cloud_dark", "sun_color", "horizon_glow", "energy", "band_low", "band_high", "cloud_opacity"]:
			print("  %s = %s" % [k, _sky_mat.get("shader_parameter/" + k)])

	func _sample(label: String) -> void:
		var img := get_viewport().get_texture().get_image()
		img.save_png("/home/ubuntu/masair-shots/sky3/probe/probe_%s.png" % label.replace(" ", "_").replace("(", "").replace(")", ""))
		print("── %s" % label)
		for y in _sample_y:
			var row := "  y=%3d  " % y
			for x in _sample_x:
				var c := img.get_pixel(x, y)
				row += "%02x%02x%02x " % [int(c.r8), int(c.g8), int(c.b8)]
			print(row)
