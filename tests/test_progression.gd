extends SceneTree
## Economy, distance unlock and per-bike tuning regression checks.

const BikeCatalog := preload("res://scripts/bike_catalog.gd")

var failures: int = 0


func check(ok: bool, what: String) -> void:
	if not ok:
		failures += 1
		print("FAIL: ", what)


func _process(_delta: float) -> bool:
	var base := BikeCatalog.stats(0, BikeCatalog.empty_tuning())
	var tuned := BikeCatalog.stats(0, {"engine": 3, "brakes": 2, "handling": 4})
	check(BikeCatalog.BIKES.size() == 5, "garage has five café racers")
	check(is_equal_approx(float(base["top_speed"]), 55.5556), "base bike preserves the tuned 200 km/h speed")
	for i in BikeCatalog.BIKES.size() - 1:
		check(
			float(BikeCatalog.BIKES[i + 1]["top_speed"]) > float(BikeCatalog.BIKES[i]["top_speed"]),
			"bike %d is stronger than bike %d" % [i + 1, i]
		)
		check(
			float(BikeCatalog.BIKES[i + 1]["unlock_m"]) > float(BikeCatalog.BIKES[i]["unlock_m"]),
			"later cafés stay distance-locked"
		)
	check(float(tuned["engine_accel"]) > float(base["engine_accel"]), "engine tuning raises acceleration")
	check(float(tuned["brake_accel"]) > float(base["brake_accel"]), "brake tuning raises stopping power")
	check(float(tuned["lean_grip"]) > float(base["lean_grip"]), "handling tuning raises grip")
	check(
		float(BikeCatalog.BIKES[4]["lean_grip"]) > float(BikeCatalog.BIKES[0]["lean_grip"]),
		"the Raven plants harder than the Mesa"
	)
	check(
		float(BikeCatalog.BIKES[4]["lean_in_rate_deg"]) < float(BikeCatalog.BIKES[0]["lean_in_rate_deg"]),
		"the Raven falls into a lean slower than the Mesa"
	)
	var AudioGD: GDScript = load("res://scripts/audio.gd")
	var mesa_engine: AudioStreamWAV = AudioGD.engine(0)
	var raven_engine: AudioStreamWAV = AudioGD.engine(4)
	check(mesa_engine != null and raven_engine != null, "every café bakes an engine loop")
	check(mesa_engine.data != raven_engine.data, "the Raven does not share the Mesa's engine sample")
	check(mesa_engine.loop_mode == AudioStreamWAV.LOOP_FORWARD, "the engine loop is seamless")
	var mesa_horn: AudioStreamWAV = AudioGD.horn(0)
	var raven_horn: AudioStreamWAV = AudioGD.horn(4)
	check(mesa_horn.mix_rate >= 44100, "the horn is sampled high enough to bite")
	check(mesa_horn.data != raven_horn.data, "each café has its own horn")
	check(mesa_horn.loop_mode == AudioStreamWAV.LOOP_FORWARD, "the horn can be held down")
	check(BikeCatalog.tune_cost(0, "engine", 1) > BikeCatalog.tune_cost(0, "engine", 0), "later tune levels cost more")
	check(BikeCatalog.tune_cost(0, "engine", 0) >= 140, "the first engine tune is a real spend")
	check(BikeCatalog.tune_cost(4, "engine", 0) > BikeCatalog.tune_cost(0, "engine", 0), "open-class tunes cost more")

	var game: Node = root.get_node("GameManager")
	game.set("persist_progress", false)
	game.set("best_m", 0.0)
	game.set("credits", 500)
	game.set("selected_bike", 0)
	var fresh: Array[Dictionary] = []
	for i in BikeCatalog.BIKES.size():
		fresh.append(BikeCatalog.empty_tuning())
	game.set("tuning", fresh)
	check(game.call("is_bike_unlocked", 0), "first bike starts unlocked")
	check(not game.call("is_bike_unlocked", 1), "second bike begins distance-locked")
	game.set("best_m", float(BikeCatalog.BIKES[1]["unlock_m"]))
	check(game.call("is_bike_unlocked", 1), "distance unlocks the second bike")
	check(not game.call("is_bike_unlocked", 4), "the last café stays locked until the long ride")
	var credit_step: float = float(game.get_script().get_script_constant_map()["CREDIT_DISTANCE"])
	check(credit_step >= 60.0, "distance pays slowly enough to make tunes a grind")
	var old_credits: int = game.credits
	var cost: int = game.call("tune_cost", 1, "engine")
	check(game.call("buy_tune", 1, "engine"), "credits purchase a bike tune")
	check(int(game.credits) == old_credits - cost, "purchase deducts the exact price")
	check(int(game.call("tune_level", 1, "engine")) == 1, "tune is stored per bike")
	var after_purchase: Dictionary = game.call("bike_stats", 1)
	check(float(after_purchase["engine_accel"]) > float(BikeCatalog.BIKES[1]["engine_accel"]), "purchased tune affects ridden stats")
	check(game.call("select_bike", 1), "an unlocked bike can be selected")
	check(int(game.selected_bike) == 1, "selected bike is stored in the garage")
	var before_award: int = game.credits
	game.call("_award_credits", 5)
	check(int(game.credits) == before_award + 5, "currency awards accumulate")

	var music: Dictionary = game.call("load_music_config")
	check(music.has("playback_position"), "music save remembers how far the track had played")
	check(music.has("track_path"), "music save remembers which track was playing")
	check(float(music.get("playback_position", -1.0)) >= 0.0, "playback position is a non-negative timestamp")

	print("progression self-check: %d failures" % failures)
	quit(1 if failures > 0 else 0)
	return true
