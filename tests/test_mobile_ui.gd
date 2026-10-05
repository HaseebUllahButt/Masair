extends SceneTree

const MainScene := preload("res://scenes/main.tscn")
const NetClientGD := preload("res://scripts/net_client.gd")
const SIZES: Array[Vector2i] = [
	Vector2i(360, 800), Vector2i(390, 844), Vector2i(844, 390), Vector2i(1280, 720),
]
const WS_PORT := 18501
const WAIT := 300

var failures := 0
var _started := false
var main: Node
var hud: Node
var server_pid := -1


func check(ok: bool, what: String) -> void:
	if not ok:
		failures += 1
		print("FAIL: ", what)


func _process(_d: float) -> bool:
	if _started:
		return false
	_started = true
	_run()
	return false


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _wait_until(done: Callable, budget: int, what: String) -> bool:
	for i in budget:
		if done.call():
			return true
		await process_frame
	check(false, what)
	return false


func _resize(s: Vector2i) -> void:
	root.size = s
	await _frames(10)


func _touch(pos: Vector2, pressed: bool, index: int = 0) -> void:
	var ev := InputEventScreenTouch.new()
	ev.pressed = pressed
	ev.position = pos
	ev.index = index
	Input.parse_input_event(ev)


func _tap(c: Control) -> bool:
	await _frames(2)
	var r := c.get_global_rect()
	if not c.is_visible_in_tree() or r.size.x <= 0.0:
		return false
	var center := r.get_center()
	check(_inside(r, Rect2(Vector2.ZERO, Vector2(root.size))), "%s tap target fully visible" % c.name)
	_touch(center, true)
	await _frames(2)
	_touch(center, false)
	await _frames(2)
	return true


func _inside(r: Rect2, vp: Rect2) -> bool:
	return r.position.x >= -1.0 and r.position.y >= -1.0 \
		and r.end.x <= vp.size.x + 1.0 and r.end.y <= vp.size.y + 1.0


func _menu_buttons() -> Array:
	var out: Array = []
	var stack: Array = [hud._menu_stack]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n == hud._music_dialog:
			continue
		if (n is Button or n is LineEdit) and n.is_visible_in_tree():
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


func _check_menu(s: Vector2i) -> void:
	var viewport := Rect2(Vector2.ZERO, Vector2(s))
	check(hud._start_menu.visible, "menu visible at %s" % s)
	var scroll_rect: Rect2 = hud._menu_scroll.get_global_rect()
	check(
		scroll_rect.position.x >= 0.0 and scroll_rect.end.x <= viewport.size.x + 1.0,
		"menu scroll inside width at %s" % s)
	check(scroll_rect.end.y <= viewport.size.y + 1.0, "menu scroll inside height at %s" % s)
	for b in _menu_buttons():
		var r: Rect2 = b.get_global_rect()
		check(r.size.y >= 47.5, "%s is %dpx tall at %s" % [b.name, int(r.size.y), s])
		check(
			r.position.x >= scroll_rect.position.x - 1.0 and r.end.x <= scroll_rect.end.x + 1.0,
			"%s stays inside the menu width at %s" % [b.name, s])
	var title: Rect2 = hud._menu_title.get_global_rect()
	check(title.size.x <= scroll_rect.size.x + 1.0, "title fits the menu width at %s" % s)
	check(
		hud._race_status.autowrap_mode != TextServer.AUTOWRAP_OFF,
		"race status wraps at %s" % s)


func _show_ride() -> void:
	paused = false
	hud._ride_started = true
	hud.hud_root.visible = true
	hud._start_menu.visible = false
	if hud._touch_controls:
		hud._touch_controls.visible = true
	hud._update_drive_pads()


func _show_menu() -> void:
	hud._start_menu.visible = true
	hud.hud_root.visible = false
	paused = true


func _check_ride_hud(s: Vector2i) -> void:
	var vp := Rect2(Vector2.ZERO, Vector2(s))
	check(hud.hud_root.visible, "ride hud visible at %s" % s)
	if s.x >= 600 and s.y >= 500:
		for item in hud._hud_defaults:
			check(item.custom_minimum_size == hud._hud_defaults[item]["min"], "desktop minimum restored for %s" % item.name)
		return
	hud._race_hud_card.visible = true
	var named := {
		"DistanceLabel": hud.distance_label, "BestLabel": hud.best_label,
		"SpeedLabel": hud.speed_label, "FlashLabel": hud.flash_label,
		"HintLabel": hud.hint_label, "CurrencyLabel": hud._currency_hud,
		"TouchMenu": hud._touch_menu_button, "SteerPad": hud._touch_steer,
		"BrakePad": hud._touch_brake, "RaceCard": hud._race_hud_card,
	}
	for key in named:
		var c: Control = named[key]
		if c == null or not c.is_visible_in_tree():
			continue
		check(_inside(c.get_global_rect(), vp), "%s inside viewport at %s: %s" % [key, s, c.get_global_rect()])
	var dist_r: Rect2 = hud.distance_label.get_global_rect()
	var best_r: Rect2 = hud.best_label.get_global_rect()
	var speed_r: Rect2 = hud.speed_label.get_global_rect()
	var card_r: Rect2 = hud._race_hud_card.get_global_rect()
	var menu_r: Rect2 = hud._touch_menu_button.get_global_rect()
	var cur_r: Rect2 = hud._currency_hud.get_global_rect()
	check(not dist_r.intersects(best_r), "distance and best separate at %s" % s)
	check(
		not menu_r.intersects(dist_r) and not menu_r.intersects(best_r)
		and not menu_r.intersects(speed_r),
		"menu clear of readouts at %s" % s)
	check(
		not card_r.intersects(dist_r) and not card_r.intersects(best_r)
		and not card_r.intersects(speed_r) and not card_r.intersects(menu_r),
		"race card clear of readouts at %s" % s)
	check(
		not cur_r.intersects(speed_r) and not cur_r.intersects(menu_r)
		and not cur_r.intersects(dist_r) and not cur_r.intersects(best_r),
		"currency clear of readouts at %s: currency %s, speed %s, menu %s, distance %s, best %s" % [s, cur_r, speed_r, menu_r, dist_r, best_r])
	var steer_r: Rect2 = hud._touch_steer.get_global_rect()
	var brake_r: Rect2 = hud._touch_brake.get_global_rect()
	check(not steer_r.intersects(brake_r), "steer and brake pads do not overlap at %s" % s)
	check(steer_r.size.y >= 48.0 and brake_r.size.y >= 48.0, "pads at least 48px at %s" % s)
	check(_inside(steer_r, vp) and _inside(brake_r, vp), "pads inside viewport at %s" % s)


func _check_panels(s: Vector2i) -> void:
	var vp := Rect2(Vector2.ZERO, Vector2(s))
	var panels: Array = [hud.crash_panel, hud.pause_panel, hud.confirm_panel, hud._results_panel]
	for p in panels:
		p.visible = true
	await _frames(4)
	for p in panels:
		var r: Rect2 = p.get_global_rect()
		check(_inside(r, vp), "%s inside viewport at %s (%s)" % [p.name, s, r])
		p.visible = false


func _check_scroll_reach() -> void:
	hud._race_panel.visible = true
	hud._ready_button.visible = true
	hud._race_start_button.visible = true
	for b in [hud._join_button, hud._ready_button, hud._race_start_button]:
		hud._menu_scroll.scroll_vertical = 0
		hud._menu_scroll.ensure_control_visible(b)
		await _frames(4)
		var r: Rect2 = b.get_global_rect()
		var s: Rect2 = hud._menu_scroll.get_global_rect()
		check(
			r.position.x >= s.position.x - 1.0 and r.position.y >= s.position.y - 1.0
			and r.end.x <= s.end.x + 1.0 and r.end.y <= s.end.y + 1.0,
			"menu scroll fully reaches %s" % b.name)


func _check_touch_drive(s: Vector2i) -> void:
	_show_ride()
	await _frames(2)
	var steer_r: Rect2 = hud._touch_steer.get_global_rect()
	_touch(steer_r.get_center() + Vector2(steer_r.size.x * 0.3, 0.0), true, 0)
	await _frames(3)
	check(hud._touch_steer_pointer != -1, "steer pad takes the touch at %s" % s)
	check(Input.get_action_strength(&"steer_right") > 0.0, "steer press drives right at %s" % s)
	var drag := InputEventScreenDrag.new()
	drag.index = 0
	drag.position = steer_r.get_center() - Vector2(steer_r.size.x * 0.3, 0.0)
	Input.parse_input_event(drag)
	await _frames(3)
	check(Input.get_action_strength(&"steer_left") > 0.0, "steer drag drives left at %s" % s)
	_touch(drag.position, false, 0)
	await _frames(3)
	check(
		Input.get_action_strength(&"steer_left") == 0.0 and Input.get_action_strength(&"steer_right") == 0.0,
		"steer released at %s" % s)
	var brake_r: Rect2 = hud._touch_brake.get_global_rect()
	_touch(brake_r.get_center(), true, 1)
	await _frames(3)
	check(Input.get_action_strength(&"brake") > 0.0, "brake pad touch holds brake at %s" % s)
	_touch(brake_r.get_center(), false, 1)
	await _frames(3)
	check(Input.get_action_strength(&"brake") == 0.0, "brake released at %s" % s)


func _check_releases() -> void:
	_show_ride()
	var releases: Array = [
		func() -> void: hud._set_paused(true),
		func() -> void: hud._show_start_menu(),
		func() -> void: hud._notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT),
		func() -> void: hud._layout_mobile_ui(),
	]
	for release in releases:
		hud._set_touch_steer(0.5)
		hud._pad_down(&"brake")
		check(
			Input.get_action_strength(&"steer_right") > 0.0 and Input.get_action_strength(&"brake") > 0.0,
			"steer and brake can be held")
		release.call()
		check(
			Input.get_action_strength(&"steer_right") == 0.0 and Input.get_action_strength(&"steer_left") == 0.0
			and Input.get_action_strength(&"brake") == 0.0,
			"held steer/brake released")
		paused = false
		hud._start_menu.visible = false
		hud.hud_root.visible = true
	paused = false


func _check_countdown_menu() -> void:
	_show_ride()
	hud._countdown_left = 2.0
	hud._on_touch_menu()
	check(hud._countdown_left > 0.0, "touch menu does not cancel the countdown")
	check(not hud._start_menu.visible, "touch menu does not open during countdown")
	hud._countdown_left = -1.0


func _check_disconnect() -> void:
	hud._on_conn_state("online")
	_show_ride()
	hud._countdown_left = 2.0
	paused = true
	hud._on_conn_state("error:lost")
	check(hud._countdown_left == -1.0, "disconnect clears the countdown")
	check(hud._start_menu.visible, "disconnect opens the join menu")
	check(hud._race_panel.visible, "disconnect shows the race panel")
	check(not hud._race_status.text.is_empty(), "disconnect leaves recovery text")
	await _frames(240)
	check(paused, "menu stays paused after disconnect")
	check(not hud._results_panel.visible, "no stale results panel")


func _check_results() -> void:
	hud._on_race_results([
		{"id": 1, "name": "alice", "place": 1, "dnf": false},
		{"id": 2, "name": "bob", "place": 2, "dnf": false},
	])
	check(hud._results_panel.visible, "results panel shows")
	check(hud._results_scroll != null, "results list scrolls")
	var vp := Rect2(Vector2.ZERO, root.size)
	check(_inside(hud._results_panel.get_global_rect(), vp), "results panel inside viewport")
	hud._return_to_race_lobby()
	check(not hud._results_panel.visible and hud._race_panel.visible, "rematch returns to the lobby")
	check(hud._start_menu.visible, "lobby is back on screen")


func _check_lobby_flow() -> void:
	var net: Node = hud._net
	check(net != null, "NetClient reachable from HUD")
	if net == null:
		return
	check(net._valid_start({"seed": 4294967295, "in": 3.0, "dist": 50.0}), "full unsigned server seed accepted")
	check(not net._valid_start({"seed": 4294967296, "in": 3.0, "dist": 50.0}), "oversized server seed rejected")
	var proj := ProjectSettings.globalize_path(".")
	server_pid = OS.create_process("godot", [
		"--headless", "--path", proj, "--script", "res://tools/mp_server.gd", "--",
		"--http=18500", "--ws=%d" % WS_PORT, "--webroot=build/web", "--dist=50",
	])
	check(server_pid > 0, "mobile flow server spawned")
	if server_pid <= 0:
		return
	var probe := StreamPeerTCP.new()
	probe.connect_to_host("127.0.0.1", WS_PORT)
	var listening := false
	for attempt in 100:
		probe.poll()
		if probe.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			listening = true
			break
		if probe.get_status() != StreamPeerTCP.STATUS_CONNECTING:
			probe.disconnect_from_host()
			probe.connect_to_host("127.0.0.1", WS_PORT)
		await create_timer(0.05, true).timeout
	probe.disconnect_from_host()
	check(listening, "mobile flow server listening")
	if not listening:
		return
	hud._show_start_menu()
	hud._race_panel.visible = true
	hud._refresh_race_panel()
	hud._server_edit.text = "ws://127.0.0.1:%d" % WS_PORT
	hud._name_edit.text = "ui"
	hud._menu_scroll.ensure_control_visible(hud._join_button)
	await _frames(10)
	if not await _tap(hud._join_button):
		check(false, "join button not tappable")
		return
	if not await _wait_until(func() -> bool: return net.state == "online", WAIT, "tap JOIN did not connect"):
		return
	var bot: Node = NetClientGD.new()
	bot.name = "BotClient"
	root.add_child(bot)
	bot.connect_to("ws://127.0.0.1:%d" % WS_PORT, "bot")
	if not await _wait_until(func() -> bool: return bot.state == "online", WAIT, "bot did not join"):
		return
	if not await _wait_until(func() -> bool: return hud._ready_button.is_visible_in_tree(), WAIT, "ready button never shown"):
		return
	hud._menu_scroll.ensure_control_visible(hud._ready_button)
	if not await _tap(hud._ready_button):
		check(false, "ready button not tappable")
		return
	check(hud._ready_pending or hud._ready_state, "ready sent or echoed")
	if not await _wait_until(func() -> bool: return hud._ready_state, WAIT, "ready echo never arrived"):
		return
	check(not hud._ready_button.disabled, "ready re-enabled by the lobby echo")
	bot.set_ready(true)
	if not await _wait_until(
		func() -> bool: return hud._race_start_button.is_visible_in_tree() and not hud._race_start_button.disabled,
		WAIT, "start never enabled"):
		return
	hud._menu_scroll.ensure_control_visible(hud._race_start_button)
	if not await _tap(hud._race_start_button):
		check(false, "start button not tappable")
		return
	if not await _wait_until(
		func() -> bool: return net.phase == "racing" and hud._countdown_left > 0.0,
		WAIT, "start tap did not begin the race"):
		return
	check(hud._start_menu.visible == false, "race hides the menu")
	var player: Node = root.find_child("Player", true, false)
	if player:
		player.set("track_z", 60.0)
	bot._send({"t": "pose", "d": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 60.0]})
	if not await _wait_until(func() -> bool: return hud._results_panel.visible, WAIT * 2, "results never arrived"):
		return
	if not await _tap(hud._results_button):
		check(false, "rematch button not tappable")
		return
	await _frames(4)
	check(hud._race_panel.visible and hud._start_menu.visible, "rematch returns to the lobby")
	bot.leave()
	bot.queue_free()


func _run() -> void:
	var net: Node = root.get_node_or_null("NetClient")
	if net == null:
		net = NetClientGD.new()
		net.name = "NetClient"
		root.add_child(net)
	main = MainScene.instantiate()
	root.add_child(main)
	current_scene = main
	await _frames(20)
	hud = main.get_node_or_null("HUD")
	check(hud != null, "HUD exists")
	if hud == null:
		return _finish()
	check(hud.hud_root != null, "game hud node enabled")
	hud._touch_seen = true
	if hud._touch_controls == null:
		hud._build_touch_controls()
	check(hud._touch_steer.get_node_or_null("SteerTrack") != null, "steer track named")
	root.content_scale_size = Vector2i.ZERO
	for s in SIZES:
		await _resize(s)
		_check_menu(s)
		_show_ride()
		await _frames(4)
		_check_ride_hud(s)
		await _check_panels(s)
		_show_menu()
		await _frames(2)
	await _resize(Vector2i(390, 844))
	_show_ride()
	await _resize(Vector2i(844, 390))
	_check_ride_hud(Vector2i(844, 390))
	await _check_touch_drive(Vector2i(844, 390))
	await _resize(Vector2i(390, 844))
	_show_menu()
	await _frames(4)
	_check_menu(Vector2i(390, 844))
	await _check_scroll_reach()
	_check_releases()
	_check_countdown_menu()
	await _check_disconnect()
	_check_results()
	await _check_lobby_flow()
	_finish()


func _finish() -> void:
	paused = false
	if server_pid > 0:
		OS.kill(server_pid)
	print("mobile ui self-check: %d failures" % failures)
	quit(1 if failures > 0 else 0)
