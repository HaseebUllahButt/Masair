extends Node
## Distance, best distance, near-miss combo, crash and restart.

signal distance_changed(distance_m: float)
signal best_changed(best_m: float)
signal crashed
signal near_miss(bonus: float, combo: int)
signal restarted
signal currency_changed(balance: int)
signal garage_changed

const BikeCatalog := preload("res://scripts/bike_catalog.gd")
const SAVE_PATH := "user://masair_save.cfg"
const COMBO_WINDOW := 2.6
const CREDIT_DISTANCE := 25.0

var distance_m: float = 0.0
var best_m: float = 0.0
var bonus_m: float = 0.0
var is_crashed: bool = false
var near_miss_count: int = 0
var combo: int = 0
var score_multiplier: float = 1.35
var credits: int = 0
var selected_bike: int = 0
var tuning: Array[Dictionary] = []

var _player: Node3D
var _combo_timer: float = 0.0
var _next_credit_distance: float = CREDIT_DISTANCE
var _unbanked_credits: int = 0


func _ready() -> void:
	_load_progress()
	best_changed.emit(best_m)
	currency_changed.emit(credits)


func bind_player(player: Node3D) -> void:
	_player = player
	apply_selected_bike()


func _process(delta: float) -> void:
	if _combo_timer > 0.0:
		_combo_timer -= delta
		if _combo_timer <= 0.0:
			combo = 0
	if is_crashed or _player == null:
		return
	var d: float = maxf(_player.track_z, 0.0) + bonus_m
	if d > distance_m:
		distance_m = d
		distance_changed.emit(distance_m)
	var route_m := maxf(float(_player.track_z), 0.0)
	var earned := 0
	while route_m >= _next_credit_distance:
		earned += 1
		_next_credit_distance += CREDIT_DISTANCE
	if earned > 0:
		_award_credits(earned)


func register_near_miss() -> void:
	if is_crashed:
		return
	near_miss_count += 1
	combo = mini(combo + 1, 9)
	_combo_timer = COMBO_WINDOW
	var bonus := 5.0 * float(combo) * score_multiplier
	bonus_m += bonus
	_award_credits(combo * 2)
	near_miss.emit(bonus, combo)


func crash() -> void:
	if is_crashed:
		return
	is_crashed = true
	combo = 0
	bank_progress()
	crashed.emit()


func set_difficulty(level: int) -> void:
	score_multiplier = [1.0, 1.35, 1.75][clampi(level, 0, 2)]


func restart() -> void:
	bank_progress()
	get_tree().paused = false
	distance_m = 0.0
	bonus_m = 0.0
	near_miss_count = 0
	combo = 0
	is_crashed = false
	_next_credit_distance = CREDIT_DISTANCE
	distance_changed.emit(0.0)
	if _player and _player.has_method("reset_run"):
		_player.call("reset_run")
	var scene := get_tree().current_scene
	if scene:
		var traffic := scene.get_node_or_null("TrafficManager")
		if traffic and traffic.has_method("reset_world"):
			traffic.call("reset_world")
	restarted.emit()


func bank_progress() -> void:
	var changed := false
	if distance_m > best_m:
		best_m = distance_m
		best_changed.emit(best_m)
		changed = true
	if changed or _unbanked_credits > 0:
		_save_progress()
		_unbanked_credits = 0
	garage_changed.emit()


func bike_count() -> int:
	return BikeCatalog.BIKES.size()


func bike_info(bike_id: int) -> Dictionary:
	return BikeCatalog.BIKES[clampi(bike_id, 0, BikeCatalog.BIKES.size() - 1)]


func bike_stats(bike_id: int) -> Dictionary:
	var safe_id := clampi(bike_id, 0, BikeCatalog.BIKES.size() - 1)
	return BikeCatalog.stats(safe_id, tuning[safe_id])


func is_bike_unlocked(bike_id: int) -> bool:
	if bike_id < 0 or bike_id >= BikeCatalog.BIKES.size():
		return false
	return best_m >= float(BikeCatalog.BIKES[bike_id]["unlock_m"])


func preview_bike(bike_id: int) -> void:
	if _player and _player.has_method("preview_bike"):
		_player.call("preview_bike", clampi(bike_id, 0, BikeCatalog.BIKES.size() - 1))


func select_bike(bike_id: int) -> bool:
	if not is_bike_unlocked(bike_id):
		return false
	selected_bike = bike_id
	apply_selected_bike()
	_save_progress()
	garage_changed.emit()
	return true


func apply_selected_bike() -> void:
	if _player and _player.has_method("apply_bike_profile"):
		_player.call("apply_bike_profile", selected_bike, bike_stats(selected_bike))


func tune_level(bike_id: int, category: String) -> int:
	if bike_id < 0 or bike_id >= tuning.size():
		return 0
	return int(tuning[bike_id].get(category, 0))


func tune_cost(bike_id: int, category: String) -> int:
	return BikeCatalog.tune_cost(bike_id, category, tune_level(bike_id, category))


func buy_tune(bike_id: int, category: String) -> bool:
	if not is_bike_unlocked(bike_id) or category not in BikeCatalog.TUNE_KEYS:
		return false
	var level := tune_level(bike_id, category)
	if level >= BikeCatalog.MAX_TUNE_LEVEL:
		return false
	var cost := BikeCatalog.tune_cost(bike_id, category, level)
	if credits < cost:
		return false
	credits -= cost
	tuning[bike_id][category] = level + 1
	if bike_id == selected_bike:
		apply_selected_bike()
	_save_progress()
	currency_changed.emit(credits)
	garage_changed.emit()
	return true


func _award_credits(amount: int) -> void:
	if amount <= 0:
		return
	credits += amount
	_unbanked_credits += amount
	currency_changed.emit(credits)
	# Save every 100 metres' worth. The UI updates every award, but normal riding
	# does not hammer the save file twice a second at top speed.
	if _unbanked_credits >= 4:
		_save_progress()
		_unbanked_credits = 0


func _ensure_tuning() -> void:
	while tuning.size() < BikeCatalog.BIKES.size():
		tuning.append(BikeCatalog.empty_tuning())


func load_music_config() -> Dictionary:
	var cfg := ConfigFile.new()
	var folder := ""
	var preset_index := 0
	var track_index := 0
	var want_playing := false
	if cfg.load(SAVE_PATH) == OK:
		preset_index = int(cfg.get_value("music", "preset_index", 0))
		track_index = int(cfg.get_value("music", "track_index", 0))
		want_playing = bool(cfg.get_value("music", "want_playing", false))
		folder = str(cfg.get_value("music", "folder", ""))
		## Migrate the old multi-folder preset save if needed.
		if folder.is_empty():
			var stored: Variant = cfg.get_value("music", "folders", [])
			if stored is PackedStringArray or stored is Array:
				for path in stored:
					var candidate := str(path)
					if not candidate.is_empty():
						folder = candidate
						break
	return {
		"preset_index": preset_index,
		"track_index": track_index,
		"want_playing": want_playing,
		"folder": folder,
	}


func save_music_config(data: Dictionary) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SAVE_PATH)
	cfg.set_value("music", "preset_index", int(data.get("preset_index", 0)))
	cfg.set_value("music", "track_index", int(data.get("track_index", 0)))
	cfg.set_value("music", "want_playing", bool(data.get("want_playing", false)))
	cfg.set_value("music", "folder", str(data.get("folder", "")))
	if cfg.has_section_key("music", "folders"):
		cfg.erase_section_key("music", "folders")
	cfg.save(SAVE_PATH)


func _load_progress() -> void:
	_ensure_tuning()
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) == OK:
		best_m = float(cfg.get_value("score", "best_m", 0.0))
		credits = maxi(0, int(cfg.get_value("economy", "credits", 0)))
		selected_bike = clampi(int(cfg.get_value("garage", "selected_bike", 0)), 0, BikeCatalog.BIKES.size() - 1)
		for bike_id in BikeCatalog.BIKES.size():
			for category in BikeCatalog.TUNE_KEYS:
				tuning[bike_id][category] = clampi(
					int(cfg.get_value("tuning", "bike_%d_%s" % [bike_id, category], 0)),
					0,
					BikeCatalog.MAX_TUNE_LEVEL
				)
	if not is_bike_unlocked(selected_bike):
		selected_bike = 0


func _save_progress() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SAVE_PATH)
	cfg.set_value("score", "best_m", best_m)
	cfg.set_value("economy", "credits", credits)
	cfg.set_value("garage", "selected_bike", selected_bike)
	for bike_id in BikeCatalog.BIKES.size():
		for category in BikeCatalog.TUNE_KEYS:
			cfg.set_value("tuning", "bike_%d_%s" % [bike_id, category], tune_level(bike_id, category))
	cfg.save(SAVE_PATH)
