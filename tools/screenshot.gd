extends SceneTree
## Dev tool: boots the real game, rides it, and writes PNG frames to disk.
##
##   godot --path . --script res://tools/screenshot.gd -- --out=/tmp/shots --shots=6 --gap=4
##
## Run it through gamescope so it never steals focus or makes noise:
##
##   gamescope -W 1280 -H 720 --backend headless -- \
##       godot --path . --audio-driver Dummy --script res://tools/screenshot.gd -- --out=/tmp/shots
##
## Not a test — this is the only way to judge a lighting or material change
## without a human at the keyboard. It drives the actual main scene through the
## same input actions a player uses, so what it captures is what ships.

const DEFAULT_OUT := "/tmp/masair-shots"
const RoadChunkGD: GDScript = preload("res://scripts/road_chunk.gd")


func _initialize() -> void:
	var opts := _parse_args()
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	var cap := Capture.new()
	cap.out_dir = opts.get("out", DEFAULT_OUT)
	cap.shots = int(opts.get("shots", 6))
	cap.gap = float(opts.get("gap", 4.0))
	cap.warmup = float(opts.get("warmup", 2.5))
	cap.mode = String(opts.get("mode", "dusk"))
	cap.bench = opts.has("bench")
	cap.look = String(opts.get("look", ""))
	cap.viewpoint = opts.has("viewpoint")
	cap.seated = opts.has("seated")
	cap.detour = opts.has("detour")
	cap.notraffic = opts.has("notraffic")
	cap.overview = String(opts.get("overview", ""))
	cap.dry = opts.has("dry")
	cap.wet = opts.has("wet")
	cap.menu = opts.has("menu")
	cap.bike = int(opts.get("bike", 0))
	cap.world_seed = int(opts.get("seed", 0))
	cap.tree_ref = self
	root.add_child(cap)


func _parse_args() -> Dictionary:
	var out := {}
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=", true, 1)
		if kv.size() == 2:
			out[kv[0]] = kv[1]
		elif kv.size() == 1 and kv[0] != "":
			# Bare switches: --viewpoint and --bench used to be silently dropped, so
			# both modes never ran and the "parked" shots were of a moving bike.
			out[kv[0]] = "1"
	return out


class Capture:
	extends Node

	var out_dir: String = DEFAULT_OUT
	var shots: int = 6
	var gap: float = 4.0
	var warmup: float = 2.5
	var mode: String = "dusk"
	## "left"/"right": hold the glance action, to check that sky bodies stay put
	## in the world instead of swimming with the camera.
	var look: String = ""
	var viewpoint := false
	## Ride the overlook spur instead of the carriageway, steering for its
	## centreline the way a player would. The only way to see the detour itself.
	var detour := false
	## Empty the road of traffic. Implied by --detour.
	var notraffic := false
	var seated := false
	## Dev overview: a free camera looking at part of the overlook from outside.
	## Judging a place you can only see from inside its own parking space costs
	## more rounds of guessing than the camera does.
	var overview: String = ""
	## Hold the weather clear. A rain band drops visibility to a few tens of
	## metres, which makes a shot of a distant view a shot of grey.
	var dry := false
	var wet := false
	var menu := false
	var bike: int = 0
	var _cam: Camera3D
	## Pin the world so a ride and a parked shot are of the same landscape. The
	## route boots on a clock-time seed, which makes two runs incomparable.
	var world_seed: int = 0
	var tree_ref: SceneTree

	var bench: bool = false

	var _elapsed := 0.0
	var _taken := 0
	var _busy := false
	var _frames := 0
	var _worst := 0.0
	var _slow := 0
	var _last_slow := 0.0
	var _ignore_next_frame := false

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		DirAccess.make_dir_recursive_absolute(out_dir)
		# Automated captures bypass the player-facing start menu. Select medium and
		# unpause through the same public entry point the button uses.
		var hud := get_tree().root.find_child("HUD", true, false)
		if not menu and hud and hud.has_method("_start_ride"):
			hud.call("_start_ride")
		if world_seed != 0:
			_pin_world(world_seed)
		if bench:
			# Headroom, not refresh rate: a vsynced 60 fps hides how much budget a
			# new effect actually ate. Under a compositor that paces us anyway
			# (gamescope), the measured GPU time below is the honest number.
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
			RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
		if notraffic or detour:
			# The autopilot steers for a line, not around obstacles, so a lorry in
			# lane two ends every detour run long before the spur opens. Traffic is
			# not what a detour capture is for.
			var traffic := get_tree().root.find_child("TrafficManager", true, false)
			if traffic:
				traffic.set("max_active", 0)
				traffic.call("reset_world")
		if overview != "":
			# Deferred: root is still setting up its children during _ready(), and
			# an add_child() there is refused outright.
			_overview_camera.call_deferred()
		elif viewpoint:
			_park_at_viewpoint()
		elif not menu:
			Input.action_press("throttle")
		if look != "":
			Input.action_press("look_%s" % look)
		# Select the requested authored look directly. Simulating T here was order-
		# dependent: Main could process before this helper released/re-pressed the
		# action, leaving a file named "night" with the previous dusk sky.
		var mood_id: int = {"auto": 0, "dusk": 0, "day": 1, "night": 2}.get(mode, 0)
		var main := get_tree().root.find_child("Main", true, false)
		if main and main.has_method("preview_mood"):
			main.call("preview_mood", mood_id)
		await get_tree().process_frame
		await get_tree().process_frame
		if menu and hud:
			var id := clampi(bike, 0, 2)
			hud.set("_bike_index", id)
			var game := get_tree().root.get_node_or_null("GameManager")
			if game and game.has_method("preview_bike"):
				game.call("preview_bike", id)
			hud.call("_refresh_garage")

	func _pin_world(value: int) -> void:
		var path := get_tree().root.get_node("RoadPath")
		path.call("set_world_seed", value)
		var streamer := get_tree().root.find_child("RoadStreamer", true, false)
		if streamer and streamer.has_method("reset_world"):
			streamer.call("reset_world")

	func _overview_camera() -> void:
		var path := get_tree().root.get_node("RoadPath")
		if world_seed == 0:
			_pin_world(72117)
		var centre: float = path.call("viewpoint_centre_for", 800.0)
		var side: float = path.call("viewpoint_side_for", centre)
		var player := get_tree().root.find_child("Player", true, false)
		player.track_z = centre
		player.lateral = side * (float(path.call("spur_offset", centre)) + 10.0)
		player.speed = 0.0
		player.call("_place")
		var streamer := get_tree().root.find_child("RoadStreamer", true, false)
		if streamer and streamer.has_method("reset_world"):
			streamer.call("reset_world")
		var subject: Vector3 = path.call("point_at", centre, side * float(path.call("spur_offset", centre)))
		var eye := subject
		match overview:
			"spur":
				# Down the length of the detour from above the junction.
				subject = path.call("point_at", centre - 120.0, side * float(path.call("spur_offset", centre - 120.0)))
				eye = path.call("point_at", centre - 300.0, 0.0) + Vector3(0, 120.0, 0)
			"terrace":
				# Close in on the seating, from out over the drop.
				subject = path.call("viewpoint_seat", centre).origin
				# Sample the carved cliff face, not the abstract road plane.  Thirty
				# metres beyond the platform the spur lift is intentionally zero, so
				# point_at() put this inspection camera underneath the terrace.
				eye = path.call("ground_at", centre - 9.0, side * (float(path.call("spur_offset", centre)) + 30.0)) + Vector3(0, 18.0, 0)
			"across":
				# From out over the water, looking back at the headland.
				eye = path.call("point_at", centre, side * 260.0) + Vector3(0, 40.0, 0)
			_:
				eye = path.call("point_at", centre - 70.0, side * (float(path.call("spur_offset", centre)) - 40.0)) + Vector3(0, 55.0, 0)
		var cam := Camera3D.new()
		cam.far = 2000.0
		cam.fov = 62.0
		get_tree().root.add_child(cam)
		cam.global_position = eye
		cam.look_at(subject, Vector3.UP)
		cam.current = true
		_cam = cam

	func _park_at_viewpoint() -> void:
		## Deterministic visual QA for the overlook: parked on the platform at the
		## top of the spur, facing the view.
		var path := get_tree().root.get_node("RoadPath")
		if world_seed == 0:
			_pin_world(72117)
		var centre: float = path.call("viewpoint_centre_for", 800.0)
		var side: float = path.call("viewpoint_side_for", centre)
		var player := get_tree().root.find_child("Player", true, false)
		player.track_z = centre
		# Parked in a bay against the outer kerb, which is where a rider stops and
		# is the only lateral the view is composed for. A fixed offset in metres
		# put the bike outside the parking the moment the platform got narrower.
		var apron: float = float(path.get("PLATFORM_HALF_WIDTH"))
		player.lateral = side * (float(path.call("spur_offset", centre)) + apron - 3.5)
		player.speed = 0.0
		player.call("_place")
		var streamer := get_tree().root.find_child("RoadStreamer", true, false)
		if streamer and streamer.has_method("reset_world"):
			streamer.call("reset_world")
		if seated:
			player.call("_toggle_seat")
		else:
			look = "right" if side > 0.0 else "left"

	func _process(delta: float) -> void:
		_elapsed += delta
		if dry:
			var world := get_tree().root.find_child("Main", true, false)
			if world:
				world.set("rain", 0.0)
		elif wet:
			var world := get_tree().root.find_child("Main", true, false)
			if world:
				world.set("rain", 1.0)
		if _cam:
			# The bike's own camera keeps taking the viewport back when the player
			# is placed, and setting `current` again is a no-op once it is true.
			_cam.make_current()
		if detour:
			_autopilot()
		if _ignore_next_frame:
			# PNG encoding is deliberately synchronous and is not gameplay work.
			_ignore_next_frame = false
		elif _elapsed > warmup:
			_frames += 1
			_worst = maxf(_worst, delta)
			# A hitch is what a player calls lag. Counting them, and noting when the
			# last one landed, separates one-off shader compilation at startup from
			# a stutter that recurs every time a chunk streams in.
			if delta > 0.033:
				_slow += 1
				_last_slow = _elapsed
		if _busy or _taken >= shots:
			return
		if _elapsed < warmup + gap * float(_taken):
			return
		_busy = true
		_shoot()

	func _autopilot() -> void:
		## Steer for the spur once its mouth opens, then hold its centreline. This
		## is the same input a player gives; nothing is teleported.
		var path := get_tree().root.get_node("RoadPath")
		var player := get_tree().root.find_child("Player", true, false)
		if player == null:
			return
		var span: Vector2 = path.call("spur_interval", player.track_z)
		var target: float = 0.0
		if span != Vector2.ZERO:
			target = (span.x + span.y) * 0.5
		var error: float = target - float(player.lateral)
		Input.action_release("steer_left")
		Input.action_release("steer_right")
		# Proportional-ish: stop steering once the lateral velocity already covers
		# the error, or the bike saws from edge to edge and scrubs off all its
		# speed on the boundary.
		if absf(error) > 0.4 and absf(float(player.lat_vel)) < absf(error) * 1.2:
			# Body +X is screen-left, so the action that moves lateral up is
			# steer_left. Reading it off the sign here keeps the tool honest if
			# that convention ever changes.
			Input.action_press("steer_left" if error > 0.0 else "steer_right")

	func _shoot() -> void:
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var path := "%s/%s_%02d.png" % [out_dir, mode, _taken]
		img.save_png(path)
		_ignore_next_frame = true
		print("shot ", path)
		_taken += 1
		_busy = false
		if _taken >= shots:
			Input.action_release("throttle")
			_report()
			tree_ref.quit(0)

	func _report() -> void:
		var ridden := maxf(_elapsed - warmup, 0.001)
		print(
			"perf: %.1f fps avg over %.1f s (%d frames), worst frame %.1f ms"
			% [float(_frames) / ridden, ridden, _frames, _worst * 1000.0]
		)
		if bench:
			print(
				"hitches: %d frames over 33 ms, last at t=%.1f s of %.1f s"
				% [_slow, _last_slow, _elapsed]
			)
			var rid := get_viewport().get_viewport_rid()
			print(
				"gpu: %.2f ms/frame, cpu: %.2f ms/frame"
				% [
					RenderingServer.viewport_get_measured_render_time_gpu(rid),
					RenderingServer.viewport_get_measured_render_time_cpu(rid),
				]
			)
