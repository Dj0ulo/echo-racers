class_name Hud
extends CanvasLayer
## Minimal driving HUD: speedometer, FPS, a fading controls hint and the pause overlay.

var car: CarController

var _speed_label: Label
var _fps_label: Label
var _hint_label: Label
var _pause_panel: Control
var _hint_time := 10.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

	_speed_label = _make_label(64)
	_speed_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_KEEP_SIZE, 40)
	_speed_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_speed_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_speed_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	_fps_label = _make_label(16)
	_fps_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_KEEP_SIZE, 16)
	_fps_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_fps_label.modulate.a = 0.7

	_hint_label = _make_label(18)
	_hint_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT, Control.PRESET_MODE_KEEP_SIZE, 24)
	_hint_label.text = "W/S  throttle / brake-reverse\nA/D  steer\nSpace  handbrake (drift)\nR  reset car\nEsc  pause"

	_pause_panel = ColorRect.new()
	(_pause_panel as ColorRect).color = Color(0.05, 0.07, 0.1, 0.45)
	_pause_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pause_panel.visible = false
	add_child(_pause_panel)
	var pause_label := _make_label(40, _pause_panel)
	pause_label.text = "PAUSED\n\nEsc  resume      Q  quit"
	pause_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pause_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	pause_label.set_anchors_preset(Control.PRESET_FULL_RECT)


func _process(delta: float) -> void:
	if car:
		_speed_label.text = "%d km/h" % roundi(car.get_speed_kmh())
	_fps_label.text = "%d FPS" % Engine.get_frames_per_second()
	if _hint_time > 0.0 and not get_tree().paused:
		_hint_time -= delta
		_hint_label.modulate.a = clampf(_hint_time, 0.0, 1.0)


func set_paused(paused: bool) -> void:
	_pause_panel.visible = paused


func _make_label(font_size: int, parent: Node = self) -> Label:
	var label := Label.new()
	var settings := LabelSettings.new()
	settings.font_size = font_size
	settings.font_color = Color(1, 1, 1)
	settings.outline_size = maxi(font_size / 8, 4)
	settings.outline_color = Color(0, 0, 0, 0.6)
	label.label_settings = settings
	parent.add_child(label)
	return label
