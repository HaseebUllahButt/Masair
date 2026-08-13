extends Node3D
## Streams road chunks ahead of the player and drops them behind.

const RoadChunkGD: GDScript = preload("res://scripts/road_chunk.gd")
const RoadPathGD: GDScript = preload("res://scripts/road_path.gd")
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
	## Snap the loaded ring onto the bike. Restart randomizes the world seed, so
	## every previously streamed chunk is the wrong biome and has to go. Only the
	## road under the bike is built this frame; the rest of the ring fills
	## incrementally — two dense setups here were the hitch.
	_stream_generation += 1
	_build_in_flight = false
	for chunk in _chunks.values():
		if is_instance_valid(chunk):
			(chunk as Node).free()
	_chunks.clear()
	if _player == null:
		return
	var current: int = int(floor(_player.track_z / CHUNK_LENGTH))
	_spawn(current, false)


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
	var bounds := _desired_bounds(current)
	var min_i: int = bounds.x
	var max_i: int = bounds.y

	for i in _chunks.keys():
		if int(i) < min_i or int(i) > max_i:
			var dropped: Node = _chunks[i]
			_chunks.erase(i)
			if is_instance_valid(dropped):
				if build_all:
					dropped.free()
				else:
					dropped.queue_free()

	if build_all:
		for i in range(min_i, max_i + 1):
			if not _chunks.has(i):
				_spawn(i, false)
	elif not _build_in_flight:
		var next := _nearest_missing(current, min_i, max_i)
		if next >= 0:
			_build_in_flight = true
			_spawn_incremental(next, _stream_generation)


func _desired_bounds(current: int) -> Vector2i:
	var min_i := maxi(current - chunks_behind, 0)
	var max_i := current + chunks_ahead
	if _path and _path.has_method("on_spur") and _path.call("on_spur", _player.track_z, _player.lateral):
		# Keep the complete authored spur once the rider commits to it. The road is
		# 3.36 km end-to-end; the old fixed 600 m ring freed its two ends while the
		# player was still on it, so looking back showed the route ending in empty sky.
		#
		# At the platform the camera looks at the lake, not back down the spur.
		# Loading both junctions here paid for fifty chunks of trees the view never
		# sees, which is most of why the overlook stuttered.
		var centre: float = float(_path.call("viewpoint_centre_for", _player.track_z))
		var half_span: float = RoadPathGD.SPUR_HALF_SPAN
		if _path.has_method("at_platform") and bool(_path.call("at_platform", _player.track_z, _player.lateral)):
			half_span = RoadPathGD.LAKE_SPAN + 180.0
		min_i = maxi(floori((centre - half_span) / CHUNK_LENGTH) - 1, 0)
		max_i = ceili((centre + half_span) / CHUNK_LENGTH) + 1
	return Vector2i(min_i, max_i)


func _nearest_missing(current: int, min_i: int, max_i: int) -> int:
	## Build what can enter the camera first. Iterating from min_i made a scenic
	## expansion construct its far end while a nearby empty chunk was visible.
	var radius := 0
	var furthest := maxi(current - min_i, max_i - current)
	while radius <= furthest:
		var ahead := current + radius
		if ahead <= max_i and not _chunks.has(ahead):
			return ahead
		var behind := current - radius
		if radius > 0 and behind >= min_i and not _chunks.has(behind):
			return behind
		radius += 1
	return -1


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
	if generation != _stream_generation:
		return
	_build_in_flight = false
