extends SceneTree
## Dev tool: boots the real game, rides it, and writes PNG frames to disk.
##
##   godot --path . --script res://tools/screenshot.gd -- --out=/tmp/shots --shots=6 --gap=4
##   godot --path . --script res://tools/screenshot.gd -- --catalog --out=/tmp/splendor-gallery
##
## Run it through gamescope so it never steals focus or makes noise:
##
##   gamescope -W 1280 -H 720 --backend headless -- \
##       godot --path . --audio-driver Dummy --script res://tools/screenshot.gd -- --out=/tmp/shots
##
## Not a test — this is the only way to judge a lighting or material change
## without a human at the keyboard. It drives the actual main scene through the
## same input actions a player uses, so what it captures is what ships.

const DEFAULT_OUT := "/tmp/splendor-shots"
const RoadChunkGD: GDScript = preload("res://scripts/road_chunk.gd")
const BikeCatalog := preload("res://scripts/bike_catalog.gd")


func _initialize() -> void:
	var opts := _parse_args()
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	var cap := Capture.new()
	cap.out_dir = opts.get("out", DEFAULT_OUT)
	cap.shots = int(opts.get("shots", 8 if opts.has("sweep") else 6))
	cap.gap = float(opts.get("gap", 1.0 if opts.has("sweep") else 4.0))
	cap.warmup = float(opts.get("warmup", 2.5))
	cap.mode = String(opts.get("mode", "dusk"))
	cap.bench = opts.has("bench")
	cap.look = String(opts.get("look", ""))
	cap.viewpoint = opts.has("viewpoint")
	cap.seated = opts.has("seated")
	cap.detour = opts.has("detour")
	cap.with_traffic = opts.has("traffic")
	cap.spur = opts.has("spur")
	cap.notraffic = opts.has("notraffic")
	cap.overview = String(opts.get("overview", ""))
	cap.dry = opts.has("dry")
	cap.wet = opts.has("wet")
	cap.menu = opts.has("menu")
	cap.bike = int(opts.get("bike", 0))
	cap.speed_limit = float(opts.get("speed", 0.0))
	cap.world_seed = int(opts.get("seed", 0))
	cap.park_z = float(opts.get("z", -1.0))
	cap.start_z = float(opts.get("startz", -1.0))
	cap.shot_name = String(opts.get("name", ""))
	cap.nohud = opts.has("nohud")
	cap.catalog = opts.has("catalog")
	cap.sweep = opts.has("sweep")
	cap.yaw = float(opts.get("yaw", 0.0))
	cap.pitch = float(opts.get("pitch", 0.0))
	cap.hide = String(opts.get("hide", ""))
	cap.pick = opts.has("pick")
	cap.trace = String(opts.get("trace", ""))
	cap.hitch = opts.has("hitch")
	cap.settle = opts.has("settle")
	cap.tree_ref = self
	if cap.hitch:
		RoadChunkGD.set("hitch_trace", true)
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
	## Park a QA camera on the scenic road at --z instead of the highway.
	var spur: bool = false
	## Empty the road of traffic. Implied by --detour, which only the
	## junction-corridor QA wants overridden: --traffic rides the fork with the
	## population intact.
	var notraffic := false
	var with_traffic := false
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
	## Park on the carriageway at this route distance instead of riding. Negative
	## leaves the bike under throttle as usual.
	var park_z: float = -1.0
	## Filename stem. Empty uses the lighting mode, as before.
	var shot_name: String = ""
	var nohud := false
	## One boot, every rural biome on the road and seated at its first overlook.
	var catalog := false
	## Seated panorama: each shot turns the head another 45 degrees from --yaw,
	## so one run photographs the whole ring around the bench. No steer input is
	## ever pressed in a capture, so writing _seat_yaw directly is stable.
	var sweep := false
	## Seated head angles in degrees. Zero is the composed view off the rail.
	var yaw := 0.0
	var pitch := 0.0
	## Comma-separated node names to hide — for telling one mesh's silhouette
	## from another's when a shape cannot be traced back to its builder.
	var hide: String = ""
	## Ray-pick diagnostic: instead of a PNG, print which mesh paints each pixel
	## of a coarse screen grid — for tracing a shape to its builder when hiding
	## by name has ruled everything out. Skips image output entirely.
	var pick := false
	## Per-frame hitch log: any frame over 20 ms prints its wall cost, where the
	## bike was, and the streamer's job/queue state, so a spike can be blamed on
	## a build stage instead of guessed at.
	var hitch := false
	## "x,y" pixel to trace a single ray through: prints every batch it crosses.
	var trace: String = ""
	## Hold the warmup clock until the streamer reports itself idle. Chunks
	## arrive one job per frame, so a fixed warmup races the build queue on a
	## loaded box and photographs a half-missing vista; --settle waits the real
	## world out, then counts warmup on a finished one.
	var settle := false
	var _catalog_jobs: Array[Dictionary] = []
	var _cam: Camera3D
	## Pin the world so a ride and a parked shot are of the same landscape. The
	## route boots on a clock-time seed, which makes two runs incomparable.
	var world_seed: int = 0
	## Riding starts this far along the route — for detour runs that must reach
	## the junction before an unlucky lorry ends them.
	var start_z: float = -1.0
	var tree_ref: SceneTree

	var bench: bool = false
	## km/h ceiling for detour runs — riding the climb flat out outruns the
	## dress queue and photographs streaming lag rather than the road a player
	## on a twisty spur actually sees.
	var speed_limit: float = 0.0

	var _elapsed := 0.0
	var _settled := false
	var _settle_frames := 0
	var _settle_wait := 0.0
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
		if catalog or notraffic or (detour and not with_traffic):
			# The autopilot steers for a line, not around obstacles, so a lorry in
			# lane two ends every detour run long before the spur opens. Traffic is
			# not what a detour capture is for — unless the capture is *of* the
			# traffic at the fork, which is what --traffic is for.
			var traffic := get_tree().root.find_child("TrafficManager", true, false)
			if traffic:
				traffic.set("max_active", 0)
				traffic.call("reset_world")
		elif detour and with_traffic:
			# The autopilot still steers for a line through whatever is in it, and
			# one lorry at the fork mouth ends the run before the corridor commits.
			# Spawn protection stretched over the whole capture keeps the bike
			# alive; the cars on the main road keep driving, which is the thing
			# under test.
			var rider := get_tree().root.find_child("Player", true, false)
			if rider:
				rider.set("_invuln", 1e9)
		if nohud or catalog:
			if hud:
				hud.visible = false
		if catalog:
			dry = true
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
			_prepare_catalog()
			_apply_catalog_job(0)
		elif overview != "":
			# Deferred: root is still setting up its children during _ready(), and
			# an add_child() there is refused outright.
			_overview_camera.call_deferred()
		elif viewpoint:
			_park_at_viewpoint()
		elif park_z >= 0.0:
			_park_on_road(park_z)
		elif not menu:
			if start_z >= 0.0:
				var path := get_tree().root.get_node("RoadPath")
				if world_seed == 0:
					world_seed = 72117
				_set_seed(world_seed)
				var player := get_tree().root.find_child("Player", true, false)
				player.track_z = start_z
				player.call("_place")
				var streamer := get_tree().root.find_child("RoadStreamer", true, false)
				if streamer and streamer.has_method("reset_world"):
					streamer.call("reset_world")
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
			var id := clampi(bike, 0, BikeCatalog.BIKES.size() - 1)
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

	func _prepare_catalog() -> void:
		## One seed whose first biome (and therefore first overlook) is each
		## rural theme. The permutation is shuffled from the seed, so walking
		## small integers is enough.
		var path := get_tree().root.get_node("RoadPath")
		var labels := {1: "forest", 4: "country"}
		var seeds := {}
		var probe := 1
		while seeds.size() < labels.size() and probe < 20000:
			path.call("set_world_seed", probe)
			var theme_id: int = int(path.call("theme_for_chunk", 0))
			if theme_id in labels and not seeds.has(theme_id):
				seeds[theme_id] = probe
				print("catalog seed %s=%d" % [labels[theme_id], probe])
			probe += 1
		_catalog_jobs.clear()
		for theme_id in [1, 4]:
			var label: String = labels[theme_id]
			var seed: int = int(seeds.get(theme_id, 72117))
			var road := {
				"name": "%s_road" % label,
				"seed": seed,
				"kind": "road",
				"z": 1600.0,
				# A catalog shot that races the streamer is a shot that reports a
				# regression the game does not have: give the chunks in front of
				# the bike time to finish streaming.
				"warmup": 11.0,
				"look": "",
			}
			var lookoff := {
				"name": "%s_lookoff" % label,
				"seed": seed,
				# An overlook is twenty-odd chunks of basin, far shore and skyline
				# arriving one per frame through the incremental streamer, and at 12 s
				# a catalog run would occasionally photograph a valley with its far
				# side still missing — which is indistinguishable from a lighting
				# regression until you re-run it.
				"kind": "lookoff",
				"warmup": 18.0,
				"look": "",
			}
			_catalog_jobs.append(road)
			_catalog_jobs.append(lookoff)
		shots = _catalog_jobs.size()
		gap = 0.0

	func _apply_catalog_job(index: int) -> void:
		if index < 0 or index >= _catalog_jobs.size():
			return
		var job: Dictionary = _catalog_jobs[index]
		shot_name = String(job["name"])
		warmup = float(job["warmup"])
		world_seed = int(job["seed"])
		seated = String(job["kind"]) == "lookoff"
		viewpoint = seated
		park_z = float(job.get("z", -1.0))
		look = String(job.get("look", ""))
		_elapsed = 0.0
		_busy = false
		Input.action_release("throttle")
		Input.action_release("steer_left")
		Input.action_release("steer_right")
		Input.action_release("look_left")
		Input.action_release("look_right")
		if seated:
			_park_at_viewpoint()
		else:
			_park_on_road(park_z)
		if look != "":
			Input.action_press("look_%s" % look)

	func _set_seed(value: int) -> void:
		var path := get_tree().root.get_node("RoadPath")
		path.call("set_world_seed", value)

	func _park_on_road(z: float) -> void:
		## Mid-biome carriageway, looking down the route. Chunk 0 of mountain is
		## a tunnel mouth; a kilometre in is the ordinary landscape.
		var player := get_tree().root.find_child("Player", true, false)
		if player == null:
			return
		if world_seed == 0:
			world_seed = 72117
		_set_seed(world_seed)
		player.track_z = z
		player.lateral = float(get_tree().root.get_node("RoadPath").call("viewpoint_side_for", z)) * float(get_tree().root.get_node("RoadPath").call("spur_offset", z)) if spur else 0.0
		player.speed = 0.0
		player.lat_vel = 0.0
		player.set("seated", false)
		player.set("_committed_to_spur", spur)
		player.set("_heading", 0.0)
		player.set("_look_yaw", 0.0)
		# Clear the bench camera too. `_park_at_viewpoint` zeroes these on its way
		# *in*, and nothing zeroed them on the way out — so a road shot that
		# happened to follow a lookoff inherited the seated pitch and yaw and came
		# back as a slab of tarmac with the horizon jammed against the top of the
		# frame. The catalog runs road-then-lookoff per biome, so every road shot
		# after the first is downstream of a seated job.
		player.set("_seat_yaw", 0.0)
		player.set("_seat_pitch", 0.0)
		player.call("_place")
		var streamer := get_tree().root.find_child("RoadStreamer", true, false)
		if streamer and streamer.has_method("reset_world"):
			streamer.call("reset_world")

	func _overview_camera() -> void:
		var path := get_tree().root.get_node("RoadPath")
		if world_seed == 0:
			world_seed = 72117
		_set_seed(world_seed)
		var centre: float = path.call("viewpoint_centre_for", 800.0)
		var side: float = path.call("viewpoint_side_for", centre)
		var player := get_tree().root.find_child("Player", true, false)
		if overview == "junction" or overview == "mouth":
			# The streamer builds around the player, not the camera — parked on
			# the platform, a camera at the mouth photographs unstreamed ground.
			player.track_z = centre - float(path.get("SPUR_HALF_SPAN")) + 100.0
			player.lateral = 0.0
		else:
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
				var terrace_frame: Basis = path.call("frame_flat_at", centre)
				eye = subject + terrace_frame.x * side * 15.0 - terrace_frame.z * 10.0 + Vector3.UP * 7.0
			"across":
				# From out over the water, looking back at the headland.
				eye = path.call("point_at", centre, side * 260.0) + Vector3(0, 40.0, 0)
			"junction":
				# The mouth of the spur, from just above the carriageway before it.
				var entry: float = centre - float(path.get("SPUR_HALF_SPAN"))
				subject = path.call("point_at", entry + 70.0, side * 10.0)
				eye = path.call("point_at", entry - 30.0, -side * 6.0) + Vector3(0, 22.0, 0)
			"mouth":
				# The deceleration lane and gore at rider height, from the saddle.
				var entry_m: float = centre - float(path.get("SPUR_HALF_SPAN"))
				subject = path.call("point_at", entry_m + 160.0, side * 8.0)
				eye = path.call("point_at", entry_m + 30.0, side * 3.0) + Vector3(0, 2.2, 0)
			"parapet":
				# The terrace rail and masonry from out over the drop, held at
				# deck height — the angle a floating skirt or gapped wall shows on.
				var off: float = float(path.call("spur_offset", centre))
				subject = path.call("point_at", centre, side * (off + 9.0))
				eye = path.call("point_at", centre + 14.0, side * (off + 42.0)) + Vector3(0, 3.0, 0)
			"face":
				# Dead-on close-up of the headland face under the deck lip —
				# where the hanging slat curtain shows from `across`.
				var off_f: float = float(path.call("spur_offset", centre))
				subject = path.call("point_at", centre - 8.0, side * (off_f + 41.0))
				subject.y = 8.0
				eye = path.call("point_at", centre + 4.0, side * (off_f + 95.0))
				eye.y = 26.0
			"bay":
				# Standing on the platform looking back at the parking, kerb and
				# parapet line — what the rider sees walking to the bench.
				var off_b: float = float(path.call("spur_offset", centre))
				subject = path.call("point_at", centre - 6.0, side * off_b)
				eye = path.call("point_at", centre + 18.0, side * (off_b + 6.5)) + Vector3(0, 1.7, 0)
			_:
				eye = path.call("point_at", centre - 70.0, side * (float(path.call("spur_offset", centre)) - 40.0)) + Vector3(0, 55.0, 0)
		var cam := Camera3D.new()
		cam.far = 5200.0
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
			world_seed = 72117
		_set_seed(world_seed)
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
		player.lat_vel = 0.0
		player.set("_committed_to_spur", true)
		player.call("_place")
		var streamer := get_tree().root.find_child("RoadStreamer", true, false)
		if streamer and streamer.has_method("reset_world"):
			streamer.call("reset_world")
		if seated:
			# Set the flag directly: _toggle_seat() would stand up if a previous
			# catalog job already sat the rider down.
			player.set("seated", true)
			player.set("_seat_yaw", deg_to_rad(wrapf(yaw, -180.0, 180.0)))
			player.set("_seat_pitch", deg_to_rad(pitch))
		else:
			player.set("seated", false)
			look = "right" if side > 0.0 else "left"

	func _process(delta: float) -> void:
		var holding := false
		if settle and not _settled:
			# _idle_current is set to the player's chunk once the streamer has
			# nothing left to build, dress or unload; -1 while work is pending.
			var s := get_tree().root.find_child("RoadStreamer", true, false)
			var idle := s != null and int(s.get("_idle_current")) >= 0
			_settle_frames = _settle_frames + 1 if idle else 0
			_settle_wait += delta
			_settled = _settle_frames >= 6 or _settle_wait > 300.0
			holding = not _settled
			if Engine.get_process_frames() % 120 == 0:
				print(
					"settle: wait=%.0f frames=%d idle=%s state=%s" % [
						_settle_wait, _settle_frames, str(idle),
						s.call("debug_state") if s and s.has_method("debug_state") else "?",
					]
				)
		if not holding:
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
			if hitch and delta > 0.020:
				var p := get_tree().root.find_child("Player", true, false)
				var s := get_tree().root.find_child("RoadStreamer", true, false)
				print(
					"hitch: frame %.1f ms at t=%.1f z=%.0f lat=%.1f | %s"
					% [
						delta * 1000.0, _elapsed,
						float(p.track_z) if p else -1.0,
						float(p.lateral) if p else 0.0,
						s.call("debug_state") if s and s.has_method("debug_state") else "?",
					]
				)
		if _busy or _taken >= shots:
			return
		if catalog:
			if _elapsed < warmup:
				return
		elif _elapsed < warmup + gap * float(_taken):
			return
		_busy = true
		if seated and sweep:
			var player := get_tree().root.find_child("Player", true, false)
			if player:
				# The seat clamps yaw to [-PI, PI], so a full panorama must wrap
				# the angle: feeding 225..315 raw clamps them all onto 180.
				player.set("_seat_yaw", deg_to_rad(wrapf(yaw + _taken * 45.0, -180.0, 180.0)))
		if seated:
			# Stills of an overlook show its signature moment — the eagle on the
			# water — not whichever lull the clock landed on.
			var life := get_tree().root.find_child("LookoutLife", true, false)
			if life and life.has_method("stage_capture"):
				life.call("stage_capture")
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
		if speed_limit > 0.0:
			if float(player.speed) * 3.6 > speed_limit:
				Input.action_release("throttle")
			else:
				Input.action_press("throttle")
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
		if hide != "":
			for node_name in hide.split(","):
				# Chunk meshes repeat the same node name once per chunk —
				# find_child hides one copy and leaves the rest, which reads as
				# "not the culprit". Hide every match.
				for node in get_tree().root.find_children(node_name.strip_edges(), "Node3D", true, false):
					(node as Node3D).visible = false
		# Two frames: the one where the new seat yaw lands in _update_seat, and
		# the one that is actually drawn. A single post_draw can race the rig.
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		if trace != "":
			_trace_ray()
			_taken += 1
		elif pick:
			_pick_report()
			_taken += 1
			_busy = false
			if _taken >= shots:
				tree_ref.quit(0)
			return
		var img := get_viewport().get_texture().get_image()
		var stem := shot_name if shot_name != "" else mode
		var suffix := ""
		if sweep:
			suffix = "_y%03d" % int(round(fposmod(yaw + _taken * 45.0, 360.0)))
		var path := "%s/%s%s.png" % [out_dir, stem, suffix] if shot_name != "" else "%s/%s%s_%02d.png" % [out_dir, stem, suffix, _taken]
		img.save_png(path)
		_ignore_next_frame = true
		var p := get_tree().root.find_child("Player", true, false)
		if p:
			print("shot ", path, " z=%.0f lat=%.1f" % [float(p.track_z), float(p.lateral)])
		else:
			print("shot ", path)
		_taken += 1
		_busy = false
		if _taken >= shots:
			Input.action_release("throttle")
			_report()
			tree_ref.quit(0)
		elif catalog:
			_apply_catalog_job(_taken)

	func _trace_ray() -> void:
		## One ray through --trace=x,y: every batch it crosses, nearest first,
		## so a pixel's real owner shows even through overlapping geometry.
		var cam := get_viewport().get_camera_3d()
		if cam == null:
			print("trace: no active camera")
			return
		var pixels: Array[Vector2] = []
		for pair in trace.split(";"):
			var xy := pair.split(",")
			pixels.append(Vector2(float(xy[0]), float(xy[1])))
		var batches: Array = []
		_pick_collect(get_tree().root, batches, false)
		_pick_collect(get_tree().root, batches, true)
		for px in pixels:
			_trace_one(cam, px, batches)

	func _trace_one(cam: Camera3D, px: Vector2, batches: Array) -> void:
		var origin := cam.project_ray_origin(px)
		var dir := cam.project_ray_normal(px)
		var hits: Array = []
		for batch in batches:
			var xf: Transform3D = batch["xf"]
			if absf(xf.basis.determinant()) < 1e-9:
				continue
			var inv := xf.affine_inverse()
			var lo := inv * origin
			var ld := inv.basis * dir
			var box: AABB = batch["aabb"]
			if not box.intersects_ray(lo, ld):
				continue
			var tris: PackedVector3Array = batch["tris"]
			var i := 0
			var local_best := INF
			var best_pos := Vector3.ZERO
			while i < tris.size():
				var hit: Variant = Geometry3D.ray_intersects_triangle(
					lo, ld.normalized(), tris[i], tris[i + 1], tris[i + 2]
				)
				if hit != null:
					var wp: Vector3 = xf * hit
					var d: float = origin.distance_to(wp)
					if d < local_best:
						local_best = d
						best_pos = wp
				i += 3
			if local_best < INF:
				hits.append({"d": local_best, "name": batch["name"], "pos": best_pos})
		hits.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["d"]) < float(b["d"]))
		for h in hits.slice(0, 8):
			print("trace %.0f,%.0f -> %.1f %s @%s" % [px.x, px.y, float(h["d"]), h["name"], (h["pos"] as Vector3).snapped(Vector3.ONE)])

	func _pick_report() -> void:
		## Screen-space mesh census: cast the current camera's rays on a coarse
		## grid, hit-test every committed triangle, and print one character per
		## cell naming the owning node ('.' = void / sky pixel). Followed by the
		## world hit positions so the region can be mapped back to the world.
		var cam := get_viewport().get_camera_3d()
		if cam == null:
			print("pick: no active camera")
			return
		var batches: Array = []
		_pick_collect(get_tree().root, batches, false)
		var mm_batches: Array = []
		_pick_collect(get_tree().root, mm_batches, true)
		print("pick: %d mesh batches, %d mm batches, cam=%s" % [batches.size(), mm_batches.size(), cam.global_position])
		var codes := {}
		var next_code := 65
		var size := get_viewport().get_visible_rect().size
		var cols := 96
		var rows := 40
		for r in rows:
			var line := "y%03d " % int(float(r) / float(rows) * size.y)
			for c in cols:
				var px := Vector2(
					(float(c) + 0.5) / float(cols) * size.x,
					(float(r) + 0.5) / float(rows) * size.y
				)
				var hit: Dictionary = _pick_ray(cam, px, batches)
				var name: String = String(hit.get("name", ""))
				if not codes.has(name):
					codes[name] = char(next_code)
					next_code += 1
				line += codes[name]
			print(line)
		print("legend:")
		for name in codes:
			print("  %s = %s" % [codes[name], name if name != "" else "VOID"])
		# World positions for a few cells, so distances are checkable.
		for r in [int(rows * 0.55), int(rows * 0.7), int(rows * 0.9)]:
			for c in [int(cols * 0.35), int(cols * 0.5), int(cols * 0.65)]:
				var px := Vector2(
					(float(c) + 0.5) / float(cols) * size.x,
					(float(r) + 0.5) / float(rows) * size.y
				)
				var hit: Dictionary = _pick_ray(cam, px, batches)
				print(
					"cell(%d,%d) -> %s" % [c, r, hit]
				)
		var all := batches + mm_batches
		for py in range(60, int(size.y * 0.75), 10):
			var row := "band y%d |" % py
			for px in range(int(size.x * 0.30), int(size.x * 0.55), 12):
				var hit: Dictionary = _pick_ray(cam, Vector2(px, py), all)
				var name := String(hit.get("name", "void"))
				row += " %s@%.0f" % [name, float(hit.get("d", -1.0))]
			print(row)

	func _pick_collect(node: Node, batches: Array, include_mm: bool) -> void:
		if include_mm and node is MultiMeshInstance3D and node.visible and node.multimesh and node.multimesh.mesh:
			var mm: MultiMesh = node.multimesh
			var faces: PackedVector3Array = mm.mesh.get_faces()
			var aabb := mm.mesh.get_aabb()
			var owner := String(node.get_parent().name) if node.get_parent() else "?"
			for i in mm.instance_count:
				var xf: Transform3D = node.global_transform * mm.get_instance_transform(i)
				batches.append(
					{
						"name": "%s/%s#%d@%.0f,%.0f,%.0f" % [
							owner, node.name, i, xf.origin.x, xf.origin.y, xf.origin.z
						],
						"tris": faces,
						"aabb": aabb,
						"xf": xf,
					}
				)
		elif node is MeshInstance3D and node.visible and node.mesh:
			batches.append(
				{
					"name": node.name,
					"tris": node.mesh.get_faces(),
					"aabb": node.mesh.get_aabb(),
					"xf": node.global_transform,
				}
			)
		for child in node.get_children():
			_pick_collect(child, batches, include_mm)

	func _pick_ray(cam: Camera3D, px: Vector2, batches: Array) -> Dictionary:
		var origin := cam.project_ray_origin(px)
		var dir := cam.project_ray_normal(px)
		var best := {}
		var best_t := INF
		for batch in batches:
			var xf: Transform3D = batch["xf"]
			if absf(xf.basis.determinant()) < 1e-9:
				continue
			var inv := xf.affine_inverse()
			var lo := inv * origin
			var ld := inv.basis * dir
			var box: AABB = batch["aabb"]
			if not box.intersects_ray(lo, ld):
				continue
			var tris: PackedVector3Array = batch["tris"]
			var i := 0
			while i < tris.size():
				var hit: Variant = Geometry3D.ray_intersects_triangle(
					lo, ld.normalized(), tris[i], tris[i + 1], tris[i + 2]
				)
				if hit != null:
					var world_hit: Vector3 = xf * hit
					var d: float = origin.distance_to(world_hit)
					if d < best_t:
						best_t = d
						best = {"name": batch["name"], "pos": world_hit, "d": snappedf(d, 0.1)}
				i += 3
		return best

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
