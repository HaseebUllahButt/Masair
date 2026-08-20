extends Node3D
## Streams road chunks ahead of the player and drops them behind.

const RoadChunkGD: GDScript = preload("res://scripts/road_chunk.gd")
const RoadPathGD: GDScript = preload("res://scripts/road_path.gd")
const CHUNK_LENGTH: float = 40.0
@export var chunks_ahead: int = 14
@export var chunks_behind: int = 2
## Runtime chunks are built one at a time. setup_incremental() spans many
## frames, so merely limiting how many builds *start* per frame still lets the
## whole ring overlap and pile its expensive stages onto the same frames.
## Ribbon slices are cheap enough to run beside one dress job; that keeps the
## road out in front of the camera without waiting for every tree to land.

var _chunks: Dictionary = {}
var _player: Node3D
var _path: Node
var _build_in_flight: bool = false
var _props_in_flight: bool = false
var _props_queue: Array[Node3D] = []
var _scenic_queue: Array[Node3D] = []
var _highway_queue: Array[Node3D] = []
var _unload_queue: Array[Node] = []
var _stream_generation: int = 0
var _open_until: int = -1
var _defer_stream: bool = false
var _scenic_in_flight: bool = false
var _highway_in_flight: bool = false
var _corridor_key: int = -1
var _idle_current: int = -1
## Arriving at the bench shrinks keep from the whole spur to the lake. Freeing
## sixty woodland chunks in one `_process` is a hitch of its own; hide them
## immediately and destroy a couple per frame.
const UNLOADS_PER_FRAME := 2
## Two fully dressed chunks after spawn/R so the opening shot is not a bare
## ribbon with props popping in twenty metres out.
const OPENING_AHEAD := 2
## Dress this far ahead of the bike so the corridor looks finished before it
## enters the lens. Too tight and the ride reads as pop-in / procedural.
const DRESS_AHEAD := 10
## Ribbon look-ahead on the scenic spur — must stay ahead of DRESS_AHEAD so
## tarmac is ready when the dress window wants to plant.
const SCENIC_CHUNKS_AHEAD := 12
## How far behind the bike spur terrain stays loaded while riding.
const SCENIC_KEEP_BEHIND := 7
## Keep this many strips of tarmac in the pipeline even while trees plant.
## Tighter than this and top speed watches the road appear.
const RIBBON_PRIORITY_AHEAD := 10
## Spur divergence at which the unused path is culled. Below this, both the
## exit and the highway stay drawn so the junction remains readable.
const CORRIDOR_COMMIT := RoadPathGD.CORRIDOR_COMMIT


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
	_scenic_in_flight = false
	_highway_in_flight = false
	_props_queue.clear()
	_scenic_queue.clear()
	_highway_queue.clear()
	_open_until = -1
	_corridor_key = -1
	_idle_current = -1
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
	var busy := (
		_build_in_flight or _props_in_flight or _scenic_in_flight or _highway_in_flight
	)
	if (
		not build_all
		and not busy
		and current == _idle_current
		and _props_queue.is_empty()
		and _scenic_queue.is_empty()
		and _highway_queue.is_empty()
		and _unload_queue.is_empty()
		and _open_until < 0
		and _nearest_missing(current, build_min, build_max) < 0
		and not _has_undressed_nearby(current)
		and not _has_undressed_scenic(current)
		and not _has_undressed_highway(current)
	):
		_apply_corridor()
		return
	_idle_current = -1

	for i in _chunks.keys():
		if int(i) < keep_min or int(i) > keep_max:
			var dropped: Node = _chunks[i]
			_chunks.erase(i)
			if dropped is Node3D:
				_props_queue.erase(dropped as Node3D)
				_scenic_queue.erase(dropped as Node3D)
				_highway_queue.erase(dropped as Node3D)
			if is_instance_valid(dropped):
				if build_all:
					dropped.free()
				else:
					(dropped as Node3D).visible = false
					_unload_queue.append(dropped)
	if not build_all:
		_drain_unloads()

	_apply_corridor()
	if _player_wants_scenic():
		_enqueue_scenic(current)
	if _player_wants_highway():
		_enqueue_highway(current)

	if build_all:
		for i in range(build_min, build_max + 1):
			if not _chunks.has(i):
				_spawn(i, false)
		return
	if _fill_opening(current, build_max):
		return
	# Ribbons and dressing share the pipeline. Exclusive jobs left either a
	# vanishing road (trees first) or a bare curb (ribbons first). A ribbon
	# slice is one cross-section; it can run beside one dress job after the
	# frame that starts it.
	var started_ribbon := false
	if not _build_in_flight:
		var next := _nearest_missing(current, build_min, build_max)
		var urgent_ribbon := next >= 0 and next <= current + RIBBON_PRIORITY_AHEAD
		if next >= 0 and (
			urgent_ribbon
			or not (
				_has_undressed_nearby(current)
				or _has_undressed_scenic(current)
				or _has_undressed_highway(current)
			)
		):
			_build_in_flight = true
			started_ribbon = true
			# Sync only the hole under the wheels. Syncing current+1 paid an
			# 11–24 ms ribbon hitch every chunk boundary at top speed.
			var under: Node = _chunks.get(current)
			var need_sync := next == current and (
				under == null or under.get_node_or_null("RoadSurface") == null
			)
			if need_sync:
				_spawn_ribbon_sync(next, _stream_generation)
			else:
				_spawn_incremental(next, _stream_generation)
	if not started_ribbon:
		_start_next_dress(current)
	if (
		not _build_in_flight
		and not _props_in_flight
		and not _scenic_in_flight
		and not _highway_in_flight
		and _props_queue.is_empty()
		and _scenic_queue.is_empty()
		and _highway_queue.is_empty()
		and _unload_queue.is_empty()
		and _open_until < 0
	):
		_idle_current = current


func _enqueue_nearby_props(current: int) -> void:
	## Far spur chunks stay ribbon-only until they enter the dress window.
	var dress_max := current + DRESS_AHEAD
	for i in range(maxi(current - 1, 0), dress_max + 1):
		if not _chunks.has(i):
			continue
		var chunk: Node3D = _chunks[i]
		if not is_instance_valid(chunk) or not chunk.is_inside_tree():
			continue
		if bool(chunk.get_meta("props_done", false)):
			continue
		if bool(chunk.get_meta("props_queued", false)):
			continue
		if chunk.get_node_or_null("RoadSurface") == null:
			continue
		chunk.set_meta("props_queued", true)
		var on_spur := bool(chunk.get("_on_spur"))
		chunk.set_meta("highway_requested", _player_wants_highway() or not on_spur)
		if _player_wants_scenic() and on_spur:
			chunk.set_meta("scenic_requested", true)
		_props_queue.append(chunk)


func _start_next_dress(current: int) -> void:
	if _props_in_flight or _scenic_in_flight or _highway_in_flight:
		return
	_enqueue_nearby_props(current)
	if _player_wants_scenic():
		_enqueue_scenic(current)
	if _player_wants_highway():
		_enqueue_highway(current)
	if not _scenic_queue.is_empty():
		_scenic_in_flight = true
		_build_next_scenic(_stream_generation)
	elif not _highway_queue.is_empty():
		_highway_in_flight = true
		_build_next_highway(_stream_generation)
	elif not _props_queue.is_empty():
		_props_in_flight = true
		_build_next_props(_stream_generation)


func _has_undressed_nearby(current: int) -> bool:
	## True when the camera corridor still has bare ribbons waiting for props.
	var dress_max := current + DRESS_AHEAD
	for i in range(maxi(current - 1, 0), dress_max + 1):
		if not _chunks.has(i):
			continue
		var chunk: Node3D = _chunks[i]
		if not is_instance_valid(chunk):
			continue
		if chunk.get_node_or_null("RoadSurface") == null:
			continue
		if bool(chunk.get_meta("props_done", false)):
			continue
		return true
	return false


func _player_wants_scenic() -> bool:
	if _player == null or _path == null or not _path.has_method("on_spur"):
		return false
	return bool(_path.call("on_spur", _player.track_z, _player.lateral))


func _player_committed() -> bool:
	if _player == null or _path == null or not _path.has_method("spur_divergence"):
		return false
	return float(_path.call("spur_divergence", _player.track_z)) >= CORRIDOR_COMMIT


func _player_wants_highway() -> bool:
	return not (_player_wants_scenic() and _player_committed())


func _enqueue_scenic(current: int) -> void:
	var dress_max := current + DRESS_AHEAD
	for i in range(maxi(current - 1, 0), dress_max + 1):
		if not _chunks.has(i):
			continue
		var chunk: Node3D = _chunks[i]
		if not is_instance_valid(chunk) or not chunk.is_inside_tree():
			continue
		if not bool(chunk.get("_on_spur")):
			continue
		if bool(chunk.get_meta("scenic_done", false)):
			continue
		if bool(chunk.get_meta("scenic_queued", false)):
			continue
		if bool(chunk.get_meta("scenic_building", false)):
			continue
		if chunk.get_node_or_null("RoadSurface") == null:
			continue
		chunk.set_meta("scenic_queued", true)
		chunk.set_meta("scenic_requested", true)
		_scenic_queue.append(chunk)


func _has_undressed_scenic(current: int) -> bool:
	if not _player_wants_scenic():
		return false
	var dress_max := current + DRESS_AHEAD
	for i in range(maxi(current - 1, 0), dress_max + 1):
		if not _chunks.has(i):
			continue
		var chunk: Node3D = _chunks[i]
		if not is_instance_valid(chunk):
			continue
		if not bool(chunk.get("_on_spur")):
			continue
		if chunk.get_node_or_null("RoadSurface") == null:
			continue
		if bool(chunk.get_meta("scenic_done", false)):
			continue
		return true
	return false


func _enqueue_highway(current: int) -> void:
	var dress_max := current + DRESS_AHEAD
	for i in range(maxi(current - 1, 0), dress_max + 1):
		if not _chunks.has(i):
			continue
		var chunk: Node3D = _chunks[i]
		if not is_instance_valid(chunk) or not chunk.is_inside_tree():
			continue
		if bool(chunk.get_meta("highway_done", false)):
			continue
		if bool(chunk.get_meta("highway_queued", false)):
			continue
		if bool(chunk.get_meta("highway_building", false)):
			continue
		if chunk.get_node_or_null("RoadSurface") == null:
			continue
		if not bool(chunk.get_meta("props_done", false)):
			continue
		chunk.set_meta("highway_queued", true)
		chunk.set_meta("highway_requested", true)
		_highway_queue.append(chunk)


func _has_undressed_highway(current: int) -> bool:
	if not _player_wants_highway():
		return false
	var dress_max := current + DRESS_AHEAD
	for i in range(maxi(current - 1, 0), dress_max + 1):
		if not _chunks.has(i):
			continue
		var chunk: Node3D = _chunks[i]
		if not is_instance_valid(chunk):
			continue
		if chunk.get_node_or_null("RoadSurface") == null:
			continue
		if not bool(chunk.get_meta("props_done", false)):
			continue
		if bool(chunk.get_meta("highway_done", false)):
			continue
		return true
	return false


func _arm_opening(current: int) -> void:
	_open_until = current + OPENING_AHEAD


func _fill_opening(current: int, build_max: int) -> bool:
	## A short fully-dressed look-ahead after spawn so the first glance is not
	## pop-in. Kept small enough that restart hitch stays tolerable.
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
		var centre: float = float(_path.call("viewpoint_centre_for", _player.track_z))
		if _path.has_method("at_platform") and bool(_path.call("at_platform", _player.track_z, _player.lateral)):
			# Parked on the bench: keep the lake, drop the climb. Fifty woodland
			# chunks behind the eye were most of the overlook stutter.
			var half_span: float = RoadPathGD.LAKE_SPAN + 100.0
			min_i = maxi(floori((centre - half_span) / CHUNK_LENGTH) - 1, 0)
			max_i = ceili((centre + half_span) / CHUNK_LENGTH) + 1
		else:
			# Sliding window while riding. Full-spur retention kept ~80 live
			# terrain meshes and made the climb hitch every frame.
			min_i = maxi(current - SCENIC_KEEP_BEHIND, 0)
			max_i = current + SCENIC_CHUNKS_AHEAD
	return Vector2i(min_i, max_i)


func _desired_build_bounds(current: int) -> Vector2i:
	## Building stays around the rider even on a scenic spur.
	var ahead := chunks_ahead
	var behind := chunks_behind
	if _path and _path.has_method("on_spur") and _path.call("on_spur", _player.track_z, _player.lateral):
		ahead = SCENIC_CHUNKS_AHEAD
		behind = mini(chunks_behind, 2)
	return Vector2i(maxi(current - behind, 0), current + ahead)


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
		# Opening chunks are sync. Skip the unused scenic basin unless the bike
		# is already on the spur — otherwise riding past a turnoff still paid
		# for the lake.
		var include_scenic := _player_wants_scenic()
		var include_highway := _player_wants_highway()
		chunk.call("setup", index, theme_for_chunk(index), include_scenic, include_highway)
		chunk.set_meta("props_done", true)
		if include_scenic:
			chunk.set_meta("scenic_done", true)
		if include_highway:
			chunk.set_meta("highway_done", true)
	_apply_corridor_to(chunk)


func _spawn_ribbon_sync(index: int, generation: int) -> void:
	## Immediate tarmac for the hole under the bike only.
	var chunk: Node3D = RoadChunkGD.new() as Node3D
	chunk.name = "Chunk%d" % index
	add_child(chunk)
	_chunks[index] = chunk
	chunk.call("setup_ribbon", index, theme_for_chunk(index))
	_apply_corridor_to(chunk)
	if generation != _stream_generation:
		return
	_build_in_flight = false


func _spawn_incremental(index: int, generation: int) -> void:
	var chunk: Node3D = RoadChunkGD.new() as Node3D
	chunk.name = "Chunk%d" % index
	add_child(chunk)
	_chunks[index] = chunk
	await chunk.call("setup_ribbon_incremental", index, theme_for_chunk(index))
	if generation != _stream_generation:
		return
	_build_in_flight = false


func _build_next_props(generation: int) -> void:
	while not _props_queue.is_empty():
		var chunk: Node3D = _take_nearest_props()
		if chunk == null:
			break
		if not is_instance_valid(chunk) or not chunk.is_inside_tree():
			continue
		var on_spur := bool(chunk.get("_on_spur"))
		chunk.set_meta("highway_requested", _player_wants_highway() or not on_spur)
		if _player_wants_scenic() and on_spur:
			chunk.set_meta("scenic_requested", true)
		await chunk.call("setup_props_incremental")
		if generation != _stream_generation:
			return
		if is_instance_valid(chunk):
			chunk.set_meta("props_done", true)
			chunk.set_meta("props_queued", false)
			_apply_corridor_to(chunk)
		break
	if generation == _stream_generation:
		_props_in_flight = false


func _take_nearest_props() -> Node3D:
	## Plant what the camera is about to see. FIFO dressed the oldest (often
	## already behind the bike) while the road ahead stayed bare.
	if _props_queue.is_empty() or _player == null:
		return _props_queue.pop_front() if not _props_queue.is_empty() else null
	var current: int = int(floor(_player.track_z / CHUNK_LENGTH))
	var dress_max := current + DRESS_AHEAD
	var best_i := -1
	var best_d := INF
	for i in _props_queue.size():
		var chunk: Node3D = _props_queue[i]
		if not is_instance_valid(chunk):
			continue
		var index := int(chunk.get("chunk_index"))
		if index < current - 1 or index > dress_max:
			continue
		var d: float = float(index - current) if index >= current else 0.5 + float(current - index)
		if d < best_d:
			best_d = d
			best_i = i
	if best_i < 0:
		# Outside the dress window — drop and wait until the rider gets closer.
		_props_queue.clear()
		return null
	var chosen: Node3D = _props_queue[best_i]
	_props_queue.remove_at(best_i)
	return chosen


func _build_next_scenic(generation: int) -> void:
	while not _scenic_queue.is_empty():
		var chunk: Node3D = _take_nearest_scenic()
		if chunk == null:
			break
		if not is_instance_valid(chunk) or not chunk.is_inside_tree():
			continue
		if bool(chunk.get_meta("scenic_done", false)):
			chunk.set_meta("scenic_queued", false)
			continue
		await chunk.call("ensure_scenic_dress")
		if generation != _stream_generation:
			return
		if is_instance_valid(chunk):
			chunk.set_meta("scenic_queued", false)
			_apply_corridor_to(chunk)
		break
	if generation == _stream_generation:
		_scenic_in_flight = false


func _take_nearest_scenic() -> Node3D:
	if _scenic_queue.is_empty() or _player == null:
		return _scenic_queue.pop_front() if not _scenic_queue.is_empty() else null
	var current: int = int(floor(_player.track_z / CHUNK_LENGTH))
	var dress_max := current + DRESS_AHEAD
	var best_i := -1
	var best_d := INF
	for i in _scenic_queue.size():
		var chunk: Node3D = _scenic_queue[i]
		if not is_instance_valid(chunk):
			continue
		var index := int(chunk.get("chunk_index"))
		if index < current - 1 or index > dress_max:
			continue
		var d: float = float(index - current) if index >= current else 0.5 + float(current - index)
		if d < best_d:
			best_d = d
			best_i = i
	if best_i < 0:
		for leftover in _scenic_queue:
			if is_instance_valid(leftover):
				leftover.set_meta("scenic_queued", false)
		_scenic_queue.clear()
		return null
	var chosen: Node3D = _scenic_queue[best_i]
	_scenic_queue.remove_at(best_i)
	return chosen


func _build_next_highway(generation: int) -> void:
	while not _highway_queue.is_empty():
		var chunk: Node3D = _take_nearest_highway()
		if chunk == null:
			break
		if not is_instance_valid(chunk) or not chunk.is_inside_tree():
			continue
		if bool(chunk.get_meta("highway_done", false)):
			chunk.set_meta("highway_queued", false)
			continue
		await chunk.call("ensure_highway_dress")
		if generation != _stream_generation:
			return
		if is_instance_valid(chunk):
			chunk.set_meta("highway_queued", false)
			_apply_corridor_to(chunk)
		break
	if generation == _stream_generation:
		_highway_in_flight = false


func _take_nearest_highway() -> Node3D:
	if _highway_queue.is_empty() or _player == null:
		return _highway_queue.pop_front() if not _highway_queue.is_empty() else null
	var current: int = int(floor(_player.track_z / CHUNK_LENGTH))
	var dress_max := current + DRESS_AHEAD
	var best_i := -1
	var best_d := INF
	for i in _highway_queue.size():
		var chunk: Node3D = _highway_queue[i]
		if not is_instance_valid(chunk):
			continue
		var index := int(chunk.get("chunk_index"))
		if index < current - 1 or index > dress_max:
			continue
		var d: float = float(index - current) if index >= current else 0.5 + float(current - index)
		if d < best_d:
			best_d = d
			best_i = i
	if best_i < 0:
		for leftover in _highway_queue:
			if is_instance_valid(leftover):
				leftover.set_meta("highway_queued", false)
		_highway_queue.clear()
		return null
	var chosen: Node3D = _highway_queue[best_i]
	_highway_queue.remove_at(best_i)
	return chosen


func _apply_corridor() -> void:
	if _player == null or _path == null or not _path.has_method("on_spur"):
		return
	var on_scenic := bool(_path.call("on_spur", _player.track_z, _player.lateral))
	var committed := float(_path.call("spur_divergence", _player.track_z)) >= CORRIDOR_COMMIT
	var key := (1 if on_scenic else 0) | (2 if committed else 0)
	if key == _corridor_key:
		return
	_corridor_key = key
	for chunk in _chunks.values():
		if chunk is Node:
			_apply_corridor_to(chunk as Node)


func _apply_corridor_to(chunk: Node) -> void:
	if not is_instance_valid(chunk) or not chunk.has_method("apply_corridor"):
		return
	if _player == null or _path == null or not _path.has_method("on_spur"):
		return
	var on_scenic := bool(_path.call("on_spur", _player.track_z, _player.lateral))
	var committed := float(_path.call("spur_divergence", _player.track_z)) >= CORRIDOR_COMMIT
	chunk.call("apply_corridor", on_scenic, committed, committed)
