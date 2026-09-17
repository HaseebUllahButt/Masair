extends CanvasLayer
## Distance, best, speed, near-miss combo, crash prompt.

const BikeCatalog := preload("res://scripts/bike_catalog.gd")

@onready var hud_root: Control = $Root
@onready var distance_label: Label = $Root/DistanceLabel
@onready var best_label: Label = $Root/BestLabel
@onready var speed_label: Label = $Root/SpeedLabel
@onready var flash_label: Label = $Root/FlashLabel
@onready var crash_panel: PanelContainer = $Root/CrashPanel
@onready var crash_label: Label = $Root/CrashPanel/CrashLabel
@onready var pause_panel: PanelContainer = $Root/PausePanel
@onready var pause_label: Label = $Root/PausePanel/PauseLabel
@onready var hint_label: Label = $Root/HintLabel
@onready var confirm_panel: PanelContainer = $Root/ConfirmPanel
@onready var confirm_label: Label = $Root/ConfirmPanel/ConfirmLabel

const COMBO_COLORS := [Color(1, 0.85, 0.2), Color(1, 0.66, 0.25), Color(1, 0.45, 0.35), Color(0.7, 0.95, 1.0)]

var _game: Node
var _player: Node
var _flash: float = 0.0
var _hint: float = 6.0
var _shown_speed: float = 0.0
var _prompt_shown: bool = false
var _start_menu: Control
var _mood_id: int = 0
var _mood_value: Label
var _difficulty_index: int = 1
var _difficulty_value: Label
var _ride_started: bool = false
var _wallet_label: Label
var _currency_hud: Label
var _bike_name: Label
var _bike_note: Label
var _bike_stats: Label
var _bike_index: int = 0
var _tune_buttons: Dictionary = {}
var _start_button: Button
var _music: Node
var _music_preset: Label
var _music_folder: Button
var _music_track: Label
var _music_play: Button
var _music_dialog: FileDialog
var _font_display: Font
var _font_head: Font
var _font_ui: Font
var _font_italic: Font
var _font_kicker: Font
var _speed_caption: Label
var _confirming_restart: bool = false
var _paused_for_confirm: bool = false
var _restore_pause_on_cancel: bool = false
var _net: Node
var _race_panel: VBoxContainer
var _race_toggle: Button
var _race_status: Label
var _name_edit: LineEdit
var _server_edit: LineEdit
var _join_button: Button
var _lobby_label: Label
var _ready_button: Button
var _race_start_button: Button
var _ready_state: bool = false
var _countdown_left: float = -1.0
var _race_dist: float = 5000.0
var _my_finish_place: int = 0
var _pos_label: Label
var _results_panel: PanelContainer
var _results_label: Label
var _touch_controls: Control
var _touch_held: Dictionary = {}
var _touch_seen: bool = false
var _race_hud_card: PanelContainer
var _race_progress: ProgressBar
var _race_remaining: Label
var _race_gap: Label
var _results_button: Button
var _touch_steer: Control
var _touch_steer_thumb: ColorRect
var _touch_steer_pointer: int = -1
var _touch_steer_axis: float = 0.0
var _touch_auto_throttle: bool = false
var _menu_scroll: ScrollContainer
var _menu_stack: VBoxContainer

const MOOD_NAMES := ["GOLDEN DUSK", "DAYLIGHT", "MIDNIGHT"]
const DIFFICULTY_NAMES := ["OPEN ROAD", "SUNDAY RUN", "THE TON"]
const DIFFICULTY_COPY := [
	"10 vehicles  ·  generous gaps  ·  score ×1.0",
	"17 vehicles  ·  lively packs  ·  score ×1.35",
	"24 vehicles  ·  tight gaps  ·  score ×1.75",
]


func _ready() -> void:
	# The pause overlay must keep receiving input while the rest of the tree is paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load_type()
	_apply_ride_type()
	_game = get_node_or_null("/root/GameManager")
	crash_panel.visible = false
	pause_panel.visible = false
	if confirm_panel:
		confirm_panel.visible = false
	flash_label.modulate.a = 0.0
	if _touch_controls_wanted():
		_build_touch_controls()
	hint_label.text = _ride_hint()
	crash_panel.gui_input.connect(_on_crash_panel_input)
	_music = get_node_or_null("/root/MusicPlayer")
	_build_currency_hud()
	_build_start_menu()
	_net = get_node_or_null("/root/NetClient")
	if _net:
		_net.conn_state.connect(_on_conn_state)
		_net.lobby.connect(_on_lobby)
		_net.race_starting.connect(_on_race_starting)
		_net.race_finish.connect(_on_race_finish)
		_net.race_results.connect(_on_race_results)
	_build_race_hud()
	if _game:
		_game.distance_changed.connect(_on_distance)
		_game.best_changed.connect(_on_best)
		_game.crashed.connect(_on_crashed)
		_game.near_miss.connect(_on_near_miss)
		_game.restarted.connect(_on_restarted)
		_game.currency_changed.connect(_on_currency)
		_game.garage_changed.connect(_refresh_garage)
		_on_distance(_game.distance_m)
		_on_best(_game.best_m)
		_on_currency(_game.credits)
		_bike_index = _game.selected_bike
		_refresh_garage()
	call_deferred("_show_initial_menu")


func bind_player(player: Node) -> void:
	_player = player


func _process(delta: float) -> void:
	if _countdown_left > 0.0:
		_tick_countdown(delta)
	_sync_touch_drive()
	if _start_menu and _start_menu.visible:
		_layout_start_menu()
		if Input.is_action_just_pressed("toggle_day"):
			_cycle_menu_mood()
		return
	if _confirming_restart:
		if Input.is_action_just_pressed("pause"):
			_set_confirm_restart(false)
		elif Input.is_action_just_pressed("restart") and _game:
			_clear_confirm_restart()
			_game.restart()
	elif Input.is_action_just_pressed("restart") and _game:
		if _game.is_crashed:
			_game.restart()
		else:
			_set_confirm_restart(true)
	elif Input.is_action_just_pressed("pause") and _countdown_left < 0.0:
		if _game == null or not _game.is_crashed:
			_set_paused(not get_tree().paused)
	if _player:
		# Ease the readout so the digits do not strobe.
		_shown_speed = lerpf(_shown_speed, _player.speed * 3.6, 1.0 - exp(-9.0 * delta))
		speed_label.text = "%d" % int(_shown_speed)
		_update_cruise_caption()
		_update_prompt()
	_update_race_pos()

	if _flash > 0.0:
		_flash -= delta
		flash_label.modulate.a = clampf(_flash * 2.2, 0.0, 1.0)
		flash_label.scale = Vector2.ONE * (1.0 + clampf(_flash - 0.55, 0.0, 0.2) * 0.9)

	if _hint > 0.0:
		_hint -= delta
		hint_label.modulate.a = clampf(_hint, 0.0, 1.0) * 0.4

	if _game and _game.is_crashed:
		crash_panel.modulate.a = minf(crash_panel.modulate.a + delta * 3.0, 1.0)
	if get_tree().paused and Input.is_action_just_pressed("menu") and not _confirming_restart:
		_show_start_menu()


func _update_prompt() -> void:
	## The one piece of the overlook that has to be told rather than shown: that
	## the rider can leave the saddle. Only ever appears where it is true.
	var seated: bool = bool(_player.get("seated"))
	var can_sit: bool = _player.has_method("can_sit") and bool(_player.call("can_sit"))
	var wanted := ""
	if _touch_controls == null:
		if seated:
			wanted = "A/D  turn   ·   W/S  look up and down   ·   F  back to the bike"
		elif can_sit:
			wanted = "F  get off and sit down"
	if wanted == "":
		if _prompt_shown:
			_prompt_shown = false
			_hint = 0.0
			hint_label.modulate.a = 0.0
		return
	_prompt_shown = true
	hint_label.text = wanted
	hint_label.modulate.a = 0.62


func _set_paused(should_pause: bool) -> void:
	get_tree().paused = should_pause
	pause_panel.visible = should_pause
	if should_pause:
		_update_pause_label()


func _set_confirm_restart(show: bool) -> void:
	_confirming_restart = show
	if confirm_panel:
		confirm_panel.visible = show
	if show:
		_restore_pause_on_cancel = pause_panel.visible
		_paused_for_confirm = not get_tree().paused
		get_tree().paused = true
		pause_panel.visible = false
		if confirm_label:
			confirm_label.text = "START A NEW RIDE?\n\nR  confirm   ·   ESC  cancel"
	else:
		if _restore_pause_on_cancel:
			pause_panel.visible = true
			_restore_pause_on_cancel = false
		elif _paused_for_confirm:
			get_tree().paused = false
		_paused_for_confirm = false


func _clear_confirm_restart() -> void:
	_confirming_restart = false
	_paused_for_confirm = false
	_restore_pause_on_cancel = false
	if confirm_panel:
		confirm_panel.visible = false


func _update_cruise_caption() -> void:
	if _speed_caption == null:
		return
	var cruising: bool = _player != null and bool(_player.get("cruise_on"))
	_speed_caption.text = "CRUISE" if cruising else "KM/H"
	_speed_caption.modulate = Color(1, 0.94, 0.72, 0.85) if cruising else Color(1, 0.94, 0.72, 0.55)


func _on_distance(d: float) -> void:
	distance_label.text = "%d m" % int(d)


func _on_best(b: float) -> void:
	best_label.text = "%d m" % int(b)
	_refresh_garage()


func _on_currency(balance: int) -> void:
	if _currency_hud:
		_currency_hud.text = "CR %d" % balance
	_refresh_garage()


func _on_crashed() -> void:
	_clear_confirm_restart()
	_release_touch_actions()
	crash_panel.visible = true
	crash_panel.modulate.a = 0.0
	if _game and _game.in_race():
		var my_z := maxf(float(_player.get("track_z")), 0.0) if _player else 0.0
		var remaining := maxi(0, int(_race_dist - my_z))
		var action := "TAP TO REJOIN THE RACE" if _touch_controls else "R  rejoin the race"
		crash_label.text = "BIKE DOWN\n\n%d m to finish\n\n%s" % [remaining, action]
		return
	var d := int(_game.distance_m) if _game else 0
	var n: int = _game.near_miss_count if _game else 0
	var balance: int = int(_game.credits) if _game else 0
	var again := "TAP TO RIDE AGAIN" if _touch_controls else "R  ride again"
	crash_label.text = "RIDE OVER\n\n%d m   ·   %d near misses   ·   CR %d\n\n%s" % [d, n, balance, again]


func _on_near_miss(bonus: float, combo: int) -> void:
	var reward := combo * 2
	flash_label.text = (
		"+%d m  CLOSE CALL  ·  +%d CR" % [int(bonus), reward]
		if combo < 2
		else "+%d m  FLOW x%d  ·  +%d CR" % [int(bonus), combo, reward]
	)
	flash_label.modulate = COMBO_COLORS[mini(combo - 1, COMBO_COLORS.size() - 1)]
	_flash = 0.75


func show_lighting_mode(mode: int) -> void:
	const MODE_NAMES := ["DUSK MODE", "DAY MODE", "NIGHT MODE"]
	const MODE_COLORS := [Color("ffbd91"), Color("d8f2ff"), Color("a9c8ff")]
	var safe_mode := clampi(mode, 0, MODE_NAMES.size() - 1)
	flash_label.text = MODE_NAMES[safe_mode]
	flash_label.modulate = MODE_COLORS[safe_mode]
	_flash = 0.9


func _on_restarted() -> void:
	_clear_confirm_restart()
	crash_panel.visible = false
	pause_panel.visible = false
	flash_label.modulate.a = 0.0
	_flash = 0.0
	_shown_speed = 0.0
	flash_label.scale = Vector2.ONE
	if _player:
		_update_prompt()
		_update_cruise_caption()

func _update_pause_label() -> void:
	if pause_label == null:
		return
	if _touch_controls:
		pause_label.text = "ROADSIDE PAUSE\n\nTap MENU to resume"
	else:
		pause_label.text = "ROADSIDE PAUSE\n\nESC / P  resume   ·   M  ride menu"


func _build_start_menu() -> void:
	## Cinematic title over the live road. Keep the left stack short so the bike
	## owns the frame; settings and garage are one breath each.
	_start_menu = Control.new()
	_start_menu.name = "StartMenu"
	_start_menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	_start_menu.mouse_filter = Control.MOUSE_FILTER_STOP

	var veil := ColorRect.new()
	veil.set_anchors_preset(Control.PRESET_FULL_RECT)
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var veil_shader := Shader.new()
	veil_shader.code = """
shader_type canvas_item;
void fragment() {
	float left = 1.0 - smoothstep(0.0, 0.42, UV.x);
	float vig = smoothstep(0.34, 1.08, distance(UV, vec2(0.68, 0.48)));
	COLOR = vec4(0.03, 0.035, 0.04, left * 0.62 + vig * 0.28);
}
"""
	var veil_mat := ShaderMaterial.new()
	veil_mat.shader = veil_shader
	veil.material = veil_mat
	veil.color = Color.WHITE
	_start_menu.add_child(veil)

	var scroll := ScrollContainer.new()
	_menu_scroll = scroll
	scroll.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	scroll.offset_left = 40.0
	scroll.offset_top = 36.0
	scroll.offset_right = 480.0
	scroll.offset_bottom = -36.0
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_start_menu.add_child(scroll)

	var stack := VBoxContainer.new()
	_menu_stack = stack
	stack.custom_minimum_size.x = 404.0
	stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stack.add_theme_constant_override("separation", 10)
	scroll.add_child(stack)

	stack.add_child(_menu_label("OPEN COUNTRY", 13, Color("e8b089"), _font_kicker))
	var title := _menu_label("SPLENDOR", 78, Color("f4efe4"), _font_display)
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.45))
	title.add_theme_constant_override("shadow_offset_x", 0)
	title.add_theme_constant_override("shadow_offset_y", 4)
	title.add_theme_constant_override("line_spacing", -8)
	stack.add_child(title)
	stack.add_child(_menu_label("coffee  ·  petrol  ·  the long way round", 16, Color("c8c2b4"), _font_italic))

	var spacer := Control.new()
	spacer.custom_minimum_size.y = 18.0
	stack.add_child(spacer)

	_mood_value = _menu_label(MOOD_NAMES[_mood_id], 18, Color("f4efe4"), _font_head)
	stack.add_child(_cycle_row("LIGHT", _mood_value, _nudge_mood.bind(-1), _nudge_mood.bind(1)))
	_difficulty_value = _menu_label(DIFFICULTY_NAMES[_difficulty_index], 18, Color("f4efe4"), _font_head)
	stack.add_child(_cycle_row("TRAFFIC", _difficulty_value, _nudge_difficulty.bind(-1), _nudge_difficulty.bind(1)))

	var garage_gap := Control.new()
	garage_gap.custom_minimum_size.y = 14.0
	stack.add_child(garage_gap)
	_build_garage(stack)

	var ride_gap := Control.new()
	ride_gap.custom_minimum_size.y = 8.0
	stack.add_child(ride_gap)

	_start_button = Button.new()
	_start_button.text = "RIDE"
	_start_button.custom_minimum_size = Vector2(0.0, 50.0)
	_start_button.add_theme_font_override("font", _font_display)
	_start_button.add_theme_font_size_override("font_size", 28)
	_start_button.add_theme_color_override("font_color", Color("f4efe4"))
	_start_button.add_theme_color_override("font_hover_color", Color.WHITE)
	var ink := StyleBoxFlat.new()
	ink.bg_color = Color("c92a38")
	ink.content_margin_left = 22
	ink.content_margin_right = 22
	_start_button.add_theme_stylebox_override("normal", ink)
	var hover := ink.duplicate() as StyleBoxFlat
	hover.bg_color = Color("c47848")
	_start_button.add_theme_stylebox_override("hover", hover)
	_start_button.add_theme_stylebox_override("pressed", hover)
	var locked := ink.duplicate() as StyleBoxFlat
	locked.bg_color = Color(0.10, 0.09, 0.08, 0.80)
	_start_button.add_theme_stylebox_override("disabled", locked)
	_start_button.add_theme_color_override("font_disabled_color", Color("8a857a"))
	_start_button.pressed.connect(_start_ride)
	stack.add_child(_start_button)

	stack.add_child(_menu_label("MULTIPLAYER", 11, Color("9a9588"), _font_kicker))
	_race_toggle = _menu_button("PLAY WITH FRIENDS", 20)
	_race_toggle.custom_minimum_size = Vector2(0.0, 50.0)
	_race_toggle.pressed.connect(func() -> void:
		_race_panel.visible = not _race_panel.visible
		if _race_panel.visible:
			_refresh_race_panel()
			call_deferred("_focus_race_panel"))
	stack.add_child(_race_toggle)
	_build_race_panel(stack)

	_build_music_panel()
	add_child(_start_menu)


func _build_music_panel() -> void:
	## Quiet top-right jukebox: tone preset, one line for the track (click to
	## pick a folder), and transport. Nothing else.
	var panel := VBoxContainer.new()
	panel.name = "MusicPanel"
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 0)
	panel.position = Vector2(-320.0, 48.0)
	panel.size = Vector2(272.0, 0.0)
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.grow_vertical = Control.GROW_DIRECTION_END
	panel.add_theme_constant_override("separation", 6)
	_start_menu.add_child(panel)

	var preset_row := HBoxContainer.new()
	preset_row.alignment = BoxContainer.ALIGNMENT_END
	preset_row.add_theme_constant_override("separation", 10)
	var preset_caption := _menu_label("PRESET", 13, Color("d8d2c4"), _font_kicker)
	preset_caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	preset_row.add_child(preset_caption)
	var preset_prev := _garage_arrow("‹")
	preset_prev.custom_minimum_size = Vector2(36.0, 36.0)
	preset_prev.pressed.connect(_nudge_music_preset.bind(-1))
	preset_row.add_child(preset_prev)
	_music_preset = _menu_label("FLAT", 18, Color("f4efe4"), _font_head)
	_music_preset.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_music_preset.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_music_preset.custom_minimum_size.x = 120.0
	preset_row.add_child(_music_preset)
	var preset_next := _garage_arrow("›")
	preset_next.custom_minimum_size = Vector2(36.0, 36.0)
	preset_next.pressed.connect(_nudge_music_preset.bind(1))
	preset_row.add_child(preset_next)
	panel.add_child(preset_row)

	_music_folder = Button.new()
	_music_folder.text = "pick folder"
	_music_folder.flat = true
	_music_folder.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_music_folder.focus_mode = Control.FOCUS_NONE
	_music_folder.add_theme_font_override("font", _font_ui)
	_music_folder.add_theme_font_size_override("font_size", 13)
	_music_folder.add_theme_color_override("font_color", Color("9a9588"))
	_music_folder.add_theme_color_override("font_hover_color", Color("e8b55d"))
	_music_folder.add_theme_color_override("font_pressed_color", Color("c47848"))
	_music_folder.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	_music_folder.add_theme_stylebox_override("hover", StyleBoxEmpty.new())
	_music_folder.add_theme_stylebox_override("pressed", StyleBoxEmpty.new())
	_music_folder.pressed.connect(_open_music_folder)
	panel.add_child(_music_folder)

	_music_track = _menu_label("", 15, Color("c8c2b4"), _font_head)
	_music_track.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_music_track.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_music_track.custom_minimum_size = Vector2(272.0, 0.0)
	panel.add_child(_music_track)

	var transport := HBoxContainer.new()
	transport.alignment = BoxContainer.ALIGNMENT_END
	transport.add_theme_constant_override("separation", 6)
	var previous := _garage_arrow("‹")
	previous.custom_minimum_size = Vector2(40.0, 40.0)
	previous.pressed.connect(_music_previous)
	transport.add_child(previous)
	_music_play = _garage_arrow("▶")
	_music_play.custom_minimum_size = Vector2(48.0, 40.0)
	_music_play.pressed.connect(_music_toggle)
	transport.add_child(_music_play)
	var next := _garage_arrow("›")
	next.custom_minimum_size = Vector2(40.0, 40.0)
	next.pressed.connect(_music_next)
	transport.add_child(next)
	panel.add_child(transport)

	_music_dialog = FileDialog.new()
	_music_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_music_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_music_dialog.title = "Music folder"
	_music_dialog.use_native_dialog = true
	_music_dialog.process_mode = Node.PROCESS_MODE_ALWAYS
	_music_dialog.dir_selected.connect(_on_music_folder_selected)
	_start_menu.add_child(_music_dialog)

	if _music:
		_music.playlist_changed.connect(_refresh_music_ui)
		_music.track_changed.connect(func(_title: String) -> void: _refresh_music_ui())
		_music.playing_changed.connect(func(_on: bool) -> void: _refresh_music_ui())
		_music.preset_changed.connect(func(_i: int) -> void: _refresh_music_ui())
	_refresh_music_ui()


func _refresh_music_ui() -> void:
	if _music == null:
		return
	if _music_preset:
		_music_preset.text = str(_music.call("preset_name"))
	if _music_folder:
		var folder := str(_music.call("folder_label"))
		_music_folder.text = folder.to_lower() if folder != "PICK FOLDER" else "pick folder"
	if _music_track:
		var title := str(_music.call("track_title"))
		if title in ["no folder", "no playable tracks"]:
			_music_track.text = ""
		else:
			_music_track.text = title
	if _music_play:
		_music_play.text = "II" if bool(_music.call("is_playing")) else "▶"


func _nudge_music_preset(direction: int) -> void:
	if _music:
		_music.call("cycle_preset", direction)


func _open_music_folder() -> void:
	if _music_dialog == null:
		return
	var start := OS.get_system_dir(OS.SYSTEM_DIR_MUSIC)
	if _music:
		var current: String = str(_music.call("current_folder"))
		if not current.is_empty():
			start = current
	if not start.is_empty():
		_music_dialog.current_dir = start
	_music_dialog.popup_centered_ratio(0.55)


func _on_music_folder_selected(path: String) -> void:
	if _music:
		_music.call("set_folder", path)


func _music_toggle() -> void:
	if _music:
		_music.call("toggle_play")


func _music_previous() -> void:
	if _music:
		_music.call("previous_track")


func _music_next() -> void:
	if _music:
		_music.call("next_track")


func _build_currency_hud() -> void:
	_currency_hud = Label.new()
	_currency_hud.name = "CurrencyLabel"
	_currency_hud.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_currency_hud.position = Vector2(-80.0, 24.0)
	_currency_hud.size = Vector2(160.0, 32.0)
	_currency_hud.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_currency_hud.add_theme_font_override("font", _font_head)
	_currency_hud.add_theme_font_size_override("font_size", 18)
	_currency_hud.add_theme_color_override("font_color", Color("e8b55d"))
	_currency_hud.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	hud_root.add_child(_currency_hud)


func _build_garage(stack: VBoxContainer) -> void:
	var bike_row := HBoxContainer.new()
	bike_row.add_theme_constant_override("separation", 8)
	var previous := _garage_arrow("‹")
	previous.custom_minimum_size = Vector2(40.0, 48.0)
	previous.pressed.connect(_cycle_bike.bind(-1))
	bike_row.add_child(previous)

	var identity := VBoxContainer.new()
	identity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	identity.add_theme_constant_override("separation", 2)
	_bike_name = _menu_label("MESA 400", 24, Color("f4efe4"), _font_head)
	_bike_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	identity.add_child(_bike_name)
	_bike_note = _menu_label("", 13, Color("a8a294"), _font_ui)
	_bike_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	identity.add_child(_bike_note)
	_wallet_label = _menu_label("CR 0", 13, Color("e8b55d"), _font_head)
	_wallet_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	identity.add_child(_wallet_label)
	bike_row.add_child(identity)

	var next := _garage_arrow("›")
	next.custom_minimum_size = Vector2(40.0, 48.0)
	next.pressed.connect(_cycle_bike.bind(1))
	bike_row.add_child(next)
	stack.add_child(bike_row)

	var tunes := HBoxContainer.new()
	tunes.add_theme_constant_override("separation", 6)
	for category in BikeCatalog.TUNE_KEYS:
		var tune := Button.new()
		tune.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tune.custom_minimum_size.y = 34.0
		tune.alignment = HORIZONTAL_ALIGNMENT_CENTER
		tune.add_theme_font_override("font", _font_ui)
		tune.add_theme_font_size_override("font_size", 12)
		tune.add_theme_color_override("font_color", Color("ded8ca"))
		tune.pressed.connect(_buy_tune.bind(category))
		_style_tune_button(tune)
		_tune_buttons[category] = tune
		tunes.add_child(tune)
	stack.add_child(tunes)
	_bike_stats = null


func _garage_arrow(copy: String) -> Button:
	var button := Button.new()
	button.text = copy
	button.custom_minimum_size = Vector2(44.0, 52.0)
	button.add_theme_font_override("font", _font_display)
	button.add_theme_font_size_override("font_size", 28)
	button.add_theme_color_override("font_color", Color("f4efe4"))
	button.add_theme_color_override("font_hover_color", Color("e8b55d"))
	_style_tune_button(button)
	return button


func _style_tune_button(button: Button) -> void:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.06, 0.06, 0.07, 0.40)
	box.border_color = Color(0.76, 0.47, 0.28, 0.28)
	box.border_width_bottom = 1
	box.content_margin_left = 8
	box.content_margin_right = 8
	button.add_theme_stylebox_override("normal", box)
	var hover := box.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.16, 0.10, 0.08, 0.75)
	hover.border_color = Color(0.76, 0.47, 0.28, 0.65)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", hover)


func _cycle_bike(direction: int) -> void:
	if _game == null:
		return
	_bike_index = posmod(_bike_index + direction, _game.bike_count())
	_game.preview_bike(_bike_index)
	_refresh_garage()
	if _net and _net.online():
		_net.send_bike(_bike_index)


func _buy_tune(category: String) -> void:
	if _game and _game.buy_tune(_bike_index, category):
		_game.preview_bike(_bike_index)
	_refresh_garage()


func _refresh_garage() -> void:
	if _game == null or _bike_name == null:
		return
	var info: Dictionary = _game.bike_info(_bike_index)
	var unlocked: bool = _game.is_bike_unlocked(_bike_index)
	_bike_name.text = str(info["name"])
	_wallet_label.text = "CR %d" % int(_game.credits)
	if unlocked:
		_bike_note.text = str(info["tagline"]).to_lower()
		_bike_note.add_theme_color_override("font_color", Color("9a9588"))
	else:
		var remaining := maxf(0.0, float(info["unlock_m"]) - float(_game.best_m))
		_bike_note.text = "locked  ·  %.1f km more" % (remaining / 1000.0)
		_bike_note.add_theme_color_override("font_color", Color("d98078"))
	const SHORT := {"engine": "ENG", "brakes": "BRK", "handling": "HND"}
	for category in BikeCatalog.TUNE_KEYS:
		var button: Button = _tune_buttons[category]
		var level: int = _game.tune_level(_bike_index, category)
		var short: String = SHORT[category]
		if level >= BikeCatalog.MAX_TUNE_LEVEL:
			button.text = "%s  %d/%d" % [short, level, BikeCatalog.MAX_TUNE_LEVEL]
			button.disabled = true
		else:
			var cost: int = _game.tune_cost(_bike_index, category)
			button.text = "%s  %d/%d  ·  %d" % [short, level, BikeCatalog.MAX_TUNE_LEVEL, cost]
			button.disabled = not unlocked or int(_game.credits) < cost
	if _start_button:
		_start_button.disabled = not unlocked
		_start_button.text = "RIDE" if unlocked else "LOCKED"


func _menu_label(copy: String, size: int, color: Color, font: Font = null) -> Label:
	var label := Label.new()
	label.text = copy
	if font:
		label.add_theme_font_override("font", font)
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	return label


func _cycle_row(caption: String, value: Label, on_prev: Callable, on_next: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var label := _menu_label(caption, 13, Color("d8d2c4"), _font_kicker)
	label.custom_minimum_size.x = 72.0
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)
	var previous := _garage_arrow("‹")
	previous.custom_minimum_size = Vector2(36.0, 36.0)
	previous.pressed.connect(on_prev)
	row.add_child(previous)
	value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(value)
	var next := _garage_arrow("›")
	next.custom_minimum_size = Vector2(36.0, 36.0)
	next.pressed.connect(on_next)
	row.add_child(next)
	return row


func _nudge_mood(direction: int) -> void:
	_mood_id = posmod(_mood_id + direction, 3)
	if _mood_value:
		_mood_value.text = MOOD_NAMES[_mood_id]
	_preview_mood()


func _nudge_difficulty(direction: int) -> void:
	_difficulty_index = posmod(_difficulty_index + direction, DIFFICULTY_NAMES.size())
	if _difficulty_value:
		_difficulty_value.text = DIFFICULTY_NAMES[_difficulty_index]


func _cycle_menu_mood() -> void:
	## Same dusk → day → night order as T during a ride.
	_nudge_mood(1)


func _preview_mood() -> void:
	var main := _main_scene()
	if main and main.has_method("preview_mood"):
		main.call("preview_mood", _mood_id)


func _set_hero_view(on: bool) -> void:
	var vis: Node = get_tree().root.find_child("Visual", true, false)
	if vis and vis.has_method("set_hero_view"):
		vis.call("set_hero_view", on)


func _main_scene() -> Node:
	var scene := get_tree().current_scene
	if scene and scene.has_method("begin_ride"):
		return scene
	return get_tree().root.find_child("Main", true, false)


func _show_start_menu() -> void:
	_release_touch_actions()
	if _game:
		_game.bank_progress()
		_bike_index = _game.selected_bike
	get_tree().paused = true
	pause_panel.visible = false
	crash_panel.visible = false
	_clear_confirm_restart()
	hud_root.visible = false
	_start_menu.visible = true
	if not _ride_started:
		_park_on_road()
	_preview_mood()
	if _game:
		_game.preview_bike(_bike_index)
	_refresh_garage()
	_set_hero_view(true)
	if _start_button:
		_start_button.grab_focus()


func _park_on_road() -> void:
	## Spawn is kilometre zero: looking from in front of the bike there is no
	## road behind it, only the cut face of the terrain. Park a couple of chunks
	## in, on the carriageway, so both wheels sit on tarmac with road both ways.
	var player: Node = get_tree().root.find_child("Player", true, false)
	if player == null:
		return
	player.set("track_z", 120.0)
	player.set("lateral", 0.0)
	player.set("speed", 0.0)
	player.set("lean", 0.0)
	player.set("lat_vel", 0.0)
	if player.has_method("_place"):
		player.call("_place")
	var streamer: Node = get_tree().root.find_child("RoadStreamer", true, false)
	if streamer and streamer.has_method("reset_world"):
		streamer.call("reset_world")


func _show_initial_menu() -> void:
	if not _ride_started:
		_show_start_menu()
		# Web players almost certainly arrived at a host's address — put the
		# join box on the table instead of hiding it behind a menu fold.
		if _touch_controls_wanted() and _race_panel and not _race_panel.visible:
			_race_panel.visible = true
			_refresh_race_panel()
			call_deferred("_layout_start_menu")


func _focus_race_panel() -> void:
	if _menu_scroll == null or _race_panel == null or not _race_panel.visible:
		return
	_menu_scroll.ensure_control_visible(_race_panel)


func _layout_start_menu() -> void:
	if _menu_scroll == null or _menu_stack == null or _start_menu == null:
		return
	var viewport_size := get_viewport().get_visible_rect().size
	var narrow := viewport_size.x < 760.0
	var margin := 24.0 if narrow else 40.0
	var panel_width := maxf(1.0, minf(440.0, viewport_size.x - margin * 2.0))
	var panel_height := maxf(1.0, viewport_size.y - 72.0)
	_menu_scroll.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_menu_scroll.position = Vector2(margin, 36.0)
	_menu_scroll.size = Vector2(panel_width, panel_height)
	_menu_stack.custom_minimum_size.x = panel_width
	var music := _start_menu.get_node_or_null("MusicPanel") as Control
	if music:
		music.visible = not narrow


func _start_ride() -> void:
	if _start_menu == null or not _start_menu.visible:
		return
	_set_hero_view(false)
	if _game and not _game.select_bike(_bike_index):
		_set_hero_view(true)
		return
	var main := _main_scene()
	if main and main.has_method("begin_ride"):
		main.call("begin_ride", _mood_id, _difficulty_index)
	if _game:
		_game.restart()
	else:
		var player: Node = get_tree().root.find_child("Player", true, false)
		if player and player.has_method("reset_run"):
			player.call("reset_run")
	_ride_started = true
	_start_menu.visible = false
	hud_root.visible = true
	get_tree().paused = false
	_hint = 6.0
	hint_label.text = _ride_hint()


func _load_type() -> void:
	_font_display = _ttf("res://assets/fonts/NotoSans-ExtraCondensedBlack.ttf")
	_font_head = _ttf("res://assets/fonts/NotoSans-ExtraCondensedBold.ttf")
	_font_ui = _ttf("res://assets/fonts/NotoSans-ExtraCondensedMedium.ttf")
	_font_italic = _ttf("res://assets/fonts/NotoSans-CondensedLightItalic.ttf")
	_font_kicker = _tracked(_font_ui, 8)


func _ttf(path: String) -> FontFile:
	# load() resolves the import remap — the exported build ships the imported
	# .fontdata, not the raw .ttf, so a runtime file read would find nothing.
	var font: FontFile = load(path)
	font.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	return font


func _tracked(base: Font, extra: int) -> FontVariation:
	var variation := FontVariation.new()
	variation.base_font = base
	variation.spacing_glyph = extra
	return variation


func _apply_ride_type() -> void:
	_style_hud_label(distance_label, _font_head, 28)
	_style_hud_label(best_label, _font_head, 28)
	_style_hud_label(speed_label, _font_display, 72)
	_style_hud_label(flash_label, _font_head, 32)
	_style_hud_label(hint_label, _font_kicker, 13)
	_style_hud_label(crash_label, _font_head, 22)
	_style_hud_label(pause_label, _font_head, 22)
	if confirm_label:
		_style_hud_label(confirm_label, _font_head, 22)
	var distance_caption: Label = hud_root.get_node_or_null("DistanceCaption")
	var best_caption: Label = hud_root.get_node_or_null("BestCaption")
	_speed_caption = hud_root.get_node_or_null("SpeedCaption")
	if distance_caption:
		_style_hud_label(distance_caption, _font_kicker, 12)
	if best_caption:
		_style_hud_label(best_caption, _font_kicker, 12)
	if _speed_caption:
		_style_hud_label(_speed_caption, _font_kicker, 13)


func _style_hud_label(label: Label, font: Font, size: int) -> void:
	if label == null or font == null:
		return
	label.add_theme_font_override("font", font)
	label.add_theme_font_size_override("font_size", size)


# -------------------------------------------------------------------- touch


func _input(event: InputEvent) -> void:
	## Build lazily when the first touch arrives, then keep steering on the global
	## input path so a finger can drag beyond the pad without losing the bike.
	if event is InputEventScreenTouch:
		_touch_seen = true
		if _touch_controls == null:
			_build_touch_controls()
			return
		if not _touch_controls.visible or not _ride_started or _touch_steer == null:
			return
		if event.pressed:
			if _touch_steer_pointer == -1 and _touch_steer.get_global_rect().has_point(event.position):
				_touch_steer_pointer = event.index
				_apply_touch_steer_global(event.position)
				get_viewport().set_input_as_handled()
		elif event.index == _touch_steer_pointer:
			_touch_steer_pointer = -1
			_set_touch_steer(0.0)
			get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag and event.index == _touch_steer_pointer:
		_apply_touch_steer_global(event.position)
		get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		_release_touch_actions()


func _touch_controls_wanted() -> bool:
	if _touch_seen or OS.has_feature("mobile"):
		return true
	if not OS.has_feature("web"):
		return false
	if OS.has_feature("web_android") or OS.has_feature("web_ios"):
		return true
	return _browser_has_touch()


func _browser_has_touch() -> bool:
	var bridge := Engine.get_singleton("JavaScriptBridge")
	if bridge == null:
		return false
	return bool(bridge.eval("navigator.maxTouchPoints > 0 || ('ontouchstart' in window)"))


func _ride_hint() -> String:
	if _touch_controls != null:
		return "AUTO GAS  ·  slide LEAN to steer  ·  hold BRAKE  ·  tap HORN"
	return "W/S ride   ·   A/D lean   ·   Q/E look   ·   H horn   ·   C cruise   ·   F scenic bench   ·   T light   ·   R restart"


func _build_touch_controls() -> void:
	## Lives inside hud_root, so the pads follow the ride HUD: gone in the menu,
	## up while riding and through the countdown lights. HUD runs ALWAYS so the
	## pads still take input while the countdown holds the tree paused.
	_touch_controls = Control.new()
	_touch_controls.name = "TouchControls"
	_touch_controls.set_anchors_preset(Control.PRESET_FULL_RECT)
	_touch_controls.mouse_filter = Control.MOUSE_FILTER_PASS
	_touch_controls.z_index = 20
	_touch_controls.hidden.connect(_release_touch_actions)
	hud_root.add_child(_touch_controls)

	var viewport_width := get_viewport().get_visible_rect().size.x
	var narrow := viewport_width < 760.0
	var steer_width := 300.0 if not narrow else maxf(132.0, viewport_width * 0.36)
	var steer_copy := "‹   SLIDE TO LEAN   ›" if not narrow else "‹  LEAN  ›"
	var steer_font := 19 if not narrow else 15
	_touch_steer = _pad(steer_copy, Vector2(steer_width, 116.0), steer_font)
	_touch_steer.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 24)
	_touch_steer.gui_input.connect(_on_touch_steer_input)
	_touch_controls.add_child(_touch_steer)

	var track := ColorRect.new()
	track.position = Vector2(24.0, 79.0)
	track.size = Vector2(maxf(_touch_steer.size.x - 48.0, 84.0), 3.0)
	track.color = Color(0.90, 0.68, 0.42, 0.38)
	track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_touch_steer.add_child(track)

	_touch_steer_thumb = ColorRect.new()
	_touch_steer_thumb.position = Vector2((_touch_steer.size.x - 42.0) * 0.5, 76.0)
	_touch_steer_thumb.size = Vector2(42.0, 8.0)
	_touch_steer_thumb.color = Color("e8b089")
	_touch_steer_thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_touch_steer.add_child(_touch_steer_thumb)

	var pedals := VBoxContainer.new()
	pedals.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 24)
	pedals.add_theme_constant_override("separation", 10)
	var pedal_top := HBoxContainer.new()
	pedal_top.alignment = BoxContainer.ALIGNMENT_END
	pedal_top.add_theme_constant_override("separation", 10)
	var auto_gas := _menu_label("AUTO GAS", 13, Color(0.56, 0.82, 0.48, 0.9), _font_kicker)
	auto_gas.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	pedal_top.add_child(auto_gas)
	var horn := _hold_pad("HORN", &"horn", Vector2(96.0, 48.0), 17)
	horn.size_flags_horizontal = Control.SIZE_SHRINK_END
	pedal_top.add_child(horn)
	pedals.add_child(pedal_top)
	var brake_width := 164.0 if not narrow else maxf(120.0, viewport_width * 0.34)
	var brake := _hold_pad("BRAKE", &"brake", Vector2(brake_width, 116.0), 23)
	brake.size_flags_horizontal = Control.SIZE_SHRINK_END
	pedals.add_child(brake)
	_touch_controls.add_child(pedals)

	var menu := _pad("MENU", Vector2(112.0, 48.0), 16)
	menu.set_anchors_preset(Control.PRESET_TOP_LEFT)
	menu.position = Vector2(24.0, 88.0)
	menu.pressed.connect(_on_touch_menu)
	_touch_controls.add_child(menu)


func _pad(copy: String, pad_size: Vector2, font_size: int) -> Button:
	var pad := Button.new()
	pad.text = copy
	pad.custom_minimum_size = Vector2(maxf(pad_size.x, 48.0), maxf(pad_size.y, 48.0))
	pad.focus_mode = Control.FOCUS_NONE
	pad.add_theme_font_override("font", _font_display)
	pad.add_theme_font_size_override("font_size", font_size)
	pad.add_theme_color_override("font_color", Color(0.96, 0.93, 0.86, 0.92))
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.04, 0.05, 0.07, 0.42)
	box.border_color = Color(0.90, 0.68, 0.42, 0.50)
	box.set_border_width_all(2)
	box.set_corner_radius_all(16)
	pad.add_theme_stylebox_override("normal", box)
	var held := box.duplicate() as StyleBoxFlat
	held.bg_color = Color(0.79, 0.47, 0.28, 0.58)
	held.border_color = Color(1.0, 0.82, 0.55, 0.85)
	pad.add_theme_stylebox_override("pressed", held)
	return pad


func _hold_pad(copy: String, action: StringName, pad_size: Vector2, font_size: int) -> Button:
	var pad := _pad(copy, pad_size, font_size)
	pad.button_down.connect(_pad_down.bind(action))
	pad.button_up.connect(_pad_up.bind(action))
	return pad


func _pad_down(action: StringName) -> void:
	_touch_held[action] = true
	Input.action_press(action)


func _pad_up(action: StringName) -> void:
	_touch_held.erase(action)
	Input.action_release(action)


func _release_touch_actions() -> void:
	## A pad's finger can be lost — panel opened over it, tab backgrounded —
	## and a phantom held GAS is a crash on the next spawn. Release what we held.
	_touch_steer_pointer = -1
	_set_touch_steer(0.0)
	if _touch_auto_throttle:
		Input.action_release(&"throttle")
		_touch_auto_throttle = false
	for action in _touch_held:
		Input.action_release(action)
	_touch_held.clear()


func _on_touch_menu() -> void:
	_countdown_left = -1.0
	if _game and _game.in_race():
		_set_paused(not get_tree().paused)
	else:
		_show_start_menu()


func _sync_touch_drive() -> void:
	if _touch_controls == null:
		return
	var active: bool = (
		_touch_controls.visible and _ride_started and not get_tree().paused
		and (_game == null or not _game.is_crashed)
	)
	var braking := Input.get_action_strength("brake") > 0.05
	var want := active and not braking
	if want and not _touch_auto_throttle:
		Input.action_press(&"throttle")
		_touch_auto_throttle = true
	elif not want and _touch_auto_throttle:
		Input.action_release(&"throttle")
		_touch_auto_throttle = false


func _on_touch_steer_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed and _touch_steer_pointer == -1:
			_touch_steer_pointer = event.index
			_apply_touch_steer_position(event.position.x)
			_touch_steer.accept_event()
		elif not event.pressed and event.index == _touch_steer_pointer:
			_touch_steer_pointer = -1
			_set_touch_steer(0.0)
			_touch_steer.accept_event()
	elif event is InputEventScreenDrag and event.index == _touch_steer_pointer:
		_apply_touch_steer_position(event.position.x)
		_touch_steer.accept_event()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and _touch_steer_pointer == -1:
			_touch_steer_pointer = -2
			_apply_touch_steer_position(event.position.x)
		elif not event.pressed and _touch_steer_pointer == -2:
			_touch_steer_pointer = -1
			_set_touch_steer(0.0)
		_touch_steer.accept_event()
	elif event is InputEventMouseMotion and _touch_steer_pointer == -2:
		_apply_touch_steer_position(event.position.x)
		_touch_steer.accept_event()


func _apply_touch_steer_global(position: Vector2) -> void:
	if _touch_steer == null:
		return
	_apply_touch_steer_position(_touch_steer.to_local(position).x)


func _apply_touch_steer_position(x: float) -> void:
	if _touch_steer == null:
		return
	var half := maxf(_touch_steer.size.x * 0.5, 1.0)
	var raw := clampf((x - half) / (half * 0.86), -1.0, 1.0)
	var magnitude := 0.0
	if absf(raw) > 0.12:
		magnitude = clampf(inverse_lerp(0.12, 1.0, absf(raw)), 0.0, 1.0)
	_set_touch_steer(signf(raw) * magnitude)


func _set_touch_steer(axis: float) -> void:
	_touch_steer_axis = clampf(axis, -1.0, 1.0)
	Input.action_release(&"steer_left")
	Input.action_release(&"steer_right")
	if _touch_steer_axis < 0.0:
		Input.action_press(&"steer_left", -_touch_steer_axis)
	elif _touch_steer_axis > 0.0:
		Input.action_press(&"steer_right", _touch_steer_axis)
	if _touch_steer != null and _touch_steer_thumb != null:
		_touch_steer_thumb.position.x = lerpf(18.0, maxf(_touch_steer.size.x - 60.0, 18.0), (_touch_steer_axis + 1.0) * 0.5)


func _on_crash_panel_input(event: InputEvent) -> void:
	if _touch_controls == null or _game == null or not _game.is_crashed:
		return
	if event is InputEventScreenTouch and event.pressed:
		_game.restart()


# --------------------------------------------------------------------- race


func _menu_button(copy: String, size: int) -> Button:
	var button := Button.new()
	button.text = copy
	button.flat = true
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.add_theme_font_override("font", _font_head)
	button.add_theme_font_size_override("font_size", size)
	button.add_theme_color_override("font_color", Color("f4efe4"))
	button.add_theme_color_override("font_hover_color", Color("e8b55d"))
	button.add_theme_color_override("font_pressed_color", Color("c47848"))
	button.add_theme_color_override("font_disabled_color", Color("8a857a"))
	return button


func _race_edit(placeholder: String) -> LineEdit:
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.custom_minimum_size = Vector2(0.0, 48.0)
	edit.add_theme_font_override("font", _font_ui)
	edit.add_theme_font_size_override("font_size", 15)
	edit.add_theme_color_override("font_color", Color("f4efe4"))
	edit.add_theme_color_override("font_placeholder_color", Color("9a9588"))
	edit.add_theme_color_override("caret_color", Color("e8b55d"))
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.06, 0.06, 0.07, 0.55)
	box.border_color = Color(0.76, 0.47, 0.28, 0.28)
	box.border_width_bottom = 1
	box.content_margin_left = 8
	box.content_margin_right = 8
	edit.add_theme_stylebox_override("normal", box)
	return edit


func _accent_button(copy: String, size: int) -> Button:
	var button := Button.new()
	button.text = copy
	button.add_theme_font_override("font", _font_display)
	button.add_theme_font_size_override("font_size", size)
	button.add_theme_color_override("font_color", Color("f4efe4"))
	button.add_theme_color_override("font_hover_color", Color.WHITE)
	button.add_theme_color_override("font_disabled_color", Color("8a857a"))
	var ink := StyleBoxFlat.new()
	ink.bg_color = Color("c92a38")
	ink.content_margin_left = 16
	ink.content_margin_right = 16
	button.add_theme_stylebox_override("normal", ink)
	var hover := ink.duplicate() as StyleBoxFlat
	hover.bg_color = Color("c47848")
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", hover)
	var off := ink.duplicate() as StyleBoxFlat
	off.bg_color = Color(0.10, 0.09, 0.08, 0.80)
	button.add_theme_stylebox_override("disabled", off)
	return button


func _build_race_panel(stack: VBoxContainer) -> void:
	_race_panel = VBoxContainer.new()
	_race_panel.name = "RacePanel"
	_race_panel.visible = false
	_race_panel.add_theme_constant_override("separation", 6)
	stack.add_child(_race_panel)

	_race_panel.add_child(_menu_label("RACE BRIEF", 11, Color("9a9588"), _font_kicker))
	_race_panel.add_child(_menu_label("HOST ONCE · FRIENDS OPEN THE LINK · READY · START", 14, Color("e8b089"), _font_head))

	_race_status = _menu_label("STEP 1 · JOIN OR HOST A LOBBY", 13, Color("9a9588"), _font_kicker)
	_race_panel.add_child(_race_status)

	_race_panel.add_child(_menu_label("RIDER NAME", 11, Color("9a9588"), _font_kicker))
	_name_edit = _race_edit("your name")
	_race_panel.add_child(_name_edit)
	_race_panel.add_child(_menu_label("RACE SERVER ADDRESS", 11, Color("9a9588"), _font_kicker))
	_server_edit = _race_edit("ws://your-host:8001")
	_race_panel.add_child(_server_edit)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_join_button = _accent_button("JOIN", 17)
	_join_button.custom_minimum_size = Vector2(0.0, 50.0)
	_join_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_join_button.pressed.connect(_on_join_pressed)
	row.add_child(_join_button)
	_ready_button = _menu_button("READY", 17)
	_ready_button.custom_minimum_size = Vector2(0.0, 50.0)
	_ready_button.pressed.connect(_on_ready_pressed)
	_ready_button.visible = false
	row.add_child(_ready_button)
	_race_panel.add_child(row)

	_lobby_label = _menu_label("", 15, Color("f4efe4"), _font_head)
	_lobby_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_race_panel.add_child(_lobby_label)

	_race_start_button = _accent_button("WAITING FOR RIDER", 17)
	_race_start_button.custom_minimum_size = Vector2(0.0, 50.0)
	_race_start_button.visible = false
	_race_start_button.pressed.connect(func() -> void:
		if _net:
			_net.request_start())
	_race_panel.add_child(_race_start_button)

	var host := _menu_label(
		"HOST: run SplendorServer and share http://your-address:8000. Friends open that link, choose a name, and tap JOIN RACE.",
		12, Color("9a9588"), _font_ui)
	host.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_race_panel.add_child(host)


func _refresh_race_panel() -> void:
	if _net == null:
		return
	_name_edit.text = str(_net.rider_name)
	var url: String = str(_net.server_url)
	var suggested: String = _net.suggested_url()
	if url == "ws://127.0.0.1:8001" and suggested != url:
		url = suggested # browser page came from the host — use its hostname
	_server_edit.text = url
	_sync_race_widgets()


func _sync_race_widgets() -> void:
	var online: bool = _net != null and _net.online()
	var connecting: bool = _net != null and _net.state == "connecting"
	_join_button.text = "LEAVE LOBBY" if online else "JOIN RACE"
	_join_button.disabled = connecting
	_name_edit.editable = not online and not connecting
	_server_edit.editable = not online and not connecting
	if not online:
		_race_toggle.text = "PLAY WITH FRIENDS"
		_ready_button.visible = false
		_race_start_button.visible = false
		_race_status.add_theme_color_override("font_color", Color("9a9588"))
		if connecting:
			_race_status.text = "CONNECTING TO RACE SERVER..."
		elif _net != null and str(_net.state).begins_with("error:"):
			_race_status.text = "COULDN'T CONNECT · CHECK THE ADDRESS"
		else:
			_race_status.text = "STEP 1 · JOIN OR HOST A LOBBY"
		return
	_update_lobby_state()


func _update_lobby_state() -> void:
	var total := 0
	var ready_count := 0
	var own_ready := false
	var leader_name := "THE LEADER"
	for id in _net.players:
		var p: Dictionary = _net.players[id]
		total += 1
		var rider_ready := bool(p.get("ready", false))
		if rider_ready:
			ready_count += 1
		if int(id) == _net.my_id:
			own_ready = rider_ready
		if int(id) == _net.leader_id:
			leader_name = str(p.get("name", "the leader")).to_upper()
	_ready_state = own_ready
	var is_leader: bool = _net.my_id >= 0 and _net.my_id == _net.leader_id
	var in_lobby: bool = _net.phase == "lobby"
	var all_ready := total >= 2 and ready_count == total
	_race_toggle.text = "RACE LOBBY · %d" % total
	_ready_button.visible = in_lobby
	_ready_button.text = "READY ✓" if own_ready else "READY"
	_race_start_button.visible = is_leader and in_lobby
	_race_start_button.disabled = not all_ready
	if total < 2:
		_race_start_button.text = "WAITING FOR RIDER"
	elif not all_ready:
		_race_start_button.text = "WAITING FOR READY"
	else:
		_race_start_button.text = "START RACE"
	var muted := Color("9a9588")
	var green := Color("8fd07a")
	if _net.phase == "racing":
		_race_status.text = "RACE IN PROGRESS"
		_race_status.add_theme_color_override("font_color", muted)
	elif total < 2:
		_race_status.text = "STEP 2 · SHARE THE LINK — WAITING FOR A RIDER"
		_race_status.add_theme_color_override("font_color", muted)
	elif not own_ready:
		_race_status.text = "STEP 2 · TAP READY WHEN YOUR BIKE IS SET"
		_race_status.add_theme_color_override("font_color", muted)
	elif not all_ready:
		var waiting := total - ready_count
		_race_status.text = "STEP 2 · WAITING FOR %d RIDER%s" % [waiting, "" if waiting == 1 else "S"]
		_race_status.add_theme_color_override("font_color", muted)
	elif is_leader:
		_race_status.text = "STEP 3 · EVERYONE IS READY — START THE RACE"
		_race_status.add_theme_color_override("font_color", green)
	else:
		_race_status.text = "READY · WAITING FOR %s TO START" % leader_name
		_race_status.add_theme_color_override("font_color", green)


func _on_join_pressed() -> void:
	if _net == null:
		return
	if _net.online():
		_leave_lobby()
		return
	var server := _server_edit.text.strip_edges()
	var rider := _name_edit.text.strip_edges()
	if server.is_empty():
		_race_status.text = "ENTER THE RACE SERVER ADDRESS"
		return
	if rider.is_empty():
		_race_status.text = "ENTER A RIDER NAME"
		return
	_net.connect_to(server, rider)


func _leave_lobby() -> void:
	_ready_state = false
	if _net:
		_net.leave()
	if _game:
		_game.end_race()
	_my_finish_place = 0
	_lobby_label.text = ""
	_results_panel.visible = false


func _on_ready_pressed() -> void:
	_ready_state = not _ready_state
	if _net:
		_net.set_ready(_ready_state)
	_ready_button.text = "READY ✓" if _ready_state else "READY"
	if _ready_state:
		_race_status.text = "READY SENT · WAITING FOR THE LOBBY"


func _on_conn_state(state: String) -> void:
	_sync_race_widgets()
	if state != "online":
		_ready_state = false
		if _ready_button:
			_ready_button.text = "READY"
		if _game and _game.in_race():
			_game.end_race()


func _on_lobby(list: Array, my_id: int, leader_id: int, phase: String) -> void:
	var lines: Array[String] = []
	for p in list:
		var tags: Array[String] = []
		if int(p["id"]) == my_id:
			tags.append("you")
		if int(p["id"]) == leader_id:
			tags.append("leader")
		var tag := " (%s)" % ", ".join(tags) if not tags.is_empty() else ""
		var mark := "READY " if bool(p.get("ready", false)) else "WAIT  "
		lines.append("%s %s%s" % [mark, p["name"], tag])
	_lobby_label.text = "\n".join(lines)
	_sync_race_widgets()


func _on_race_starting(seed: int, delay_s: float, dist: float) -> void:
	_race_dist = dist
	_my_finish_place = 0
	_ready_state = false
	if _ready_button:
		_ready_button.text = "READY"
	_results_panel.visible = false
	_set_hero_view(false)
	_start_menu.visible = false
	hud_root.visible = true
	crash_panel.visible = false
	pause_panel.visible = false
	_clear_confirm_restart()
	if _game:
		_game.select_bike(_bike_index)
		_game.begin_race(seed)
	_ride_started = true
	get_tree().paused = true # restart() unpauses; hold everyone on the lights
	hint_label.text = "RACE TO %.1f KM · FIRST RIDER TO THE FINISH" % (dist / 1000.0)
	_hint = delay_s + 0.5
	_countdown_left = maxf(delay_s, 0.01)
	_update_race_pos()


func _tick_countdown(delta: float) -> void:
	_countdown_left -= delta
	flash_label.pivot_offset = flash_label.size * 0.5
	if _countdown_left > 0.0:
		flash_label.text = str(ceili(_countdown_left))
		flash_label.modulate = Color("f4efe4")
		flash_label.modulate.a = 1.0
		flash_label.scale = Vector2.ONE * 2.2
	else:
		_countdown_left = -1.0
		get_tree().paused = false
		flash_label.scale = Vector2.ONE * 2.2
		flash_label.text = "GO!"
		flash_label.modulate = Color("8fd07a")
		flash_label.modulate.a = 1.0
		_flash = 0.55
		hint_label.text = "RACE LIVE · %d M TO THE FINISH" % int(_race_dist)
		_hint = 2.0


func _on_race_finish(id: int, place: int) -> void:
	if _net and id == _net.my_id:
		_my_finish_place = place
		flash_label.text = "P%d — YOU FINISHED" % place
		flash_label.modulate = Color("8fd07a")
		_flash = 1.2
		if _race_gap:
			_race_gap.text = "FINISHED P%d · WAITING FOR THE FIELD" % place
	else:
		var info: Dictionary = _net.players.get(id, {}) if _net else {}
		flash_label.text = "%s finished P%d" % [str(info.get("name", "rider")), place]
		flash_label.modulate = Color("c8c2b4")
		_flash = 0.8


func _on_race_results(order: Array) -> void:
	if _game:
		_game.end_race()
	_my_finish_place = 0
	_ready_state = false
	_release_touch_actions()
	var lines: Array[String] = ["RACE RESULTS", ""]
	for p in order:
		var me := "  ← you" if _net and int(p["id"]) == _net.my_id else ""
		if bool(p.get("dnf", false)):
			lines.append("dnf  %s  (%d m)%s" % [p["name"], int(p.get("d", 0)), me])
		else:
			lines.append("P%d  %s%s" % [int(p["place"]), p["name"], me])
	lines.append("")
	lines.append("Ready up in the lobby for a rematch.")
	_results_label.text = "\n".join(lines)
	_results_panel.visible = true
	if _race_hud_card:
		_race_hud_card.visible = false
	get_tree().paused = true
	pause_panel.visible = false
	_update_race_pos()


func _update_race_pos() -> void:
	if _race_hud_card == null:
		return
	var racing: bool = (
		_net != null and _net.online() and _net.phase == "racing"
		and _game != null and _game.in_race()
	)
	if not racing:
		_race_hud_card.visible = false
		return
	_race_hud_card.visible = true
	# same number net_client reports: road distance, not distance_m + bonus
	var my_dist: float = maxf(float(_player.get("track_z")), 0.0) if _player else 0.0
	var ahead := 0
	var lead_gap := 0.0
	var count := 1
	for id in _net.players:
		if id == _net.my_id:
			continue
		count += 1
		var d := float(_net.players[id].get("dist", 0.0))
		if d > my_dist:
			ahead += 1
			lead_gap = maxf(lead_gap, d - my_dist)
	var place := ahead + 1
	_pos_label.text = "P%d / %d" % [place, count]
	_race_remaining.text = "%d M TO FINISH" % int(maxf(_race_dist - my_dist, 0.0))
	_race_progress.max_value = maxf(_race_dist, 1.0)
	_race_progress.value = clampf(my_dist, 0.0, _race_dist)
	if _my_finish_place > 0:
		_race_gap.text = "FINISHED P%d" % _my_finish_place
	elif place == 1 and count > 1:
		_race_gap.text = "LEADING THE RACE"
	elif lead_gap > 0.0:
		_race_gap.text = "%d M TO THE LEADER" % int(lead_gap)
	else:
		_race_gap.text = "RACE TO THE FINISH"


func _build_race_hud() -> void:
	_race_hud_card = PanelContainer.new()
	_race_hud_card.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_race_hud_card.offset_left = -356.0
	_race_hud_card.offset_top = 52.0
	_race_hud_card.offset_right = -24.0
	_race_hud_card.offset_bottom = 148.0
	_race_hud_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_race_hud_card.visible = false
	var card := StyleBoxFlat.new()
	card.bg_color = Color(0.03, 0.035, 0.04, 0.78)
	card.border_color = Color(0.90, 0.68, 0.42, 0.45)
	card.set_border_width_all(1)
	card.set_corner_radius_all(4)
	card.content_margin_left = 14
	card.content_margin_right = 14
	card.content_margin_top = 12
	card.content_margin_bottom = 12
	_race_hud_card.add_theme_stylebox_override("panel", card)

	var card_box := VBoxContainer.new()
	card_box.add_theme_constant_override("separation", 5)
	_race_hud_card.add_child(card_box)

	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 8)
	_pos_label = Label.new()
	_pos_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pos_label.add_theme_color_override("font_color", Color("f4efe4"))
	_style_hud_label(_pos_label, _font_display if _font_display != null else _font_head, 24)
	top_row.add_child(_pos_label)
	_race_remaining = Label.new()
	_race_remaining.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_race_remaining.add_theme_color_override("font_color", Color("c8c2b4"))
	_race_remaining.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_style_hud_label(_race_remaining, _font_head, 15)
	top_row.add_child(_race_remaining)
	card_box.add_child(top_row)

	_race_progress = ProgressBar.new()
	_race_progress.min_value = 0.0
	_race_progress.max_value = 100.0
	_race_progress.custom_minimum_size.y = 8.0
	_race_progress.show_percentage = false
	var bar_bg := StyleBoxFlat.new()
	bar_bg.bg_color = Color(0.06, 0.06, 0.07, 0.9)
	bar_bg.set_corner_radius_all(3)
	_race_progress.add_theme_stylebox_override("background", bar_bg)
	var bar_fill := StyleBoxFlat.new()
	bar_fill.bg_color = Color("c92a38")
	bar_fill.set_corner_radius_all(3)
	_race_progress.add_theme_stylebox_override("fill", bar_fill)
	card_box.add_child(_race_progress)

	_race_gap = _menu_label("", 13, Color("9a9588"), _font_head)
	card_box.add_child(_race_gap)
	hud_root.add_child(_race_hud_card)

	_results_panel = PanelContainer.new()
	_results_panel.set_anchors_preset(Control.PRESET_CENTER)
	_results_panel.custom_minimum_size = Vector2(380.0, 0.0)
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.03, 0.035, 0.04, 0.88)
	box.border_color = Color(0.76, 0.47, 0.28, 0.35)
	box.set_border_width_all(1)
	box.content_margin_left = 28
	box.content_margin_right = 28
	box.content_margin_top = 20
	box.content_margin_bottom = 20
	_results_panel.add_theme_stylebox_override("panel", box)
	var results_box := VBoxContainer.new()
	results_box.add_theme_constant_override("separation", 14)
	_results_panel.add_child(results_box)
	_results_label = _menu_label("", 19, Color("f4efe4"), _font_head)
	results_box.add_child(_results_label)
	_results_button = _accent_button("BACK TO RACE LOBBY", 17)
	_results_button.custom_minimum_size = Vector2(0.0, 42.0)
	_results_button.pressed.connect(_return_to_race_lobby)
	results_box.add_child(_results_button)
	_results_panel.visible = false
	hud_root.add_child(_results_panel)


func _return_to_race_lobby() -> void:
	_results_panel.visible = false
	_show_start_menu()
	_race_panel.visible = true
	_refresh_race_panel()
