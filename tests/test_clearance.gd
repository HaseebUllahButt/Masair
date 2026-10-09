extends SceneTree
## Headless regression: no foliage in the corridor the rider occupies.
##
##   godot --headless --path . --script res://tests/test_clearance.gd
##
## The corridor is the carriageway plus the scenic spur, each widened by its
## shoulder. Any part of a plant whose underside sits below 6 m of road height
## must keep 1.5 m of air past the corridor edge, and nothing may cross the
## edge at all below 9 m — crowns may still lean in above that. The complaint
## this guards: leaves in the rider's face at speed.
##
## Every foliage bucket is measured from its real mesh bounds under its real
## transform — not the trunk's planting point — so a crown on the inside of a
## bend is caught at the station where it reaches the road, not the one where
## it was planted.

const RoadChunkGD: GDScript = preload("res://scripts/road_chunk.gd")
const RoadPathGD: GDScript = preload("res://scripts/road_path.gd")

## Mirrored from road_chunk.gd (kept literal so the same check can run against a
## baseline tree and demonstrate the intrusion it is now guarding).
const SHOULDER := RoadPathGD.SPUR_SHOULDER
const HALF := 8.0
const LOW_MARGIN := 1.5
const LOW_HEIGHT := 6.0
const OVERHANG_HEIGHT := 9.0
const SWAY := 0.12

var failures: int = 0
var _reported: int = 0
var _hits_by_label: Dictionary = {}


func check(ok: bool, what: String) -> void:
	if not ok:
		failures += 1
		print("FAIL: ", what)


func _intrusion(what: String, detail: String) -> void:
	failures += 1
	if _reported < 25:
		_reported += 1
		print("FAIL: %s — %s" % [what, detail])


func _bands(path: Node, z: float) -> Array:
	var bands: Array = [Vector2(-HALF - SHOULDER, HALF + SHOULDER)]
	var spur: Vector2 = path.call("spur_interval", z)
	if spur != Vector2.ZERO:
		bands.append(Vector2(spur.x - SHOULDER, spur.y + SHOULDER))
	return bands


func _part_intrudes(
	path: Node, world: Vector3, reach: float, bottom: float, sways: bool, label: String, index: int
) -> int:
	## Stations across the part's own span: on a bend the road can come to the
	## crown well away from the planted station.
	var sway: float = reach * SWAY + 0.05 if sways else 0.0
	var span: float = reach + sway + LOW_MARGIN + 2.0
	var hits := 0
	var step := 2.0
	var sz: float = world.z - span
	while sz <= world.z + span + 0.01:
		var centre: Vector3 = path.call("center_at", sz)
		var right: Vector3 = (path.call("frame_flat_at", sz) as Basis).x
		var slat: float = (world - centre).dot(right)
		for band in _bands(path, sz):
			var road_y: float = (path.call("point_at", sz, clampf(slat, band.x, band.y)) as Vector3).y
			if bottom >= road_y + OVERHANG_HEIGHT:
				continue
			var margin: float = LOW_MARGIN if bottom < road_y + LOW_HEIGHT else 0.0
			var need: float = reach + sway + margin
			if slat + need > band.x and slat - need < band.y:
				hits += 1
				_hits_by_label[label] = int(_hits_by_label.get(label, 0)) + 1
				_intrusion(
					"%s enters the corridor" % label,
					"chunk %d, z=%.0f lateral=%.1f reach=%.1f bottom=%.1f road_y=%.1f band=[%.1f,%.1f] need=%.1f"
					% [index, sz, slat, reach, bottom, road_y, band.x, band.y, need]
				)
				break
		sz += step
	return hits


func _check_bucket(
	chunk: Node3D, path: Node, instances: Array, mesh: Mesh, sways: bool, label: String, index: int
) -> int:
	var origin: Vector3 = chunk.get("_origin")
	var aabb: AABB = mesh.get_aabb()
	var centre_local: Vector3 = aabb.get_center()
	var hits := 0
	for xform in instances:
		var reach := 0.0
		var bottom := INF
		for corner in 8:
			var local: Vector3 = aabb.position + aabb.size * Vector3(
				float(corner & 1), float((corner >> 1) & 1), float((corner >> 2) & 1)
			)
			var off: Vector3 = (xform as Transform3D).basis * (local - centre_local)
			reach = maxf(reach, Vector2(off.x, off.z).length())
			bottom = minf(bottom, ((xform as Transform3D).basis * local).y + xform.origin.y)
		var world: Vector3 = xform * centre_local + origin
		hits += _part_intrudes(path, world, reach, bottom + origin.y, sways, label, index)
	return hits


func _check_scene_trees(chunk: Node3D, path: Node, index: int) -> int:
	## Kit trees are scene instances, not bucket entries — measure them from
	## their own mesh bounds so the sentinels follow the same rule.
	var hits := 0
	for child in chunk.get_children():
		# Kit foliage only — the benches, lamps and signs share the Lookout*
		# names but are furniture, and furniture answers to the footprint rule,
		# not the leaves-in-your-face rule.
		var is_foliage := (
			String(child.name).begins_with("LookoutSentinel")
			or String(child.name).begins_with("LookoutGrove")
		)
		if not (child is Node3D and is_foliage):
			continue
		var bounds := AABB()
		var found := false
		var meshes: Array[Node] = child.find_children("*", "MeshInstance3D", true, false)
		if child is MeshInstance3D:
			meshes.push_front(child)
		for mesh_node: Node in meshes:
			var mi := mesh_node as MeshInstance3D
			if mi.mesh == null:
				continue
			var local_frame := Transform3D.IDENTITY
			var ancestor: Node3D = mi
			while ancestor != child:
				local_frame = ancestor.transform * local_frame
				ancestor = ancestor.get_parent() as Node3D
			var a: AABB = local_frame * mi.get_aabb()
			bounds = a if not found else bounds.merge(a)
			found = true
		if not found:
			continue
		var xf: Transform3D = (child as Node3D).transform
		var centre_local: Vector3 = bounds.get_center()
		var world: Vector3 = xf * centre_local + (chunk.get("_origin") as Vector3)
		var reach := 0.0
		var bottom := INF
		for corner in 8:
			var local: Vector3 = bounds.position + bounds.size * Vector3(
				float(corner & 1), float((corner >> 1) & 1), float((corner >> 2) & 1)
			)
			var off: Vector3 = xf.basis * (local - centre_local)
			reach = maxf(reach, Vector2(off.x, off.z).length())
			bottom = minf(bottom, (xf.basis * local).y + xf.origin.y)
		hits += _part_intrudes(
			path, world, reach, bottom + (chunk.get("_origin") as Vector3).y, true, String(child.name), index
		)
	return hits


func _check_chunk(path: Node, index: int, theme_id: int) -> int:
	var chunk: Node3D = RoadChunkGD.new()
	chunk.name = "ClearanceChunk_%d" % index
	get_root().add_child(chunk)
	chunk.call("setup", index, theme_id)
	var hits := 0
	hits += _check_bucket(chunk, path, chunk.get("_crowns"), RoadChunkGD.unit_crown(), true, "crown", index)
	hits += _check_bucket(chunk, path, chunk.get("_conifers"), RoadChunkGD.unit_conifer(), true, "conifer", index)
	hits += _check_bucket(chunk, path, chunk.get("_leaves"), RoadChunkGD.unit_sphere(), true, "bush", index)
	hits += _check_bucket(chunk, path, chunk.get("_trunks"), RoadChunkGD.unit_trunk(), false, "limb", index)
	hits += _check_bucket(chunk, path, chunk.get("_grass"), RoadChunkGD.grass_tuft(), true, "grass", index)
	hits += _check_scene_trees(chunk, path, index)
	var foliage_near_road := 0
	var origin: Vector3 = chunk.get("_origin")
	for bucket in ["_crowns", "_conifers", "_trunks", "_leaves", "_grass"]:
		for xform in chunk.get(bucket):
			var wz: float = (xform as Transform3D).origin.z + origin.z
			var slat: float = ((xform as Transform3D).origin + origin - path.call("center_at", wz)).dot(
				(path.call("frame_flat_at", wz) as Basis).x
			)
			if absf(slat) < 30.0:
				foliage_near_road += 1
	check(foliage_near_road > 0, "chunk %d still plants foliage beside the road (roadside stays lush)" % index)
	chunk.free()
	return hits


func _biome_chunk(path: Node, theme_id: int) -> int:
	for region in 8:
		var index := region * 300 + 150
		if int(path.call("theme_for_chunk", index)) == theme_id:
			return index
	return -1


func _first_overlook(path: Node, theme_id: int) -> float:
	var first: float = RoadPathGD.VIEWPOINT_FIRST
	var period: float = RoadPathGD.VIEWPOINT_PERIOD
	var half: float = RoadPathGD.SPUR_HALF_SPAN
	var biome: float = RoadPathGD.BIOME_LENGTH
	for k in 24:
		var centre: float = first + period * float(k)
		var start: float = floorf(centre / biome) * biome
		if centre - half < start or centre + half > start + biome:
			continue
		if int(path.call("theme_at", centre)) == theme_id:
			return centre
	return -1.0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var path: Node = get_root().get_node_or_null("RoadPath")
	if path == null:
		path = RoadPathGD.new()
		path.name = "RoadPath"
		get_root().add_child(path)
	path.call("set_world_seed", 91827)

	var hits := 0
	for theme_id in [RoadChunkGD.Env.FOREST, RoadChunkGD.Env.COUNTRY]:
		var mid := _biome_chunk(path, theme_id)
		check(mid >= 0, "biome %d exists on the route" % theme_id)
		if mid < 0:
			continue
		# Ordinary riding chunks, biased toward the curviest stretch nearby —
		# that is where a cleared trunk still swings its crown over the tarmac.
		var ranked: Array = []
		for i in range(mid - 6, mid + 7):
			var curve := 0.0
			var z0 := float(i) * RoadChunkGD.LENGTH
			for s in 8:
				curve += absf(float(path.call("curvature_at", z0 + float(s) * 5.0)))
			ranked.append([i, curve])
		ranked.sort_custom(func(a: Array, b: Array) -> bool: return a[1] > b[1])
		for entry in ranked.slice(0, 4):
			hits += _check_chunk(path, int(entry[0]), theme_id)

		# The scenic detour: the platform chunk itself and the wooded climb down
		# toward the junction, where the tunnel planting used to meet overhead.
		var centre := _first_overlook(path, theme_id)
		check(centre >= 0.0, "biome %d hosts an overlook" % theme_id)
		if centre >= 0.0:
			var owner := int(path.call("viewpoint_index_for", centre))
			for i in range(owner - 6, owner + 2):
				hits += _check_chunk(path, i, theme_id)
			# The junction mouth, where the spur is still a lane on the edge of
			# the carriageway and a shifted tree can land on the other road.
			var mouth := int(floor((centre - RoadPathGD.SPUR_HALF_SPAN + 120.0) / RoadChunkGD.LENGTH))
			for i in range(mouth, mouth + 3):
				hits += _check_chunk(path, i, theme_id)

	check(hits == 0, "foliage kept clear of the corridor (%d intrusions)" % hits)
	for label in _hits_by_label:
		print("  intrusions %s: %d" % [label, _hits_by_label[label]])
	print("clearance self-check: %d failures" % failures)
	quit(1 if failures > 0 else 0)
