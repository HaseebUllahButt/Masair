extends RefCounted
## Bike progression and tuning maths. The garage UI and motorcycle both read
## this table so displayed performance and ridden performance cannot drift.
##
## Every machine is a café racer: round lamp, clip-ons, teardrop tank, hump
## tail. Nothing here is a sports bike. Handling numbers are the *feel* of each
## frame — the Mesa flicks, the Raven plants — not a single stat that just
## climbs with unlock order.

const MAX_TUNE_LEVEL := 5
const TUNE_KEYS := ["engine", "brakes", "handling"]

const BIKES: Array[Dictionary] = [
	{
		"name": "MESA 400",
		"tagline": "HONEST CAFÉ · 200 KM/H",
		"unlock_m": 0.0,
		"top_speed": 55.5556,
		"engine_accel": 12.0,
		"brake_accel": 16.0,
		"engine_brake": 3.6,
		"lean_grip": 40.0,
		"high_speed_lean_rate": 0.60,
		"lean_in_rate_deg": 210.0,
		"lean_out_rate_deg": 255.0,
		"max_lat_speed": 13.4,
		"grip_damp": 2.45,
		"corner_load": 0.40,
		"max_lean_deg": 33.0,
		"steer_authority_speed": 7.5,
		"start_speed": 16.0,
		"gears": 6.0,
		"idle_pitch": 0.64,
		"pitch_span": 1.12,
	},
	{
		"name": "SABRE 650",
		"tagline": "SLIM TWIN · 220 KM/H",
		"unlock_m": 5000.0,
		"top_speed": 61.1111,
		"engine_accel": 14.3,
		"brake_accel": 17.8,
		"engine_brake": 3.3,
		"lean_grip": 42.0,
		"high_speed_lean_rate": 0.58,
		"lean_in_rate_deg": 200.0,
		"lean_out_rate_deg": 245.0,
		"max_lat_speed": 13.8,
		"grip_damp": 2.55,
		"corner_load": 0.38,
		"max_lean_deg": 33.0,
		"steer_authority_speed": 8.0,
		"start_speed": 17.0,
		"gears": 6.0,
		"idle_pitch": 0.56,
		"pitch_span": 1.18,
	},
	{
		"name": "HALCYON 750",
		"tagline": "BRITISH GREEN · 232 KM/H",
		"unlock_m": 12000.0,
		"top_speed": 64.4444,
		"engine_accel": 15.6,
		"brake_accel": 18.8,
		"engine_brake": 3.1,
		"lean_grip": 44.0,
		"high_speed_lean_rate": 0.56,
		"lean_in_rate_deg": 188.0,
		"lean_out_rate_deg": 232.0,
		"max_lat_speed": 14.1,
		"grip_damp": 2.68,
		"corner_load": 0.36,
		"max_lean_deg": 33.5,
		"steer_authority_speed": 8.6,
		"start_speed": 17.5,
		"gears": 5.0,
		"idle_pitch": 0.50,
		"pitch_span": 1.22,
	},
	{
		"name": "TEMPEST 900",
		"tagline": "BIG TWIN CAFÉ · 248 KM/H",
		"unlock_m": 22000.0,
		"top_speed": 68.8889,
		"engine_accel": 17.2,
		"brake_accel": 20.2,
		"engine_brake": 2.8,
		"lean_grip": 46.5,
		"high_speed_lean_rate": 0.54,
		"lean_in_rate_deg": 178.0,
		"lean_out_rate_deg": 220.0,
		"max_lat_speed": 14.5,
		"grip_damp": 2.80,
		"corner_load": 0.34,
		"max_lean_deg": 34.0,
		"steer_authority_speed": 9.2,
		"start_speed": 18.0,
		"gears": 5.0,
		"idle_pitch": 0.46,
		"pitch_span": 1.28,
	},
	{
		"name": "RAVEN 1100",
		"tagline": "BLACK BOMBER · 262 KM/H",
		"unlock_m": 36000.0,
		"top_speed": 72.7778,
		"engine_accel": 19.0,
		"brake_accel": 22.0,
		"engine_brake": 2.5,
		"lean_grip": 49.0,
		"high_speed_lean_rate": 0.50,
		"lean_in_rate_deg": 168.0,
		"lean_out_rate_deg": 208.0,
		"max_lat_speed": 15.0,
		"grip_damp": 2.95,
		"corner_load": 0.32,
		"max_lean_deg": 34.5,
		"steer_authority_speed": 10.0,
		"start_speed": 19.0,
		"gears": 4.0,
		"idle_pitch": 0.40,
		"pitch_span": 1.35,
	},
]


static func empty_tuning() -> Dictionary:
	return {"engine": 0, "brakes": 0, "handling": 0}


static func tune_cost(bike_id: int, category: String, current_level: int) -> int:
	if category not in TUNE_KEYS or current_level < 0 or current_level >= MAX_TUNE_LEVEL:
		return 0
	var base: int = {"engine": 150, "brakes": 115, "handling": 130}[category]
	var bike_factor := 1.0 + float(clampi(bike_id, 0, BIKES.size() - 1)) * 0.65
	var level_factor := float(current_level + 1) * pow(1.22, float(current_level))
	return int(round(float(base) * level_factor * bike_factor))


static func stats(bike_id: int, tuning: Dictionary) -> Dictionary:
	var safe_id := clampi(bike_id, 0, BIKES.size() - 1)
	var base: Dictionary = BIKES[safe_id]
	var engine := clampi(int(tuning.get("engine", 0)), 0, MAX_TUNE_LEVEL)
	var brakes := clampi(int(tuning.get("brakes", 0)), 0, MAX_TUNE_LEVEL)
	var handling := clampi(int(tuning.get("handling", 0)), 0, MAX_TUNE_LEVEL)
	var h := float(handling)
	return {
		"top_speed": float(base["top_speed"]) * (1.0 + float(engine) * 0.012),
		"engine_accel": float(base["engine_accel"]) * (1.0 + float(engine) * 0.06),
		"brake_accel": float(base["brake_accel"]) * (1.0 + float(brakes) * 0.07),
		"engine_brake": float(base["engine_brake"]) * (1.0 + float(engine) * 0.03),
		"lean_grip": float(base["lean_grip"]) * (1.0 + h * 0.045),
		"high_speed_lean_rate": minf(0.78, float(base["high_speed_lean_rate"]) * (1.0 + h * 0.04)),
		"max_lat_speed": float(base["max_lat_speed"]) + h * 0.38,
		"lean_in_rate_deg": float(base["lean_in_rate_deg"]) * (1.0 + h * 0.03),
		"lean_out_rate_deg": float(base["lean_out_rate_deg"]) * (1.0 + h * 0.03),
		"grip_damp": float(base["grip_damp"]) * (1.0 + h * 0.025),
		"corner_load": maxf(0.22, float(base["corner_load"]) * (1.0 - h * 0.03)),
		"max_lean_deg": minf(36.0, float(base["max_lean_deg"]) + h * 0.25),
		"steer_authority_speed": float(base["steer_authority_speed"]),
		"start_speed": float(base["start_speed"]),
		"gears": float(base["gears"]),
		"idle_pitch": float(base["idle_pitch"]),
		"pitch_span": float(base["pitch_span"]),
	}
