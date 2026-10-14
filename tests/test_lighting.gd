extends SceneTree
## Moods fade rather than cut, start from what is on screen, and the first one
## is a dawn rather than a second sunset.

var failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)


func _run() -> void:
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	main.set_process(false)
	main.call("preview_mood", 1, true)
	var sun: DirectionalLight3D = main.get_node("Sun")
	var env: Environment = (main.get_node("WorldEnvironment") as WorldEnvironment).environment
	var sky: ShaderMaterial = env.sky.sky_material
	var day_light: Color = sun.light_color

	main.call("_cycle_lighting")
	check(int(main.get("lighting_mode")) == 2, "T moves on to night")
	check(sun.light_color.is_equal_approx(day_light), "a fade starts from the light on screen")
	main.call("_step_fade", 0.5)
	var halfway: Color = sun.light_color
	check(not halfway.is_equal_approx(day_light), "the light moves during the fade")
	check(halfway.get_luminance() > Color("9ec8de").get_luminance() * 0.5, "halfway has not snapped to night")
	main.call("_cycle_lighting")
	check(sun.light_color.is_equal_approx(halfway), "a second T continues from the half-faded hour")
	main.call("_step_fade", 1.0)
	check((main.get("_mood_from") as Dictionary).is_empty(), "a finished fade settles on the row")
	check(int(main.get("lighting_mode")) == 0, "the cycle wraps round to dawn")

	# Dawn reads as morning: blue overhead, warmth only on the sun's side, and
	# a key that is gold rather than sunset orange.
	var zenith: Color = sky.get_shader_parameter("zenith_color")
	check(zenith.b > zenith.r * 1.8, "the dawn sky overhead is already blue")
	check(float(sky.get_shader_parameter("azimuth_split")) > 0.5, "dawn warmth belongs to the sun's side of the sky")
	var anti: Color = sky.get_shader_parameter("anti_horizon")
	check(anti.b > anti.r, "the sky opposite the sunrise is the cool earth-shadow")
	check(sun.light_color.g > sun.light_color.r * 0.75, "the dawn key is gold, not sunset orange")
	check(env.fog_height_density > 0.0, "dawn lays mist in the low ground")
	check(sun.rotation_degrees.x > -10.0, "the dawn sun sits low")

	# Rain still layers over dawn without leaving the rose band or moon behind.
	main.set("rain", 1.0)
	main.call("_apply_lighting")
	check(float(sky.get_shader_parameter("belt_strength")) == 0.0, "a closed sky hides the dawn rose band")
	check(float(sky.get_shader_parameter("ghost_moon")) == 0.0, "a closed sky hides the morning moon")
	main.set("rain", 0.0)

	# A night squall stays night rather than lighting the dome grey.
	main.call("preview_mood", 2, true)
	main.set("rain", 1.0)
	main.call("_apply_lighting")
	var storm: Color = sky.get_shader_parameter("zenith_color")
	check(storm.get_luminance() < 0.08 and storm.b > storm.r, "a night squall keeps the sky dark blue")
	main.set("rain", 0.0)

	var hud_script: GDScript = load("res://scripts/hud.gd")
	check(hud_script.get_script_constant_map()["MOOD_NAMES"][0] == "DAWN", "the title picker calls the first mood dawn")
	main.free()
	print("lighting: %d failures" % failures)
	quit(1 if failures else 0)
