class_name EchoUi
extends CanvasLayer
## Echo mode overlay: the Y side menu (up/down + A, B back), race timer, checkpoint counter and split deltas,
## the 3-2-1-GO countdown, result banner, echo point prompt, editor help/cursor lines, toasts and the small
## synthesised beeps. Runs while the game is paused.

const PANEL_WIDTH := 440.0
const MARGIN := 24.0
const ACCENT := Color(0.3, 0.88, 1.0)
const TEXT := Color(0.88, 0.96, 1.0)
const MUTED := Color(0.5, 0.62, 0.74)
const GOOD := Color(0.35, 1.0, 0.55)
const BAD := Color(1.0, 0.38, 0.35)

var _menu_panel: PanelContainer
var _menu_title: Label
var _menu_subtitle: Label
var _menu_list: VBoxContainer
var _items: Array[Dictionary] = []
var _rows: Array[PanelContainer] = []
var _selected := 0
var _on_cancel := Callable()
var _nav_dir := 0
var _nav_repeat := 0.0
var _row_style := StyleBoxFlat.new()
var _row_selected_style := StyleBoxFlat.new()

var _race_box: VBoxContainer
var _timer_label: Label
var _info_label: Label
var _delta_label: Label
var _countdown_label: Label
var _banner: VBoxContainer
var _banner_title: Label
var _banner_sub: Label
var _prompt_label: Label
var _toast_label: Label
var _help_label: Label
var _cursor_label: Label
var _delta_time := 0.0
var _toast_time := 0.0

var _player: AudioStreamPlayer
var _beep_low: AudioStreamWAV
var _beep_high: AudioStreamWAV
var _chime: AudioStreamWAV
var _tick: AudioStreamWAV


func _ready() -> void:
	layer = 5
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_menu()

	_race_box = VBoxContainer.new()
	_race_box.alignment = BoxContainer.ALIGNMENT_BEGIN
	_race_box.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_KEEP_SIZE, 18)
	_race_box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_race_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_race_box)
	_timer_label = _label(48, TEXT, _race_box)
	_info_label = _label(20, ACCENT, _race_box)
	_delta_label = _label(30, GOOD, _race_box)
	for l in [_timer_label, _info_label, _delta_label]:
		(l as Label).horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_race_box.visible = false

	_countdown_label = _label(150, ACCENT)
	_countdown_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_countdown_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_countdown_label.visible = false

	_banner = VBoxContainer.new()
	_banner.set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_KEEP_SIZE)
	_banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_banner.grow_vertical = Control.GROW_DIRECTION_BOTH
	_banner.position.y -= 120.0
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_banner)
	_banner_title = _label(64, ACCENT, _banner)
	_banner_sub = _label(26, TEXT, _banner)
	_banner_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.visible = false

	_prompt_label = _label(24, ACCENT)
	_prompt_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_KEEP_SIZE, 70)
	_prompt_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	_toast_label = _label(22, TEXT)
	_toast_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_KEEP_SIZE, 170)
	_toast_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	_cursor_label = _label(22, TEXT)
	_cursor_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_KEEP_SIZE, MARGIN)
	_cursor_label.position.y -= 34.0
	_cursor_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_help_label = _label(16, MUTED)
	_help_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_KEEP_SIZE, MARGIN)
	_help_label.grow_vertical = Control.GROW_DIRECTION_BEGIN

	_player = AudioStreamPlayer.new()
	_player.max_polyphony = 4
	_player.volume_db = -6.0
	add_child(_player)
	_beep_low = _tone([660.0], 0.16)
	_beep_high = _tone([1320.0], 0.45)
	_chime = _tone([988.0, 1480.0], 0.09)
	_tick = _tone([1800.0], 0.025, 0.15)


func _process(delta: float) -> void:
	if _menu_panel.visible:
		var dir := 0
		if Input.is_action_pressed(&"ui_down") or VehicleInput.joy_axis(JOY_AXIS_LEFT_Y) > 0.6:
			dir = 1
		elif Input.is_action_pressed(&"ui_up") or VehicleInput.joy_axis(JOY_AXIS_LEFT_Y) < -0.6:
			dir = -1
		if dir != _nav_dir:
			_nav_dir = dir
			_nav_repeat = 0.4
			if dir != 0:
				_move(dir)
		elif dir != 0:
			_nav_repeat -= delta
			if _nav_repeat <= 0.0:
				_nav_repeat = 0.11
				_move(dir)
	if _delta_time > 0.0:
		_delta_time -= delta
		_delta_label.modulate.a = clampf(_delta_time, 0.0, 1.0)
	if _toast_time > 0.0:
		_toast_time -= delta
		_toast_label.modulate.a = clampf(_toast_time, 0.0, 1.0)


func _input(event: InputEvent) -> void:
	if not _menu_panel.visible or event is InputEventMouse:
		return
	var joy := event as InputEventJoypadButton
	if event.is_action_pressed(&"ui_accept") or (joy and joy.pressed and joy.button_index == JOY_BUTTON_A):
		_activate()
	elif (event.is_action_pressed(&"ui_cancel") or event.is_action_pressed(&"echo_menu")
			or (joy and joy.pressed and joy.button_index == JOY_BUTTON_B)):
		if _on_cancel.is_valid():
			_on_cancel.call()
	# Swallow everything while the menu is up so the game (pause, reset, ...) never sees it.
	get_viewport().set_input_as_handled()


# --- Side menu -----------------------------------------------------------------------------------

## `items`: dictionaries {text: String, action: Callable, enabled: bool (optional)}. `on_cancel` runs on
## B / Esc / Y (nothing when invalid).
func open_menu(title: String, subtitle: String, items: Array[Dictionary], on_cancel := Callable(), selected := 0) -> void:
	_menu_title.text = title
	_menu_subtitle.text = subtitle
	_menu_subtitle.visible = not subtitle.is_empty()
	_items = items
	_on_cancel = on_cancel
	for row in _rows:
		row.queue_free()
	_rows.clear()
	for item in items:
		var row := PanelContainer.new()
		var l := _label(21, TEXT, row)
		l.text = item.text
		_menu_list.add_child(row)
		_rows.append(row)
	_selected = clampi(selected, 0, maxi(items.size() - 1, 0))
	if not _enabled(_selected):
		_move(1, false)
	_refresh_rows()
	_menu_panel.visible = true
	_nav_dir = 0


func close_menu() -> void:
	_menu_panel.visible = false


func is_menu_open() -> bool:
	return _menu_panel.visible


func set_item_text(i: int, text: String) -> void:
	if i < _rows.size() and _items[i].text != text:
		_items[i].text = text
		(_rows[i].get_child(0) as Label).text = text


func set_menu_subtitle(text: String) -> void:
	_menu_subtitle.text = text


func _activate() -> void:
	if _selected < _items.size() and _enabled(_selected):
		var action: Callable = _items[_selected].action
		_player.stream = _tick
		_player.play()
		action.call()


func _enabled(i: int) -> bool:
	return i < _items.size() and _items[i].get("enabled", true)


func _move(dir: int, sound := true) -> void:
	var n := _items.size()
	for step in n:
		_selected = wrapi(_selected + dir, 0, n)
		if _enabled(_selected):
			break
	_refresh_rows()
	if sound:
		_player.stream = _tick
		_player.play()


func _refresh_rows() -> void:
	for i in _rows.size():
		var sel := i == _selected
		_rows[i].add_theme_stylebox_override(&"panel", _row_selected_style if sel else _row_style)
		var l := _rows[i].get_child(0) as Label
		l.label_settings.font_color = (Color.WHITE if sel else TEXT) if _enabled(i) else MUTED


func _build_menu() -> void:
	_menu_panel = PanelContainer.new()
	_menu_panel.anchor_left = 1.0
	_menu_panel.anchor_right = 1.0
	_menu_panel.anchor_bottom = 1.0
	_menu_panel.offset_left = -PANEL_WIDTH - MARGIN
	_menu_panel.offset_right = -MARGIN
	_menu_panel.offset_top = MARGIN
	_menu_panel.offset_bottom = -MARGIN
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.02, 0.05, 0.1, 0.84)
	style.border_color = ACCENT
	style.border_width_left = 3
	style.set_corner_radius_all(10)
	style.set_content_margin_all(22)
	style.shadow_color = Color(0.2, 0.7, 1.0, 0.25)
	style.shadow_size = 14
	_menu_panel.add_theme_stylebox_override(&"panel", style)
	add_child(_menu_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 10)
	_menu_panel.add_child(box)
	_menu_title = _label(32, ACCENT, box)
	_menu_subtitle = _label(16, MUTED, box)
	_menu_subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var gap := Control.new()
	gap.custom_minimum_size.y = 8
	box.add_child(gap)
	_menu_list = VBoxContainer.new()
	_menu_list.add_theme_constant_override(&"separation", 4)
	box.add_child(_menu_list)
	var filler := Control.new()
	filler.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(filler)
	var hint := _label(15, MUTED, box)
	hint.text = "↑ ↓  choose      A / Enter  select      B / Esc  back"
	_row_style.set_content_margin_all(8)
	_row_style.content_margin_left = 14
	_row_style.bg_color = Color(0, 0, 0, 0)
	_row_selected_style.set_content_margin_all(8)
	_row_selected_style.content_margin_left = 14
	_row_selected_style.bg_color = Color(ACCENT, 0.2)
	_row_selected_style.border_color = ACCENT
	_row_selected_style.border_width_left = 4
	_row_selected_style.set_corner_radius_all(6)
	_menu_panel.visible = false


# --- Race HUD ------------------------------------------------------------------------------------

func show_race_hud(on: bool) -> void:
	_race_box.visible = on
	if not on:
		_delta_label.modulate.a = 0.0
		_countdown_label.visible = false


func set_timer(text: String, color := TEXT) -> void:
	_timer_label.text = text
	_timer_label.label_settings.font_color = color


func set_info(text: String) -> void:
	_info_label.text = text


## Split against the echo: negative = ahead (green).
func flash_delta(d: float) -> void:
	_delta_label.text = EchoRun.format_delta(d)
	_delta_label.label_settings.font_color = GOOD if d < 0.0 else BAD
	_delta_time = 2.5
	_delta_label.modulate.a = 1.0
	_player.stream = _chime
	_player.play()


## 3, 2, 1, then 0 for GO.
func show_countdown(n: int) -> void:
	_countdown_label.visible = true
	_countdown_label.text = str(n) if n > 0 else "GO!"
	_countdown_label.label_settings.font_color = ACCENT if n > 0 else GOOD
	_countdown_label.pivot_offset = _countdown_label.size * 0.5
	_countdown_label.scale = Vector2.ONE * 1.5
	_countdown_label.modulate.a = 1.0
	var tw := create_tween()
	tw.tween_property(_countdown_label, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	if n <= 0:
		tw.tween_property(_countdown_label, "modulate:a", 0.0, 0.6).set_delay(0.35)
		tw.tween_callback(func() -> void: _countdown_label.visible = false)
	_player.stream = _beep_low if n > 0 else _beep_high
	_player.play()


func hide_countdown() -> void:
	_countdown_label.visible = false


func show_banner(title: String, subtitle: String, color: Color) -> void:
	_banner_title.text = title
	_banner_title.label_settings.font_color = color
	_banner_sub.text = subtitle
	_banner.visible = true
	_banner.modulate.a = 0.0
	create_tween().tween_property(_banner, "modulate:a", 1.0, 0.3)


func hide_banner() -> void:
	_banner.visible = false


func show_prompt(text: String) -> void:
	_prompt_label.text = text


func toast(text: String, seconds := 3.5) -> void:
	_toast_label.text = text
	_toast_time = seconds
	_toast_label.modulate.a = 1.0


func set_help(text: String) -> void:
	_help_label.text = text


func set_cursor_info(text: String) -> void:
	_cursor_label.text = text


# --- Helpers -------------------------------------------------------------------------------------

func _label(font_size: int, color: Color, parent: Node = self) -> Label:
	var label := Label.new()
	var settings := LabelSettings.new()
	settings.font_size = font_size
	settings.font_color = color
	settings.outline_size = maxi(font_size / 8, 4)
	settings.outline_color = Color(0.0, 0.03, 0.08, 0.7)
	label.label_settings = settings
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	return label


## Short sine blips (one note per frequency, back to back) with a soft attack and decay.
static func _tone(freqs: Array, note: float, vol := 0.4) -> AudioStreamWAV:
	var rate := 22050
	var per := int(note * rate)
	var data := PackedByteArray()
	data.resize(per * freqs.size() * 2)
	for k in freqs.size():
		var f: float = freqs[k]
		for i in per:
			var t := float(i) / rate
			var env := minf(t / 0.004, 1.0) * pow(1.0 - float(i) / per, 1.5)
			var s := (sin(TAU * f * t) + 0.25 * sin(TAU * 2.0 * f * t)) * env * vol
			data.encode_s16((k * per + i) * 2, int(clampf(s, -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.data = data
	return wav
