extends SceneTree
## Time the synchronous work inside game.restart() so the 48 ms budget has a
## visible breakdown instead of one number.

const MainScene := preload("res://scenes/main.tscn")
const RoadChunkGD := preload("res://scripts/road_chunk.gd")

var frames := 0
var main: Node


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 8:
		main = MainScene.instantiate()
		root.add_child(main)
		current_scene = main
	if frames == 30:
		var streamer: Node = main.get_node("RoadStreamer")
		var path: Node = root.get_node("RoadPath")
		# Ribbon alone vs ribbon + shoulder, on the real chunk code.
		for trial in 3:
			path.call("randomize_world")
			var t5 := Time.get_ticks_usec()
			var chunk: Node3D = RoadChunkGD.new() as Node3D
			var new_ms := float(Time.get_ticks_usec() - t5) / 1000.0
			chunk.name = "Probe%d" % trial
			var t6 := Time.get_ticks_usec()
			main.add_child(chunk)
			var add_ms := float(Time.get_ticks_usec() - t6) / 1000.0
			var t0 := Time.get_ticks_usec()
			chunk.call("setup_ribbon", 0, streamer.call("theme_for_chunk", 0))
			var sync_ms := float(Time.get_ticks_usec() - t0) / 1000.0
			var theme_names := {0: "forest", 1: "mountain", 2: "country", 3: "city"}
			print(
				"trial %d: setup_ribbon(0) theme=%s = %.1f ms"
				% [trial, theme_names.get(streamer.call("theme_for_chunk", 0), "?"), sync_ms]
			)
			print("   new()=%.1f ms add_child=%.1f ms" % [new_ms, add_ms])
			chunk.queue_free()
			# The emergency surface variant: road quads + markings only.
			var t2 := Time.get_ticks_usec()
			var fast: Node3D = RoadChunkGD.new() as Node3D
			fast.name = "ProbeFast%d" % trial
			main.add_child(fast)
			fast.call("setup_ribbon_fast", 0, streamer.call("theme_for_chunk", 0))
			print("   setup_ribbon_fast(0) = %.1f ms" % (float(Time.get_ticks_usec() - t2) / 1000.0))
			fast.queue_free()
			# Split the dressable parts: ribbon geometry vs shoulder grass/hedge.
			var parts: Node3D = RoadChunkGD.new() as Node3D
			parts.name = "ProbeParts%d" % trial
			main.add_child(parts)
			var t4 := Time.get_ticks_usec()
			parts.call("_configure", 0, streamer.call("theme_for_chunk", 0))
			print("   configure=%.1f ms" % (float(Time.get_ticks_usec() - t4) / 1000.0))
			var t3 := Time.get_ticks_usec()
			parts.call("_build_ribbon")
			var ribbon_ms := float(Time.get_ticks_usec() - t3) / 1000.0
			t3 = Time.get_ticks_usec()
			parts.call("_dress_shoulder_immediate")
			var dress_ms := float(Time.get_ticks_usec() - t3) / 1000.0
			print("   ribbon=%.1f ms dress=%.1f ms" % [ribbon_ms, dress_ms])
			parts.queue_free()
		var game: Node = root.get_node("GameManager")
		for trial in 3:
			var t1 := Time.get_ticks_usec()
			game.restart()
			print("restart() trial %d = %.1f ms" % [trial, float(Time.get_ticks_usec() - t1) / 1000.0])
		quit()
	return false
