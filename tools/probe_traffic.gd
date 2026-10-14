extends SceneTree
## Deterministic 5 km drive with the real manager and car physics, without scenery.
## Every physics step checks physical footprints, not destination lane numbers:
## a collision halfway through a lane change must not disappear between samples.
## Run with --seed=2 --difficulty=2 --distance=5000 --speed=120 --lane=0.

const TrafficManagerGD: GDScript = preload("res://scripts/traffic_manager.gd")

class Rider:
	extends Node3D
	var track_z: float = 0.0
	var lateral: float = 0.0
	var speed: float = 33.33
	var half_length: float = 1.0
	var alive: bool = true
	func get_half_length() -> float:
		return half_length
	func get_half_width() -> float:
		return 0.38

var failures: int = 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var opts: Dictionary = {}
	for arg in OS.get_cmdline_user_args():
		var kv: PackedStringArray = arg.trim_prefix("--").split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	var world_seed: int = int(opts.get("seed", 2))
	var difficulty: int = int(opts.get("difficulty", 2))
	var distance: float = float(opts.get("distance", 5000.0))
	seed(world_seed)
	var path: Node = root.get_node("RoadPath")
	path.call("set_world_seed", world_seed)
	var rider: Rider = Rider.new()
	rider.speed = float(opts.get("speed", 120.0)) / 3.6
	rider.lateral = float(opts.get("lane", 0.0))
	root.add_child(rider)
	var manager: Node = TrafficManagerGD.new()
	root.add_child(manager)
	manager.call("bind_player", rider)
	manager.call("set_difficulty", difficulty)
	manager.set_process(false)
	await process_frame
	var elapsed: float = 0.0
	var step: float = 1.0 / 60.0
	var seen: Dictionary = {}
	var overlap_pairs: Dictionary = {}
	var hard_brakes: int = 0
	var changes: int = 0
	var oncoming: Dictionary = {}
	var close_spawns: int = 0
	var close_despawns: int = 0
	var min_gap: float = INF
	var min_headway: float = INF
	var peak: int = 0
	var simulation_us: int = 0
	var frames: int = 0
	while rider.track_z < distance:
		var tick: int = Time.get_ticks_usec()
		rider.track_z = float(path.call("advance", rider.track_z, rider.speed * step))
		manager.call("_process", step)
		var cars: Array = manager.get("_cars")
		peak = maxi(peak, cars.size())
		var present: Dictionary = {}
		for car: Node3D in cars:
			car.set_physics_process(false)
			car.call("_physics_process", step)
			var id: int = car.get_instance_id()
			var state: Dictionary = seen.get(id, {})
			var dz: float = float(car.track_z) - rider.track_z
			if state.is_empty() and absf(dz) < 260.0:
				close_spawns += 1
			if int(car.direction) != 1:
				oncoming[id] = true
			var hard: bool = (float(state.get("speed", car.speed)) - float(car.speed)) / step > 4.5
			if hard and not bool(state.get("hard", false)):
				hard_brakes += 1
			if bool(car.get("_lane_change_active")) and not bool(state.get("changing", false)):
				changes += 1
			present[id] = {"speed": car.speed, "hard": hard, "changing": car.get("_lane_change_active"), "dz": dz}
		for id: int in seen:
			if not present.has(id) and absf(float(seen[id].dz)) < 320.0:
				close_despawns += 1
		seen = present
		for i: int in cars.size():
			var a: Node3D = cars[i]
			for j: int in range(i + 1, cars.size()):
				var b: Node3D = cars[j]
				var width: float = float(a.get_half_width()) + float(b.get_half_width())
				# Include drawn wander: physical car sides are what the rider sees.
				var ax: float = float(a.get("_drawn_lateral"))
				var bx: float = float(b.get("_drawn_lateral"))
				if absf(ax - bx) >= width:
					continue
				var gap: float = absf(float(a.track_z) - float(b.track_z)) - float(a.get_half_length()) - float(b.get_half_length())
				min_gap = minf(min_gap, gap)
				var follower: Node3D = a if float(a.track_z) < float(b.track_z) else b
				min_headway = minf(min_headway, gap / maxf(float(follower.speed), 0.1))
				if gap < 0.0:
					var pair: String = "%d:%d" % [a.get_instance_id(), b.get_instance_id()]
					if not overlap_pairs.has(pair):
						print("OVERLAP t=%.2f rider_z=%.1f gap=%.2f | A kind=%d z=%.2f x=%.2f v=%.2f a=%.2f lane=%d moving=%s | B kind=%d z=%.2f x=%.2f v=%.2f a=%.2f lane=%d moving=%s" % [elapsed, rider.track_z, gap, a.kind, a.track_z, ax, a.speed, a.get("acceleration"), a.lane, a.get("_lane_change_active"), b.kind, b.track_z, bx, b.speed, b.get("acceleration"), b.lane, b.get("_lane_change_active")])
					overlap_pairs[pair] = true
		simulation_us += Time.get_ticks_usec() - tick
		elapsed += step
		frames += 1
		if frames % 120 == 0:
			await process_frame
	print("traffic probe seed=%d difficulty=%d: %.0f m in %.1f simulated s, peak=%d cars" % [world_seed, difficulty, rider.track_z, elapsed, peak])
	print("overlap/collision pairs=%d hard-brake events (>4.5 m/s²)=%d lane changes=%d" % [overlap_pairs.size(), hard_brakes, changes])
	print("min bumper gap=%.2f m min headway=%.2f s oncoming=%d close spawns=%d visible/mirror despawns=%d" % [min_gap, min_headway, oncoming.size(), close_spawns, close_despawns])
	print("traffic simulation CPU=%.3f ms/tick (includes probe checks, excludes rendering)" % [float(simulation_us) / float(frames) / 1000.0])
	failures = overlap_pairs.size() + oncoming.size() + close_spawns + close_despawns
	manager.call("_clear_cars")
	manager.free()
	rider.free()
	quit(1 if failures > 0 else 0)
