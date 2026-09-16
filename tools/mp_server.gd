extends SceneTree
## SplendorServer — one process that both hosts the web build and runs races.
##
##   godot --headless --path . --script res://tools/mp_server.gd -- \
##       --http=8000 --ws=8001 --webroot=build/web --dist=5000
##
## Port --http serves --webroot over plain HTTP. Port --ws accepts WebSocket
## clients (JSON protocol, see net_client.gd). The host forwards both ports;
## players just open http://<host>:<http> — the page derives the ws address
## from window.location, so nobody types an address.
##
## Race flow: lobby (ready flags) -> leader sends "start" -> server picks the
## world seed and broadcasts it -> countdown rides out client-side -> first
## rider whose reported distance reaches --dist wins. Crash puts you back at
## kilometre zero on the SAME road; the race only ends when everyone finishes
## or RESULTS_TIMEOUT_S elapses after the first finisher.

const MIME := {
	"html": "text/html; charset=utf-8",
	"js": "application/javascript",
	"wasm": "application/wasm",
	"pck": "application/octet-stream",
	"css": "text/css",
	"png": "image/png",
	"jpg": "image/jpeg",
	"svg": "image/svg+xml",
	"ico": "image/x-icon",
	"json": "application/json",
	"ogg": "audio/ogg",
	"mp3": "audio/mpeg",
	"wav": "audio/wav",
	"woff2": "font/woff2",
}
const GZIP_EXTS := ["html", "js", "wasm", "pck", "css", "json", "svg"]
const MAX_HTTP_HEAD := 16384
const HTTP_READ_TIMEOUT_S := 5.0
const JOIN_TIMEOUT_S := 10.0
const RESULTS_TIMEOUT_S := 60.0

var _http := TCPServer.new()
var _ws_srv := TCPServer.new()
var _webroot := "build/web"
var _race_dist := 5000.0
var _http_pending: Array = [] # [{s:StreamPeerTCP, buf:PackedByteArray, t:float}]
var _ws_pending: Array = [] # [{ws:WebSocketPeer, t:float}] handshake done, not yet joined
var _players := {} # id -> {ws, name, bike, ready, dist, finished, ms}
var _next_id := 1
var _phase := "lobby" # lobby | racing
var _seed := 0
var _finish_order: Array = []
var _first_finish_t := -1.0


func _initialize() -> void:
	var http_port := 8000
	var ws_port := 8001
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=", true, 1)
		if kv.size() != 2:
			continue
		match kv[0]:
			"http": http_port = int(kv[1])
			"ws": ws_port = int(kv[1])
			"webroot": _webroot = kv[1]
			"dist": _race_dist = float(kv[1])
	if _http.listen(http_port) != OK:
		printerr("http listen failed on %d" % http_port)
		quit(1)
		return
	if _ws_srv.listen(ws_port) != OK:
		printerr("ws listen failed on %d" % ws_port)
		quit(1)
		return
	_precompress_dir(_webroot)
	print("SplendorServer up: files http://0.0.0.0:%d  ws :%d  root=%s  race=%dm" % [
		http_port, ws_port, _webroot, int(_race_dist)])


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _process(delta: float) -> bool:
	_poll_http(delta)
	_poll_ws()
	_poll_players()
	_check_results_timeout()
	return false


# --------------------------------------------------------------------- http


func _poll_http(delta: float) -> void:
	while _http.is_connection_available():
		var s := _http.take_connection()
		if s:
			_http_pending.append({"s": s, "buf": PackedByteArray(), "t": 0.0})
	for i in range(_http_pending.size() - 1, -1, -1):
		var c: Dictionary = _http_pending[i]
		var sock: StreamPeerTCP = c["s"]
		sock.poll()
		var st := sock.get_status()
		if st != StreamPeerTCP.STATUS_CONNECTED:
			_http_pending.remove_at(i)
			continue
		var n := sock.get_available_bytes()
		if n > 0:
			var r := sock.get_partial_data(MAX_HTTP_HEAD - c["buf"].size())
			if r[0] == OK:
				c["buf"] = c["buf"] + r[1]
		var head_end := _find_head_end(c["buf"])
		if head_end >= 0:
			_serve_http(sock, c["buf"].slice(0, head_end).get_string_from_ascii())
			_http_pending.remove_at(i)
			continue
		c["t"] += delta
		if c["buf"].size() >= MAX_HTTP_HEAD or c["t"] > HTTP_READ_TIMEOUT_S:
			if c["buf"].size() >= MAX_HTTP_HEAD:
				_send_http(sock, 431, "text/plain", "header too large".to_utf8_buffer())
			_http_pending.remove_at(i)


func _find_head_end(buf: PackedByteArray) -> int:
	for i in buf.size() - 3:
		if buf[i] == 13 and buf[i + 1] == 10 and buf[i + 2] == 13 and buf[i + 3] == 10:
			return i + 4
	return -1


func _serve_http(sock: StreamPeerTCP, head: String) -> void:
	var line := head.split("\r\n")[0]
	var parts := line.split(" ")
	var path := parts[1] if parts.size() >= 2 else "/"
	path = path.split("?")[0].uri_decode()
	if path == "/" or path.is_empty():
		path = "/index.html"
	var clean := path.simplify_path()
	if clean.begins_with("/"):
		clean = clean.substr(1)
	if clean.is_empty() or clean.begins_with(".."):
		_send_http(sock, 403, "text/plain", "forbidden".to_utf8_buffer())
		return
	var file_path := _webroot.path_join(clean)
	if not FileAccess.file_exists(file_path):
		_send_http(sock, 404, "text/plain", "not found".to_utf8_buffer())
		return
	var encoding := ""
	if _accepts_gzip(head) and FileAccess.file_exists(file_path + ".gz"):
		file_path += ".gz"
		encoding = "gzip"
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		_send_http(sock, 500, "text/plain", "read error".to_utf8_buffer())
		return
	var body := f.get_buffer(f.get_length())
	var ext := clean.get_extension().to_lower()
	_send_http(sock, 200, MIME.get(ext, "application/octet-stream"), body, encoding)


func _accepts_gzip(head: String) -> bool:
	for l in head.split("\r\n"):
		if l.to_lower().begins_with("accept-encoding:"):
			return "gzip" in l.to_lower()
	return false


func _precompress_dir(dir_path: String) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	for sub in d.get_directories():
		_precompress_dir(dir_path.path_join(sub))
	for name in d.get_files():
		var ext := name.get_extension().to_lower()
		if ext == "gz" or not (ext in GZIP_EXTS):
			continue
		var src := dir_path.path_join(name)
		var dst := src + ".gz"
		if FileAccess.file_exists(dst) and FileAccess.get_modified_time(dst) >= FileAccess.get_modified_time(src):
			continue
		var f := FileAccess.open(src, FileAccess.READ)
		if f == null:
			continue
		var raw := f.get_buffer(f.get_length())
		f = null
		var gz := raw.compress(FileAccess.COMPRESSION_GZIP)
		var out := FileAccess.open(dst, FileAccess.WRITE)
		if out == null:
			continue
		out.store_buffer(gz)
		out = null
		print("gzip: %s (%d KB -> %d KB)" % [src, raw.size() / 1024, gz.size() / 1024])


func _send_http(sock: StreamPeerTCP, code: int, mime: String, body: PackedByteArray, encoding: String = "") -> void:
	var reason: String = {200: "OK", 403: "Forbidden", 404: "Not Found", 431: "Header Too Large", 500: "Error"}.get(code, "OK")
	var enc_head := ""
	if not encoding.is_empty():
		enc_head = "Content-Encoding: %s\r\n" % encoding
	var head := "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n%sConnection: close\r\nVary: Accept-Encoding\r\nCross-Origin-Opener-Policy: same-origin\r\nCross-Origin-Embedder-Policy: require-corp\r\n\r\n" % [
		code, reason, mime, body.size(), enc_head]
	sock.put_data(head.to_ascii_buffer())
	sock.put_data(body)
	# give the socket a moment to flush before disconnecting
	for i in 8:
		sock.poll()
		OS.delay_msec(4)


# ------------------------------------------------------------------- lobby


func _poll_ws() -> void:
	while _ws_srv.is_connection_available():
		var s := _ws_srv.take_connection()
		if s == null:
			break
		var ws := WebSocketPeer.new()
		if ws.accept_stream(s) != OK:
			s.disconnect_from_host()
			continue
		_ws_pending.append({"ws": ws, "t": _now()})
	for i in range(_ws_pending.size() - 1, -1, -1):
		var c: Dictionary = _ws_pending[i]
		var ws: WebSocketPeer = c["ws"]
		ws.poll()
		var st := ws.get_ready_state()
		if st == WebSocketPeer.STATE_OPEN:
			# don't drain here — packets need the limbo slot's -1 sender id so a
			# fast "join" is not dropped as from an unknown peer
			_ws_pending.remove_at(i)
			_ws_limbo.append({"ws": ws, "t": _now()})
		elif st == WebSocketPeer.STATE_CLOSED or _now() - c["t"] > JOIN_TIMEOUT_S:
			_ws_pending.remove_at(i)


var _ws_limbo: Array = [] # open sockets that have not sent "join" yet


func _poll_players() -> void:
	for i in range(_ws_limbo.size() - 1, -1, -1):
		var ws: WebSocketPeer = _ws_limbo[i]["ws"]
		ws.poll()
		if ws.get_ready_state() != WebSocketPeer.STATE_OPEN or _now() - _ws_limbo[i]["t"] > JOIN_TIMEOUT_S:
			_ws_limbo.remove_at(i)
			continue
		_drain_packets(ws, -1, _ws_limbo[i])
	for id in _players.keys():
		var p: Dictionary = _players[id]
		var ws: WebSocketPeer = p["ws"]
		ws.poll()
		if ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
			_drop_player(id)
			continue
		_drain_packets(ws, id)


func _drain_packets(ws: WebSocketPeer, from_id: int, limbo: Dictionary = {}) -> void:
	while ws.get_available_packet_count() > 0:
		var msg: Variant = JSON.parse_string(ws.get_packet().get_string_from_utf8())
		if typeof(msg) != TYPE_DICTIONARY or not msg.has("t"):
			continue
		_on_msg(from_id, msg, limbo)


func _on_msg(from_id: int, m: Dictionary, limbo: Dictionary) -> void:
	match str(m["t"]):
		"join":
			if from_id != -1:
				return
			var id := _next_id
			_next_id += 1
			var ws: WebSocketPeer = limbo.get("ws")
			_ws_limbo.erase(limbo)
			var name := str(m.get("name", "rider")).substr(0, 16)
			if name.is_empty():
				name = "rider %d" % id
			_players[id] = {
				"ws": ws, "name": name, "bike": int(m.get("bike", 0)),
				"ready": false, "dist": 0.0, "finished": false, "ms": 0,
			}
			var welcome := {"t": "welcome", "id": id, "phase": _phase, "dist": _race_dist, "leader": _leader_id()}
			if _phase == "racing":
				welcome["seed"] = _seed
			_send(ws, welcome)
			_broadcast_lobby()
			print("join: %s (#%d)" % [name, id])
		"leave":
			if from_id != -1:
				_drop_player(from_id)
		"ready":
			if _players.has(from_id):
				_players[from_id]["ready"] = bool(m.get("v", false))
				_broadcast_lobby()
		"bike":
			if _players.has(from_id) and _phase == "lobby":
				_players[from_id]["bike"] = int(m.get("i", 0))
				_broadcast_lobby()
		"start":
			if _phase == "lobby" and from_id == _leader_id():
				_start_race()
		"pose":
			if _phase == "racing" and _players.has(from_id):
				var p: Dictionary = _players[from_id]
				var d: Array = m.get("d", [])
				if d.size() >= 8 and not p["finished"]:
					p["dist"] = float(d[7])
					if p["dist"] >= _race_dist:
						_finish(from_id)
				m["id"] = from_id
				_broadcast(m, from_id)
		"ping":
			var ws2: WebSocketPeer = _players[from_id]["ws"] if _players.has(from_id) else limbo.get("ws")
			if ws2:
				_send(ws2, {"t": "pong"})


func _leader_id() -> int:
	return _players.keys().min() if not _players.is_empty() else -1


func _start_race() -> void:
	_seed = randi()
	_phase = "racing"
	_finish_order = []
	_first_finish_t = -1.0
	for id in _players:
		_players[id]["dist"] = 0.0
		_players[id]["finished"] = false
		_players[id]["ready"] = false
	_broadcast({"t": "start", "seed": _seed, "in": 3.0, "dist": _race_dist})
	print("race start: seed=%d dist=%d riders=%d" % [_seed, int(_race_dist), _players.size()])


func _finish(id: int) -> void:
	var p: Dictionary = _players[id]
	p["finished"] = true
	_finish_order.append(id)
	if _finish_order.size() == 1:
		_first_finish_t = _now()
	_broadcast({"t": "finish", "id": id, "place": _finish_order.size()})
	if _finish_order.size() >= _players.size():
		_end_race()


func _check_results_timeout() -> void:
	if _phase != "racing" or _first_finish_t < 0.0:
		return
	if _now() - _first_finish_t > RESULTS_TIMEOUT_S:
		_end_race()


func _end_race() -> void:
	_phase = "lobby"
	var order: Array = []
	for i in _finish_order.size():
		var id: int = _finish_order[i]
		order.append({"id": id, "name": _players[id]["name"], "place": i + 1, "dnf": false})
	for id in _players:
		if not _players[id]["finished"]:
			order.append({"id": id, "name": _players[id]["name"], "dnf": true, "d": int(_players[id]["dist"])})
		_players[id]["ready"] = false
	_broadcast({"t": "results", "order": order})
	_broadcast_lobby()
	print("race over: %s" % str(order))


func _drop_player(id: int) -> void:
	var name: String = _players[id]["name"]
	_players.erase(id)
	_finish_order.erase(id)
	print("left: %s (#%d)" % [name, id])
	if _players.is_empty():
		_phase = "lobby"
		_finish_order = []
		_first_finish_t = -1.0
		return
	_broadcast({"t": "left", "id": id})
	_broadcast_lobby()
	if _phase == "racing" and _finish_order.size() >= _players.size() and _finish_order.size() > 0:
		_end_race()


func _broadcast_lobby() -> void:
	var players: Array = []
	for id in _players:
		var p: Dictionary = _players[id]
		players.append({"id": id, "name": p["name"], "bike": p["bike"], "ready": p["ready"]})
	_broadcast({"t": "lobby", "players": players, "leader": _leader_id(), "phase": _phase})


func _broadcast(m: Dictionary, except_id: int = -1) -> void:
	var text := JSON.stringify(m)
	for id in _players:
		if id == except_id:
			continue
		var ws: WebSocketPeer = _players[id]["ws"]
		if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			ws.send_text(text)


func _send(ws: WebSocketPeer, m: Dictionary) -> void:
	if ws and ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify(m))


func _finalize() -> void:
	for id in _players:
		_players[id]["ws"].close()
	_http.stop()
	_ws_srv.stop()
