extends SceneTree
## Dev tool: list which biome each seed starts in, so catalog and QA captures
## can pin a world that opens on the theme under test.

const RoadPathGD: GDScript = preload("res://scripts/road_path.gd")


func _initialize() -> void:
	var path: Node = RoadPathGD.new()
	root.add_child(path)
	var names := {1: "forest", 3: "mountain", 4: "country"}
	var found := {}
	for probe in range(1, 60):
		path.call("set_world_seed", probe)
		var theme_id: int = int(path.call("theme_for_chunk", 0))
		var list: Array = found.get(theme_id, [])
		list.append(probe)
		found[theme_id] = list
	for theme_id in found:
		print("%s seeds: %s" % [names.get(theme_id, "?"), found[theme_id]])
	quit()
