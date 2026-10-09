extends RefCounted
## Worker-thread prep for MusicPlayer. Godot's WorkerThreadPool does not return
## task values from wait_for_task_completion() — only an Error — so jobs mutate
## this RefCounted object and the main thread reads it after the task finishes.
## Decoding also lives here: a cached WAV is tens of MB and load_from_file()
## used to freeze the game for ~1 s on the main thread whenever a track loaded.
## The decode is pure file I/O plus a RefCounted create — safe off the main
## thread; only assigning the stream to an AudioStreamPlayer needs the loop.

const CACHE_DIR := "user://music_cache"
const NATIVE_EXTS := ["mp3", "ogg", "oga", "wav"]
const TRANSCODE_EXTS := ["flac", "m4a", "aac"]

var source_path: String = ""
var playable_path: String = ""
var stream: AudioStream = null


func prepare(source: String, ffmpeg: bool) -> void:
	source_path = source
	playable_path = resolve_playable(source, ffmpeg)
	if not playable_path.is_empty():
		stream = decode(playable_path)


static func decode(playable: String) -> AudioStream:
	if playable.is_empty() or not FileAccess.file_exists(playable):
		return null
	match playable.get_extension().to_lower():
		"mp3":
			return AudioStreamMP3.load_from_file(playable)
		"ogg", "oga":
			return AudioStreamOggVorbis.load_from_file(playable)
		"wav":
			return AudioStreamWAV.load_from_file(playable)
	return null


static func resolve_playable(path: String, ffmpeg: bool) -> String:
	if path.is_empty() or not FileAccess.file_exists(path):
		return ""
	var ext := path.get_extension().to_lower()
	if ext in NATIVE_EXTS:
		return path
	if ext in TRANSCODE_EXTS:
		return transcode_cached(path, ffmpeg)
	return ""


static func transcode_cached(path: String, ffmpeg: bool) -> String:
	if not ffmpeg:
		return ""
	if not FileAccess.file_exists(path):
		return ""
	var cache_abs := ProjectSettings.globalize_path(CACHE_DIR)
	DirAccess.make_dir_recursive_absolute(cache_abs)
	var stamp := int(FileAccess.get_modified_time(path))
	var key := "%s_%d_44k.wav" % [path.md5_text(), stamp]
	var out_abs := cache_abs.path_join(key)
	if FileAccess.file_exists(out_abs):
		return out_abs
	var legacy := cache_abs.path_join("%s_%d.wav" % [path.md5_text(), stamp])
	if FileAccess.file_exists(legacy):
		return legacy
	var sink: Array = []
	var code := OS.execute(
		"ffmpeg",
		[
			"-y", "-hide_banner", "-loglevel", "error", "-threads", "1",
			"-i", path, "-vn", "-ac", "2", "-ar", "44100", "-c:a", "pcm_s16le",
			out_abs,
		],
		sink,
		true,
		true
	)
	if code != 0 or not FileAccess.file_exists(out_abs):
		return ""
	return out_abs
