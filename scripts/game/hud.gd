class_name Hud
extends CanvasLayer
## Minimal driving HUD: speedometer with a boost gauge, FPS, a fading controls hint and the pause overlay.

const BOOST_FULL := Color(0.3, 0.82, 1.0)
const BOOST_ACTIVE := Color(1.0, 0.55, 0.12)
const BOOST_COOLDOWN := Color(0.5, 0.55, 0.6)
const BOOST_REFILL := Color(0.22, 0.5, 0.85)
const BOOST_BAR_SIZE := Vector2(260, 14)

var car: CarController

var _speed_label: Label
var _fps_label: Label
var _hint_label: Label
var _pause_panel: Control
var _boost_bar: Control
var _boost_label: Label
var _boost_shown := 1.0    ## Smoothed gauge value for display.
var _boost_flash := 0.0    ## Brief highlight when the gauge becomes full again.
var _boost_was_full := true
var _bar_bg := StyleBoxFlat.new()
var _bar_fill := StyleBoxFlat.new()
var _hint_time := 10.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

	_speed_label = _make_label(64)
	_speed_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_KEEP_SIZE, 40)
	_speed_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_speed_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_speed_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	_build_boost_gauge()

	_fps_label = _make_label(16)
	_fps_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_KEEP_SIZE, 16)
	_fps_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_fps_label.modulate.a = 0.7

	_hint_label = _make_label(18)
	_hint_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT, Control.PRESET_MODE_KEEP_SIZE, 24)
	_hint_label.text = "W/S  throttle / brake-reverse\nA/D  steer\nSpace  handbrake (drift)\nShift  boost\nR  reset car\nEsc  pause"

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
		_update_boost_gauge(delta)
	_fps_label.text = "%d FPS" % Engine.get_frames_per_second()
	if _hint_time > 0.0 and not get_tree().paused:
		_hint_time -= delta
		_hint_label.modulate.a = clampf(_hint_time, 0.0, 1.0)


func _build_boost_gauge() -> void:
	_boost_bar = Control.new()
	_boost_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_boost_bar)
	# Right-aligned just under the speed readout.
	_boost_bar.anchor_left = 1.0
	_boost_bar.anchor_right = 1.0
	_boost_bar.anchor_top = 1.0
	_boost_bar.anchor_bottom = 1.0
	_boost_bar.offset_right = -44.0
	_boost_bar.offset_left = -44.0 - BOOST_BAR_SIZE.x
	_boost_bar.offset_bottom = -22.0
	_boost_bar.offset_top = -22.0 - BOOST_BAR_SIZE.y
	_boost_bar.draw.connect(_draw_boost_bar)

	_boost_label = _make_label(14)
	_boost_label.text = "BOOST"
	_boost_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_boost_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_boost_label.anchor_left = 1.0
	_boost_label.anchor_right = 1.0
	_boost_label.anchor_top = 1.0
	_boost_label.anchor_bottom = 1.0
	_boost_label.offset_right = _boost_bar.offset_left - 10.0
	_boost_label.offset_left = _boost_label.offset_right - 80.0
	_boost_label.offset_bottom = _boost_bar.offset_bottom + 6.0
	_boost_label.offset_top = _boost_bar.offset_top - 6.0

	_bar_bg.bg_color = Color(0.04, 0.06, 0.09, 0.6)
	_bar_bg.border_color = Color(1, 1, 1, 0.35)
	_bar_bg.set_border_width_all(2)
	_bar_bg.set_corner_radius_all(7)
	_bar_fill.set_corner_radius_all(5)


func _update_boost_gauge(delta: float) -> void:
	_boost_shown = lerpf(_boost_shown, car.boost_amount, 1.0 - exp(-14.0 * delta))
	var full := car.boost_amount >= 1.0
	if full and not _boost_was_full:
		_boost_flash = 1.0
	_boost_was_full = full
	_boost_flash = maxf(_boost_flash - delta * 2.0, 0.0)
	_boost_bar.queue_redraw()


func _boost_color() -> Color:
	if car.is_boosting:
		# Flicker like a flame while burning nitro.
		var t := Time.get_ticks_msec() * 0.001
		return BOOST_ACTIVE.lightened(0.15 + 0.15 * sin(t * 30.0))
	if car.boost_cooldown_left > 0.0:
		return BOOST_COOLDOWN
	if car.boost_amount < 1.0:
		return BOOST_REFILL
	return BOOST_FULL.lerp(Color.WHITE, _boost_flash * 0.7)


func _draw_boost_bar() -> void:
	if car == null:
		return
	var rect := Rect2(Vector2.ZERO, _boost_bar.size)
	var col := _boost_color()
	_bar_bg.border_color = Color(col, 0.55) if car.is_boosting or _boost_flash > 0.0 else Color(1, 1, 1, 0.35)
	_bar_bg.draw(_boost_bar.get_canvas_item(), rect)
	var inner := rect.grow(-3.0)
	var w := inner.size.x * clampf(_boost_shown, 0.0, 1.0)
	if w >= 2.0:
		_bar_fill.bg_color = col
		_bar_fill.draw(_boost_bar.get_canvas_item(), Rect2(inner.position, Vector2(w, inner.size.y)))
	_boost_label.modulate = Color(col.lightened(0.3), 0.9)


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
