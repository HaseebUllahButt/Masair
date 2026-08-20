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
	hint_label.text = "W/S ride   ·   A/D lean   ·   H horn   ·   C cruise   ·   T light   ·   R restart"
	_music = get_node_or_null("/root/MusicPlayer")
	_build_currency_hud()
	_build_start_menu()
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
	if _start_menu and _start_menu.visible:
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
	elif Input.is_action_just_pressed("pause"):
		if _game == null or not _game.is_crashed:
			_set_paused(not get_tree().paused)
	if _player:
		# Ease the readout so the digits do not strobe.
		_shown_speed = lerpf(_shown_speed, _player.speed * 3.6, 1.0 - exp(-9.0 * delta))
		speed_label.text = "%d" % int(_shown_speed)
		_update_cruise_caption()
		_update_prompt()

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
	crash_panel.visible = true
	crash_panel.modulate.a = 0.0
	var d := int(_game.distance_m) if _game else 0
	var n: int = _game.near_miss_count if _game else 0
	var balance: int = int(_game.credits) if _game else 0
	crash_label.text = "RIDE OVER\n\n%d m   ·   %d near misses   ·   CR %d\n\nR  ride again" % [d, n, balance]


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
	if _player:
		_update_prompt()
		_update_cruise_caption()

func _update_pause_label() -> void:
	if pause_label == null:
		return
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

	var stack := VBoxContainer.new()
	stack.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	stack.offset_left = 56.0
	stack.offset_top = 64.0
	stack.offset_right = 460.0
	stack.offset_bottom = -56.0
	stack.add_theme_constant_override("separation", 10)
	_start_menu.add_child(stack)

	stack.add_child(_menu_label("OPEN COUNTRY", 13, Color("e8b089"), _font_kicker))
	var title := _menu_label("MASAIR", 78, Color("f4efe4"), _font_display)
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
	hint_label.text = "W/S ride   ·   A/D lean   ·   Q/E look   ·   H horn   ·   C cruise   ·   F scenic bench   ·   T light   ·   R restart"


func _load_type() -> void:
	_font_display = _ttf("res://assets/fonts/NotoSans-ExtraCondensedBlack.ttf")
	_font_head = _ttf("res://assets/fonts/NotoSans-ExtraCondensedBold.ttf")
	_font_ui = _ttf("res://assets/fonts/NotoSans-ExtraCondensedMedium.ttf")
	_font_italic = _ttf("res://assets/fonts/NotoSans-CondensedLightItalic.ttf")
	_font_kicker = _tracked(_font_ui, 8)


func _ttf(path: String) -> FontFile:
	var font := FontFile.new()
	font.load_dynamic_font(path)
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
