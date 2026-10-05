extends SceneTree
## Live-network check for net_client.gd against a real mp_server.gd child
## process, plus a stub WebSocket acceptor for the silent-socket timeout.
##   godot --headless --path . --script res://tests/test_multiplayer.gd

const NetClientGD := preload("res://scripts/net_client.gd")
const WS_PORT := 18081
const STUB_PORT := 18099
const WAIT := 240

var failures := 0
var _started := false
var server_pid := -1
var c1: Node
var c2: Node
var c3: Node
var c4: Node
var extra: Node
var onlines := {}
var lobbies := {}
var starts := {}
var finishes: Array = []
var results: Array = []
var results_seen := 0
var stub_srv := TCPServer.new()
var stub_peer: StreamPeerTCP
var stub_buf := PackedByteArray()
var stub_shook := false
var stub_join_count := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		failures += 1
		print("FAIL: ", what)


func _mk_client(tag: String) -> Node:
	var c: Node = NetClientGD.new()
	c.name = "Client_" + tag
	root.add_child(c)
	onlines[c] = 0
	lobbies[c] = []
	c.conn_state.connect(_on_conn_state.bind(c))
	c.lobby.connect(_on_lobby.bind(c))
	c.race_starting.connect(_on_race_starting.bind(c))
	c.race_finish.connect(_on_race_finish)
	c.race_results.connect(_on_race_results)
	return c


func _on_conn_state(state: String, c: Node) -> void:
	if state == "online":
		onlines[c] = int(onlines.get(c, 0)) + 1


func _on_lobby(list: Array, _my_id: int, _leader: int, _ph: String, c: Node) -> void:
	lobbies[c] = list


func _on_race_starting(seed: int, delay_s: float, dist: float, c: Node) -> void:
	starts[c] = {"seed": seed, "in": delay_s, "dist": dist}


func _on_race_finish(id: int, place: int) -> void:
	finishes.append({"id": id, "place": place})


func _on_race_results(order: Array) -> void:
	results = order
	results_seen += 1


func _url_checks() -> void:
	var n: Node = NetClientGD.new()
	root.add_child(n)
	var f: Callable = n.normalize_server_url
	check(f.call("ws://host:8001") == "ws://host:8001", "ws url passes through")
	check(f.call("wss://h:9001") == "wss://h:9001", "wss url passes through")
	check(f.call("ws://host/ws?a=1") == "ws://host/ws?a=1", "ws path and query preserved")
	check(f.call("wss://host/ws") == "wss://host/ws", "wss path preserved without port rewrite")
	check(f.call("ws://host") == "ws://host", "ws url without port kept as written")
	check(f.call("http://host:8000") == "ws://host:8001", "http 8000 maps to ws 8001")
	check(f.call("http://host") == "ws://host:8001", "http default port maps to 8001")
	check(f.call("https://host:9000") == "wss://host:9001", "https 9000 maps to wss 9001")
	check(f.call("http://[::1]:8000/") == "ws://[::1]:8001", "bracketed ipv6 http link maps port +1")
	check(f.call("10.0.0.5") == "ws://10.0.0.5:8001", "bare ip gets default ws port")
	check(f.call("10.0.0.5:9001") == "ws://10.0.0.5:9001", "bare ip keeps port")
	check(f.call("[::1]:8001") == "ws://[::1]:8001", "bracketed ipv6 passes")
	check(f.call("[::1]") == "ws://[::1]:8001", "bracketed ipv6 gets default port")
	check(f.call("") == "", "blank rejected")
	check(f.call("   ") == "", "whitespace rejected")
	check(f.call("ftp://h:21") == "", "unsupported scheme rejected")
	check(f.call("ws://h:0") == "", "port zero rejected")
	check(f.call("ws://h:65536") == "", "port above 65535 rejected")
	check(f.call("ws://h:65535") == "ws://h:65535", "port 65535 allowed")
	check(f.call("http://h:65535") == "", "http 65535 would map past the range")
	check(f.call("ws://h:") == "", "empty explicit port rejected")
	check(f.call("ws://u@h:8001") == "", "userinfo rejected")
	check(f.call("ws://h x:8001") == "", "spaces rejected")
	check(f.call("ws://h\t:8001") == "", "tabs rejected")
	check(f.call("ws://h\n:8001") == "", "newlines rejected")
	check(f.call("ws://:8001") == "", "missing host rejected")
	check(f.call("ws://h..x:8001") == "", "empty host label rejected")
	check(f.call("ws://h:notaport") == "", "non-numeric port rejected")
	n.queue_free()


func _start_server() -> void:
	var proj := ProjectSettings.globalize_path(".")
	server_pid = OS.create_process("godot", [
		"--headless", "--path", proj, "--script", "res://tools/mp_server.gd", "--",
		"--http=18080", "--ws=%d" % WS_PORT, "--webroot=build/web", "--dist=50",
	])
	check(server_pid > 0, "mp_server process spawned")
	stub_srv.listen(STUB_PORT)


func _stub_poll() -> void:
	if stub_peer == null and stub_srv.is_connection_available():
		stub_peer = stub_srv.take_connection()
	if stub_peer == null:
		return
	stub_peer.poll()
	if stub_peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		stub_peer = null
		return
	var avail := stub_peer.get_available_bytes()
	if avail <= 0:
		return
	stub_buf.append_array(stub_peer.get_data(avail)[1])
	if not stub_shook:
		var text := stub_buf.get_string_from_utf8()
		var at := text.find("\r\n\r\n")
		if at < 0:
			return
		var key := ""
		for line in text.substr(0, at).split("\r\n"):
			if line.to_lower().begins_with("sec-websocket-key:"):
				key = line.split(":", true, 1)[1].strip_edges()
		var h := HashingContext.new()
		h.start(HashingContext.HASH_SHA1)
		h.update((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").to_utf8_buffer())
		var resp := "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n" % Marshalls.raw_to_base64(h.finish())
		stub_peer.put_data(resp.to_utf8_buffer())
		stub_buf = stub_buf.slice(at + 4)
		stub_shook = true
	while stub_shook:
		if stub_buf.size() < 2:
			return
		var masked := (stub_buf[1] & 0x80) != 0
		var len := int(stub_buf[1] & 0x7f)
		var off := 2
		if len == 126:
			if stub_buf.size() < 4:
				return
			len = (stub_buf[2] << 8) | stub_buf[3]
			off = 4
		elif len == 127:
			return
		var mask_off := off
		if masked:
			off += 4
		if stub_buf.size() < off + len:
			return
		var payload := PackedByteArray()
		for i in len:
			var b: int = stub_buf[off + i]
			if masked:
				b ^= stub_buf[mask_off + (i % 4)]
			payload.append(b)
		if (stub_buf[0] & 0x0f) == 1 and payload.get_string_from_utf8().contains("\"join\""):
			stub_join_count += 1
		stub_buf = stub_buf.slice(off + len)


func _wait_frames(n: int) -> void:
	for i in n:
		_stub_poll()
		await process_frame


func _wait_until(done: Callable, budget: int, what: String) -> bool:
	for i in budget:
		_stub_poll()
		if done.call():
			return true
		await process_frame
	check(false, what)
	return false


func _connect(c: Node, url: String, rider: String) -> bool:
	c.connect_to(url, rider)
	return await _wait_until(func() -> bool: return c.state == "online", WAIT, "%s did not reach online" % c.name)


func _fin_pose() -> Dictionary:
	return {"t": "pose", "d": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 60.0]}


func _ids(list: Array) -> Array:
	var out: Array = []
	for p in list:
		out.append(int(p.get("id", -1)))
	return out


func _all_ready(list: Array, count: int) -> bool:
	if list.size() != count:
		return false
	for p in list:
		if not bool(p.get("ready", false)):
			return false
	return true


func _process(_d: float) -> bool:
	if _started:
		return false
	_started = true
	_run()
	return false


func _run() -> void:
	_url_checks()
	_start_server()
	await _wait_frames(120)

	var raw := WebSocketPeer.new()
	raw.connect_to_url("ws://127.0.0.1:%d" % WS_PORT)
	if not await _wait_until(
		func() -> bool:
			raw.poll()
			return raw.get_ready_state() == WebSocketPeer.STATE_OPEN,
		WAIT, "raw socket never opened"):
		return _finish()
	for i in 5:
		raw.send_text(JSON.stringify({"t": "join", "name": "burst", "bike": 0}))
	raw.send_text(JSON.stringify({"t": "ready", "v": true}))
	var welcomes := 0
	var raw_id := -1
	var raw_count := -1
	var raw_ready := false
	for i in WAIT:
		raw.poll()
		while raw.get_available_packet_count() > 0:
			var m: Variant = JSON.parse_string(raw.get_packet().get_string_from_utf8())
			if typeof(m) != TYPE_DICTIONARY:
				continue
			if m.get("t") == "welcome":
				welcomes += 1
				raw_id = int(m.get("id", -1))
			elif m.get("t") == "lobby":
				raw_count = m.get("players", []).size()
				for p in m.get("players", []):
					if int(p.get("id", -1)) == raw_id:
						raw_ready = p.get("ready") == true
		if welcomes > 0 and raw_ready:
			break
		await process_frame
	await _wait_frames(20)
	raw.poll()
	while raw.get_available_packet_count() > 0:
		var m: Variant = JSON.parse_string(raw.get_packet().get_string_from_utf8())
		if typeof(m) == TYPE_DICTIONARY and m.get("t") == "welcome":
			welcomes += 1
	check(welcomes == 1, "join burst produced exactly one welcome (%d)" % welcomes)
	check(raw_id > 0, "join burst assigned one id (%d)" % raw_id)
	check(raw_count == 1, "join burst lobby holds one player (%d)" % raw_count)
	check(raw_ready, "batched ready applied to the joined id")
	raw.close()
	await _wait_frames(30)

	c1 = _mk_client("a")
	if not await _connect(c1, "ws://127.0.0.1:%d" % WS_PORT, "alice"):
		return _finish()
	check(int(onlines[c1]) == 1, "one welcome for one connect")

	for i in 5:
		c1._send({"t": "join", "name": "ghost%d" % i})
	c1.set_ready(false)
	if not await _wait_until(func() -> bool: return lobbies[c1].size() > 0, WAIT, "no lobby after dup joins"):
		return _finish()
	check(lobbies[c1].size() == 1, "duplicate join burst still one player (%d)" % lobbies[c1].size())
	check(int(onlines[c1]) == 1, "duplicate joins produced no extra welcome")

	extra = _mk_client("stub")
	extra.connect_to("ws://127.0.0.1:%d" % STUB_PORT, "tester")
	if not await _wait_until(
		func() -> bool: return extra.ws.get_ready_state() == WebSocketPeer.STATE_OPEN and extra._join_sent,
		WAIT, "stub handshake never opened"):
		return _finish()
	await _wait_frames(60)
	check(stub_join_count == 1, "join sent exactly once on open socket (%d)" % stub_join_count)
	extra._connect_elapsed = NetClientGD.CONNECT_TIMEOUT_S
	if not await _wait_until(func() -> bool: return extra.state == "error:timeout", 60, "silent open socket never timed out"):
		return _finish()

	if not await _connect(extra, "ws://127.0.0.1:%d" % WS_PORT, "tester"):
		return _finish()
	check(extra.players.size() == 2, "retry after timeout sees the lobby")
	extra.leave()
	check(extra.state == "off" and extra.players.is_empty(), "leave clears state")

	var cancel: Node = _mk_client("cancel")
	cancel.connect_to("ws://127.0.0.1:%d" % WS_PORT, "fly")
	cancel.leave()
	check(cancel.state == "off" and cancel.players.is_empty() and cancel.my_id == -1, "cancel during connect is off and empty")
	cancel.queue_free()

	c2 = _mk_client("b")
	c3 = _mk_client("c")
	if not await _connect(c2, "ws://127.0.0.1:%d" % WS_PORT, "bob"):
		return _finish()
	if not await _connect(c3, "ws://127.0.0.1:%d" % WS_PORT, "carol"):
		return _finish()
	if not await _wait_until(func() -> bool: return lobbies[c1].size() >= 3, WAIT, "lobby never reached three riders"):
		return _finish()
	check(c1.players.size() == 3, "three players in lobby state (%d)" % c1.players.size())

	var dup := _mk_client("dup")
	if not await _connect(dup, "ws://127.0.0.1:%d" % WS_PORT, "dupper"):
		return _finish()
	if not await _wait_until(func() -> bool: return lobbies[c1].size() == 4, WAIT, "lobby never reached four riders"):
		return _finish()
	dup._send({"t": "leave"})
	dup._send({"t": "leave"})
	if not await _wait_until(func() -> bool: return lobbies[c1].size() == 3, WAIT, "batched leaves confused the lobby"):
		return _finish()
	check(c1.state == "online", "repeated leave did not kill the session")
	dup.leave()

	c1._on_msg({"t": "lobby", "players": [{"id": -2, "name": "bad"}, {"id": 99, "name": 42, "ready": "yes", "bike": "x", "dist": INF}, "junk"], "leader": "x", "phase": "bogus"})
	check(c1.phase == "lobby", "bogus phase normalized to lobby")
	check(c1.players.size() == 1, "malformed lobby entries dropped (%d)" % c1.players.size())
	check(c1.players.has(99) and c1.players[99]["ready"] == false and c1.players[99]["dist"] == 0.0, "lobby entry sanitized")
	var had_id: int = c1.my_id
	c1._on_msg({"t": "welcome", "id": -5})
	check(c1.my_id == had_id, "welcome with bad id ignored")
	c1._on_msg({"t": "start"})
	check(c1.phase == "lobby" and not starts.has(c1), "start without seed ignored")
	c1._on_msg({"t": "pose", "id": 4242, "d": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0]})
	check(not c1.riders.has(4242), "pose from unknown id spawned no rider")
	var results_before := results_seen
	c1._on_msg({"t": "results", "order": "banana"})
	check(results_seen == results_before + 1 and results.is_empty(), "malformed results emit empty order")
	check(c1.state == "online", "malformed messages did not kill the client")
	c1.set_ready(false)
	if not await _wait_until(func() -> bool: return c1.players.size() == 3, WAIT, "real lobby not restored after malformed test"):
		return _finish()

	c2.request_start()
	await _wait_frames(60)
	check(not starts.has(c2) and not starts.has(c1), "non-leader start was ignored")

	c1.ws.send_text("not json at all")
	c1.ws.send_text("[1,2,3]")
	c1.ws.send_text("{\"t\":\"pose\",\"d\":\"banana\"}")
	c1.ws.send_text("{\"t\":\"bogus\"}")
	c1.request_start()
	await _wait_frames(60)
	check(not starts.has(c1), "start without all-ready was ignored")
	check(c1.state == "online", "malformed packets did not kill the session")

	c1.set_ready(true)
	c2.set_ready(true)
	c3.set_ready(true)
	if not await _wait_until(func() -> bool: return _all_ready(lobbies[c1], 3), WAIT, "lobby never showed all ready"):
		return _finish()
	c1.request_start()
	if not await _wait_until(
		func() -> bool: return starts.has(c1) and starts.has(c2) and starts.has(c3),
		WAIT, "race_starting missing on a client"):
		return _finish()
	check(starts[c1]["seed"] == starts[c2]["seed"] and starts[c2]["seed"] == starts[c3]["seed"], "all clients share the seed")
	check(starts[c1]["in"] == starts[c2]["in"], "all clients share the countdown")

	c1._send(_fin_pose())
	c2._send(_fin_pose())
	c3._send(_fin_pose())
	if not await _wait_until(func() -> bool: return results.size() == 3, WAIT, "results never arrived"):
		return _finish()
	var fin_ids := _ids(finishes)
	for id in [c1.my_id, c2.my_id, c3.my_id]:
		check(id in fin_ids, "finish packet for rider %d" % id)
	check(_ids(results).size() == 3 and int(results[0]["place"]) == 1, "results carry all riders in order")

	c1.leave()
	if not await _wait_until(func() -> bool: return c2.leader_id == c2.my_id, WAIT, "successor never became leader"):
		return _finish()
	c2.set_ready(true)
	c3.set_ready(true)
	if not await _wait_until(func() -> bool: return _all_ready(lobbies[c2], 2), WAIT, "successor lobby not ready"):
		return _finish()
	starts.clear()
	finishes.clear()
	results = []
	c2.request_start()
	if not await _wait_until(func() -> bool: return starts.has(c2) and starts.has(c3), WAIT, "successor start missing"):
		return _finish()

	c4 = _mk_client("late")
	if not await _connect(c4, "ws://127.0.0.1:%d" % WS_PORT, "dave"):
		return _finish()
	check(c4.phase == "racing", "late joiner rides along mid-race")
	c4._send(_fin_pose())
	await _wait_frames(30)
	check(c4.my_id not in _ids(finishes), "late joiner finish was rejected")
	var seen_before := results_seen
	c2._send({"t": "leave"})
	c2._send({"t": "leave"})
	c3.leave()
	if not await _wait_until(
		func() -> bool: return results_seen > seen_before and c4.phase == "lobby",
		WAIT, "race did not end when every starter left"):
		return _finish()
	check(c4.players.size() == 1, "only the ride-along remains in the lobby (%d)" % c4.players.size())

	c1.connect_to("ws://127.0.0.1:%d" % WS_PORT, "alice")
	if not await _wait_until(func() -> bool: return c1.state == "online", WAIT, "reconnect failed"):
		return _finish()
	if not await _wait_until(func() -> bool: return c1.players.size() == 2, WAIT, "reconnect lobby wrong (%d)" % c1.players.size()):
		return _finish()
	check(int(onlines[c1]) == 2, "reconnect took a fresh peer")
	check(c4.players.size() == 2, "no duplicate player after reconnect (%d)" % c4.players.size())

	_finish()


func _finish() -> void:
	for c in [c1, c2, c3, c4, extra]:
		if c:
			c.leave()
			c.queue_free()
	if server_pid > 0:
		OS.kill(server_pid)
	if stub_peer:
		stub_peer.disconnect_from_host()
	stub_srv.stop()
	print("multiplayer self-check: %d failures" % failures)
	quit(1 if failures > 0 else 0)
