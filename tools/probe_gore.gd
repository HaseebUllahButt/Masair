extends SceneTree
## Scratch probe: print the gore/junction geometry for a seed so screenshot z
## values can be aimed instead of guessed.

func _initialize() -> void:
	var path := root.get_node("RoadPath")
	for seed in [1, 2]:
		path.call("set_world_seed", seed)
		var centre: float = path.call("viewpoint_centre_for", 2800.0)
		var side: float = path.call("viewpoint_side_for", centre)
		var theme: int = int(path.call("theme_for_chunk", int(centre / 40.0)))
		var entry: float = centre - 1680.0
		print("seed=%d centre=%.0f side=%.0f theme=%d entry=%.0f merge=%.0f" % [seed, centre, side, theme, entry, centre + 1680.0])
		# Where the gore is painted (gap 1.6..11.0) and where paving runs.
		var z := entry
		var opened := -1.0
		var marked_a := -1.0
		var marked_b := -1.0
		var paved_b := -1.0
		var commit := -1.0
		while z < entry + 1500.0:
			var gap: float = path.call("spur_gap", z)
			var half: float = path.call("spur_half_width", z)
			var div: float = path.call("spur_divergence", z)
			if opened < 0.0 and half > 0.0:
				opened = z
			if marked_a < 0.0 and gap >= 1.6:
				marked_a = z
			if gap >= 1.6 and gap <= 11.0:
				marked_b = z
			if gap >= 0.12 and gap < 12.0:
				paved_b = z
			if commit < 0.0 and div >= 0.22:
				commit = z
			z += 5.0
		print("  lane opens z=%.0f | hatch z=%.0f..%.0f | paved till z=%.0f | commit z=%.0f" % [opened, marked_a, marked_b, paved_b, commit])
	quit()
