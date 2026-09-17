extends Node
## Client side of Splendor multiplayer: talks JSON/WebSocket to mp_server.gd.
##
## The web build auto-fills the address from window.location, so a friend who
## opened http://host:8000 joins ws://host:8001 without typing anything.
##
## Poses are road coordinates, not world transforms: everyone runs the same
## world_seed, so [track_z, lateral, heading, lean, wheelie, speed, alive,
## distance] fully reconstructs a rider on every client through
## RoadPath.road_transform_at().

signal conn_state(state: String) # "off" | "connecting" | "online" | "error:<msg>"
signal lobby(players: Array, my_id: int, leader_id: int, phase: String)
signal race_starting(seed: int, delay_s: float, dist_m: float)
signal race_finish(id: int, place: int)
signal race_results(order: Array)

const RemoteRiderGD := preload("res://scripts/remote_rider.gd")
const POSE_HZ := 15.0
const CFG_PATH := "user://net_client.cfg"

var ws := WebSocketPeer.new()
var state := "off"
var my_id := -1
var leader_id := -1
var phase := "lobby" # what the server says: lobby | racing
var players := {} # id -> {name, bike, ready}
var riders := {} # id -> RemoteRider node
var rider_name := "rider"
var server_url := "ws://127.0.0.1:8001"
var _pose_acc := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS # polls stay alive through the countdown pause
	_load_cfg()


func suggested_url() -> String:
	## Where the page was served from is where the ws server lives. Only the
	## port differs (+1 over http), so joining is zero-config for friends.
	if OS.has_feature("web"):
		var bridge := Engine.get_singleton("JavaScriptBridge")
		if bridge:
			var loc: Variant = bridge.get_interface("location")
			if loc and loc.hostname:
				var scheme := "wss" if str(loc.protocol) == "https:" else "ws"
				return "%s://%s:%d" % [scheme, loc.hostname, 8001]
	return "ws://127.0.0.1:8001"


func _load_cfg() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) == OK:
		rider_name = str(cfg.get_value("net", "name", rider_name))
		server_url = str(cfg.get_value("net", "url", server_url))
	else:
		# a name you never had to type — one less step before you're in
		rider_name = "rider %d" % randi_range(100, 999)


func _save_cfg() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("net", "name", rider_name)
	cfg.set_value("net", "url", server_url)
	cfg.save(CFG_PATH)


func connect_to(url: String, p_name: String) -> void:
	leave()
	server_url = url
	rider_name = p_name.substr(0, 16)
	_save_cfg()
	state = "connecting"
	conn_state.emit(state)
	var err := ws.connect_to_url(server_url)
	if err != OK:
		state = "error:connect failed (%d)" % err
		conn_state.emit(state)


func leave() -> void:
	if ws.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		ws.close()
	my_id = -1
	leader_id = -1
	phase = "lobby"
	players.clear()
	_clear_riders()
	if state != "off":
		state = "off"
		conn_state.emit(state)


func set_ready(v: bool) -> void:
	_send({"t": "ready", "v": v})


func send_bike(i: int) -> void:
	_send({"t": "bike", "i": i})


func request_start() -> void:
	_send({"t": "start"})


func online() -> bool:
	return state == "online"


func _send(m: Dictionary) -> void:
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify(m))


func _process(delta: float) -> void:
	ws.poll()
	var st := ws.get_ready_state()
	if state == "connecting":
		if st == WebSocketPeer.STATE_OPEN:
			_send({"t": "join", "name": rider_name, "bike": _my_bike()})
		elif st == WebSocketPeer.STATE_CLOSED:
			state = "error:refused"
			conn_state.emit(state)
	elif state == "online":
		if st != WebSocketPeer.STATE_OPEN:
			leave()
			state = "error:lost"
			conn_state.emit(state)
			lobby.emit([], -1, -1, "lobby")
			return
	while st == WebSocketPeer.STATE_OPEN and ws.get_available_packet_count() > 0:
		var msg: Variant = JSON.parse_string(ws.get_packet().get_string_from_utf8())
		if typeof(msg) == TYPE_DICTIONARY and msg.has("t"):
			_on_msg(msg)
	if phase == "racing" and online() and my_id >= 0:
		_pose_acc += delta
		if _pose_acc >= 1.0 / POSE_HZ:
			_pose_acc = 0.0
			_send_pose()


func _my_bike() -> int:
	var game := get_node_or_null("/root/GameManager")
	return int(game.selected_bike) if game else 0


func _on_msg(m: Dictionary) -> void:
	match str(m["t"]):
		"welcome":
			my_id = int(m.get("id", -1))
			leader_id = int(m.get("leader", -1))
			phase = str(m.get("phase", "lobby"))
			state = "online"
			conn_state.emit(state)
			if phase == "racing" and m.has("seed"):
				# Mid-race joiner loads the same road and rides along; they are
				# simply marked DNF when results land.
				race_starting.emit(int(m["seed"]), 0.0, float(m.get("dist", 5000.0)))
		"lobby":
			players.clear()
			for p in m.get("players", []):
				players[int(p["id"])] = p
			leader_id = int(m.get("leader", -1))
			phase = str(m.get("phase", "lobby"))
			_drop_gone_riders()
			lobby.emit(m.get("players", []), my_id, leader_id, phase)
		"start":
			phase = "racing"
			race_starting.emit(int(m["seed"]), float(m.get("in", 3.0)), float(m.get("dist", 5000.0)))
		"pose":
			var id := int(m.get("id", -1))
			if id >= 0 and id != my_id:
				_apply_pose(id, m.get("d", []))
		"finish":
			race_finish.emit(int(m.get("id", -1)), int(m.get("place", 0)))
		"results":
			phase = "lobby"
			race_results.emit(m.get("order", []))
			_clear_riders()
		"left":
			var lid := int(m.get("id", -1))
			players.erase(lid)
			_remove_rider(lid)


func _send_pose() -> void:
	var player: Node = get_tree().root.find_child("Player", true, false)
	if player == null:
		return
	# Race distance is road distance: distance_m carries near-miss bonus_m,
	# which would let credits shorten a race that is meant to run to --dist.
	_send({"t": "pose", "d": [
		_snapped(player.get("track_z")), _snapped(player.get("lateral")),
		_snapped(player.get("_heading")), _snapped(player.get("lean")),
		_snapped(player.get("wheelie")), _snapped(player.get("speed")),
		1.0 if bool(player.get("alive")) else 0.0,
		_snapped(maxf(float(player.get("track_z")), 0.0)),
	]})


func _snapped(v: Variant) -> float:
	## Two decimals is more resolution than a 15 Hz pose needs, and it keeps the
	## packets small enough that JSON-over-WS stays cheap on a LAN.
	return snappedf(float(v), 0.01)


func _apply_pose(id: int, d: Array) -> void:
	if d.size() < 8:
		return
	if players.has(id):
		players[id]["dist"] = float(d[7])
	var rider: Node3D = riders.get(id)
	if rider == null:
		rider = _spawn_rider(id)
	rider.apply_pose(d)


func _spawn_rider(id: int) -> Node3D:
	var rider: Node3D = RemoteRiderGD.new()
	rider.name = "Rider_%d" % id
	var info: Dictionary = players.get(id, {})
	rider.setup(str(info.get("name", "rider %d" % id)), int(info.get("bike", 0)))
	var parent: Node = get_tree().current_scene
	if parent == null:
		parent = get_tree().root
	parent.add_child(rider)
	riders[id] = rider
	return rider


func _remove_rider(id: int) -> void:
	var rider: Node3D = riders.get(id)
	if rider:
		rider.queue_free()
		riders.erase(id)


func _drop_gone_riders() -> void:
	for id in riders.keys():
		if not players.has(id):
			_remove_rider(id)


func _clear_riders() -> void:
	for id in riders.keys():
		_remove_rider(id)
