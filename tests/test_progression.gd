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
	game.set("lifetime_m", 0.0)
	game.set("credits", 500)
	game.set("selected_bike", 0)
	var fresh: Array[Dictionary] = []
	var fresh_paint: Array[int] = []
	for i in BikeCatalog.BIKES.size():
		fresh.append(BikeCatalog.empty_tuning())
		fresh_paint.append(0)
	game.set("tuning", fresh)
	game.set("purchased", [])
	game.set("paints_owned", 1)
	game.set("paint_sel", fresh_paint)
	check(game.call("is_bike_unlocked", 0), "first bike starts unlocked")
	check(not game.call("is_bike_unlocked", 1), "second bike begins distance-locked")
	game.set("best_m", float(BikeCatalog.BIKES[1]["unlock_m"]))
	check(game.call("is_bike_unlocked", 1), "distance unlocks the second bike")
	game.set("best_m", 0.0)
	game.set("lifetime_m", float(BikeCatalog.BIKES[3]["unlock_m"]) - 1.0)
	check(not game.call("is_bike_unlocked", 3), "the Tempest stays locked just before lifetime distance")
	game.set("lifetime_m", float(BikeCatalog.BIKES[3]["unlock_m"]))
	check(game.call("is_bike_unlocked", 3), "lifetime distance unlocks the Tempest")
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

	# The dealer's sliding scale: full list at zero kilometres, melting to free
	# at the distance mark, and a purchase counts as an unlock.
	game.set("best_m", 0.0)
	game.set("lifetime_m", 0.0)
	game.set("purchased", [])
	check(
		int(game.call("bike_price", 1)) == int(BikeCatalog.BIKES[1]["price"]),
		"locked bike starts at list price"
	)
	game.set("lifetime_m", float(BikeCatalog.BIKES[1]["unlock_m"]) * 0.5)
	var half_price: int = game.call("bike_price", 1)
	check(
		half_price > 0 and half_price < int(BikeCatalog.BIKES[1]["price"]),
		"distance discounts the sticker"
	)
	game.set("credits", half_price)
	check(game.call("buy_bike", 1), "credits buy a locked bike")
	check(game.call("is_bike_unlocked", 1), "a bought bike stays unlocked without the distance")
	check(int(game.credits) == 0, "the purchase drains the exact price")
	check(not game.call("buy_bike", 1), "an owned bike is not for sale")
	game.set("purchased", [])
	game.set("lifetime_m", 0.0)
	check(not game.call("is_bike_unlocked", 1), "reset garage locks the bike again")

	# Paint shop: colours are bought once, worn per bike, STOCK always owned.
	game.set("credits", 300)
	check(game.call("owns_paint", 0), "the authored livery is always owned")
	check(not game.call("owns_paint", 1), "shop colours start unpurchased")
	check(game.call("buy_paint", 1), "credits buy a paint")
	check(game.call("owns_paint", 1), "bought paint is owned")
	check(game.call("select_paint", 0, 1), "an owned paint can be worn")
	check(int(game.call("selected_paint", 0)) == 1, "paint is stored per bike")
	check(not game.call("select_paint", 0, 2), "unbought paint cannot be worn")
	game.set("paint_sel", fresh_paint)

	# Race purse: podium pays, finishing pays, a crash-out still gets a tip —
	# and the purse pays only once per race.
	game.set("credits", 0)
	game.call("begin_race", 7, Vector2i(0, 1))
	check(int(game.call("award_race_purse", 1, true)) == 150, "first place pays the podium purse")
	check(int(game.call("award_race_purse", 1, true)) == 0, "the purse pays once")
	game.call("end_race")
	check(int(game.credits) == 150, "the purse lands in the wallet")

	var music: Dictionary = game.call("load_music_config")
	check(music.has("playback_position"), "music save remembers how far the track had played")
	check(music.has("track_path"), "music save remembers which track was playing")
	check(music.has("music_volume"), "music save exposes a separate music volume")
	check(music.has("engine_volume"), "music save exposes a separate engine volume")
	check(float(music.get("playback_position", -1.0)) >= 0.0, "playback position is a non-negative timestamp")
	check(float(music.get("music_volume", -1.0)) >= 0.0, "music volume stays in the slider range")
	check(float(music.get("engine_volume", -1.0)) >= 0.0, "engine volume stays in the slider range")
	var music_player: Node = root.get_node("MusicPlayer")
	var music_bus := AudioServer.get_bus_index("Music")
	var engine_bus := AudioServer.get_bus_index("Engine")
	check(music_bus >= 0, "music gets its own audio bus")
	check(engine_bus >= 0, "engine gets its own audio bus")
	check(music_player.has_method("set_music_volume"), "music volume has a live setter")
	check(music_player.has_method("set_engine_volume"), "engine volume has a live setter")
	var saved_music_volume: float = float(music_player.call("music_volume_value"))
	var saved_engine_volume: float = float(music_player.call("engine_volume_value"))
	music_player.call("set_music_volume", 0.37)
	music_player.call("set_engine_volume", 0.61)
	check(is_equal_approx(AudioServer.get_bus_volume_db(music_bus), linear_to_db(0.37)), "music slider reaches the music bus")
	check(is_equal_approx(AudioServer.get_bus_volume_db(engine_bus), linear_to_db(0.61)), "engine slider reaches the engine bus")
	music_player.call("set_music_volume", saved_music_volume)
	music_player.call("set_engine_volume", saved_engine_volume)

	print("progression self-check: %d failures" % failures)
	quit(1 if failures > 0 else 0)
	return true
