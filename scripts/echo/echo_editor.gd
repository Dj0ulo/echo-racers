class_name EchoEditor
extends Node3D
## Top-down 3D review of a freshly recorded run: scrub along it (left / right, LB / RB jump between
## checkpoints, triggers zoom), place checkpoints by hand (X), at random or on the run's local x/y/z extremes,
## move the finish, pick the gate style, then save the echo or discard it. Runs while the tree is paused and
## drives the EchoUi side menu.

## `track` is null when discarded. EchoManager then offers racing it / recording again or leaving race mode.
signal finished(track: EchoTrack)

@export var pitch_deg := 62.0
@export var fov := 50.0
@export var min_checkpoint_gap := 40.0  ## Metres between checkpoints, and from the start / finish.
@export var toggle_reach := 15.0        ## X removes a checkpoint closer than this (metres along the run).
@export var random_spacing := 400.0     ## Roughly one random checkpoint per this many metres.
@export var extreme_window := 150.0     ## Metres either side a point must beat to count as a local extreme.
@export var extreme_prominence_xz := 20.0
@export var extreme_prominence_y := 4.0
@export var cursor_min_scale := 1.6     ## Ghost-car cursor scale when zoomed in.
@export var cursor_max_scale := 6.0     ## Cap when zoomed out (it grows with the square root of the distance).

var run: EchoRun
var style := EchoTrack.Style.RINGS
var checkpoints: Array[int] = []  ## Sample indices of the intermediate checkpoints, ascending.
var gate_radius := 9.0

var _ui: EchoUi
var _env: Environment
var _fog_was := false
var _prev_camera: Camera3D
var _camera: Camera3D
var _ghost: GhostCar
var _gates_root: Node3D
var _cursor_label: Label3D
var _ribbon: MeshInstance3D
var _space: PhysicsDirectSpaceState3D
var _cum := PackedFloat32Array()  ## Distance along the run at each sample.
var _end := 0                     ## Finish sample (the run can be trimmed).
var _cursor := 0.0
var _hold := 0.0
var _zoom := 0.0
var _center := Vector3.ZERO
var _extent := 100.0
var _look := Vector3.ZERO
var _dist := 100.0
var _in_confirm := false


func setup(p_run: EchoRun, car: Node3D, ui: EchoUi, env: Environment, prev_camera: Camera3D, p_style: int,
		p_gate_radius: float) -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	run = p_run
	_ui = ui
	_env = env
	_prev_camera = prev_camera
	style = p_style as EchoTrack.Style
	gate_radius = p_gate_radius
	_space = car.get_world_3d().direct_space_state
	_end = run.sample_count() - 1
	_cum.resize(run.sample_count())
	for i in range(1, run.sample_count()):
		_cum[i] = _cum[i - 1] + run.positions[i].distance_to(run.positions[i - 1])
	var box := AABB(run.positions[0], Vector3.ZERO)
	for p in run.positions:
		box = box.expand(p)
	_center = box.get_center()
	_extent = maxf(maxf(box.size.x, box.size.z) * 0.5 + 40.0, 90.0)

	_ribbon = MeshInstance3D.new()
	_ribbon.material_override = Neon.ribbon_material()
	(_ribbon.material_override as ShaderMaterial).render_priority = -1
	_ribbon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ribbon)
	_build_ribbon()
	_gates_root = Node3D.new()
	add_child(_gates_root)
	_ghost = GhostCar.new()
	_ghost.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_ghost)
	_ghost.build_from(car)
	_ghost.run = run
	_ghost.set_energy(4.0)
	_ghost.set_render_priority(2)
	_cursor_label = Label3D.new()
	_cursor_label.text = "▼"
	_cursor_label.font_size = 64
	_cursor_label.fixed_size = true
	_cursor_label.pixel_size = 0.0005
	_cursor_label.no_depth_test = true
	_cursor_label.render_priority = 12
	_cursor_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_cursor_label.modulate = Color(1.0, 1.0, 1.0)
	_cursor_label.outline_modulate = Color(0.0, 0.3, 0.6)
	_cursor_label.outline_size = 16
	_ghost.add_child(_cursor_label)
	_cursor_label.position.y = 4.0

	_camera = Camera3D.new()
	_camera.fov = fov
	_camera.far = 12000.0
	_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_camera)
	_camera.make_current()
	if _env:
		_fog_was = _env.fog_enabled
		_env.fog_enabled = false
	_rebuild_gates()
	_open_menu()
	_ui.set_help("◀ ▶  scrub the run      LB / RB  previous / next checkpoint      X / F  add or remove a checkpoint      LT / RT  zoom")
	_update_cursor()
	_update_camera(0.0, true)


func _process(delta: float) -> void:
	var axis := clampf(Input.get_axis(&"ui_left", &"ui_right") + Input.get_axis(&"steer_left", &"steer_right"), -1.0, 1.0)
	if absf(axis) > 0.15:
		_hold = minf(_hold + delta, 3.0)
		var rate := maxf(run.duration() / 25.0, 1.0) * (1.0 + _hold * 2.5)  # Run seconds per real second.
		_cursor = clampf(_cursor + axis * rate * EchoRun.RATE * delta, 0.0, run.sample_count() - 1.0)
	else:
		_hold = 0.0
	if not _in_confirm:
		if Input.is_action_just_pressed(&"echo_checkpoint"):
			toggle_checkpoint()
		if Input.is_action_just_pressed(&"echo_prev"):
			_jump(-1)
		if Input.is_action_just_pressed(&"echo_next"):
			_jump(1)
	var zoom := VehicleInput.joy_axis(JOY_AXIS_TRIGGER_RIGHT) - VehicleInput.joy_axis(JOY_AXIS_TRIGGER_LEFT)
	zoom += float(Input.is_physical_key_pressed(KEY_W)) - float(Input.is_physical_key_pressed(KEY_S))
	_zoom = clampf(_zoom + zoom * delta * 0.7, 0.0, 1.0)
	_update_cursor()
	_update_camera(delta)


# --- Checkpoint editing --------------------------------------------------------------------------

func toggle_checkpoint() -> void:
	var i := roundi(_cursor)
	var near := _checkpoint_near(i)
	if near >= 0:
		checkpoints.remove_at(near)
	elif i >= _end or _cum[i] < min_checkpoint_gap or _cum[_end] - _cum[i] < min_checkpoint_gap:
		_ui.toast("Too close to the start or the finish")
		return
	else:
		checkpoints.append(i)
		checkpoints.sort()
	_changed()


func random_checkpoints() -> void:
	var total := _cum[_end]
	if total < min_checkpoint_gap * 3.0:
		_ui.toast("This run is too short for random checkpoints")
		return
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var n := clampi(roundi(total / random_spacing) + rng.randi_range(-1, 1), 1, 14)
	var spacing := total / (n + 1)
	var picks: Array[int] = []
	for k in n:
		var d := spacing * (k + 1) + rng.randf_range(-0.4, 0.4) * spacing
		picks.append(_index_at(clampf(d, min_checkpoint_gap, total - min_checkpoint_gap)))
	checkpoints = _filtered(picks)
	_changed()
	_ui.toast("%d random checkpoints" % checkpoints.size())


## Checkpoints on every local extreme of x, z (the outermost points of bends) and y (crests and dips): a point
## of the run, resampled every 5 m, that beats everything within `extreme_window` metres by a margin.
func auto_checkpoints() -> void:
	var step := 5.0
	var idx := PackedInt32Array()
	var pts := PackedVector3Array()
	var i := 0
	var d := 0.0
	while d <= _cum[_end]:
		while i < _end and _cum[i] < d:
			i += 1
		idx.append(i)
		pts.append(run.positions[i])
		d += step
	var m := pts.size()
	var w := maxi(int(extreme_window / step), 2)
	var found: Array[int] = []
	for axis in 3:
		var prominence := extreme_prominence_y if axis == 1 else extreme_prominence_xz
		for j in range(1, m - 1):
			var v := pts[j][axis]
			var hi := -INF
			var lo := INF
			for k in range(maxi(j - w, 0), mini(j + w, m - 1) + 1):
				hi = maxf(hi, pts[k][axis])
				lo = minf(lo, pts[k][axis])
			if (v >= hi and v - lo >= prominence) or (v <= lo and hi - v >= prominence):
				found.append(idx[j])
	found.sort()
	checkpoints = _filtered(found)
	_changed()
	_ui.toast("%d checkpoints on the run's x / y / z extremes" % checkpoints.size() if not checkpoints.is_empty()
		else "No clear extremes found on this run")


func clear_checkpoints() -> void:
	checkpoints.clear()
	_changed()


func set_finish_here() -> void:
	var i := roundi(_cursor)
	if _cum[i] < min_checkpoint_gap * 2.0:
		_ui.toast("The finish must be at least %d m from the start" % roundi(min_checkpoint_gap * 2.0))
		return
	_end = i
	checkpoints = _filtered(checkpoints)
	_build_ribbon()
	_changed()
	_ui.toast("Finish moved to %s" % EchoRun.format_time(_end / EchoRun.RATE))


func toggle_style() -> void:
	style = EchoTrack.Style.GATES if style == EchoTrack.Style.RINGS else EchoTrack.Style.RINGS
	_changed()


func save() -> void:
	var track := EchoTrack.new()
	track.id = EchoTrack.new_id()
	track.style = style
	var echo := run.trimmed(_end)
	var keys: Array[int] = [0]
	keys.append_array(checkpoints)
	keys.append(_end)
	for i in keys:
		track.checkpoints.append(run.positions[i])
		track.directions.append(_direction_at(i))
		echo.splits.append(i / EchoRun.RATE)
	echo.time = _end / EchoRun.RATE
	track.start = run.transform_at(0.0)
	track.length = _cum[_end]
	track.retime_to_rings(echo, gate_radius)
	track.runs.append(echo)
	_close(track)


func discard() -> void:
	_close(null)


func _close(track: EchoTrack) -> void:
	if _env:
		_env.fog_enabled = _fog_was
	_ui.close_menu()
	_ui.set_help("")
	_ui.set_cursor_info("")
	if _prev_camera:
		_prev_camera.make_current()
	finished.emit(track)
	queue_free()


## Sorted, at least `min_checkpoint_gap` apart and from the start / finish.
func _filtered(indices: Array[int]) -> Array[int]:
	var out: Array[int] = []
	var last := 0.0
	for i in indices:
		if i >= _end:
			continue
		var d := _cum[i]
		if d - last >= min_checkpoint_gap and _cum[_end] - d >= min_checkpoint_gap:
			out.append(i)
			last = d
	return out


func _checkpoint_near(i: int) -> int:
	for k in checkpoints.size():
		if absf(_cum[checkpoints[k]] - _cum[i]) < toggle_reach:
			return k
	return -1


func _index_at(distance: float) -> int:
	var lo := 0
	var hi := _end
	while lo < hi:
		var mid := (lo + hi) >> 1
		if _cum[mid] < distance:
			lo = mid + 1
		else:
			hi = mid
	return lo


func _jump(dir: int) -> void:
	var keys: Array[int] = [0]
	keys.append_array(checkpoints)
	keys.append(_end)
	if dir > 0:
		for k in keys:
			if k > _cursor + 0.5:
				_cursor = k
				return
	else:
		for n in range(keys.size() - 1, -1, -1):
			if keys[n] < _cursor - 0.5:
				_cursor = keys[n]
				return


func _direction_at(i: int) -> Vector3:
	return run.direction_at(i)


func _changed() -> void:
	_rebuild_gates()
	_refresh_menu()


# --- Visuals -------------------------------------------------------------------------------------

func _rebuild_gates() -> void:
	for c in _gates_root.get_children():
		c.queue_free()
	var keys: Array[int] = [0]
	keys.append_array(checkpoints)
	keys.append(_end)
	for n in keys.size():
		var kind := CheckpointGate.Kind.CHECKPOINT
		if n == 0:
			kind = CheckpointGate.Kind.START
		elif n == keys.size() - 1:
			kind = CheckpointGate.Kind.FINISH
		var gate := CheckpointGate.new()
		_gates_root.add_child(gate)
		gate.setup(style, kind, n, gate_radius, true)
		gate.global_transform = CheckpointGate.ground_xform(_space, run.positions[keys[n]], _direction_at(keys[n]))


## Flat ribbon along the run, blue when slow to bright cyan/white when fast; the trimmed tail is grey.
func _build_ribbon() -> void:
	var p := run.positions
	var n := p.size()
	if n < 2:
		return
	var half := clampf(_extent / 220.0, 1.2, 7.0)
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	var sides := PackedVector3Array()
	sides.resize(n)
	for i in n:
		var t := p[mini(i + 1, n - 1)] - p[maxi(i - 1, 0)]
		var s := Vector3(-t.z, 0.0, t.x)
		sides[i] = s.normalized() * half if s.length_squared() > 1e-8 else (sides[i - 1] if i > 0 else Vector3.RIGHT * half)
	for i in n - 1:
		var col := Color(0.3, 0.32, 0.38)
		if i < _end:
			var v := p[i].distance_to(p[i + 1]) * EchoRun.RATE
			var k := clampf(v / 55.0, 0.0, 1.0)
			col = Neon.BLUE.lerp(Neon.CYAN, k).lerp(Color.WHITE, maxf(k - 0.8, 0.0) * 2.5)
		var a0 := p[i] - sides[i]
		var a1 := p[i] + sides[i]
		var b0 := p[i + 1] - sides[i + 1]
		var b1 := p[i + 1] + sides[i + 1]
		verts.append_array([a0, b0, a1, a1, b0, b1])
		for c in 6:
			cols.append(col)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = cols
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_ribbon.mesh = mesh


func _update_cursor() -> void:
	var t := _cursor / EchoRun.RATE
	_ghost.show_at(t)
	var cam_scale := clampf(cursor_min_scale * sqrt(_dist / 90.0), cursor_min_scale, cursor_max_scale)
	_ghost.scale = Vector3.ONE * cam_scale
	var i := roundi(_cursor)
	var speed := 0.0
	if i + 1 < run.sample_count():
		speed = run.positions[i].distance_to(run.positions[i + 1]) * EchoRun.RATE * 3.6
	_ui.set_cursor_info("▶  %s / %s      %.2f km      %d km/h" % [EchoRun.format_time(t),
		EchoRun.format_time(_end / EchoRun.RATE), _cum[i] / 1000.0, roundi(speed)])
	if not _in_confirm:
		_ui.set_item_text(0, ("Remove checkpoint here" if _checkpoint_near(i) >= 0 else "Add checkpoint here") + "   [X]")


func _update_camera(delta: float, snap := false) -> void:
	var vp := get_viewport().get_visible_rect().size
	var aspect := vp.x / maxf(vp.y, 1.0)
	var covered := clampf((EchoUi.PANEL_WIDTH + EchoUi.MARGIN * 2.0) / maxf(vp.x, 1.0), 0.0, 0.6)
	var tan_half := tan(deg_to_rad(fov * 0.5))
	var full := _extent / (tan_half * minf(1.0, aspect * (1.0 - covered))) * 1.08
	var dist := full * pow(minf(80.0 / full, 1.0), _zoom)
	var cursor_pos := run.positions[roundi(_cursor)]
	var target := _center.lerp(cursor_pos, smoothstep(0.0, 0.6, _zoom))
	var k := 1.0 if snap else 1.0 - exp(-6.0 * delta)
	_look = _look.lerp(target, k)
	_dist = lerpf(_dist, dist, k)
	# The side menu covers the right of the screen: shift the view so the run sits in the free part.
	var shift := Vector3.RIGHT * _dist * tan_half * aspect * covered
	var pitch := deg_to_rad(pitch_deg)
	var back := Vector3(0.0, sin(pitch), cos(pitch))
	_camera.global_position = _look + shift + back * _dist
	_camera.look_at(_look + shift, Vector3.UP)


# --- Menu ----------------------------------------------------------------------------------------

func _menu_items() -> Array[Dictionary]:
	return [
		{"text": "Add checkpoint here   [X]", "action": toggle_checkpoint},
		{"text": "Random checkpoints", "action": random_checkpoints},
		{"text": "Auto: x / y / z extremes", "action": auto_checkpoints},
		{"text": "Clear checkpoints", "action": clear_checkpoints},
		{"text": "Set the finish here", "action": set_finish_here},
		{"text": "Style: %s" % ("neon rings" if style == EchoTrack.Style.RINGS else "light gates"), "action": toggle_style},
		{"text": "Save", "action": save},
		{"text": "Discard", "action": _confirm_discard},
	]


func _subtitle() -> String:
	return "%s · %.2f km · %d checkpoint%s between start and finish." % [EchoRun.format_time(_end / EchoRun.RATE),
		_cum[_end] / 1000.0, checkpoints.size(), "" if checkpoints.size() == 1 else "s"]


func _open_menu(selected := 0) -> void:
	_in_confirm = false
	_ui.open_menu("ECHO EDITOR", _subtitle(), _menu_items(), Callable(), selected)


func _refresh_menu() -> void:
	var items := _menu_items()
	for i in items.size():
		_ui.set_item_text(i, items[i].text)
	_ui.set_menu_subtitle(_subtitle())
	_update_cursor()


func _confirm_discard() -> void:
	_in_confirm = true
	_ui.open_menu("DISCARD RUN?", "The recording will be lost.", [
		{"text": "Yes, discard it", "action": discard},
		{"text": "No, keep editing", "action": _open_menu.bind(7)},
	], _open_menu.bind(7), 1)
