extends Node3D
## Keeps a bounded population of traffic on the road ahead of the bike.
##
## Density still comes from difficulty, but *what kind of road this stretch is*
## comes from a mood: a long band along z, hashed from the world seed. Same seed,
## same weather. The rider should be able to feel a quiet few kilometres, then a
## wall of vans, rather than a uniform sprinkle.

const TrafficCarGD: GDScript = preload("res://scripts/traffic_car.gd")

@export var max_active: int = 17
@export var spawn_ahead_min: float = 115.0
@export var spawn_ahead_max: float = 320.0
@export var despawn_behind: float = 45.0
@export var spawn_interval: float = 0.68
@export var first_spawn_delay: float = 3.0
## Minimum gap to any car already in a nearby lane, so nothing pops in on top
## of something else.
@export var min_gap: float = 27.0
## Keep a useful reaction window at 200 km/h. Cars are never inserted directly
## into the rider's immediate view, and the lane check below includes vehicle
## length rather than comparing centre points only.
@export var player_reaction_distance: float = 125.0

var _player: Node3D
var _cars: Array[Node3D] = []
var _timer: float = 0.0
var _rng := RandomNumberGenerator.new()
var _path: Node
var difficulty: int = 1
var pack_chance: float = 0.18
var _scenic_quiet: bool = false

## Traffic weather along the route. Indexed in this order by the mood tables.
enum Mood { CLEAR, FLOW, PACK, CRAWL, WALL }

const MOOD_COUNT := 5
## Long enough to read, not a new mood every corner. Each band hashes to a length
## in this range so a run is not a metronome of identical stretches.
const MOOD_BAND_MIN := 900.0
const MOOD_BAND_MAX := 1800.0

# Kind weights, in Kind order: mostly cars, a working truck or van in the mix,
# the odd lorry or bus to block a lane. Indexed by Kind, so reordering the enum
# without reordering this row would quietly change what the road is made of.
# FLOW keeps this mix; the other moods reweight the same seven silhouettes.
const KIND_WEIGHTS := [0.24, 0.19, 0.09, 0.15, 0.14, 0.11, 0.08]
const MOOD_KIND_WEIGHTS := [
	[0.38, 0.30, 0.18, 0.08, 0.04, 0.015, 0.005],  # CLEAR: a breath of light cars
	[0.24, 0.19, 0.09, 0.15, 0.14, 0.11, 0.08],  # FLOW: the default mix
	[0.28, 0.22, 0.12, 0.14, 0.12, 0.07, 0.05],  # PACK: cars travelling together
	[0.06, 0.05, 0.03, 0.10, 0.22, 0.28, 0.26],  # CRAWL: vans, trucks, buses
	[0.10, 0.08, 0.05, 0.30, 0.28, 0.12, 0.07],  # WALL: vans and pickups
]
const MOOD_INTERVAL_MUL := [1.9, 1.0, 0.85, 1.15, 0.58]
const MOOD_GAP_MUL := [1.7, 1.0, 0.92, 1.25, 0.68]
const MOOD_PACK_MUL := [0.0, 1.0, 2.4, 0.35, 1.35]
const MOOD_ACTIVE_MUL := [0.5, 1.0, 1.0, 0.75, 1.2]
const MOOD_SPEED_MUL := [1.06, 1.0, 0.96, 0.68, 0.88]
## Cruise range per kind (m/s). Light cars run fastest, the coupe fastest of all;
## anything heavy is slow enough to be a readable overtaking target rather than a
## wall moving at the rider's own speed.
const KIND_SPEEDS := [
	Vector2(23.0, 36.0),
	Vector2(22.0, 34.0),
	Vector2(29.0, 41.0),
	Vector2(19.0, 31.0),
	Vector2(18.0, 29.0),
	Vector2(14.0, 24.0),
	Vector2(14.0, 23.0),
]


func _ready() -> void:
	_path = get_node_or_null("/root/RoadPath")
	_seed_from_world()
	_timer = first_spawn_delay


func bind_player(player: Node3D) -> void:
	_player = player
	_seed_from_world()


func set_difficulty(level: int) -> void:
	difficulty = clampi(level, 0, 2)
	match difficulty:
		0:
			max_active = 10
			spawn_interval = 1.05
			player_reaction_distance = 155.0
			min_gap = 34.0
			pack_chance = 0.08
		1:
			max_active = 17
			spawn_interval = 0.68
			player_reaction_distance = 125.0
			min_gap = 27.0
			pack_chance = 0.18
		_:
			max_active = 24
			spawn_interval = 0.44
			player_reaction_distance = 100.0
			min_gap = 21.0
			pack_chance = 0.30
	reset_world()


func reset_world() -> void:
	_scenic_quiet = false
	for car in _cars:
		if is_instance_valid(car):
			car.free()
	_cars.clear()
	_seed_from_world()
	_timer = first_spawn_delay


func _player_on_scenic() -> bool:
	if _player == null:
		return false
	if _path == null:
		_path = get_node_or_null("/root/RoadPath")
	if _path == null or not _path.has_method("on_spur"):
		return false
	return bool(_path.on_spur(_player.track_z, _player.lateral))


func _clear_cars() -> void:
	for car in _cars:
		if is_instance_valid(car):
			car.free()
	_cars.clear()


func _seed_from_world() -> void:
	if _path == null:
		_path = get_node_or_null("/root/RoadPath")
	var seed := 1
	if _path:
		seed = int(_path.world_seed)
	_rng.seed = seed


func _world_seed() -> int:
	if _path == null:
		_path = get_node_or_null("/root/RoadPath")
	return int(_path.world_seed) if _path else 1


func _mood_index(mood: int) -> int:
	return clampi(mood, 0, MOOD_COUNT - 1)


func _band_length_at(index: int, seed: int) -> float:
	var extra := int(MOOD_BAND_MAX - MOOD_BAND_MIN)
	return MOOD_BAND_MIN + float(posmod(hash(Vector3i(index, seed, 17)), extra + 1))


func _band_index_at(z: float, seed: int) -> int:
	var z_pos := maxf(z, 0.0)
	var idx := 0
	var end := 0.0
	while idx <= 200000:
		end += _band_length_at(idx, seed)
		if z_pos < end:
			break
		idx += 1
	return idx


func mood_at(z: float) -> int:
	## Deterministic weather at this point on the route. Spawn reads the mood at
	## the car's z (ahead of the rider), not at the bike, so the band you are
	## riding into is the one that appears ahead.
	var seed := _world_seed()
	return posmod(hash(Vector3i(_band_index_at(z, seed), seed, 41)), MOOD_COUNT)


func kind_weights_for(mood: int) -> Array:
	return MOOD_KIND_WEIGHTS[_mood_index(mood)]


func mood_interval_mul(mood: int) -> float:
	return float(MOOD_INTERVAL_MUL[_mood_index(mood)])


func mood_min_gap_mul(mood: int) -> float:
	return float(MOOD_GAP_MUL[_mood_index(mood)])


func mood_pack_mul(mood: int) -> float:
	return float(MOOD_PACK_MUL[_mood_index(mood)])


func mood_speed_mul(mood: int) -> float:
	return float(MOOD_SPEED_MUL[_mood_index(mood)])


func mood_active_cap(mood: int) -> int:
	return maxi(3, int(round(float(max_active) * float(MOOD_ACTIVE_MUL[_mood_index(mood)]))))


func _process(delta: float) -> void:
	if _player == null:
		return
	if _player_on_scenic():
		if not _scenic_quiet:
			_clear_cars()
			_scenic_quiet = true
		return
	_scenic_quiet = false
	_cleanup()
	_timer -= delta
	if _timer > 0.0:
		return
	# Probe the stretch about to be populated, not the tarmac under the bike.
	var probe_z: float = _player.track_z + maxf(spawn_ahead_min, player_reaction_distance)
	var mood := mood_at(probe_z)
	_timer = spawn_interval * mood_interval_mul(mood) * _rng.randf_range(0.7, 1.5)
	var cap := mood_active_cap(mood)
	var pack := _pack_size_for(mood)
	var anchor_z := NAN
	var anchor_lane := -1
	for _i in pack:
		if _cars.size() >= cap:
			break
		var placed := _try_spawn(anchor_z, anchor_lane)
		if placed.x >= 0.0:
			anchor_z = placed.x
			anchor_lane = int(placed.y)


func _pack_size_for(mood: int) -> int:
	if _rng.randf() >= pack_chance * mood_pack_mul(mood):
		return 1
	match mood:
		Mood.PACK:
			return 3 if _rng.randf() < 0.55 else 2
		Mood.WALL:
			return 2
		_:
			return 2


func _pick_kind(weights: Array) -> int:
	var roll := _rng.randf()
	var acc := 0.0
	for i in weights.size():
		acc += float(weights[i])
		if roll < acc:
			return i
	return 0


func _try_spawn(anchor_z: float = NAN, anchor_lane: int = -1) -> Vector2:
	var z_min: float = _player.track_z + player_reaction_distance
	var ahead_min := maxf(spawn_ahead_min, player_reaction_distance)
	var ahead_max := maxf(spawn_ahead_max, ahead_min + 1.0)
	var z: float
	var lane: int
	if is_nan(anchor_z):
		z = _player.track_z + _rng.randf_range(ahead_min, ahead_max)
		lane = _rng.randi_range(0, _path.LANE_COUNT - 1)
	else:
		# Convoy members sit a readable gap ahead of the last car, usually the
		# same lane, sometimes the neighbour — still overtakeable as a group.
		var probe_mood := mood_at(anchor_z)
		var convoy_gap := min_gap * mood_min_gap_mul(probe_mood)
		z = anchor_z + _rng.randf_range(convoy_gap * 0.9, convoy_gap * 1.35)
		lane = anchor_lane
		if _rng.randf() > 0.72:
			var step := 1 if _rng.randf() < 0.5 else -1
			lane = clampi(anchor_lane + step, 0, _path.LANE_COUNT - 1)
	if z < z_min or z > _player.track_z + ahead_max:
		return Vector2(-1.0, -1.0)

	var mood := mood_at(z)
	var gap := min_gap * mood_min_gap_mul(mood)
	var lane_x: float = _path.lane_x(lane)

	for c in _cars:
		if absf(c.track_z - z) < gap and absf(c.lateral - lane_x) < 2.3:
			return Vector2(-1.0, -1.0)

	var kind := _pick_kind(kind_weights_for(mood))
	var band: Vector2 = KIND_SPEEDS[kind]
	var speed_mul := mood_speed_mul(mood)
	var speed := _rng.randf_range(band.x, band.y) * speed_mul
	var car: Node3D = TrafficCarGD.new() as Node3D
	add_child(car)
	car.call("setup", kind, lane, z, speed, _rng.randi_range(0, 9))
	car.call("set_player", _player)
	_cars.append(car)
	return Vector2(z, float(lane))


func _cleanup() -> void:
	var pz: float = _player.track_z
	var kept: Array[Node3D] = []
	for c in _cars:
		if not is_instance_valid(c):
			continue
		if c.track_z < pz - despawn_behind or c.track_z > pz + spawn_ahead_max + 120.0:
			c.queue_free()
		else:
			kept.append(c)
	_cars = kept
