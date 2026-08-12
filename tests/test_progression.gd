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
	check(is_equal_approx(float(base["top_speed"]), 55.5556), "base bike preserves the tuned 200 km/h speed")
	check(float(BikeCatalog.BIKES[1]["top_speed"]) > float(BikeCatalog.BIKES[0]["top_speed"]), "second bike is stronger")
	check(float(BikeCatalog.BIKES[2]["top_speed"]) > float(BikeCatalog.BIKES[1]["top_speed"]), "third bike is strongest")
	check(float(tuned["engine_accel"]) > float(base["engine_accel"]), "engine tuning raises acceleration")
	check(float(tuned["brake_accel"]) > float(base["brake_accel"]), "brake tuning raises stopping power")
	check(float(tuned["lean_grip"]) > float(base["lean_grip"]), "handling tuning raises grip")
	check(BikeCatalog.tune_cost(0, "engine", 1) > BikeCatalog.tune_cost(0, "engine", 0), "later tune levels cost more")

	var game: Node = root.get_node("GameManager")
	game.set("best_m", 0.0)
	game.set("credits", 500)
	game.set("selected_bike", 0)
	var fresh: Array[Dictionary] = []
	for i in BikeCatalog.BIKES.size():
		fresh.append(BikeCatalog.empty_tuning())
	game.set("tuning", fresh)
	check(game.call("is_bike_unlocked", 0), "first bike starts unlocked")
	check(not game.call("is_bike_unlocked", 1), "second bike begins distance-locked")
	game.set("best_m", 2000.0)
	check(game.call("is_bike_unlocked", 1), "distance unlocks the second bike")
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

	print("progression self-check: %d failures" % failures)
	quit(1 if failures > 0 else 0)
	return true
