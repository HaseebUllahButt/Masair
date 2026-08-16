extends SceneTree
## Integration check for the instant in-place restart path.

const MainScene := preload("res://scenes/main.tscn")
const RoadChunkGD := preload("res://scripts/road_chunk.gd")

var failures: int = 0
var frames: int = 0
var game: Node
var path: Node
var main: Node
var old_seed: int


func check(ok: bool, what: String) -> void:
	if not ok:
		failures += 1
		print("FAIL: ", what)


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 1:
		game = root.get_node("GameManager")
		path = root.get_node("RoadPath")
		main = MainScene.instantiate()
		root.add_child(main)
		current_scene = main
		old_seed = path.world_seed
	if frames == 10:
		var restart_started := Time.get_ticks_usec()
		game.restart()
		var restart_ms := float(Time.get_ticks_usec() - restart_started) / 1000.0
		var reset_player: Node = main.get_node("Player")
		check(reset_player.track_z < 0.05 and reset_player.alive, "restart resets the bike immediately")
		var parked: Transform3D = path.call(
			"road_transform_at",
			reset_player.track_z,
			reset_player.lateral,
			reset_player.half_width + reset_player.road_edge_margin
		)
		check(
			(reset_player as Node3D).global_position.distance_to(parked.origin) < 0.05,
			"restart parks the bike on the new world's road, not the previous seed"
		)
		var spawn_chunk: Node = (main.get_node("RoadStreamer").get("_chunks") as Dictionary).get(0)
		check(spawn_chunk != null and spawn_chunk.get_node_or_null("RoadSurface") != null, "spawn road mesh exists under the bike")
		check(restart_ms < 48.0, "restart stays a short hitch (%.2f ms)" % restart_ms)
	if frames == 20:
		var player: Node = main.get_node("Player")
		var streamer: Node = main.get_node("RoadStreamer")
		var traffic: Node = main.get_node("TrafficManager")
		var camera_pivot: Node3D = main.get_node("Player/CameraPivot") as Node3D
		check(path.world_seed != old_seed, "restart randomizes the world seed")
		# Heavy streamed chunks can take several real frames; the immediate check
		# above proves the reset itself while this allows the bike to roll a little.
		check(player.track_z < 12.0 and player.alive, "bike remains near the reset point")
		check((streamer.get("_chunks") as Dictionary).size() >= 2, "nearby road is ready immediately")
		check((traffic.get("_cars") as Array).is_empty(), "traffic is cleared")
		# Committing to the scenic spur must retain both junctions while riding it.
		# Parked on the platform the camera looks at the lake, so only the basin
		# stays loaded — the old long ring drew fifty chunks the view never saw.
		var original_z: float = player.track_z
		var original_lateral: float = player.lateral
		var viewpoint: float = float(path.call("viewpoint_centre_for", 800.0))
		var viewpoint_side: float = float(path.call("viewpoint_side_for", viewpoint))
		var spur_span: float = float(path.get_script().get_script_constant_map()["SPUR_HALF_SPAN"])
		var lake_span: float = float(path.get_script().get_script_constant_map()["LAKE_SPAN"])
		player.track_z = viewpoint - 220.0
		player.lateral = viewpoint_side * float(path.call("spur_offset", player.track_z))
		var riding_bounds: Vector2i = streamer.call("_desired_bounds", floori(player.track_z / 40.0))
		check(float(riding_bounds.x) * 40.0 <= viewpoint - spur_span, "riding the spur retains the entrance junction")
		check(float(riding_bounds.y + 1) * 40.0 >= viewpoint + spur_span, "riding the spur retains the exit junction")
		player.track_z = viewpoint
		player.lateral = viewpoint_side * float(path.call("spur_offset", viewpoint))
		var scenic_bounds: Vector2i = streamer.call("_desired_bounds", floori(viewpoint / 40.0))
		check(float(scenic_bounds.x) * 40.0 <= viewpoint - lake_span, "the parked overlook keeps the lake")
		check(float(scenic_bounds.y + 1) * 40.0 >= viewpoint + lake_span, "the parked overlook keeps the far end of the lake")
		check(
			float(scenic_bounds.y - scenic_bounds.x) * 40.0 < spur_span * 1.6,
			"the parked overlook does not stream the whole scenic spur"
		)
		player.track_z = original_z
		player.lateral = original_lateral
		# Restart from the scenic spur used to dump the loaded ring and refill
		# kilometre zero one slow chunk at a time, with lake meshes still finishing
		# in the old place. The spawn road has to be under the bike this frame.
		player.track_z = viewpoint
		player.lateral = viewpoint_side * float(path.call("spur_offset", viewpoint))
		player.call("_place")
		game.restart()
		check(player.track_z < 0.05 and player.alive, "restart from the spur returns to kilometre zero")
		check((streamer.get("_chunks") as Dictionary).has(0), "restart rebuilds the spawn road under the bike")
		var leftover := false
		for chunk_index in streamer.get("_chunks") as Dictionary:
			if int(chunk_index) > 20:
				leftover = true
		check(not leftover, "restart unloads the overlook instead of leaving it in the world")
		# Sitting on the bench, then R, used to leave the eye at the lake: the
		# rider stayed `seated`, distance climbed back to 2800 m, and physics
		# interpolation flew the camera across the water instead of snapping it
		# onto the new spawn road.
		player.track_z = viewpoint
		player.lateral = viewpoint_side * float(path.call("spur_offset", viewpoint))
		player.set("seated", true)
		player.set("_seat_blend", 1.0)
		player.call("_place")
		player.call("_update_view", 1.0)
		var bench: Transform3D = path.call("viewpoint_seat", viewpoint)
		game.restart()
		check(not bool(player.get("seated")), "restart stands the rider up off the bench")
		check(is_equal_approx(float(player.get("_seat_blend")), 0.0), "restart clears the bench camera blend")
		check(player.track_z < 0.05, "restart from the bench returns to kilometre zero")
		var cam: Camera3D = camera_pivot.get_node("Camera3D") as Camera3D
		check(
			cam.global_position.distance_to(bench.origin) > 80.0,
			"restart does not leave the eye sitting on the lake"
		)
		var parked_from_bench: Transform3D = path.call(
			"road_transform_at", player.track_z, player.lateral, player.half_width + player.road_edge_margin
		)
		check(
			(player as Node3D).global_position.distance_to(parked_from_bench.origin) < 0.05,
			"restart from the bench parks on the new world's road"
		)
		var horizon: Node3D = main.get_node_or_null("HorizonMountains") as Node3D
		check(horizon != null, "the follow skyline is in the ride scene")
		check(
			horizon.physics_interpolation_mode == Node.PHYSICS_INTERPOLATION_MODE_OFF,
			"the follow skyline does not interpolate teleports"
		)
		check(
			horizon.global_position.distance_to((player as Node3D).global_position) < 0.05,
			"restart snaps the skyline onto the bike instead of flying it from the lake"
		)
		var chunks_before_light: Array = (streamer.get("_chunks") as Dictionary).keys()
		main.call("_cycle_lighting")
		check(
			(streamer.get("_chunks") as Dictionary).keys() == chunks_before_light,
			"changing time never rebuilds or removes streamed road"
		)
		# Road-only confinement: even a stale/out-of-range lateral write must be
		# projected back onto the authored tarmac before the bike is placed.
		var road_bounds: Vector2 = path.call("road_bounds_at", player.track_z)
		player.set("lateral", road_bounds.y + 43.0)
		player.call("_place")
		check(
			absf(float(player.get("lateral"))) <= float(player.get("max_lateral")) + 0.001,
			"bike clamps lateral movement to the road boundary"
		)
		check(
			path.call("is_on_road", player.track_z, player.lateral, player.half_width + player.road_edge_margin),
			"bike hitbox remains inside defined road after confinement"
		)
		var road_transform: Transform3D = path.call(
			"road_transform_at", player.track_z, player.lateral, player.half_width + player.road_edge_margin
		)
		check(
			(player as Node3D).global_position.distance_to(road_transform.origin) < 0.01,
			"bike placement uses the road surface, never terrain"
		)
		Input.action_press("look_right")
		player.call("_update_view", 0.5)
		Input.action_release("look_right")
		check(camera_pivot.rotation.y > PI + 0.5, "Q/E head-look turns independently of steering")
		check(camera_pivot.rotation.y < PI + deg_to_rad(95.0), "Q/E look stops at a right angle")
		player.call("reset_run")
		check(
			is_equal_approx(camera_pivot.rotation.y, PI),
			"restart faces down the road after a head-look"
		)
		check(is_equal_approx(float(player.get("_look_yaw")), 0.0), "restart clears look yaw")
		player.set("wheelie", 1.0)
		player.set("lean", 0.0)
		player.call("_update_view", 1.0)
		check(absf(camera_pivot.position.z) > 0.3, "rider eye orbits with the bike during a wheelie")
		# Restart rolls a new world: a new biome order and a random starting biome.
		var start_themes := {}
		start_themes[int(streamer.call("theme_for_chunk", 0))] = true
		for _attempt in 10:
			game.restart()
			start_themes[int(streamer.call("theme_for_chunk", 0))] = true
			check(
				int(streamer.call("theme_for_chunk", 0)) != RoadChunkGD.Env.CITY,
				"restart never starts in the city"
			)
		check(start_themes.size() >= 2, "theme at chunk 0 can differ across restarts")
		var first_region: int = int(streamer.call("theme_for_chunk", 0))
		check(
			int(streamer.call("theme_for_chunk", 1)) == first_region,
			"the spawn stretch is one biome, not a cut every chunk"
		)
		# Time of day is chosen for the run rather than driven by distance.
		main.set("rain", 0.0)
		main.set("lighting_mode", 1)
		main.call("_apply_lighting")
		var environment: Environment = (main.get_node("WorldEnvironment") as WorldEnvironment).environment
		var sun: DirectionalLight3D = main.get_node("Sun") as DirectionalLight3D
		var sky_material: ShaderMaterial = environment.sky.sky_material as ShaderMaterial
		check(environment.sky.process_mode == Sky.PROCESS_MODE_REALTIME, "animated sky and smooth weather share a realtime radiance map")
		var day_fog: float = environment.fog_density
		check(not sun.shadow_enabled, "directional shadow mesh artefacts stay disabled")
		var ride_audio := main.get_node("RideAudio")
		var continuous_voices := 0
		for child in ride_audio.get_children():
			if child is AudioStreamPlayer and (child as AudioStreamPlayer).stream is AudioStreamWAV:
				if ((child as AudioStreamPlayer).stream as AudioStreamWAV).loop_mode != AudioStreamWAV.LOOP_DISABLED:
					continuous_voices += 1
		check(continuous_voices == 0, "ride audio has no continuous wind or noise loops")
		check(environment.ambient_light_energy < 0.4, "day mode avoids washed-out ambient light")
		check(environment.tonemap_exposure < 0.9, "day mode keeps highlight exposure controlled")
		check(day_fog < 0.001, "day mode opens the viewing distance")
		check(
			sun.light_color.r > 0.9 and sun.light_color.b > 0.5 and sun.light_color.r > sun.light_color.b,
			"day mode uses controlled warm sunlight"
		)
		check(
			float(sky_material.get_shader_parameter("star_intensity")) == 0.0,
			"day mode shows no stars"
		)
		main.set("lighting_mode", 2)
		main.call("_apply_lighting")
		# Energy times colour, not energy alone. Ambient contributes the product of
		# the two, and a bare energy threshold silently stopped meaning "darker"
		# the moment the ambient colours changed — it only ever held because the
		# three rows happened to use similarly bright colours.
		var night_ambient: float = environment.ambient_light_energy * environment.ambient_light_color.get_luminance()
		var day_ambient: float = (
			float(main.MOODS[1]["ambient"]) * (main.MOODS[1]["ambient_color"] as Color).get_luminance()
		)
		var dusk_ambient: float = (
			float(main.MOODS[0]["ambient"]) * (main.MOODS[0]["ambient_color"] as Color).get_luminance()
		)
		check(
			night_ambient < day_ambient and night_ambient < dusk_ambient,
			"night mode is darker than day and dusk"
		)
		check(environment.fog_density > 0.001 and environment.fog_density < 0.002, "night remains readable through controlled fog")
		check(sun.light_color.b > sun.light_color.r, "night mode uses cool moonlight")
		# Moon and stars are drawn by the sky shader at infinity rather than by a
		# quad parented to the camera, which is what stops them sliding across the
		# sky as the rider turns.
		check(
			float(sky_material.get_shader_parameter("star_intensity")) > 0.0,
			"night mode reveals stars"
		)
		check(
			float(sky_material.get_shader_parameter("moon_face")) > 0.0,
			"night mode gives the celestial body a moon face"
		)
		check(
			main.get_node_or_null("Player/CameraPivot/Camera3D/NightSky") == null,
			"no camera-parented celestial art remains to swim with the view"
		)
		main.set("lighting_mode", 0)
		main.call("_apply_lighting")
		check(environment.fog_density > day_fog, "dusk mode restores evening atmosphere")
		var obscured: Dictionary = main.MOODS[0].duplicate()
		obscured["fog_density"] = 0.004
		obscured["fog_aerial"] = 0.45
		obscured["fog_sky"] = 0.28
		obscured["fog_height_density"] = 0.02
		obscured["contrast"] = 1.0
		obscured["saturation"] = 0.72
		var scenic: Dictionary = main.call("_protect_scenic_visibility", obscured)
		check(float(scenic["fog_density"]) <= 0.00018, "viewpoint weather preserves the distant view")
		check(
			float(scenic["contrast"]) >= 1.2 and float(scenic["saturation"]) >= 1.1,
			"viewpoint weather preserves scenic colour separation"
		)

		main.call("begin_ride", 2, 2)
		check(int(main.get("lighting_mode")) == 2, "the start menu mood remains fixed for the ride")
		check(int(main.get_node("TrafficManager").get("max_active")) == 24, "hard mode selects dense traffic")

		# Weather: mostly dry, deterministic from the world seed, and arriving as
		# a band rather than as a per-frame roll.
		var wet_samples := 0
		var previous: float = float(main.call("rain_at", 0.0))
		var worst_jump := 0.0
		for step in 900:
			var metres := float(step) * 40.0
			var amount: float = float(main.call("rain_at", metres))
			check(amount >= 0.0 and amount <= 1.0, "rain amount stays in range")
			worst_jump = maxf(worst_jump, absf(amount - previous))
			previous = amount
			if amount > 0.5:
				wet_samples += 1
		check(wet_samples > 0, "the route runs into rain somewhere in 36 km")
		check(wet_samples < 450, "the route is dry more often than it is wet")
		check(worst_jump < 0.25, "weather arrives as a front, not as a switch")
		var dry_day: Dictionary = main.MOODS[1].duplicate()
		var storm: Dictionary = main.call("_overcast", dry_day, 1.0)
		check(
			float(storm["cloud_sharpness"]) < float(dry_day["cloud_sharpness"]),
			"rain softens the cloud deck instead of sharpening it"
		)
		check(
			is_equal_approx(float(main.call("rain_at", 12345.0)), float(main.call("rain_at", 12345.0))),
			"weather is deterministic for a given route position"
		)
		print("restart self-check: %d failures" % failures)
		quit(1 if failures > 0 else 0)
	return false
