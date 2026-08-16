extends Node3D
## Streams road chunks ahead of the player and drops them behind.

const RoadChunkGD: GDScript = preload("res://scripts/road_chunk.gd")
const RoadPathGD: GDScript = preload("res://scripts/road_path.gd")
const CHUNK_LENGTH: float = 40.0
@export var chunks_ahead: int = 5
@export var chunks_behind: int = 2
## Runtime chunks are built one at a time. setup_incremental() spans many
## frames, so merely limiting how many builds *start* per frame still lets the
## whole ring overlap and pile its expensive stages onto the same frames.

var _chunks: Dictionary = {}
var _player: Node3D
var _path: Node
var _build_in_flight: bool = false
var _props_in_flight: bool = false
var _props_queue: Array[Node3D] = []
var _unload_queue: Array[Node] = []
var _stream_generation: int = 0
var _open_until: int = -1
var _defer_stream: bool = false
## Arriving at the bench shrinks keep from the whole spur to the lake. Freeing
## sixty woodland chunks in one `_process` is a hitch of its own; hide them
## immediately and destroy a couple per frame.
const UNLOADS_PER_FRAME := 2
## One dressed chunk ahead after spawn/R. Six full setups used to hitch the
## first frames; 80 m of trees is enough to look into, the rest streams.
const OPENING_AHEAD := 1
## Dress this near window before far tarmac. Matches how far roadside trees draw.
const DRESS_AHEAD := 3


func _ready() -> void:
	## The start menu pauses the tree. Keep streaming so the title shot and the
	## first frame of a ride are not a bare ribbon.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_path = get_node("/root/RoadPath")


func bind_player(player: Node3D) -> void:
	_player = player
	# Only the road under the bike blocks startup. The next chunk immediately
	# enters the incremental queue; synchronously rebuilding two dense scenic
	# chunks was the remaining restart hitch.
	var current: int = int(floor(_player.track_z / CHUNK_LENGTH))
	if not _chunks.has(current):
		_spawn(current, false)
	_arm_opening(current)
	_defer_stream = true


func reset_world() -> void:
	## Snap the loaded ring onto the bike. Restart randomizes the world seed, so
	## every previously streamed chunk is the wrong biome and has to go. Only the
	## road under the bike is built this frame; the rest of the ring fills
	## incrementally — two dense setups here were the hitch.
	_stream_generation += 1
	_build_in_flight = false
	_props_in_flight = false
	_props_queue.clear()
	_open_until = -1
	for dropped in _unload_queue:
		if is_instance_valid(dropped):
			dropped.free()
	_unload_queue.clear()
	for chunk in _chunks.values():
		if is_instance_valid(chunk):
			(chunk as Node).free()
	_chunks.clear()
	if _player == null:
		return
	var current: int = int(floor(_player.track_z / CHUNK_LENGTH))
	_spawn(current, false)
	_arm_opening(current)
	_defer_stream = true


func _process(_delta: float) -> void:
	if _player == null:
		return
	# Spawn already paid for the chunk under the bike this frame. Starting the
	# opening dress on the same tick doubled the hitch at boot and on R.
	if _defer_stream:
		_defer_stream = false
		return
	_sync(false)


func theme_at(z: float) -> int:
	return theme_for_chunk(int(floor(z / CHUNK_LENGTH)))


func theme_for_chunk(index: int) -> int:
	if _path and _path.has_method("theme_for_chunk"):
		return int(_path.call("theme_for_chunk", index))
	return RoadChunkGD.Env.COUNTRY


func _sync(build_all: bool) -> void:
	var current: int = int(floor(_player.track_z / CHUNK_LENGTH))
	var keep_bounds := _desired_bounds(current)
	var keep_min: int = keep_bounds.x
	var keep_max: int = keep_bounds.y
	var build_bounds := _desired_build_bounds(current)
	var build_min: int = maxi(build_bounds.x, keep_min)
	var build_max: int = mini(build_bounds.y, keep_max)

	for i in _chunks.keys():
		if int(i) < keep_min or int(i) > keep_max:
			var dropped: Node = _chunks[i]
			_chunks.erase(i)
			if dropped is Node3D:
				_props_queue.erase(dropped as Node3D)
			if is_instance_valid(dropped):
				if build_all:
					dropped.free()
				else:
					(dropped as Node3D).visible = false
					_unload_queue.append(dropped)
	if not build_all:
		_drain_unloads()

	if build_all:
		for i in range(build_min, build_max + 1):
			if not _chunks.has(i):
				_spawn(i, false)
		return
	if _fill_opening(current, build_max):
		return
	var dress_max := mini(current + DRESS_AHEAD, build_max)
	var near_missing := _first_missing(current, dress_max)
	var near_undressed := _queued_props_between(current, dress_max)
	# Ribbons and props are independent queues for far scenery. Inside the
	# look-ahead window a chunk is not done until it has trees — otherwise the
	# rider stares at bare tarmac. Finish that window before spending frames on
	# far ribbon.
	if not _build_in_flight:
		if near_missing >= 0:
			_build_in_flight = true
			_spawn_dressed_incremental(near_missing, _stream_generation)
		elif not near_undressed:
			var next := _nearest_missing(current, build_min, build_max)
			if next >= 0:
				_build_in_flight = true
				_spawn_incremental(next, _stream_generation)
	if not _build_in_flight and not _props_in_flight and not _props_queue.is_empty():
		_props_in_flight = true
		_build_next_props(_stream_generation)


func _arm_opening(current: int) -> void:
	_open_until = current + OPENING_AHEAD


func _fill_opening(current: int, build_max: int) -> bool:
	## One fully dressed chunk on the frame after spawn, not six. That used to
	## hitch boot by rebuilding a whole look-ahead of forest in the first ticks.
	if _open_until < 0:
		return false
	for i in range(current + 1, _open_until + 1):
		if i > build_max:
			break
		if not _chunks.has(i):
			_spawn(i, false)
			return true
	_open_until = -1
	return false


func _first_missing(min_i: int, max_i: int) -> int:
	for i in range(min_i, max_i + 1):
		if not _chunks.has(i):
			return i
	return -1


func _queued_props_between(min_i: int, max_i: int) -> bool:
	for chunk in _props_queue:
		if not is_instance_valid(chunk):
			continue
		var index := int(chunk.get("chunk_index"))
		if index >= min_i and index <= max_i:
			return true
	return false


func _drain_unloads() -> void:
	var n := 0
	while n < UNLOADS_PER_FRAME and not _unload_queue.is_empty():
		var dropped: Node = _unload_queue.pop_front()
		if is_instance_valid(dropped):
			dropped.free()
		n += 1


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


func _desired_build_bounds(current: int) -> Vector2i:
	## Building and retaining answer different questions on a scenic spur.
	##
	## Retention spans both junctions so a glance back never exposes an unloaded
	## road. Construction stays around the rider: expanding the build queue to the
	## retention window committed all 3.36 km (roughly 84 woodland chunks) in one
	## instant. Chunks already passed remain alive through `_desired_bounds()`.
	return Vector2i(maxi(current - chunks_behind, 0), current + chunks_ahead)


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


func _spawn_dressed_incremental(index: int, generation: int) -> void:
	var chunk: Node3D = RoadChunkGD.new() as Node3D
	chunk.name = "Chunk%d" % index
	add_child(chunk)
	_chunks[index] = chunk
	await chunk.call("setup_incremental", index, theme_for_chunk(index))
	if generation != _stream_generation:
		return
	_build_in_flight = false


func _spawn_incremental(index: int, generation: int) -> void:
	var chunk: Node3D = RoadChunkGD.new() as Node3D
	chunk.name = "Chunk%d" % index
	add_child(chunk)
	_chunks[index] = chunk
	# Make the riding surface for the whole nearby ring before decorating it.
	# Serializing ribbon + props per chunk let a 50-frame lake build block every
	# road behind it, so a fast rider reached chunks whose tarmac did not exist.
	await chunk.call("setup_ribbon_incremental", index, theme_for_chunk(index))
	if generation != _stream_generation:
		return
	_build_in_flight = false
	if is_instance_valid(chunk) and chunk.is_inside_tree():
		_props_queue.append(chunk)


func _build_next_props(generation: int) -> void:
	while not _props_queue.is_empty():
		var chunk: Node3D = _take_nearest_props()
		if chunk == null:
			break
		if not is_instance_valid(chunk) or not chunk.is_inside_tree():
			continue
		await chunk.call("setup_props_incremental")
		if generation != _stream_generation:
			return
		break
	if generation == _stream_generation:
		_props_in_flight = false


func _take_nearest_props() -> Node3D:
	## Plant what the camera is about to see. FIFO dressed the oldest (often
	## already behind the bike) while the road ahead stayed bare.
	if _props_queue.is_empty() or _player == null:
		return _props_queue.pop_front() if not _props_queue.is_empty() else null
	var current: int = int(floor(_player.track_z / CHUNK_LENGTH))
	var best_i := -1
	var best_d := INF
	for i in _props_queue.size():
		var chunk: Node3D = _props_queue[i]
		if not is_instance_valid(chunk):
			continue
		var index := int(chunk.get("chunk_index"))
		var d: float = float(index - current) if index >= current else 1000.0 + float(current - index)
		if d < best_d:
			best_d = d
			best_i = i
	if best_i < 0:
		return _props_queue.pop_front()
	var chosen: Node3D = _props_queue[best_i]
	_props_queue.remove_at(best_i)
	return chosen
