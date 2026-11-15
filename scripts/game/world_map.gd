class_name WorldMap
extends CanvasLayer
## Full-screen map, opened with Select / M at any time except in the echo editor. It pauses the game and
## looks straight down on the world (north up) from its own camera, like the echo editor. Pan with the left
## stick / WASD / arrows / mouse drag, zoom with the triggers / Q E / wheel; A / Enter puts the GPS
## destination under the crosshair (or click a spot), X / F / Delete clears it, B / Select / Esc closes.
## The GPS route, the car, the destination, the echo points, delivery offers (lime parcels) and the active
## delivery's drop-off (lime pin) are drawn on top.
## Points of interest (echo race starts, delivery offers, the drop-off) snap: when the mouse pointer (or, with
## the stick / keys, the crosshair) comes within `snap_radius` px of one, it is selected: the crosshair eases
## onto it (stick / keys only), its course is previewed (the echo's best run with its checkpoints, the
## delivery's road route to its drop-off) and an info panel at the top right shows its details with a
## "GPS" button (A / Enter, or click the button or the point) that sets the destination there.

const TEXT := Color(0.92, 0.95, 1.0)
const MUTED := Color(0.62, 0.7, 0.8)
const SHADOW := Color(0, 0, 0, 0.7)

@export var fov := 50.0
@export var min_height := 140.0     ## Closest zoom (m above the ground).
@export var start_height := 1600.0  ## Zoom when the map opens.
@export var pan_speed := 0.8        ## Screen heights per second at full stick.
@export var zoom_speed := 1.5
@export var deadzone := 0.18
@export var snap_radius := 34.0     ## Pixels: a point of interest this close to the pointer is selected.
@export var snap_speed := 9.0       ## How fast the crosshair eases onto the selected point (stick / keys).

const PANEL_W := 390.0

var gps: Gps
var echo: EchoManager
var missions: MissionManager

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
var _mouse_pointer := false        ## The mouse (not the crosshair) picks the point of interest.
var _pointer := Vector2.ZERO
## Selected point of interest: {kind: "echo" | "offer" | "dropoff", pos: Vector3, ref: EchoTrack | Offer},
## empty when none.
var _sel := {}
var _preview := PackedVector3Array()       ## Course preview of the selection (world points).
var _preview_marks := PackedVector3Array() ## Echo checkpoints ([0] start, last finish) / delivery drop-off.
var _sel_road_m := INF                     ## Metres by road from the car to the selection.
var _panel := Rect2()
var _button := Rect2()


func setup(world: WorldGenerator, car: CarController, hud: Hud, env: Environment, p_gps: Gps,
		p_echo: EchoManager, p_missions: MissionManager) -> void:
	missions = p_missions
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
	_mouse_pointer = false
	_select({})
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
		if _sel.is_empty():
			_place(_look)
		else:
			activate_selection()
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
					_click(mb.position)
				_mouse_down = false
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		_mouse_pointer = true
		_pointer = mm.position
		if not _mouse_down:
			return
		if _dragged or mm.position.distance_to(_press_pos) > 6.0:
			_dragged = true
			_look -= mm.relative * _metres_per_pixel()  # Exact at ground level under the crosshair.
			_clamp_look()


func _process(delta: float) -> void:
	if not _open:
		return
	var pan := Vector2(VehicleInput.joy_axis(JOY_AXIS_LEFT_X), VehicleInput.joy_axis(JOY_AXIS_LEFT_Y))
	if pan.length() < deadzone:
		pan = Vector2.ZERO
	pan.x += _key(KEY_D) + _key(KEY_RIGHT) - _key(KEY_A) - _key(KEY_LEFT)
	pan.y += _key(KEY_S) + _key(KEY_DOWN) - _key(KEY_W) - _key(KEY_UP)
	pan = pan.limit_length(1.0)
	var zoom := VehicleInput.joy_axis(JOY_AXIS_TRIGGER_RIGHT) - VehicleInput.joy_axis(JOY_AXIS_TRIGGER_LEFT)
	var stick_zoom := -VehicleInput.joy_axis(JOY_AXIS_RIGHT_Y)
	if absf(stick_zoom) > deadzone:
		zoom += stick_zoom
	zoom += _key(KEY_E) - _key(KEY_Q)
	_height = clampf(_height * exp(-clampf(zoom, -1.0, 1.0) * zoom_speed * delta), min_height, _max_height)
	if pan != Vector2.ZERO or (absf(zoom) > 0.0 and not _mouse_pointer):
		_mouse_pointer = false
	_look += pan * _view_height_m() * pan_speed * delta
	_clamp_look()
	_update_camera(delta)
	_update_selection()
	if not _sel.is_empty() and not _mouse_pointer and pan == Vector2.ZERO:
		var p: Vector3 = _sel.pos
		_look = _look.lerp(Vector2(p.x, p.z), 1.0 - exp(-snap_speed * delta))
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


func _click(pos: Vector2) -> void:
	if not _sel.is_empty() and (_button.has_point(pos) or _to_screen(_sel.pos).distance_to(pos) <= snap_radius):
		activate_selection()
	elif not _panel.has_point(pos):
		_place(_screen_to_xz(pos))


# --- Points of interest --------------------------------------------------------------------------

## The selected point of interest ({kind, pos, ref}, empty = none); the tests read it.
func selection() -> Dictionary:
	return _sel


func preview_points() -> PackedVector3Array:
	return _preview


## Centres the map on `xz` with the crosshair (stick mode), as if panned there; the tests use it.
func look_at_xz(xz: Vector2) -> void:
	_mouse_pointer = false
	_look = xz
	_clamp_look()
	_update_camera(0.0)
	_update_selection()


## Sets the GPS destination on the selected point of interest (the panel's button).
func activate_selection() -> void:
	if not _sel.is_empty():
		gps.set_destination(_sel.pos)


func _points_of_interest() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for t in echo.tracks:
		out.append({"kind": "echo", "pos": t.start.origin, "ref": t})
	if missions:
		for o in missions.offers:
			out.append({"kind": "offer", "pos": o.pickup, "ref": o})
		if missions.active:
			out.append({"kind": "dropoff", "pos": missions.active.target, "ref": missions.active})
	return out


func _update_selection() -> void:
	var pointer := _pointer if _mouse_pointer else _overlay.size * 0.5
	# Keep the selection while the mouse is on its panel (to reach the button).
	if _mouse_pointer and not _sel.is_empty() and _panel.grow(8.0).has_point(pointer):
		return
	var best := {}
	var best_d := snap_radius
	for poi in _points_of_interest():
		var d := _to_screen(poi.pos).distance_to(pointer)
		if d < best_d:
			best = poi
			best_d = d
	if best.is_empty() != _sel.is_empty() or (not best.is_empty() and best.ref != _sel.ref):
		_select(best)


func _select(poi: Dictionary) -> void:
	_sel = poi
	_preview = PackedVector3Array()
	_preview_marks = PackedVector3Array()
	_sel_road_m = INF
	if poi.is_empty():
		return
	var graph := gps.road_graph()
	var pos: Vector3 = poi.pos
	_sel_road_m = _road_length(graph, _car.global_position, -_car.global_basis.z, pos)
	match poi.kind:
		"echo":
			var t: EchoTrack = poi.ref
			_preview_marks = t.checkpoints
			if not t.runs.is_empty():
				var run := t.runs[0]
				var step := maxi(run.positions.size() / 600, 1)
				for k in range(0, run.positions.size(), step):
					_preview.append(run.positions[k])
				_preview.append(run.positions[run.positions.size() - 1])
			else:
				_preview = t.checkpoints
		"offer":
			var o: MissionManager.Offer = poi.ref
			var a := graph.find_route(o.pickup, o.pickup_dir, o.target)
			var b := graph.find_route(o.pickup, -o.pickup_dir, o.target)
			var path := a if _path_length(o.pickup, a, o.target) <= _path_length(o.pickup, b, o.target) else b
			_preview.append(o.pickup)
			_preview.append_array(path)
			_preview.append(o.target)
			_preview_marks = PackedVector3Array([o.target])


## Metres by road from `from` (leaving along `heading`) to `to`, INF when there is no route.
func _road_length(graph: RoadGraph, from: Vector3, heading: Vector3, to: Vector3) -> float:
	return _path_length(from, graph.find_route(from, heading, to), to)


func _path_length(from: Vector3, path: PackedVector3Array, to: Vector3) -> float:
	if path.size() < 2:
		return INF
	var length := from.distance_to(path[0]) + path[path.size() - 1].distance_to(to)
	for k in range(1, path.size()):
		length += path[k - 1].distance_to(path[k])
	return length


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
	_draw_preview()
	# Echo points.
	var minimap := _hud.get_minimap()
	for p in minimap.echo_points:
		var s := _to_screen(p)
		var d := PackedVector2Array([s + Vector2(0, -9), s + Vector2(9, 0), s + Vector2(0, 9), s + Vector2(-9, 0)])
		_overlay.draw_colored_polygon(d, Minimap.ECHO_COLOR)
		d.append(d[0])
		_overlay.draw_polyline(d, Color(1, 1, 1, 0.9), 1.5, true)
	# Delivery offers and the active delivery's drop-off.
	for p in minimap.mission_offers:
		Minimap.draw_parcel_icon(_overlay, _to_screen(p), 9.0)
	if minimap.mission_target_active:
		_draw_map_pin(_to_screen(minimap.mission_target), MissionManager.COLOR)
	# Destination pin (unless it is the drop-off, already pinned in lime).
	var delivery := minimap.mission_target_active and gps.has_destination \
			and Vector2(gps.destination.x - minimap.mission_target.x, gps.destination.z - minimap.mission_target.z).length() < 1.0
	if gps.has_destination and not delivery:
		_draw_map_pin(_to_screen(gps.destination), Gps.COLOR)
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
	_draw_selection_ring()
	# Crosshair.
	_overlay.draw_arc(c, 14.0, 0.0, TAU, 40, Color(SHADOW, 0.5), 4.0, true)
	_overlay.draw_arc(c, 14.0, 0.0, TAU, 40, TEXT, 2.0, true)
	for v: Vector2 in [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]:
		_overlay.draw_line(c + v * 8.0, c + v * 24.0, TEXT, 2.0, true)
	# Texts.
	_text("MAP", Vector2(32, 52), 30, TEXT)
	var info := "No destination"
	if gps.has_destination:
		info = "%s  ·  %.1f km by road" % ["Delivery drop-off" if delivery else "Destination", gps.route_length / 1000.0]
	_text(info, Vector2(32, 84), 18, (MissionManager.COLOR if delivery else Gps.COLOR) if gps.has_destination else MUTED)
	var np := Vector2(size.x - 48, 48)
	_overlay.draw_colored_polygon(PackedVector2Array([np + Vector2(0, -26), np + Vector2(9, -10), np + Vector2(-9, -10)]),
		Color(1.0, 0.45, 0.4))
	_text("N", np + Vector2(-8, 12), 22, Color(1.0, 0.45, 0.4))
	_text("Left stick / WASD / drag  pan      LT RT / Q E / wheel  zoom      A / Enter / click  set destination" +
		"      X / F / Del  clear      B / Select / Esc  close", Vector2(32, size.y - 28), 16, MUTED)
	_draw_panel(size)


func _sel_color() -> Color:
	return Minimap.ECHO_COLOR if _sel.get("kind", "") == "echo" else MissionManager.COLOR


## Course preview of the selection: echo run with numbered checkpoints, or delivery road route + drop-off pin.
func _draw_preview() -> void:
	if _sel.is_empty() or _preview.size() < 2:
		return
	var col := _sel_color()
	var line := PackedVector2Array()
	for p in _preview:
		line.append(_to_screen(p))
	_overlay.draw_polyline(line, Color(0.0, 0.05, 0.08, 0.85), 9.0, true)
	_overlay.draw_polyline(line, col, 5.0, true)
	if _sel.kind == "echo":
		var n := _preview_marks.size()
		for i in n:
			var s := _to_screen(_preview_marks[i])
			if i == n - 1:  # Finish: chequered square.
				for q in 4:
					var o := Vector2(q % 2, q / 2) * 8.0 - Vector2(8, 8)
					_overlay.draw_rect(Rect2(s + o, Vector2(8, 8)), Color.WHITE if (q % 2) == (q / 2) else Color.BLACK)
				_overlay.draw_rect(Rect2(s - Vector2(8, 8), Vector2(16, 16)), col, false, 2.0)
			elif i > 0:
				_overlay.draw_circle(s, 9.0, Color(0.0, 0.05, 0.08, 0.9))
				_overlay.draw_circle(s, 7.0, col)
				_overlay.draw_string(_font, s + Vector2(-4, 5), str(i), HORIZONTAL_ALIGNMENT_LEFT, -1, 13,
					Color(0.02, 0.06, 0.1))
	elif _sel.kind == "offer" and not _preview_marks.is_empty():
		_draw_map_pin(_to_screen(_preview_marks[0]), MissionManager.COLOR)


## Pulsing ring and corner brackets around the selected point of interest.
func _draw_selection_ring() -> void:
	if _sel.is_empty():
		return
	var s := _to_screen(_sel.pos)
	var col := _sel_color()
	var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() / 1000.0 * 5.0)
	_overlay.draw_arc(s, 20.0 + 4.0 * pulse, 0.0, TAU, 48, Color(col, 0.35 + 0.4 * pulse), 3.0, true)
	for k in 4:
		var d := Vector2.from_angle(TAU * (k + 0.5) / 4.0) * 26.0
		var a := s + d
		_overlay.draw_line(a, a - Vector2(signf(d.x) * 9.0, 0), col, 3.0, true)
		_overlay.draw_line(a, a - Vector2(0, signf(d.y) * 9.0), col, 3.0, true)


## Info panel (top right) of the selected point of interest, with its GPS button.
func _draw_panel(size: Vector2) -> void:
	_panel = Rect2()
	_button = Rect2()
	if _sel.is_empty():
		return
	var col := _sel_color()
	var kind := ""
	var title := ""
	var lines: Array[String] = []
	var go := ""
	match _sel.kind:
		"echo":
			var t: EchoTrack = _sel.ref
			kind = "ECHO RACE"
			title = t.name
			lines.append("%.2f km  ·  %d checkpoint%s  ·  %s" % [t.length / 1000.0, t.checkpoints.size() - 2,
				"" if t.checkpoints.size() == 3 else "s", t.style_name()])
			lines.append("Best echo %s  ·  %d echo%s" % [EchoRun.format_time(t.best_time()), t.runs.size(),
				"" if t.runs.size() == 1 else "es"])
			lines.append("Par %s" % EchoRun.format_time(echo.par_time(t)))
			lines.append("Pays when you beat par and %s" % EchoRun.format_time(t.reward_reference()))
			go = "GPS to the start"
		"offer":
			var o: MissionManager.Offer = _sel.ref
			kind = "DELIVERY OFFER"
			title = o.cargo
			lines.append("Pays %s" % Wallet.format(o.reward))
			lines.append("Delivery %.1f km in %d:%02d" % [o.route_length / 1000.0, int(o.time_limit) / 60,
				int(o.time_limit) % 60])
			lines.append("Offer open %d:%02d" % [int(o.time_left) / 60, int(o.time_left) % 60])
			go = "GPS to the pickup"
		"dropoff":
			var o: MissionManager.Offer = _sel.ref
			kind = "DELIVERY DROP-OFF"
			title = o.cargo
			lines.append("Pays %s on delivery" % Wallet.format(o.reward))
			lines.append("Time left %d:%02d" % [int(o.delivery_left) / 60, int(o.delivery_left) % 60])
			go = "GPS to the drop-off"
	lines.append("From you: %s" % ("%.1f km by road" % (_sel_road_m / 1000.0) if _sel_road_m < INF else
		"%.1f km as the crow flies" % (Vector2(_sel.pos.x - _car.global_position.x,
		_sel.pos.z - _car.global_position.z).length() / 1000.0)))
	var pad := 18.0
	var h := pad + 22.0 + 32.0 + lines.size() * 25.0 + 14.0 + 44.0 + pad
	_panel = Rect2(size.x - PANEL_W - 32.0, 96.0, PANEL_W, h)
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.03, 0.05, 0.08, 0.84)
	box.border_color = Color(col, 0.8)
	box.border_width_left = 4
	box.set_corner_radius_all(6)
	_overlay.draw_style_box(box, _panel)
	var x := _panel.position.x + pad + 4.0
	var y := _panel.position.y + pad + 14.0
	_text(kind, Vector2(x, y), 15, col)
	y += 32.0
	_overlay.draw_string(_font, Vector2(x, y) + Vector2(1.5, 1.5), title, HORIZONTAL_ALIGNMENT_LEFT,
		PANEL_W - pad * 2.0, 24, SHADOW)
	_overlay.draw_string(_font, Vector2(x, y), title, HORIZONTAL_ALIGNMENT_LEFT, PANEL_W - pad * 2.0, 24, TEXT)
	y += 4.0
	for l in lines:
		y += 25.0
		_text(l, Vector2(x, y), 17, TEXT if l != lines[lines.size() - 1] else MUTED)
	_button = Rect2(x, y + 14.0, PANEL_W - pad * 2.0 - 4.0, 44.0)
	var here := gps.has_destination and Vector2(gps.destination.x - _sel.pos.x, gps.destination.z - _sel.pos.z).length() < 1.0
	var hot := _mouse_pointer and _button.has_point(_pointer)
	var btn := StyleBoxFlat.new()
	btn.bg_color = Color(col, 0.12 if here else (0.45 if hot else 0.28))
	btn.border_color = Color(col, 0.5 if here else 1.0)
	btn.set_border_width_all(2)
	btn.set_corner_radius_all(5)
	_overlay.draw_style_box(btn, _button)
	var label := "GPS set here" if here else "A / Enter / Click   %s" % go
	var fs := 17
	var w := _font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	_text(label, Vector2(_button.get_center().x - w * 0.5, _button.get_center().y + 6.0), fs, MUTED if here else TEXT)


## Map pin whose tip is at `s`.
func _draw_map_pin(s: Vector2, col: Color) -> void:
	var tip := s
	var head := s + Vector2(0, -26)
	_overlay.draw_colored_polygon(PackedVector2Array([tip, head + Vector2(-9, 4), head + Vector2(9, 4)]),
		Color(0.1, 0.07, 0.0, 0.9))
	_overlay.draw_circle(head, 12.0, Color(0.1, 0.07, 0.0, 0.9))
	_overlay.draw_colored_polygon(PackedVector2Array([tip + Vector2(0, -3), head + Vector2(-7, 5),
		head + Vector2(7, 5)]), col)
	_overlay.draw_circle(head, 10.0, col)
	_overlay.draw_circle(head, 4.0, Color.WHITE)


func _text(t: String, pos: Vector2, fs: int, col: Color) -> void:
	_overlay.draw_string(_font, pos + Vector2(1.5, 1.5), t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, SHADOW)
	_overlay.draw_string(_font, pos, t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
