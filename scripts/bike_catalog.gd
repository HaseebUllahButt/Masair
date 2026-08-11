extends RefCounted
## Bike progression and tuning maths. The garage UI and motorcycle both read
## this table so displayed performance and ridden performance cannot drift.

const MAX_TUNE_LEVEL := 5
const TUNE_KEYS := ["engine", "brakes", "handling"]

const BIKES: Array[Dictionary] = [
	{
		"name": "MESA 400",
		"tagline": "LIGHT · HONEST · 200 KM/H",
		"unlock_m": 0.0,
		"top_speed": 55.5556,
		"engine_accel": 12.0,
		"brake_accel": 16.0,
		"lean_grip": 38.0,
		"high_speed_lean_rate": 0.55,
		"start_speed": 16.0,
	},
	{
		"name": "SABRE 650",
		"tagline": "TWIN CAFÉ · 220 KM/H",
		"unlock_m": 2000.0,
		"top_speed": 61.1111,
		"engine_accel": 14.3,
		"brake_accel": 17.8,
		"lean_grip": 40.0,
		"high_speed_lean_rate": 0.58,
		"start_speed": 17.0,
	},
	{
		"name": "TEMPEST 900",
		"tagline": "BIG TWIN · 250 KM/H",
		"unlock_m": 6000.0,
		"top_speed": 69.4444,
		"engine_accel": 17.0,
		"brake_accel": 20.0,
		"lean_grip": 42.0,
		"high_speed_lean_rate": 0.61,
		"start_speed": 18.0,
	},
]


static func empty_tuning() -> Dictionary:
	return {"engine": 0, "brakes": 0, "handling": 0}


static func tune_cost(bike_id: int, category: String, current_level: int) -> int:
	if category not in TUNE_KEYS or current_level < 0 or current_level >= MAX_TUNE_LEVEL:
		return 0
	var base: int = {"engine": 60, "brakes": 45, "handling": 50}[category]
	var bike_factor := 1.0 + float(clampi(bike_id, 0, BIKES.size() - 1)) * 0.45
	return int(round(float(base * (current_level + 1)) * bike_factor))


static func stats(bike_id: int, tuning: Dictionary) -> Dictionary:
	var safe_id := clampi(bike_id, 0, BIKES.size() - 1)
	var base: Dictionary = BIKES[safe_id]
	var engine := clampi(int(tuning.get("engine", 0)), 0, MAX_TUNE_LEVEL)
	var brakes := clampi(int(tuning.get("brakes", 0)), 0, MAX_TUNE_LEVEL)
	var handling := clampi(int(tuning.get("handling", 0)), 0, MAX_TUNE_LEVEL)
	return {
		"top_speed": float(base["top_speed"]) * (1.0 + float(engine) * 0.012),
		"engine_accel": float(base["engine_accel"]) * (1.0 + float(engine) * 0.06),
		"brake_accel": float(base["brake_accel"]) * (1.0 + float(brakes) * 0.07),
		"lean_grip": float(base["lean_grip"]) * (1.0 + float(handling) * 0.04),
		"high_speed_lean_rate": minf(0.74, float(base["high_speed_lean_rate"]) * (1.0 + float(handling) * 0.035)),
		"max_lat_speed": 13.0 + float(handling) * 0.35,
		"lean_in_rate_deg": 175.0 * (1.0 + float(handling) * 0.025),
		"lean_out_rate_deg": 215.0 * (1.0 + float(handling) * 0.025),
		"start_speed": float(base["start_speed"]),
	}
