class_name WorldMap
extends CanvasLayer
## Full-screen map, opened with Select / M at any time except in the echo editor. It pauses the game and
## looks straight down on the world (north up) from its own camera, like the echo editor. Pan with the left
## stick / WASD / arrows / mouse drag, zoom with the triggers / Q E / wheel; A / Enter puts the GPS
## destination under the crosshair (or click a spot), X / F / Delete clears it, B / Select / Esc closes.
## The GPS route, the car, the destination and the echo points are drawn on top.

const TEXT := Color(0.92, 0.95, 1.0)
const MUTED := Color(0.62, 0.7, 0.8)
const SHADOW := Color(0, 0, 0, 0.7)

@export var fov := 50.0
@export var min_height := 140.0     ## Closest zoom (m above the ground).
@export var start_height := 1600.0  ## Zoom when the map opens.
@export var pan_speed := 0.8        ## Screen heights per second at full stick.
@export var zoom_speed := 1.5
@export var deadzone := 0.18

var gps: Gps
var echo: EchoManager

var _world: WorldGenerator
var _car: CarController
var _hud: Hud
var _env: Environment
var _camera: Camera3D
var _prev_camera: Camera3D
var _overlay: Control
var _font: Font
var _open := false
var _look := Vector2.ZERO
var _height := 1600.0
var _max_height := 6000.0
var _ground := 0.0
var _bounds := Rect2()
var _fog_was := false
var _clouds: Node3D
var _mouse_down := false
var _dragged := false
var _press_pos := Vector2.ZERO


func setup(world: WorldGenerator, car: CarController, hud: Hud, env: Environment, p_gps: Gps,
		p_echo: EchoManager) -> void:
	_world = world
	_car = car
	_hud = hud
	_env = env
	gps = p_gps
	echo = p_echo
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 8
	visible = false
	_font = ThemeDB.fallback_font
	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	add_child(_overlay)
	_camera = Camera3D.new()
	_camera.fov = fov
	_camera.near = 1.0
	_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_camera)
	var box := Rect2()
	var first := true
	for r in world.roads:
		for p in r.points:
			if first:
				box = Rect2(p.x, p.z, 0.0, 0.0)
				first = false
			else:
				box = box.expand(Vector2(p.x, p.z))
	_bounds = box.grow(500.0)
	_clouds = world.find_child("Clouds", true, false) as Node3D


func is_open() -> bool:
	return _open


func open() -> void:
	if _open:
		return
	_open = true
	get_tree().paused = true
	visible = true
	_prev_camera = get_viewport().get_camera_3d()
	_camera.make_current()
	if _env:
		_fog_was = _env.fog_enabled
		_env.fog_enabled = false
	if _clouds:
		_clouds.visible = false
	_hud.visible = false
	echo.ui.visible = false
	_look = Vector2(_car.global_position.x, _car.global_position.z)
	_ground = _car.global_position.y
	_height = start_height
	var vp := get_viewport().get_visible_rect().size
	var aspect := vp.x / maxf(vp.y, 1.0)
	_max_height = maxf(_bounds.size.x / aspect, _bounds.size.y) * 0.5 / tan(deg_to_rad(fov * 0.5))
	_mouse_down = false
	_update_camera(0.0)


func close() -> void:
	if not _open:
		return
	_open = false
	visible = false
	if _env:
		_env.fog_enabled = _fog_was
	if _clouds:
		_clouds.visible = true
	_hud.visible = true
	echo.ui.visible = true
	if is_instance_valid(_prev_camera):
		_prev_camera.make_current()
	get_tree().paused = false


func _unhandled_input(event: InputEvent) -> void:
	if _open or not event.is_action_pressed(&"world_map"):
		return
	if get_tree().paused or echo.state == EchoManager.State.EDITING:
		return
	get_viewport().set_input_as_handled()
	open()


func _input(event: InputEvent) -> void:
	if not _open:
		return
	get_viewport().set_input_as_handled()
	var joy := event as InputEventJoypadButton
	if event.is_action_pressed(&"world_map") or event.is_action_pressed(&"pause") \
			or event.is_action_pressed(&"ui_cancel") or (joy and joy.pressed and joy.button_index == JOY_BUTTON_B):
		close()
	elif event.is_action_pressed(&"ui_accept") or (joy and joy.pressed and joy.button_index == JOY_BUTTON_A):
		_place(_look)
	elif event.is_action_pressed(&"echo_checkpoint") or (event is InputEventKey and event.pressed
			and (event as InputEventKey).physical_keycode in [KEY_DELETE, KEY_BACKSPACE]):
		if gps.has_destination:
			gps.clear_destination()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_height = clampf(_height / 1.15, min_height, _max_height)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_height = clampf(_height * 1.15, min_height, _max_height)
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_mouse_down = true
				_dragged = false
				_press_pos = mb.position
			else:
				if _mouse_down and not _dragged:
					_place(_screen_to_xz(mb.position))
				_mouse_down = false
	elif event is InputEventMouseMotion and _mouse_down:
		var mm := event as InputEventMouseMotion
		if _dragged or mm.position.distance_to(_press_pos) > 6.0:
			_dragged = true
			_look -= mm.relative * _metres_per_pixel()  # Exact at ground level under the crosshair.
			_clamp_look()


func _process(delta: float) -> void:
	if not _open:
		return
	var pan := Vector2(Input.get_joy_axis(0, JOY_AXIS_LEFT_X), Input.get_joy_axis(0, JOY_AXIS_LEFT_Y))
	if pan.length() < deadzone:
		pan = Vector2.ZERO
	pan.x += _key(KEY_D) + _key(KEY_RIGHT) - _key(KEY_A) - _key(KEY_LEFT)
	pan.y += _key(KEY_S) + _key(KEY_DOWN) - _key(KEY_W) - _key(KEY_UP)
	pan = pan.limit_length(1.0)
	var zoom := Input.get_joy_axis(0, JOY_AXIS_TRIGGER_RIGHT) - Input.get_joy_axis(0, JOY_AXIS_TRIGGER_LEFT)
	var stick_zoom := -Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y)
	if absf(stick_zoom) > deadzone:
		zoom += stick_zoom
	zoom += _key(KEY_E) - _key(KEY_Q)
	_height = clampf(_height * exp(-clampf(zoom, -1.0, 1.0) * zoom_speed * delta), min_height, _max_height)
	_look += pan * _view_height_m() * pan_speed * delta
	_clamp_look()
	_update_camera(delta)
	_overlay.queue_redraw()


func _key(k: Key) -> float:
	return 1.0 if Input.is_physical_key_pressed(k) else 0.0


func _view_height_m() -> float:
	return 2.0 * _height * tan(deg_to_rad(fov * 0.5))


func _metres_per_pixel() -> float:
	return _view_height_m() / maxf(get_viewport().get_visible_rect().size.y, 1.0)


func _clamp_look() -> void:
	_look = _look.clamp(_bounds.position, _bounds.end)


func _update_camera(delta: float) -> void:
	var terrain := _world.terrain
	if terrain and terrain.is_inside(_look.x, _look.y):
		var g := terrain.get_height(_look.x, _look.y)
		_ground = g if delta <= 0.0 else lerpf(_ground, g, 1.0 - exp(-3.0 * delta))
	_camera.far = _height + 4000.0
	_camera.global_transform = Transform3D(Basis.looking_at(Vector3.DOWN, Vector3.FORWARD),
		Vector3(_look.x, _ground + _height, _look.y))


func _screen_to_xz(screen: Vector2) -> Vector2:
	# Ray against the terrain: a few fixed-point steps on the height under the hit point.
	var o := _camera.project_ray_origin(screen)
	var d := _camera.project_ray_normal(screen)
	var y := _ground
	var p := o
	for _k in 4:
		p = o + d * ((y - o.y) / minf(d.y, -0.01))
		if _world.terrain and _world.terrain.is_inside(p.x, p.z):
			y = _world.terrain.get_height(p.x, p.z)
	return Vector2(p.x, p.z)


func _place(xz: Vector2) -> void:
	var terrain := _world.terrain
	if terrain and not terrain.is_inside(xz.x, xz.y):
		return
	var y := terrain.get_height(xz.x, xz.y) if terrain else _ground
	gps.set_destination(Vector3(xz.x, y, xz.y))


func _to_screen(p: Vector3) -> Vector2:
	return _camera.unproject_position(p)


# --- Overlay -------------------------------------------------------------------------------------

func _draw_overlay() -> void:
	var size := _overlay.size
	var c := size * 0.5
	# Route.
	if gps.has_destination and gps.route.size() >= 2:
		var line := PackedVector2Array()
		for p in gps.route:
			line.append(_to_screen(p))
		_overlay.draw_polyline(line, Color(0.1, 0.07, 0.0, 0.85), 9.0, true)
		_overlay.draw_polyline(line, Gps.COLOR, 5.0, true)
	# Echo points.
	var minimap := _hud.get_minimap()
	for p in minimap.echo_points:
		var s := _to_screen(p)
		var d := PackedVector2Array([s + Vector2(0, -9), s + Vector2(9, 0), s + Vector2(0, 9), s + Vector2(-9, 0)])
		_overlay.draw_colored_polygon(d, Minimap.ECHO_COLOR)
		d.append(d[0])
		_overlay.draw_polyline(d, Color(1, 1, 1, 0.9), 1.5, true)
	# Destination pin.
	if gps.has_destination:
		var s := _to_screen(gps.destination)
		var tip := s
		var head := s + Vector2(0, -26)
		_overlay.draw_colored_polygon(PackedVector2Array([tip, head + Vector2(-9, 4), head + Vector2(9, 4)]),
			Color(0.1, 0.07, 0.0, 0.9))
		_overlay.draw_circle(head, 12.0, Color(0.1, 0.07, 0.0, 0.9))
		_overlay.draw_colored_polygon(PackedVector2Array([tip + Vector2(0, -3), head + Vector2(-7, 5),
			head + Vector2(7, 5)]), Gps.COLOR)
		_overlay.draw_circle(head, 10.0, Gps.COLOR)
		_overlay.draw_circle(head, 4.0, Color.WHITE)
	# Car arrow.
	var car_s := _to_screen(_car.global_position)
	var f := -_car.global_basis.z
	var fwd := Vector2(f.x, f.z)
	fwd = fwd.normalized() if fwd.length_squared() > 1e-6 else Vector2(0, -1)
	var right := Vector2(-fwd.y, fwd.x)
	var arrow := PackedVector2Array([car_s + fwd * 14.0, car_s - fwd * 10.0 + right * 10.0, car_s - fwd * 5.0,
		car_s - fwd * 10.0 - right * 10.0])
	_overlay.draw_colored_polygon(arrow, Minimap.PLAYER_COLOR)
	arrow.append(arrow[0])
	_overlay.draw_polyline(arrow, Color.WHITE, 2.0, true)
	# Crosshair.
	_overlay.draw_arc(c, 14.0, 0.0, TAU, 40, Color(SHADOW, 0.5), 4.0, true)
	_overlay.draw_arc(c, 14.0, 0.0, TAU, 40, TEXT, 2.0, true)
	for v: Vector2 in [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]:
		_overlay.draw_line(c + v * 8.0, c + v * 24.0, TEXT, 2.0, true)
	# Texts.
	_text("MAP", Vector2(32, 52), 30, TEXT)
	var info := "No destination"
	if gps.has_destination:
		info = "Destination  ·  %.1f km by road" % (gps.route_length / 1000.0)
	_text(info, Vector2(32, 84), 18, Gps.COLOR if gps.has_destination else MUTED)
	var np := Vector2(size.x - 48, 48)
	_overlay.draw_colored_polygon(PackedVector2Array([np + Vector2(0, -26), np + Vector2(9, -10), np + Vector2(-9, -10)]),
		Color(1.0, 0.45, 0.4))
	_text("N", np + Vector2(-8, 12), 22, Color(1.0, 0.45, 0.4))
	_text("Left stick / WASD / drag  pan      LT RT / Q E / wheel  zoom      A / Enter / click  set destination" +
		"      X / F / Del  clear      B / Select / Esc  close", Vector2(32, size.y - 28), 16, MUTED)


func _text(t: String, pos: Vector2, fs: int, col: Color) -> void:
	_overlay.draw_string(_font, pos + Vector2(1.5, 1.5), t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, SHADOW)
	_overlay.draw_string(_font, pos, t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
