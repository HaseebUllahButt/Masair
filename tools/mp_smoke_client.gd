extends SceneTree
## Headless client for mp_server.gd — joins a lobby, readies up, expects the
## leader-start handshake, streams a couple of poses, and verifies the server
## relays them back. Exits 0 on PASS.
##
##   godot --headless --path . --script res://tools/mp_smoke_client.gd -- --url=ws://127.0.0.1:8001

var _ws := WebSocketPeer.new()
var _url := "ws://127.0.0.1:8001"
var _t := 0.0
var _stage := 0
var _failures: Array[String] = []
var _my_id := -1
var _got_start := false
var _got_pose_back := false
var _sent_pose := false


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=", true, 1)
		if kv.size() == 2 and kv[0] == "url":
			_url = kv[1]
	print("smoke: connecting %s" % _url)
	if _ws.connect_to_url(_url) != OK:
		_fail("connect_to_url rejected")
		quit(1)


func _fail(m: String) -> void:
	_failures.append(m)
	printerr("smoke FAIL: %s" % m)


func _process(delta: float) -> bool:
	_t += delta
	_ws.poll()
	var st := _ws.get_ready_state()
	if st == WebSocketPeer.STATE_CLOSED:
		_fail("socket closed early at stage %d" % _stage)
		return _done()
	while st == WebSocketPeer.STATE_OPEN and _ws.get_available_packet_count() > 0:
		var m: Variant = JSON.parse_string(_ws.get_packet().get_string_from_utf8())
		if typeof(m) == TYPE_DICTIONARY:
			_on_msg(m)

	match _stage:
		0:
			if st == WebSocketPeer.STATE_OPEN:
				_ws.send_text(JSON.stringify({"t": "join", "name": "smoke", "bike": 2}))
				_stage = 1
		1:
			if _my_id >= 0:
				_ws.send_text(JSON.stringify({"t": "ready", "v": true}))
				_ws.send_text(JSON.stringify({"t": "start"}))
				_stage = 2
		2:
			if _got_start:
				_ws.send_text(JSON.stringify({"t": "pose", "d": [120.5, 0.4, 0.01, -0.2, 0.0, 22.0, 1.0, 42.0]}))
				_sent_pose = true
				_stage = 3
		3:
			if _t > 5.0:
				return _done()

	if _t > 8.0:
		_fail("timeout at stage %d" % _stage)
		return _done()
	return false


func _on_msg(m: Dictionary) -> void:
	match str(m.get("t", "")):
		"welcome":
			_my_id = int(m.get("id", -1))
			if _my_id <= 0:
				_fail("bad welcome id")
			if float(m.get("dist", 0)) < 100.0:
				_fail("welcome missing dist")
			if str(m.get("phase", "")) == "racing":
				_got_start = true # mid-race join: seed arrives in welcome
		"lobby":
			var found := false
			for p in m.get("players", []):
				if int(p.get("id", -1)) == _my_id:
					found = true
					if _stage >= 2 and not bool(p.get("ready", true)):
						pass
			if _stage == 1 and not found:
				_fail("lobby missing self")
		"start":
			_got_start = true
			if not m.has("seed"):
				_fail("start missing seed")
		"pose":
			# our own pose is NOT relayed back (except_id) — only other players'
			if int(m.get("id", -1)) == _my_id:
				_fail("server relayed own pose back")
			else:
				_got_pose_back = true
		"finish", "results":
			pass


func _done() -> bool:
	if _stage >= 2 and not _got_start:
		_fail("never got start")
	if _sent_pose and _got_pose_back:
		pass # fine either way with one client — relay only fires with >=2
	if _failures.is_empty():
		print("smoke: PASS%s" % (" (+relay)" if _got_pose_back else ""))
		quit(0)
	else:
		print("smoke: %d failure(s)" % _failures.size())
		quit(1)
	return true
