class_name PauseMenu
extends CanvasLayer
## Start / Esc pause menu, centered over a dimmed screen: Resume, Save, Quit. Up/down (keys, d-pad, stick) +
## Enter / A, or the mouse; Start / Esc / B resumes. Same look as the echo side menu (EchoUi helpers).
## Emits the choice; main.gd does the actual pausing, saving and quitting.

signal resume_requested
signal save_requested
signal quit_requested

@export var panel_width := 360.0
@export var dim_color := Color(0.02, 0.04, 0.08, 0.5)
@export var feedback_seconds := 1.6  ## How long the "Saved" line stays up.

var _panel: PanelContainer
var _rows: Array[PanelContainer] = []
var _actions: Array[Signal] = []
var _feedback: Label
var _feedback_time := 0.0
var _selected := 0
var _nav_dir := 0
var _nav_repeat := 0.0
var _row_style: StyleBoxFlat
var _row_selected_style: StyleBoxFlat
var _player: AudioStreamPlayer
var _tick: AudioStreamWAV
var _chime: AudioStreamWAV


func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	var dim := ColorRect.new()
	dim.color = dim_color
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	_panel = PanelContainer.new()
	_panel.custom_minimum_size.x = panel_width
	var style := EchoUi.panel_style()
	style.border_width_top = 3
	style.border_width_bottom = 3
	_panel.add_theme_stylebox_override(&"panel", style)
	center.add_child(_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 10)
	_panel.add_child(box)
	var title := EchoUi.make_label(40, EchoUi.ACCENT, box)
	title.text = "PAUSED"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var gap := Control.new()
	gap.custom_minimum_size.y = 6
	box.add_child(gap)

	_row_style = EchoUi.row_style(false)
	_row_selected_style = EchoUi.row_style(true)
	var list := VBoxContainer.new()
	list.add_theme_constant_override(&"separation", 4)
	box.add_child(list)
	for item: Array in [["Resume", resume_requested], ["Save", save_requested], ["Quit", quit_requested]]:
		var row := PanelContainer.new()
		row.mouse_filter = Control.MOUSE_FILTER_STOP
		var l := EchoUi.make_label(24, EchoUi.TEXT, row)
		l.text = item[0]
		list.add_child(row)
		var i := _rows.size()
		row.mouse_entered.connect(_hover.bind(i))
		row.gui_input.connect(_row_input.bind(i))
		_rows.append(row)
		_actions.append(item[1])

	_feedback = EchoUi.make_label(18, EchoUi.GOOD, box)
	_feedback.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_feedback.modulate.a = 0.0
	var hint := EchoUi.make_label(15, EchoUi.MUTED, box)
	hint.text = "↑ ↓  choose     A / Enter  select\nStart / Esc  resume"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	_player = AudioStreamPlayer.new()
	_player.volume_db = -6.0
	add_child(_player)
	_tick = EchoUi._tone([1800.0], 0.025, 0.15)
	_chime = EchoUi._tone([988.0, 1480.0], 0.09)
	_refresh()


func open() -> void:
	_selected = 0
	_nav_dir = 0
	_feedback_time = 0.0
	_feedback.modulate.a = 0.0
	_refresh()
	visible = true


func close() -> void:
	visible = false


func is_open() -> bool:
	return visible


## Brief confirmation line under the items ("Saved").
func show_feedback(text: String, ok := true) -> void:
	_feedback.text = text
	_feedback.label_settings.font_color = EchoUi.GOOD if ok else EchoUi.BAD
	_feedback_time = feedback_seconds
	_feedback.modulate.a = 1.0
	_player.stream = _chime if ok else _tick
	_player.play()


func _process(delta: float) -> void:
	if _feedback_time > 0.0:
		_feedback_time -= delta
		_feedback.modulate.a = clampf(_feedback_time * 2.0, 0.0, 1.0)
	if not visible:
		return
	# Held up/down (and the left stick) repeat, like the echo menu.
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


func _input(event: InputEvent) -> void:
	if not visible or event is InputEventMouse:
		return  # Mouse events go on to the rows (gui_input).
	var joy := event as InputEventJoypadButton
	if event.is_action_pressed(&"pause") or event.is_action_pressed(&"ui_cancel") \
			or (joy and joy.pressed and joy.button_index == JOY_BUTTON_B):
		resume_requested.emit()
	elif event.is_action_pressed(&"ui_accept") or (joy and joy.pressed and joy.button_index == JOY_BUTTON_A):
		_activate(_selected)
	elif event is InputEventKey and event.pressed and (event as InputEventKey).physical_keycode == KEY_Q:
		quit_requested.emit()
	# Swallow everything while the menu is up so the game (reset, echo menu, map, ...) never sees it.
	get_viewport().set_input_as_handled()


func _row_input(event: InputEvent, i: int) -> void:
	var mb := event as InputEventMouseButton
	if mb and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		_activate(i)


func _hover(i: int) -> void:
	if i != _selected:
		_selected = i
		_refresh()


func _activate(i: int) -> void:
	_selected = i
	_refresh()
	_player.stream = _tick
	_player.play()
	_actions[i].emit()


func _move(dir: int) -> void:
	_selected = wrapi(_selected + dir, 0, _rows.size())
	_refresh()
	_player.stream = _tick
	_player.play()


func _refresh() -> void:
	for i in _rows.size():
		var sel := i == _selected
		_rows[i].add_theme_stylebox_override(&"panel", _row_selected_style if sel else _row_style)
		var l := _rows[i].get_child(0) as Label
		l.label_settings.font_color = Color.WHITE if sel else EchoUi.TEXT
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
