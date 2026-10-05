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
const CONNECT_TIMEOUT_S := 10.0

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
var _connect_elapsed := 0.0
var _join_sent := false
var auto_join := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS # polls stay alive through the countdown pause
	_load_cfg()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--server="):
			var from_arg := normalize_server_url(arg.trim_prefix("--server="))
			if not from_arg.is_empty():
				server_url = from_arg
		elif arg == "--multiplayer":
			auto_join = true


func suggested_url() -> String:
	## Where the page was served from is where the ws server lives. Only the
	## port differs (+1 over http), so joining is zero-config for friends.
	if OS.has_feature("web"):
		var bridge := Engine.get_singleton("JavaScriptBridge")
		if bridge:
			var loc: Variant = bridge.get_interface("location")
			if loc and loc.hostname:
				var scheme := "wss" if str(loc.protocol) == "https:" else "ws"
				# ws always lives one port above http; a page that arrived via
				# the :80 captive redirect reports no port — fall back to the
				# default pair 8000/8001.
				var port := int(str(loc.port))
				if port <= 0:
					port = 8000
				return "%s://%s:%d" % [scheme, loc.hostname, port + 1]
	return "ws://127.0.0.1:8001"


func normalize_server_url(raw: String) -> String:
	var text := raw
	if text.is_empty():
		return ""
	for i in text.length():
		var ch := text.unicode_at(i)
		if ch <= 32 or (ch >= 127 and ch <= 159):
			return ""
	var lower := text.to_lower()
	var scheme := "ws"
	var rest := text
	var http_map := false
	var has_scheme := false
	if lower.begins_with("wss://"):
		scheme = "wss"
		rest = text.substr(6)
		has_scheme = true
	elif lower.begins_with("ws://"):
		rest = text.substr(5)
		has_scheme = true
	elif lower.begins_with("https://"):
		scheme = "wss"
		rest = text.substr(8)
		has_scheme = true
		http_map = true
	elif lower.begins_with("http://"):
		rest = text.substr(7)
		has_scheme = true
		http_map = true
	elif lower.contains("://"):
		return ""
	var cut := rest.length()
	for sep in ["/", "?", "#"]:
		var at := rest.find(sep)
		if at >= 0:
			cut = mini(cut, at)
	var authority := rest.substr(0, cut)
	var tail := rest.substr(cut)
	if authority.contains("@"):
		return ""
	var host := ""
	var port_text := ""
	var has_port := false
	if authority.begins_with("["):
		var close := authority.find("]")
		if close < 0:
			return ""
		host = authority.substr(1, close - 1)
		var after := authority.substr(close + 1)
		if not after.is_empty():
			if not after.begins_with(":"):
				return ""
			port_text = after.substr(1)
			has_port = true
	else:
		var colon := authority.rfind(":")
		if colon >= 0:
			host = authority.substr(0, colon)
			port_text = authority.substr(colon + 1)
			has_port = true
		else:
			host = authority
		if host.contains(":"):
			return ""
	if not _valid_host(host):
		return ""
	var port := -1
	if has_port:
		if port_text.is_empty() or port_text.length() > 5:
			return ""
		for digit in port_text:
			if digit < "0" or digit > "9":
				return ""
		port = int(port_text)
		if port <= 0 or port > 65535:
			return ""
	if http_map:
		if port < 0:
			port = 8000
		port += 1
		if port > 65535:
			return ""
		return "%s://%s:%d" % [scheme, _host_out(host), port]
	if not has_scheme:
		if port < 0:
			port = 8001
		return "ws://%s:%d" % [_host_out(host), port]
	if port > 0:
		return "%s://%s:%d%s" % [scheme, _host_out(host), port, tail]
	return "%s://%s%s" % [scheme, _host_out(host), tail]


func _host_out(host: String) -> String:
	return "[%s]" % host if host.contains(":") else host


func _valid_host(host: String) -> bool:
	if host.is_empty() or host.length() > 253:
		return false
	for i in host.length():
		var ch := host.unicode_at(i)
		var ok := (ch >= 48 and ch <= 57) or (ch >= 65 and ch <= 90) \
			or (ch >= 97 and ch <= 122) or ch == 45 or ch == 46 or ch == 95 \
			or ch == 58 or ch == 37
		if not ok:
			return false
	if not host.contains(":"):
		for label in host.split("."):
			if label.is_empty():
				return false
	return true


func _load_cfg() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) == OK:
		rider_name = str(cfg.get_value("net", "name", rider_name))
		# A browser arrived from the host it should join. A URL saved from the
		# previous party must never override that origin or friends see a perfectly
		# healthy page whose JOIN button quietly targets yesterday's laptop.
		server_url = (
			suggested_url()
			if OS.has_feature("web")
			else str(cfg.get_value("net", "url", server_url))
		)
	else:
		# a name you never had to type — one less step before you're in
		rider_name = "rider %d" % randi_range(100, 999)
		if OS.has_feature("web"):
			server_url = suggested_url()


func _save_cfg() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("net", "name", rider_name)
	cfg.set_value("net", "url", server_url)
	cfg.save(CFG_PATH)


func connect_to(url: String, p_name: String) -> void:
	leave()
	var normalized := normalize_server_url(url)
	if normalized.is_empty():
		state = "error:invalid_address"
		conn_state.emit(state)
		return
	# WebSocketPeer can be closed and reused in theory, but browser and native
	# backends do not all clear a failed handshake identically. A fresh peer makes
	# LEAVE -> JOIN and retry-after-refusal deterministic.
	ws = WebSocketPeer.new()
	server_url = normalized
	rider_name = p_name.strip_edges().substr(0, 16)
	if rider_name.is_empty():
		rider_name = "rider %d" % randi_range(100, 999)
	_save_cfg()
	_connect_elapsed = 0.0
	_pose_acc = 0.0
	_join_sent = false
	state = "connecting"
	conn_state.emit(state)
	var err := ws.connect_to_url(server_url)
	if err != OK:
		_fail("refused")


func leave() -> void:
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_send({"t": "leave"})
	if ws.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		ws.close()
	my_id = -1
	leader_id = -1
	phase = "lobby"
	players.clear()
	_clear_riders()
	_connect_elapsed = 0.0
	_pose_acc = 0.0
	_join_sent = false
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
		_connect_elapsed += delta
		if st == WebSocketPeer.STATE_OPEN and not _join_sent:
			_join_sent = true
			_send({"t": "join", "name": rider_name, "bike": _my_bike()})
		if st == WebSocketPeer.STATE_CLOSED:
			_fail("refused")
			return
		elif _connect_elapsed >= CONNECT_TIMEOUT_S:
			_fail("timeout")
			return
	elif state == "online":
		if st != WebSocketPeer.STATE_OPEN:
			_fail("lost")
			return
	while st == WebSocketPeer.STATE_OPEN and ws.get_available_packet_count() > 0:
		var json := JSON.new()
		if json.parse(ws.get_packet().get_string_from_utf8()) != OK:
			continue
		var msg: Variant = json.data
		if typeof(msg) == TYPE_DICTIONARY and msg.has("t"):
			_on_msg(msg)
	if phase == "racing" and online() and my_id >= 0:
		_pose_acc += delta
		if _pose_acc >= 1.0 / POSE_HZ:
			_pose_acc = 0.0
			_send_pose()


func _fail(reason: String) -> void:
	if ws.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		ws.close()
	ws = WebSocketPeer.new()
	my_id = -1
	leader_id = -1
	phase = "lobby"
	players.clear()
	_clear_riders()
	_connect_elapsed = 0.0
	_pose_acc = 0.0
	_join_sent = false
	state = "error:" + reason
	conn_state.emit(state)
	lobby.emit([], -1, -1, "lobby")


func start_slot() -> Vector2i:
	## This rider's place on the start grid and the size of the field. Every
	## client holds the same lobby, so sorting its ids gives every client the
	## same grid without the server having to hand one out.
	var ids: Array = players.keys()
	ids.sort()
	var slot := ids.find(my_id)
	if slot < 0:
		return Vector2i(0, 1)
	return Vector2i(slot, ids.size())


func _my_bike() -> int:
	var game := get_node_or_null("/root/GameManager")
	return int(game.selected_bike) if game else 0


func _as_int(v: Variant, fallback: int = -1) -> int:
	match typeof(v):
		TYPE_INT, TYPE_FLOAT, TYPE_BOOL:
			return int(v)
		TYPE_STRING, TYPE_STRING_NAME:
			return int(v) if str(v).is_valid_int() else fallback
	return fallback


func _as_float(v: Variant, fallback: float = 0.0) -> float:
	match typeof(v):
		TYPE_INT, TYPE_FLOAT, TYPE_BOOL:
			return float(v)
		TYPE_STRING, TYPE_STRING_NAME:
			return float(v) if str(v).is_valid_float() else fallback
	return fallback


func _clean_players(raw: Variant) -> Array:
	var out: Array = []
	if typeof(raw) != TYPE_ARRAY:
		return out
	for p in raw:
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var id := _as_int(p.get("id", -1))
		if id <= 0:
			continue
		var rider_name_clean := str(p.get("name", "")).substr(0, 16)
		if rider_name_clean.is_empty():
			rider_name_clean = "rider %d" % id
		var dist := _as_float(p.get("dist", 0.0), 0.0)
		out.append({
			"id": id,
			"name": rider_name_clean,
			"bike": clampi(_as_int(p.get("bike", 0), 0), 0, 63),
			"ready": p.get("ready") is bool and p.get("ready"),
			"dist": dist if is_finite(dist) and dist >= 0.0 else 0.0,
		})
	return out


func _clean_results(raw: Variant) -> Array:
	var out: Array = []
	if typeof(raw) != TYPE_ARRAY:
		return out
	for e in raw:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var id := _as_int(e.get("id", -1))
		if id <= 0:
			continue
		out.append({
			"id": id,
			"name": str(e.get("name", "rider")).substr(0, 16),
			"place": _as_int(e.get("place", 0), 0),
			"dnf": e.get("dnf") is bool and e.get("dnf"),
			"d": _as_int(e.get("d", 0), 0),
		})
	return out


func _clean_phase(raw: Variant) -> String:
	var ph := str(raw)
	return ph if ph == "lobby" or ph == "racing" else "lobby"


func _valid_start(m: Dictionary) -> bool:
	for field in ["seed", "in", "dist"]:
		var value: Variant = m.get(field, 3.0 if field == "in" else 5000.0)
		if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
			return false
		if not is_finite(float(value)):
			return false
	if not m.has("seed") or float(m.seed) != floorf(float(m.seed)) or float(m.seed) < 0.0 or float(m.seed) > 4294967295.0:
		return false
	var delay := float(m.get("in", 3.0))
	var dist := float(m.get("dist", 5000.0))
	return delay >= 0.0 and delay <= 30.0 and dist > 0.0 and dist <= 1000000.0


func _store_players(list: Array) -> void:
	players.clear()
	for p in list:
		players[int(p["id"])] = p


func _on_msg(m: Dictionary) -> void:
	match str(m.get("t", "")):
		"welcome":
			var raw_id: Variant = m.get("id")
			if typeof(raw_id) != TYPE_INT and typeof(raw_id) != TYPE_FLOAT:
				return
			if not is_finite(float(raw_id)) or float(raw_id) != floorf(float(raw_id)) or float(raw_id) > 2147483647.0:
				return
			var id := _as_int(raw_id)
			if id <= 0:
				return
			my_id = id
			leader_id = _as_int(m.get("leader", -1))
			phase = _clean_phase(m.get("phase", "lobby"))
			_store_players(_clean_players(m.get("players")))
			lobby.emit(players.values(), my_id, leader_id, phase)
			state = "online"
			conn_state.emit(state)
			if phase == "racing" and _valid_start(m):
				# Mid-race joiner loads the same road and rides along; they are
				# simply marked DNF when results land.
				race_starting.emit(_as_int(m["seed"]), 0.0, _as_float(m.get("dist"), 5000.0))
		"lobby":
			_store_players(_clean_players(m.get("players")))
			leader_id = _as_int(m.get("leader", -1))
			phase = _clean_phase(m.get("phase", "lobby"))
			_drop_gone_riders()
			lobby.emit(players.values(), my_id, leader_id, phase)
		"start":
			if not _valid_start(m):
				return
			phase = "racing"
			race_starting.emit(_as_int(m["seed"]), _as_float(m.get("in", 3.0), 3.0), _as_float(m.get("dist"), 5000.0))
		"pose":
			var id := _as_int(m.get("id", -1))
			if id > 0 and id != my_id and players.has(id):
				_apply_pose(id, m.get("d", []))
		"finish":
			var fid := _as_int(m.get("id", -1))
			if fid > 0:
				race_finish.emit(fid, _as_int(m.get("place", 0), 0))
		"results":
			phase = "lobby"
			race_results.emit(_clean_results(m.get("order")))
			_clear_riders()
		"left":
			var lid := _as_int(m.get("id", -1))
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


func _apply_pose(id: int, raw_d: Variant) -> void:
	if typeof(raw_d) != TYPE_ARRAY:
		return
	var d: Array = raw_d
	if d.size() < 8:
		return
	for i in 8:
		if typeof(d[i]) != TYPE_FLOAT and typeof(d[i]) != TYPE_INT:
			return
		if not is_finite(float(d[i])):
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
