extends Node
## Folder jukebox with EQ tone presets. Playback keeps running while the tree is
## paused (PROCESS_MODE_ALWAYS) and rides on a dedicated Music bus.
##
## Godot can only decode mp3/ogg/wav at runtime. FLAC/M4A are listed in the
## playlist and decoded once via ffmpeg into a CD-quality WAV cache (no second
## lossy encode). ffmpeg runs on a worker thread; AudioStream decoding stays on
## the main thread because Godot does not expose task return values from
## WorkerThreadPool. Two voices crossfade and the next track is prefetched while
## the current one plays. Playback position survives process restarts.

signal playlist_changed
signal track_changed(title: String)
signal playing_changed(is_playing: bool)
signal preset_changed(index: int)

const MusicLoader := preload("res://scripts/music_loader.gd")

const BUS_NAME := "Music"
## Tone shapes for AudioEffectEQ10 (32 Hz → 16 kHz). Values are gain in dB.
const PRESETS := [
	{"name": "FLAT", "gains": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]},
	{"name": "BASS BOOST", "gains": [7.0, 6.0, 4.0, 2.0, 0.0, 0.0, 0.0, 0.0, -0.5, -1.0]},
	{"name": "VOCALS", "gains": [-3.0, -2.0, -1.0, 2.0, 4.5, 5.0, 3.5, 1.0, 0.0, -1.0]},
	{"name": "TREBLE", "gains": [-1.0, -0.5, 0.0, 0.0, 0.5, 1.5, 3.0, 5.0, 6.0, 5.0]},
	{"name": "ROCK", "gains": [5.0, 3.5, 1.0, -1.0, -2.0, -1.0, 1.0, 3.0, 4.0, 3.5]},
	{"name": "SOFT", "gains": [2.0, 1.5, 0.5, 0.0, -1.0, -1.5, -1.0, 0.0, 1.0, 1.5]},
	{"name": "CUSTOM", "gains": [3.0, 2.5, 1.0, 0.0, -1.5, -1.0, 0.5, 2.0, 2.5, 1.5]},
]
const NATIVE_EXTS := ["mp3", "ogg", "oga", "wav"]
const TRANSCODE_EXTS := ["flac", "m4a", "aac"]
const VOLUME_DB := -9.0
const FADE_SEC := 0.35
const SAVE_INTERVAL := 5.0
const CACHE_KEEP := 3

var music_folder: String = ""
var preset_index: int = 0
var tracks: Array[String] = []
var track_index: int = 0
var has_ffmpeg: bool = false

var _voices: Array[AudioStreamPlayer] = []
var _active: int = 0
var _eq: AudioEffectEQ10
var _want_playing: bool = false
var _audible_index: int = 0
var _resume_position: float = 0.0
var _saved_track_path: String = ""
var _fade_t: float = 1.0
var _fading: bool = false
var _save_timer: float = 0.0
var _stream_cache: Dictionary = {}
var _play_request: Dictionary = {}
var _prefetch_path: String = ""
var _task_id: int = -1
var _load_job: MusicLoader = null
var _failed: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	has_ffmpeg = _detect_ffmpeg()
	_ensure_music_bus()
	for i in 2:
		var voice := AudioStreamPlayer.new()
		voice.name = "Voice%d" % i
		voice.bus = BUS_NAME
		voice.volume_db = VOLUME_DB
		voice.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(voice)
		voice.finished.connect(_on_voice_finished.bind(i))
		_voices.append(voice)
	_load_config()
	_apply_preset()
	_reload_playlist(false)
	call_deferred("resume_if_wanted")


func _process(delta: float) -> void:
	_pump_tasks()
	if _fading:
		_fade_t = minf(1.0, _fade_t + delta / FADE_SEC)
		_apply_fade_volumes()
		if _fade_t >= 1.0:
			_finish_fade()
	_maybe_overlap_next()
	if _voice_playing():
		_save_timer += delta
		if _save_timer >= SAVE_INTERVAL:
			_save_timer = 0.0
			_save_config()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_CLOSE_REQUEST, NOTIFICATION_APPLICATION_PAUSED:
			_save_config()
		NOTIFICATION_EXIT_TREE:
			_save_config()
			_drain_task()


func preset_count() -> int:
	return PRESETS.size()


func preset_name(index: int = -1) -> String:
	var i := preset_index if index < 0 else clampi(index, 0, PRESETS.size() - 1)
	return str(PRESETS[i]["name"])


func current_folder() -> String:
	return music_folder


func folder_label() -> String:
	if music_folder.is_empty():
		return "PICK FOLDER"
	var leaf := music_folder.get_file()
	return leaf if not leaf.is_empty() else music_folder


func track_title() -> String:
	if tracks.is_empty():
		if music_folder.is_empty():
			return "no folder"
		return "no playable tracks"
	return tracks[track_index].get_file().get_basename()


func track_count() -> int:
	return tracks.size()


func playback_position() -> float:
	return _current_position()


func format_note() -> String:
	if has_ffmpeg:
		return "MP3 OGG WAV FLAC M4A"
	return "MP3 OGG WAV  ·  install ffmpeg for FLAC/M4A"


func is_playing() -> bool:
	if _voice_playing():
		return true
	return _want_playing and not _play_request.is_empty()


func cycle_preset(direction: int) -> void:
	preset_index = posmod(preset_index + direction, PRESETS.size())
	_apply_preset()
	preset_changed.emit(preset_index)
	_save_config()


func set_folder(path: String) -> void:
	var clean := path.strip_edges()
	if clean.is_empty():
		return
	music_folder = clean
	track_index = 0
	_audible_index = 0
	_resume_position = 0.0
	_saved_track_path = ""
	_stream_cache.clear()
	_failed.clear()
	_play_request.clear()
	_prefetch_path = ""
	_reload_playlist(true)
	_save_config()


func toggle_play() -> void:
	if tracks.is_empty():
		_want_playing = false
		_play_request.clear()
		playing_changed.emit(false)
		return
	if _voice_playing():
		if not _play_request.is_empty():
			_play_request.clear()
			track_index = _audible_index
			_emit_track()
		_finish_fade()
		_voice().stream_paused = true
		_resume_position = _voice().get_playback_position()
		_want_playing = false
		playing_changed.emit(false)
		_save_config()
		return
	if not _play_request.is_empty():
		_play_request.clear()
		_want_playing = false
		playing_changed.emit(false)
		_save_config()
		return
	var paused := _voice()
	if paused.stream != null and paused.stream_paused:
		paused.stream_paused = false
		_want_playing = true
		playing_changed.emit(true)
		_save_config()
		return
	_request_play(track_index, _resume_position)
	_save_config()


func next_track() -> void:
	if tracks.is_empty():
		return
	track_index = (track_index + 1) % tracks.size()
	_resume_position = 0.0
	if _want_playing or _voice_playing() or not _play_request.is_empty():
		_request_play(track_index, 0.0)
	else:
		_emit_track()
	_save_config()


func previous_track() -> void:
	if tracks.is_empty():
		return
	if _voice_playing() and _voice().get_playback_position() > 2.0:
		_play_request.clear()
		_voice().seek(0.0)
		_resume_position = 0.0
		track_index = _audible_index
		_emit_track()
		_save_config()
		return
	track_index = (track_index - 1 + tracks.size()) % tracks.size()
	_resume_position = 0.0
	if _want_playing or _voice_playing() or not _play_request.is_empty():
		_request_play(track_index, 0.0)
	else:
		_emit_track()
	_save_config()


func resume_if_wanted() -> void:
	## Called once the café is up so autoplay does not fight boot audio.
	if DisplayServer.get_name() == "headless":
		return
	if _want_playing and not tracks.is_empty() and not _voice_playing():
		if track_index >= tracks.size():
			track_index = 0
		_request_play(track_index, _resume_position)


func _detect_ffmpeg() -> bool:
	## OS.execute returns -1 when the binary is missing.
	var sink: Array = []
	return OS.execute("ffmpeg", ["-version"], sink, true, true) == 0


func _ensure_music_bus() -> void:
	var idx := AudioServer.get_bus_index(BUS_NAME)
	if idx == -1:
		idx = AudioServer.bus_count
		AudioServer.add_bus(idx)
		AudioServer.set_bus_name(idx, BUS_NAME)
		AudioServer.set_bus_send(idx, "Master")
	## Wipe prior effects so reloads do not stack EQ instances.
	while AudioServer.get_bus_effect_count(idx) > 0:
		AudioServer.remove_bus_effect(idx, 0)
	_eq = AudioEffectEQ10.new()
	AudioServer.add_bus_effect(idx, _eq, 0)


func _apply_preset() -> void:
	if _eq == null:
		return
	var gains: Array = PRESETS[preset_index]["gains"]
	var bands := mini(_eq.get_band_count(), gains.size())
	for band in bands:
		_eq.set_band_gain_db(band, float(gains[band]))


func _reload_playlist(autoplay: bool) -> void:
	var keep_index := track_index
	tracks.clear()
	if not music_folder.is_empty():
		_scan_folder(music_folder, tracks)
		tracks.sort()
	if tracks.is_empty():
		track_index = 0
		_audible_index = 0
	else:
		var found := tracks.find(_saved_track_path)
		if found >= 0:
			track_index = found
		else:
			track_index = clampi(keep_index, 0, tracks.size() - 1)
		_audible_index = track_index
	playlist_changed.emit()
	_emit_track()
	_stop_all()
	if autoplay and not tracks.is_empty():
		_request_play(track_index, 0.0)
	else:
		if autoplay:
			_want_playing = false
		playing_changed.emit(false)


func _accepted_ext(ext: String) -> bool:
	if ext in NATIVE_EXTS:
		return true
	return has_ffmpeg and ext in TRANSCODE_EXTS


func _scan_folder(path: String, out: Array[String]) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for sub in dir.get_directories():
		if sub.begins_with("."):
			continue
		_scan_folder(path.path_join(sub), out)
	for file_name in dir.get_files():
		if file_name.begins_with("."):
			continue
		var ext := file_name.get_extension().to_lower()
		if _accepted_ext(ext):
			out.append(path.path_join(file_name))


func _voice() -> AudioStreamPlayer:
	if _voices.is_empty():
		return null
	return _voices[_active]


func _voice_playing() -> bool:
	var v := _voice()
	return v != null and v.playing and not v.stream_paused


func _current_position() -> float:
	var v := _voice()
	if v and v.stream != null and (v.playing or v.stream_paused):
		return maxf(0.0, v.get_playback_position())
	return maxf(0.0, _resume_position)


func _request_play(index: int, seek: float) -> void:
	if tracks.is_empty():
		_stop_all()
		_want_playing = false
		playing_changed.emit(false)
		return
	track_index = clampi(index, 0, tracks.size() - 1)
	_resume_position = maxf(0.0, seek)
	_want_playing = true
	_emit_track()
	playing_changed.emit(true)
	var path := tracks[track_index]
	if _failed.has(path):
		_skip_failed(path)
		return
	_play_request = {"path": path, "seek": _resume_position}
	if _stream_cache.has(path):
		_fulfill_play()


func _fulfill_play() -> void:
	if _play_request.is_empty():
		return
	var path := str(_play_request.get("path", ""))
	if not _stream_cache.has(path):
		return
	var seek := float(_play_request.get("seek", 0.0))
	_play_request.clear()
	_begin_playback(_stream_cache[path] as AudioStream, seek)
	_queue_prefetch()


func _begin_playback(stream: AudioStream, seek: float) -> void:
	if stream == null:
		return
	var length := stream.get_length()
	var from := maxf(0.0, seek)
	if length > 1.5 and from >= length - 1.0 and tracks.size() > 1:
		_resume_position = 0.0
		track_index = (track_index + 1) % tracks.size()
		_emit_track()
		_play_request = {"path": tracks[track_index], "seek": 0.0}
		if _stream_cache.has(tracks[track_index]):
			_fulfill_play()
		return
	if length > 0.0:
		from = minf(from, maxf(0.0, length - 0.05))
	var incoming := 1 - _active
	var next_voice := _voices[incoming]
	var current := _voice()
	var outgoing_live := current != null and current.playing and not current.stream_paused and current.stream != null
	if outgoing_live:
		next_voice.stream = stream
		next_voice.stream_paused = false
		next_voice.volume_db = linear_to_db(0.0001)
		next_voice.play(from)
		_active = incoming
		_audible_index = track_index
		_resume_position = from
		_fade_t = 0.0
		_fading = true
		_apply_fade_volumes()
	else:
		if current:
			current.stop()
			current.stream = null
			current.volume_db = VOLUME_DB
		_active = incoming
		next_voice.stream = stream
		next_voice.stream_paused = false
		next_voice.volume_db = VOLUME_DB
		next_voice.play(from)
		_audible_index = track_index
		_resume_position = from
		_fading = false
		_fade_t = 1.0
		_trim_cache()
	_want_playing = true
	playing_changed.emit(true)


func _apply_fade_volumes() -> void:
	var lin := db_to_linear(VOLUME_DB)
	_voices[_active].volume_db = linear_to_db(maxf(0.0001, lin * _fade_t))
	_voices[1 - _active].volume_db = linear_to_db(maxf(0.0001, lin * (1.0 - _fade_t)))


func _finish_fade() -> void:
	if not _voices:
		return
	_fading = false
	_fade_t = 1.0
	var current := _voice()
	if current:
		current.volume_db = VOLUME_DB
	var other := _voices[1 - _active]
	other.stop()
	other.stream = null
	other.volume_db = VOLUME_DB
	_trim_cache()


func _maybe_overlap_next() -> void:
	if not _want_playing or _fading or tracks.size() < 2:
		return
	if not _play_request.is_empty():
		return
	var v := _voice()
	if v == null or not v.playing or v.stream == null:
		return
	var length := v.stream.get_length()
	if length <= FADE_SEC + 0.5:
		return
	if v.get_playback_position() < length - FADE_SEC:
		return
	track_index = (track_index + 1) % tracks.size()
	_resume_position = 0.0
	_request_play(track_index, 0.0)


func _queue_prefetch() -> void:
	if tracks.size() < 2:
		_prefetch_path = ""
		return
	var nxt := tracks[(track_index + 1) % tracks.size()]
	var prv := tracks[(track_index - 1 + tracks.size()) % tracks.size()]
	if not _stream_cache.has(nxt) and not _failed.has(nxt):
		_prefetch_path = nxt
	elif not _stream_cache.has(prv) and not _failed.has(prv):
		_prefetch_path = prv
	else:
		_prefetch_path = ""


func _pump_tasks() -> void:
	if _task_id != -1:
		if not WorkerThreadPool.is_task_completed(_task_id):
			return
		WorkerThreadPool.wait_for_task_completion(_task_id)
		_task_id = -1
		if _load_job:
			_finish_load_job(_load_job)
			_load_job = null
	## A nested fulfill may already have started the next decode.
	if _task_id != -1:
		return
	var path := _next_load_path()
	if _task_id != -1 or path.is_empty() or _stream_cache.has(path):
		return
	if MusicLoader.needs_transcode(path):
		_load_job = MusicLoader.new()
		_task_id = WorkerThreadPool.add_task(_load_job.prepare.bind(path, has_ffmpeg))
	else:
		_load_native(path)


func _next_load_path() -> String:
	if not _play_request.is_empty():
		var wanted := str(_play_request.get("path", ""))
		if _stream_cache.has(wanted):
			_fulfill_play()
		elif _failed.has(wanted):
			_play_request.clear()
			_skip_failed(wanted)
			if not _play_request.is_empty():
				return str(_play_request.get("path", ""))
		else:
			return wanted
	if not _prefetch_path.is_empty():
		if _stream_cache.has(_prefetch_path) or _failed.has(_prefetch_path):
			_prefetch_path = ""
			_queue_prefetch()
		return _prefetch_path
	return ""


func _finish_load_job(job: MusicLoader) -> void:
	var path := job.source_path
	var playable := job.playable_path
	var stream: AudioStream = _load_playable_file(playable) if not playable.is_empty() else null
	_handle_loaded(path, stream)


func _load_native(path: String) -> void:
	_handle_loaded(path, _load_playable_file(path))


func _handle_loaded(path: String, stream: AudioStream) -> void:
	if stream:
		_remember(path, stream)
	else:
		_failed[path] = true
	if str(_play_request.get("path", "")) == path:
		if stream:
			_fulfill_play()
		else:
			_play_request.clear()
			_skip_failed(path)
		return
	if _prefetch_path == path:
		_prefetch_path = ""
		_queue_prefetch()


func _skip_failed(failed_path: String) -> void:
	if tracks.is_empty():
		_want_playing = false
		playing_changed.emit(false)
		return
	var start := track_index
	while true:
		track_index = (track_index + 1) % tracks.size()
		if track_index == start:
			_want_playing = false
			playing_changed.emit(false)
			_emit_track()
			return
		if tracks[track_index] != failed_path and not _failed.has(tracks[track_index]):
			break
	_request_play(track_index, 0.0)


func _remember(path: String, stream: AudioStream) -> void:
	_stream_cache[path] = stream
	_trim_cache()


func _trim_cache() -> void:
	if _stream_cache.size() <= CACHE_KEEP or tracks.is_empty():
		return
	var keep: Dictionary = {}
	for offset in [-1, 0, 1]:
		keep[tracks[posmod(track_index + offset, tracks.size())]] = true
	var live_voice := _voice()
	var live: AudioStream = live_voice.stream if live_voice else null
	var other: AudioStream = _voices[1 - _active].stream
	var drop: Array[String] = []
	for path in _stream_cache.keys():
		var key := str(path)
		if keep.has(key):
			continue
		var cached: AudioStream = _stream_cache[key]
		if cached == live or cached == other:
			continue
		drop.append(key)
	for key in drop:
		_stream_cache.erase(key)
		if _stream_cache.size() <= CACHE_KEEP:
			break


func _load_playable_file(playable: String) -> AudioStream:
	if playable.is_empty() or not FileAccess.file_exists(playable):
		return null
	var ext := playable.get_extension().to_lower()
	match ext:
		"mp3":
			return AudioStreamMP3.load_from_file(playable)
		"ogg", "oga":
			return AudioStreamOggVorbis.load_from_file(playable)
		"wav":
			return AudioStreamWAV.load_from_file(playable)
		_:
			return null


func _stop_all() -> void:
	_finish_fade()
	_play_request.clear()
	_prefetch_path = ""
	for voice in _voices:
		voice.stop()
		voice.stream = null
		voice.stream_paused = false
		voice.volume_db = VOLUME_DB


func _drain_task() -> void:
	if _task_id == -1:
		return
	WorkerThreadPool.wait_for_task_completion(_task_id)
	_task_id = -1
	_load_job = null


func _on_voice_finished(which: int) -> void:
	if which != _active or _fading:
		return
	if not _play_request.is_empty():
		return
	if not _want_playing or tracks.is_empty():
		playing_changed.emit(false)
		return
	track_index = (track_index + 1) % tracks.size()
	_resume_position = 0.0
	_request_play(track_index, 0.0)
	_save_config()


func _emit_track() -> void:
	track_changed.emit(track_title())


func _load_config() -> void:
	var game := get_node_or_null("/root/GameManager")
	if game == null or not game.has_method("load_music_config"):
		return
	var data: Dictionary = game.call("load_music_config")
	preset_index = clampi(int(data.get("preset_index", 0)), 0, PRESETS.size() - 1)
	music_folder = str(data.get("folder", ""))
	track_index = maxi(0, int(data.get("track_index", 0)))
	_want_playing = bool(data.get("want_playing", false))
	_resume_position = maxf(0.0, float(data.get("playback_position", 0.0)))
	_saved_track_path = str(data.get("track_path", ""))
	_audible_index = track_index


func _save_config() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var game := get_node_or_null("/root/GameManager")
	if game == null or not game.has_method("save_music_config"):
		return
	var path := ""
	if track_index >= 0 and track_index < tracks.size():
		path = tracks[track_index]
	game.call(
		"save_music_config",
		{
			"preset_index": preset_index,
			"folder": music_folder,
			"track_index": track_index,
			"want_playing": _want_playing,
			"playback_position": _current_position(),
			"track_path": path,
		}
	)
