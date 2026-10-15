extends SceneTree
## Dev tool: photographs the overlook kit pieces close up on a neutral floor —
## bench, lantern bollard, rail bay, pier, map board, balcony — so a change to
## their build can be judged at the size a seated rider sees them, without
## booting a world and riding to an overlook.
##
##   gamescope -W 1280 -H 720 --backend headless -- \
##       godot --path . --audio-driver Dummy --script res://tools/kit_lineup.gd -- --out=DIR

var out_dir: String = "/tmp/splendor-kit"

const PIECES := [
	["res://scenes/lookout_bench.tscn", Vector3(0, 0, 0)],
	["res://scenes/lookout_bollard.tscn", Vector3(1.6, 0, 0)],
	["res://scenes/lookout_board.tscn", Vector3(3.2, 0, 0)],
	["res://scenes/lookout_pier.tscn", Vector3(5.0, 0.3, -2.0)],
	["res://scenes/lookout_rail.tscn", Vector3(5.0, 0.3, 0.0)],
	["res://scenes/lookout_rail.tscn", Vector3(5.0, 0.3, 4.0)],
	["res://scenes/lookout_deck.tscn", Vector3(-1.6, 0.0, 6.0)],
	["res://scenes/lookout_balcony.tscn", Vector3(9.0, 0.3, 2.0)],
]


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=", true, 1)
		if kv.size() == 2 and kv[0] == "out":
			out_dir = kv[1]
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(out_dir)
	var world := Node3D.new()
	root.add_child(world)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-38.0), deg_to_rad(-140.0), 0.0)
	sun.light_energy = 1.4
	sun.light_color = Color("fff1dc")
	sun.shadow_enabled = true
	world.add_child(sun)
	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("8ea7bd")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("9fb3c6")
	environment.ambient_light_energy = 0.55
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = environment
	world.add_child(env)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(80, 80)
	ground.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("6b675b")
	ground.material_override = mat
	world.add_child(ground)
	for row in PIECES:
		var packed: PackedScene = load(String(row[0]))
		if packed == null:
			continue
		var piece: Node3D = packed.instantiate()
		piece.position = row[1]
		world.add_child(piece)
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.fov = 40.0
	for shot in [
		{"name": "kit_wide", "pos": Vector3(-5.5, 3.4, -6.5), "look": Vector3(4.0, 0.6, 1.0)},
		{"name": "kit_bench", "pos": Vector3(-1.9, 1.25, -1.9), "look": Vector3(0.0, 0.45, 0.0)},
		{"name": "kit_bench_back", "pos": Vector3(1.8, 1.4, 1.6), "look": Vector3(0.0, 0.5, 0.0)},
		{"name": "kit_lamp_board", "pos": Vector3(1.0, 1.3, -3.2), "look": Vector3(2.4, 0.7, 0.0)},
		{"name": "kit_rail", "pos": Vector3(2.4, 1.5, -3.6), "look": Vector3(5.0, 0.9, 1.0)},
		{"name": "kit_rail_out", "pos": Vector3(8.2, 1.4, -2.8), "look": Vector3(5.0, 0.8, 1.0)},
		{"name": "kit_balcony", "pos": Vector3(15.0, 4.0, -6.0), "look": Vector3(10.0, 0.5, 2.0)},
	]:
		camera.position = shot["pos"]
		camera.look_at(shot["look"])
		for _i in 3:
			await process_frame
		await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		var path := "%s/%s.png" % [out_dir, shot["name"]]
		image.save_png(path)
		print("shot ", path)
	quit(0)
