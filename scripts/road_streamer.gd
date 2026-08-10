extends Node3D
## Streams road chunks ahead of the player and drops them behind.

const RoadChunkGD: GDScript = preload("res://scripts/road_chunk.gd")
const CHUNK_LENGTH: float = 40.0
@export var chunks_ahead: int = 9
@export var chunks_behind: int = 2
## Runtime chunks are built one at a time. setup_incremental() spans many
## frames, so merely limiting how many builds *start* per frame still lets the
## whole ring overlap and pile its expensive stages onto the same frames.

var _chunks: Dictionary = {}
var _player: Node3D
var _path: Node
var _build_in_flight: bool = false
var _stream_generation: int = 0


func _ready() -> void:
	_path = get_node("/root/RoadPath")


func bind_player(player: Node3D) -> void:
	_player = player
	# Only the road under the bike blocks startup. The next chunk immediately
	# enters the incremental queue; synchronously rebuilding two dense scenic
	# chunks was the remaining restart hitch.
	var current: int = int(floor(_player.track_z / CHUNK_LENGTH))
	if not _chunks.has(current):
		_spawn(current, false)
	_sync(false)


func reset_world() -> void:
	# Invalidate a suspended incremental build before freeing its chunk. Its
	# coroutine may resume after a process-frame await, but it must not unlock a
	# newer generation's build queue.
	_stream_generation += 1
	_build_in_flight = false
	for chunk in _chunks.values():
		if is_instance_valid(chunk):
			(chunk as Node).free()
	_chunks.clear()
	if _player:
		bind_player(_player)
		_sync(true)


func _process(_delta: float) -> void:
	if _player:
		_sync(false)


func theme_at(z: float) -> int:
	return theme_for_chunk(int(floor(z / CHUNK_LENGTH)))


func theme_for_chunk(index: int) -> int:
	if _path and _path.has_method("theme_for_chunk"):
		return int(_path.call("theme_for_chunk", index))
	return RoadChunkGD.Env.COUNTRY


func _sync(build_all: bool) -> void:
	var current: int = int(floor(_player.track_z / CHUNK_LENGTH))
	var behind: int = chunks_behind
	var ahead: int = chunks_ahead
	if _path and _path.has_method("on_spur") and _path.call("on_spur", _player.track_z, _player.lateral):
		# On a viewpoint spur the rider stops, gets off and turns round. Two
		# chunks of history is fine at 200 km/h and absurd standing still: the
		# road they just rode up would end in mid-air behind them.
		behind = 9
		# Near the destination the landscape, not only the road, has to exist around
		# the player.  The lake is just over a kilometre long; the normal riding ring
		# loaded only 360 m each way and cut its water, far shore and range into hard
		# triangular ends inside the reward view.  Expand only for the final approach
		# and platform, while the incremental builder keeps the extra chunks spread
		# over frames.
		var centre: float = float(_path.call("viewpoint_centre_for", _player.track_z))
		if absf(_player.track_z - centre) < 620.0:
			behind = 15
			ahead = 15
	var min_i: int = maxi(current - behind, 0)
	var max_i: int = current + ahead

	for i in range(min_i, max_i + 1):
		if _chunks.has(i):
			continue
		if build_all:
			_spawn(i, false)
		elif not _build_in_flight:
			_build_in_flight = true
			_spawn_incremental(i, _stream_generation)
		# Never start a second coroutine while the first one is yielding through
		# its ribbon and MultiMesh stages.
		if not build_all:
			break

	for i in _chunks.keys():
		if int(i) < min_i or int(i) > max_i:
			(_chunks[i] as Node).queue_free()
			_chunks.erase(i)


func _spawn(index: int, incremental: bool) -> void:
	var chunk: Node3D = RoadChunkGD.new() as Node3D
	chunk.name = "Chunk%d" % index
	add_child(chunk)
	_chunks[index] = chunk
	if incremental:
		chunk.call("setup_incremental", index, theme_for_chunk(index))
	else:
		chunk.call("setup", index, theme_for_chunk(index))


func _spawn_incremental(index: int, generation: int) -> void:
	var chunk: Node3D = RoadChunkGD.new() as Node3D
	chunk.name = "Chunk%d" % index
	add_child(chunk)
	_chunks[index] = chunk
	await chunk.call("setup_incremental", index, theme_for_chunk(index))
	if generation == _stream_generation:
		_build_in_flight = false
