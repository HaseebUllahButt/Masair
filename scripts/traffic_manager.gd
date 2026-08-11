extends Node3D
## Keeps a bounded population of traffic on the road ahead of the bike.

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

# Kind weights, in Kind order: mostly cars, a working truck or van in the mix,
# the odd lorry or bus to block a lane. Indexed by Kind, so reordering the enum
# without reordering this row would quietly change what the road is made of.
const KIND_WEIGHTS := [0.24, 0.19, 0.09, 0.15, 0.14, 0.11, 0.08]
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
	_rng.randomize()
	_timer = first_spawn_delay
	_path = get_node("/root/RoadPath")


func bind_player(player: Node3D) -> void:
	_player = player


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
	for car in _cars:
		if is_instance_valid(car):
			car.free()
	_cars.clear()
	_timer = first_spawn_delay


func _process(delta: float) -> void:
	if _player == null:
		return
	_cleanup()
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = spawn_interval * _rng.randf_range(0.7, 1.5)
	# Pairs and the odd triple keep the road busy without every gap being a wall.
	var pack: int = 2 if _rng.randf() < pack_chance else 1
	for _i in pack:
		if _cars.size() >= max_active:
			break
		_try_spawn()


func _pick_kind() -> int:
	var roll := _rng.randf()
	var acc := 0.0
	for i in KIND_WEIGHTS.size():
		acc += KIND_WEIGHTS[i]
		if roll < acc:
			return i
	return 0


func _try_spawn() -> void:
	var z: float = _player.track_z + _rng.randf_range(maxf(spawn_ahead_min, player_reaction_distance), spawn_ahead_max)
	var lane: int = _rng.randi_range(0, _path.LANE_COUNT - 1)
	var lane_x: float = _path.lane_x(lane)

	for c in _cars:
		if absf(c.track_z - z) < min_gap and absf(c.lateral - lane_x) < 2.3:
			return

	var kind := _pick_kind()
	var band: Vector2 = KIND_SPEEDS[kind]
	var speed := _rng.randf_range(band.x, band.y)
	var car: Node3D = TrafficCarGD.new() as Node3D
	add_child(car)
	car.call("setup", kind, lane, z, speed, _rng.randi_range(0, 9))
	car.call("set_player", _player)
	_cars.append(car)


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
