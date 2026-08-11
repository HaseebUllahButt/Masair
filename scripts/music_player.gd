extends Node
## Folder jukebox with EQ tone presets. Playback keeps running while the tree is
## paused (PROCESS_MODE_ALWAYS) and rides on a dedicated Music bus.
##
## Godot can only decode mp3/ogg/wav at runtime. FLAC/M4A are listed in the
## playlist and decoded once via ffmpeg into a lossless WAV cache (no second
## lossy encode).

signal playlist_changed
signal track_changed(title: String)
signal playing_changed(is_playing: bool)
signal preset_changed(index: int)

const BUS_NAME := "Music"
const CACHE_DIR := "user://music_cache"
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

var music_folder: String = ""
var preset_index: int = 0
var tracks: Array[String] = []
var track_index: int = 0
var has_ffmpeg: bool = false

var _player: AudioStreamPlayer
var _eq: AudioEffectEQ10
var _want_playing: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	has_ffmpeg = _detect_ffmpeg()
	_ensure_music_bus()
	_player = AudioStreamPlayer.new()
	_player.name = "Stream"
	_player.bus = BUS_NAME
	_player.volume_db = VOLUME_DB
	_player.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_player)
	_player.finished.connect(_on_track_finished)
	_load_config()
	_apply_preset()
	_reload_playlist(false)
	call_deferred("resume_if_wanted")


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


func format_note() -> String:
	if has_ffmpeg:
		return "MP3 OGG WAV FLAC M4A"
	return "MP3 OGG WAV  ·  install ffmpeg for FLAC/M4A"


func is_playing() -> bool:
	return _player != null and _player.playing and not _player.stream_paused


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
	_reload_playlist(true)
	_save_config()


func toggle_play() -> void:
	if tracks.is_empty():
		_want_playing = false
		playing_changed.emit(false)
		return
	if is_playing():
		_player.stream_paused = true
		_want_playing = false
		playing_changed.emit(false)
		_save_config()
		return
	if _player.stream != null and _player.stream_paused:
		_player.stream_paused = false
		_want_playing = true
		playing_changed.emit(true)
		_save_config()
		return
	_play_current()
	_save_config()


func next_track() -> void:
	if tracks.is_empty():
		return
	track_index = (track_index + 1) % tracks.size()
	if _want_playing or is_playing():
		_play_current()
	else:
		_emit_track()
	_save_config()


func previous_track() -> void:
	if tracks.is_empty():
		return
	## Restart the current track if we are more than a couple of seconds in.
	if is_playing() and _player.get_playback_position() > 2.0:
		_player.seek(0.0)
		_emit_track()
		return
	track_index = (track_index - 1 + tracks.size()) % tracks.size()
	if _want_playing or is_playing():
		_play_current()
	else:
		_emit_track()
	_save_config()


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
	else:
		track_index = clampi(keep_index, 0, tracks.size() - 1)
	playlist_changed.emit()
	_emit_track()
	_stop_stream()
	if autoplay and not tracks.is_empty():
		_play_current()
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


func _play_current() -> void:
	if tracks.is_empty():
		_stop_stream()
		_want_playing = false
		playing_changed.emit(false)
		return
	track_index = clampi(track_index, 0, tracks.size() - 1)
	var stream := _load_stream(tracks[track_index])
	if stream == null:
		## Skip unreadable files without getting stuck.
		var start := track_index
		while true:
			track_index = (track_index + 1) % tracks.size()
			if track_index == start:
				_stop_stream()
				_want_playing = false
				playing_changed.emit(false)
				_emit_track()
				return
			stream = _load_stream(tracks[track_index])
			if stream != null:
				break
	_player.stream = stream
	_player.stream_paused = false
	_player.play()
	_want_playing = true
	_emit_track()
	playing_changed.emit(true)


func _load_stream(path: String) -> AudioStream:
	var playable := _resolve_playable_path(path)
	if playable.is_empty():
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


func _resolve_playable_path(path: String) -> String:
	var ext := path.get_extension().to_lower()
	if ext in NATIVE_EXTS:
		return path
	if ext in TRANSCODE_EXTS:
		return _transcode_cached(path)
	return ""


func _transcode_cached(path: String) -> String:
	if not has_ffmpeg:
		return ""
	if not FileAccess.file_exists(path):
		return ""
	var cache_abs := ProjectSettings.globalize_path(CACHE_DIR)
	DirAccess.make_dir_recursive_absolute(cache_abs)
	var stamp := int(FileAccess.get_modified_time(path))
	## Decode to PCM WAV — never re-encode through Vorbis/AAC. Godot's runtime
	## loader only accepts 16-bit/float WAV, so 16-bit PCM is the transparent path.
	var key := "%s_%d.wav" % [path.md5_text(), stamp]
	var out_abs := cache_abs.path_join(key)
	if FileAccess.file_exists(out_abs):
		return out_abs
	var sink: Array = []
	var code := OS.execute(
		"ffmpeg",
		["-y", "-i", path, "-vn", "-c:a", "pcm_s16le", out_abs],
		sink,
		true,
		true
	)
	if code != 0 or not FileAccess.file_exists(out_abs):
		push_warning("MusicPlayer: ffmpeg failed for %s (code %d)" % [path.get_file(), code])
		return ""
	return out_abs


func _stop_stream() -> void:
	if _player == null:
		return
	_player.stop()
	_player.stream = null
	_player.stream_paused = false


func _on_track_finished() -> void:
	if not _want_playing or tracks.is_empty():
		playing_changed.emit(false)
		return
	track_index = (track_index + 1) % tracks.size()
	_play_current()
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


func _save_config() -> void:
	var game := get_node_or_null("/root/GameManager")
	if game == null or not game.has_method("save_music_config"):
		return
	game.call(
		"save_music_config",
		{
			"preset_index": preset_index,
			"folder": music_folder,
			"track_index": track_index,
			"want_playing": _want_playing,
		}
	)


func resume_if_wanted() -> void:
	## Called once the café is up so autoplay does not fight boot audio.
	if _want_playing and not tracks.is_empty() and not is_playing():
		if track_index >= tracks.size():
			track_index = 0
		_play_current()
