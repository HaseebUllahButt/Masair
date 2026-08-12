extends SceneTree
## Dev tool: photographs every traffic vehicle in a row, front and rear, with the
## brake and indicator overlays forced on.
##
##   gamescope -W 1600 -H 700 --backend headless -- \
##       godot --path . --audio-driver Dummy --script res://tools/lineup.gd -- --out=/tmp/lineup

const TrafficCarGD: GDScript = preload("res://scripts/traffic_car.gd")
const LowPolyGD: GDScript = preload("res://scripts/low_poly.gd")

var out_dir: String = "/tmp/masair-lineup"


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
	sun.rotation = Vector3(deg_to_rad(-42.0), deg_to_rad(38.0), 0.0)
	sun.light_energy = 1.5
	world.add_child(sun)

	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("6f7d8c")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("8fa2b6")
	environment.ambient_light_energy = 0.6
	env.environment = environment
	world.add_child(env)

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(200, 200)
	ground.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("53585c")
	ground.material_override = mat
	world.add_child(ground)

	var kinds: Array = TrafficCarGD.Kind.values()
	var x := -float(kinds.size() - 1) * 3.5
	for i in kinds.size():
		var kind: int = kinds[i]
		var holder := Node3D.new()
		holder.position = Vector3(x + float(i) * 7.0, 0.0, 0.0)
		world.add_child(holder)
		var body := MeshInstance3D.new()
		body.mesh = TrafficCarGD._mesh_for(kind, i)
		body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		holder.add_child(body)
		var contact := MeshInstance3D.new()
		contact.mesh = TrafficCarGD._shared_contact_shadow_mesh()
		contact.material_override = TrafficCarGD._shared_contact_shadow_material()
		contact.position.y = 0.035
		contact.rotation.x = -PI * 0.5
		contact.scale = Vector3(TrafficCarGD.DIMS[kind].x * 1.12, TrafficCarGD.DIMS[kind].y * 1.05, 1.0)
		holder.add_child(contact)
		var brake := MeshInstance3D.new()
		brake.mesh = TrafficCarGD._brake_mesh(kind)
		holder.add_child(brake)
		var blink := MeshInstance3D.new()
		blink.mesh = TrafficCarGD._blinker_mesh(kind, 1.0)
		holder.add_child(blink)

	var camera := Camera3D.new()
	world.add_child(camera)
	camera.fov = 45.0

	for shot in [
		{"name": "front", "pos": Vector3(0, 7.0, 42.0), "look": Vector3(0, 1.0, 0)},
		{"name": "rear", "pos": Vector3(0, 7.0, -42.0), "look": Vector3(0, 1.0, 0)},
		{"name": "three-quarter", "pos": Vector3(-26.0, 8.0, 30.0), "look": Vector3(0, 1.0, 0)},
		{"name": "closeup-coupe", "pos": Vector3(-6.0, 2.2, -8.0), "look": Vector3(-7.0, 0.9, 0)},
		{"name": "closeup-pickup", "pos": Vector3(6.0, 2.6, 9.0), "look": Vector3(0.0, 1.1, 0)},
	]:
		camera.position = shot["pos"]
		camera.look_at(shot["look"])
		await process_frame
		await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		var path := "%s/%s.png" % [out_dir, shot["name"]]
		image.save_png(path)
		print("shot ", path)
	quit(0)
