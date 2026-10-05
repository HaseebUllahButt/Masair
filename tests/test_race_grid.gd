extends SceneTree
## Regression: racers start in separate lanes and survive the green light.
##
##   godot --headless --path . --script res://tests/test_race_grid.gd
##
## Every rider used to start on the centreline at kilometre zero. Riders crash
## into each other on purpose, so once the one-second start grace ran out the
## field killed itself. This checks the grid itself, then rides a local bike
## beside a remote rider from the line: on the grid both survive, and two bikes
## sharing the old single start spot still crash — collisions are not switched off.

const MainScene := preload("res://scenes/main.tscn")
const GameManagerGD := preload("res://scripts/game_manager.gd")
const RemoteRiderGD := preload("res://scripts/remote_rider.gd")
const SEED := 1649388791
## Long enough to outlast the start grace (motorcycle invuln_time, 1 s).
const RIDE_FRAMES := 240

var failures: int = 0
var frames: int = 0
var game: Node
var main: Node
var player: Node
var remote: Node3D
var phase := 0
var phase_start := 0
var remote_lateral := 0.0


func check(ok: bool, what: String) -> void:
	if not ok:
		failures += 1
		print("FAIL: ", what)


func _check_grid() -> void:
	const MAX_LATERAL := 7.1
	# Bikes overlap inside (0.42 + 0.42) * 0.82 of each other; keep well clear.
	const CLEAR := 1.2
	for count in range(1, 9):
		var lats: Array[float] = []
		for slot in count:
			var lat: float = GameManagerGD.grid_lateral(slot, count, MAX_LATERAL)
			check(absf(lat) <= MAX_LATERAL, "grid %d/%d stays on the road (%.2f)" % [slot, count, lat])
			lats.append(lat)
		for i in count:
			for j in range(i + 1, count):
				check(absf(lats[i] - lats[j]) >= CLEAR, "grid %d and %d of %d start apart" % [i, j, count])
	check(is_zero_approx(GameManagerGD.grid_lateral(0, 1, MAX_LATERAL)), "a solo race starts on the centreline")


func _hold_traffic() -> void:
	## Only the two riders under test; a stray car would make the result luck.
	var traffic := main.get_node_or_null("TrafficManager")
	if traffic:
		traffic.process_mode = Node.PROCESS_MODE_DISABLED
	for car in get_nodes_in_group("traffic"):
		if car != remote:
			car.queue_free()


func _start(grid: Vector2i, other_lateral: float) -> void:
	game.begin_race(SEED, grid)
	_hold_traffic()
	remote_lateral = other_lateral
	if remote == null:
		remote = RemoteRiderGD.new()
		remote.name = "GridTestRider"
		main.add_child(remote)
	_pose()
	phase_start = frames


func _pose() -> void:
	# Level with the local bike, in its own start position, at the same speed.
	remote.apply_pose([
		float(player.track_z), remote_lateral, 0.0, 0.0, 0.0, float(player.speed), 1.0, float(player.track_z)
	])


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 1:
		_check_grid()
		game = root.get_node("GameManager")
		main = MainScene.instantiate()
		root.add_child(main)
		current_scene = main
		return false
	if frames == 10:
		player = main.get_node("Player")
		# Two riders: this client is slot 0, the remote rider holds slot 1.
		var max_lateral: float = float(player.max_lateral)
		_start(Vector2i(0, 2), GameManagerGD.grid_lateral(1, 2, max_lateral))
		check(
			absf(float(player.lateral) - GameManagerGD.grid_lateral(0, 2, max_lateral)) < 0.05,
			"the race start puts this rider in its grid lane (%.2f)" % float(player.lateral)
		)
		phase = 1
		return false
	if phase == 0:
		return false
	_hold_traffic()
	_pose()
	if frames - phase_start < RIDE_FRAMES:
		return false
	if phase == 1:
		check(bool(player.alive), "two riders on the grid both ride away from the line")
		check(float(player.track_z) > 5.0, "the grid race actually moved (%.1f m)" % float(player.track_z))
		# The old start: everyone on the one spot. Rider collisions must still bite.
		_start(Vector2i(0, 1), 0.0)
		phase = 2
		return false
	check(not bool(player.alive), "riders sharing one start spot still collide")
	game.end_race()
	print("race grid self-check: %d failures" % failures)
	quit(1 if failures > 0 else 0)
	return false
