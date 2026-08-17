extends SceneTree
## Photographs all five café racers three-quarter and side-on.
##
##   gamescope -W 1600 -H 900 --backend headless -- \
##       godot --path . --audio-driver Dummy --script res://tools/bike_lineup.gd -- --out=/tmp/bike-lineup

const MotorcycleVisualGD: GDScript = preload("res://scripts/motorcycle_visual.gd")
const BikeCatalog := preload("res://scripts/bike_catalog.gd")

var out_dir: String = "/tmp/masair-bikes"


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
	sun.rotation = Vector3(deg_to_rad(-38.0), deg_to_rad(42.0), 0.0)
	sun.light_energy = 1.55
	world.add_child(sun)

	var fill := DirectionalLight3D.new()
	fill.rotation = Vector3(deg_to_rad(-20.0), deg_to_rad(-110.0), 0.0)
	fill.light_energy = 0.45
	fill.light_color = Color("a8c0d8")
	world.add_child(fill)

	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("7a8896")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("9aadb8")
	environment.ambient_light_energy = 0.55
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	environment.glow_enabled = true
	environment.glow_intensity = 0.12
	environment.glow_bloom = 0.05
	# Sky reflection so chrome forks/rims don't render as flat charcoal.
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color("8eb4d4")
	sky_mat.sky_horizon_color = Color("c5d6e4")
	sky_mat.ground_bottom_color = Color("4a4e52")
	sky_mat.ground_horizon_color = Color("6a7076")
	sky.sky_material = sky_mat
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_energy = 0.7
	env.environment = environment
	world.add_child(env)

	var probe := ReflectionProbe.new()
	probe.position = Vector3(0, 1.2, 0)
	probe.size = Vector3(24, 8, 16)
	probe.update_mode = ReflectionProbe.UPDATE_ONCE
	world.add_child(probe)

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(80, 40)
	ground.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("4a4e52")
	ground.material_override = mat
	world.add_child(ground)

	var spacing := 3.2
	var n := BikeCatalog.BIKES.size()
	var bikes: Array[Node3D] = []
	for i in n:
		var holder := Node3D.new()
		holder.position = Vector3((float(i) - float(n - 1) * 0.5) * spacing, 0.0, 0.0)
		world.add_child(holder)
		var vis: Node3D = MotorcycleVisualGD.new()
		holder.add_child(vis)
		vis.call("set_bike_style", i)
		bikes.append(vis)

	var camera := Camera3D.new()
	world.add_child(camera)
	camera.fov = 42.0

	for shot in [
		{"name": "lineup-three-quarter", "pos": Vector3(-8.0, 2.6, 14.0), "look": Vector3(0.0, 0.55, 0.0), "solo": -1},
		{"name": "lineup-side", "pos": Vector3(0.0, 1.6, 15.5), "look": Vector3(0.0, 0.5, 0.0), "solo": -1},
		{"name": "lineup-front", "pos": Vector3(0.0, 1.4, 14.5), "look": Vector3(0.0, 0.55, 0.0), "solo": -1},
		{"name": "solo-mesa", "pos": Vector3(-2.0, 0.9, 2.8), "look": Vector3(0.0, 0.52, 0.0), "solo": 0},
		{"name": "solo-sabre", "pos": Vector3(-2.0, 0.9, 2.8), "look": Vector3(0.0, 0.52, 0.0), "solo": 1},
		{"name": "solo-halcyon", "pos": Vector3(-2.0, 0.9, 2.8), "look": Vector3(0.0, 0.52, 0.0), "solo": 2},
		{"name": "solo-tempest", "pos": Vector3(-2.0, 0.9, 2.8), "look": Vector3(0.0, 0.52, 0.0), "solo": 3},
		{"name": "solo-raven", "pos": Vector3(-2.0, 0.9, 2.8), "look": Vector3(0.0, 0.52, 0.0), "solo": 4},
	]:
		var solo: int = int(shot["solo"])
		for i in bikes.size():
			var holder: Node3D = bikes[i].get_parent()
			if solo < 0:
				holder.visible = true
				holder.position = Vector3((float(i) - float(n - 1) * 0.5) * spacing, 0.0, 0.0)
			else:
				holder.visible = i == solo
				holder.position = Vector3.ZERO if i == solo else Vector3(40.0, 0.0, 0.0)
		camera.position = shot["pos"]
		camera.look_at(shot["look"])
		for _wait in 4:
			await process_frame
			await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		var path := "%s/%s.png" % [out_dir, shot["name"]]
		image.save_png(path)
		print("shot ", path)
	quit(0)
