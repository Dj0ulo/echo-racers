class_name EchoManager
extends Node
## Echo mode game flow. Y opens a side menu anywhere: record a race from where the car stands (3-2-1-GO), end
## it whenever with Y to place its checkpoints in the top-view EchoEditor, then save it as an "echo" course
## marked by a neon EchoPoint. At a point, Y lists its echoes (best first) to race against as a ghost; beating
## the chosen echo lets you save your run as a new one. During any race Y offers restart / exit.

enum State { FREE, COUNTDOWN, RECORDING, RACING, FINISHED, EDITING }

@export var countdown_time := 3.0
@export var gate_radius := 9.0        ## Checkpoint half-width: how far from its centre the car may pass.
@export var min_run_seconds := 3.0    ## Shortest recording that can be turned into an echo.
@export var result_menu_delay := 1.6  ## Seconds between crossing the finish and the result menu.

var state := State.FREE
var tracks: Array[EchoTrack] = []
var ui: EchoUi

var _world: WorldGenerator
var _car: CarController
var _camera: ChaseCamera
var _hud: Hud
var _env: Environment
var _minimap: Minimap
var _points_root: Node3D
var _race_root: Node3D
var _points := {}                 ## EchoTrack.id -> EchoPoint
var _points_shown := true
var _gates: Array[CheckpointGate] = []
var _ghost: GhostCar
var _track: EchoTrack             ## Course being raced (null while recording a new one).
var _ghost_run: EchoRun           ## Echo raced against.
var _run: EchoRun                 ## Run being recorded.
var _start := Transform3D.IDENTITY
var _time := 0.0
var _finish_time := 0.0
var _countdown := 0.0
var _last_count := 0
var _tick := 0
var _record_every := 2
var _next_cp := 1
var _prev_pos := Vector3.ZERO
var _splits := PackedFloat32Array()
var _menu_paused := false
var _nearby: EchoTrack
var _near_check := 0.0
var _result_timer := -1.0
var _won := false
var _saved := false
var _editor: EchoEditor


func setup(world: WorldGenerator, car: CarController, camera: ChaseCamera, hud: Hud, env: Environment) -> void:
	_world = world
	_car = car
	_camera = camera
	_hud = hud
	_env = env
	_minimap = hud.get_minimap()
	process_mode = Node.PROCESS_MODE_ALWAYS
	_record_every = maxi(roundi(Engine.physics_ticks_per_second / EchoRun.RATE), 1)
	ui = EchoUi.new()
	add_child(ui)
	_points_root = Node3D.new()
	_points_root.name = "EchoPoints"
	add_child(_points_root)
	_race_root = Node3D.new()
	_race_root.name = "EchoRace"
	add_child(_race_root)
	tracks = EchoTrack.load_all()
	for t in tracks:
		for r in t.runs:
			t.retime_to_rings(r, gate_radius)  # Saves timed before rings counted on touch.
		t.runs.sort_custom(func(a: EchoRun, b: EchoRun) -> bool: return a.time < b.time)
	_spawn_points()


func _spawn_points() -> void:
	# Wait for the world colliders so the beacons can be dropped onto the ground.
	await get_tree().physics_frame
	await get_tree().physics_frame
	for t in tracks:
		_add_point(t)
	_update_minimap_points()


func _add_point(t: EchoTrack) -> void:
	var p := EchoPoint.new()
	_points_root.add_child(p)
	p.setup(t, CheckpointGate.ground_xform(_car.get_world_3d().direct_space_state, t.start.origin, -t.start.basis.z))
	_points[t.id] = p


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"echo_menu") or state == State.EDITING or ui.is_menu_open():
		return
	if get_tree().paused:
		return  # The regular pause screen is up.
	get_viewport().set_input_as_handled()
	open_context_menu()


func _physics_process(delta: float) -> void:
	if get_tree().paused:
		return
	match state:
		State.FREE:
			_near_check -= delta
			if _near_check <= 0.0:
				_near_check = 0.2
				_update_nearby()
		State.COUNTDOWN:
			_countdown -= delta
			var n := ceili(_countdown)
			if n != _last_count and n > 0:
				_last_count = n
				ui.show_countdown(n)
			if _countdown <= 0.0:
				_go()
		State.RECORDING, State.RACING:
			_tick += 1
			_time = float(_tick) / Engine.physics_ticks_per_second
			if _tick % _record_every == 0:
				_run.add_sample(_car.global_transform)
			if state == State.RACING:
				_update_ghost()
				_check_gates(delta)
			_prev_pos = _car.global_position
		State.FINISHED:
			_time += delta
			_update_ghost()
			if _result_timer > 0.0:
				_result_timer -= delta
				if _result_timer <= 0.0:
					_open_result_menu()


func _process(_delta: float) -> void:
	if state == State.RECORDING:
		ui.set_timer(EchoRun.format_time(_time), EchoUi.TEXT)
	elif state == State.RACING:
		ui.set_timer(EchoRun.format_time(_time), EchoUi.TEXT)
	# Echo beacons (3D and minimap) only in free roam: races, recording and the editor show just checkpoints.
	var free := state == State.FREE
	if free != _points_shown:
		_points_shown = free
		for p: EchoPoint in _points.values():
			p.visible = free
		_minimap.show_markers = free
	var has_target := state in [State.COUNTDOWN, State.RACING] and _track != null and _next_cp < _track.checkpoints.size()
	_minimap.echo_target_active = has_target
	if has_target:
		_minimap.echo_target = _track.checkpoints[_next_cp]


## Called by main before its own reset: in a race the car goes back to the last checkpoint it passed.
func handle_reset() -> bool:
	match state:
		State.COUNTDOWN:
			return true
		State.RACING:
			var xf := _track.checkpoint_transform(_next_cp - 1)
			_car.reset_to(xf)
			_camera.snap()
			_prev_pos = xf.origin
			return true
	return false


# --- Race flow -----------------------------------------------------------------------------------

func start_recording() -> void:
	_close_menu()
	_clear_race()
	_track = null
	_ghost_run = null
	var xf := _car.global_transform
	var fwd := -xf.basis.z
	fwd.y = 0.0
	if fwd.length_squared() > 1e-4:
		xf.basis = Basis.looking_at(fwd.normalized(), Vector3.UP)  # Start level, wheels down.
	_start = xf
	_begin_countdown()


func race_echo(track: EchoTrack, echo: EchoRun) -> void:
	_close_menu()
	_clear_race()
	_track = track
	_ghost_run = echo
	_start = track.start
	var space := _car.get_world_3d().direct_space_state
	var n := track.checkpoints.size()
	for i in n:
		var kind := CheckpointGate.Kind.CHECKPOINT
		if i == 0:
			kind = CheckpointGate.Kind.START
		elif i == n - 1:
			kind = CheckpointGate.Kind.FINISH
		var gate := CheckpointGate.new()
		_race_root.add_child(gate)
		gate.setup(track.style, kind, i, gate_radius)
		gate.global_transform = CheckpointGate.ground_xform(space, track.checkpoints[i], track.directions[i])
		_gates.append(gate)
	_ghost = GhostCar.new()
	_race_root.add_child(_ghost)
	_ghost.build_from(_car)
	_ghost.run = echo
	_begin_countdown()


func restart() -> void:
	if _track:
		race_echo(_track, _ghost_run)
	else:
		_close_menu()
		_begin_countdown()


func exit_race() -> void:
	_close_menu()
	_clear_race()
	_track = null
	_ghost_run = null
	_car.freeze = false
	state = State.FREE
	ui.show_race_hud(false)
	ui.hide_banner()
	_nearby = null


func end_recording() -> void:
	ui.close_menu()
	if not get_tree().paused:
		get_tree().paused = true
		_menu_paused = true
	state = State.EDITING
	ui.show_race_hud(false)
	ui.show_prompt("")
	_hud.visible = false
	_editor = EchoEditor.new()
	add_child(_editor)
	_editor.finished.connect(_on_editor_finished)
	_editor.setup(_run, _car, ui, _env, _camera, EchoTrack.Style.RINGS, gate_radius)


func save_new_echo() -> void:
	if _saved or not _won:
		return
	var rank := _track.add_run(_run)
	_track.save()
	_saved = true
	if _points.has(_track.id):
		(_points[_track.id] as EchoPoint).refresh()
	ui.toast("New echo saved: rank #%d of %d" % [rank, _track.runs.size()])
	_open_result_menu()


func _begin_countdown() -> void:
	_car.reset_to(_start)
	_car.refill_boost()
	_car.freeze = true
	_camera.snap()
	state = State.COUNTDOWN
	_countdown = countdown_time
	_last_count = 0
	_time = 0.0
	_tick = 0
	_next_cp = 1
	_splits = PackedFloat32Array([0.0])
	_result_timer = -1.0
	_run = null
	for i in _gates.size():
		_gates[i].set_state(CheckpointGate.State.NEXT if i <= 1 else CheckpointGate.State.UPCOMING)
	if _ghost:
		_ghost.show_at(0.0)
		_ghost.reset_physics_interpolation()
		_ghost.set_energy(1.0)
	ui.hide_banner()
	ui.show_prompt("")
	ui.show_race_hud(true)
	ui.set_timer(EchoRun.format_time(0.0))
	if _track:
		ui.set_info("%s   ·   vs %s   ·   %d checkpoints" % [_track.name, EchoRun.format_time(_ghost_run.time),
			_track.checkpoints.size() - 2])
	else:
		ui.set_info("● REC   ·   Y  end the race")


func _go() -> void:
	_car.freeze = false
	_car.sleeping = false
	ui.show_countdown(0)
	state = State.RACING if _track else State.RECORDING
	_tick = 0
	_time = 0.0
	_run = EchoRun.new()
	_run.date = Time.get_datetime_string_from_system(false, true).left(16)
	_run.add_sample(_car.global_transform)
	_prev_pos = _car.global_position
	if not _gates.is_empty():
		_gates[0].set_state(CheckpointGate.State.PASSED)
		_set_info_checkpoint()


func _update_ghost() -> void:
	if _ghost == null:
		return
	_ghost.show_at(_time)
	# Fade the hologram when it overlaps the player so it never hides the road.
	var d := _ghost.global_position.distance_to(_car.global_position)
	_ghost.set_energy(clampf((d - 1.5) / 8.0, 0.25, 1.0))


func _check_gates(delta: float) -> void:
	var pos := _car.global_position
	var ground := _gates[_next_cp].global_position
	var fwd := -_car.global_basis.z
	var u := -1.0
	if _track.style == EchoTrack.Style.RINGS:
		u = CheckpointGate.touch_fraction(ground, gate_radius, _prev_pos, pos, fwd)
	else:
		u = CheckpointGate.crossing(ground, _track.directions[_next_cp], gate_radius, _prev_pos, pos, fwd)
	if u < 0.0:
		return
	var t := _time - delta * (1.0 - u)
	_splits.append(t)
	var k := _next_cp
	if k < _ghost_run.splits.size():
		ui.flash_delta(t - _ghost_run.splits[k])
	_gates[k].set_state(CheckpointGate.State.PASSED)
	_next_cp += 1
	if _next_cp >= _track.checkpoints.size():
		_finish(t)
		return
	_gates[_next_cp].set_state(CheckpointGate.State.NEXT)
	_set_info_checkpoint()


func _set_info_checkpoint() -> void:
	var total := _track.checkpoints.size() - 1
	ui.set_info("%s   ·   %s %d / %d" % [_track.name, "FINISH" if _next_cp == total else "CHECKPOINT",
		_next_cp, total])


func _finish(t: float) -> void:
	state = State.FINISHED
	_finish_time = t
	_run.time = t
	_run.splits = _splits
	_run.add_sample(_car.global_transform)
	_won = t < _ghost_run.time
	_saved = false
	var d := t - _ghost_run.time
	ui.set_timer(EchoRun.format_time(t), EchoUi.GOOD if _won else EchoUi.BAD)
	if _won:
		ui.show_banner("ECHO BEATEN!", "%s   (%s)" % [EchoRun.format_time(t), EchoRun.format_delta(d)], EchoUi.GOOD)
	else:
		ui.show_banner("FINISH", "%s   (%s behind the echo)" % [EchoRun.format_time(t), EchoRun.format_delta(d)],
			EchoUi.ACCENT)
	_result_timer = result_menu_delay


func _clear_race() -> void:
	for c in _race_root.get_children():
		c.queue_free()
	_gates.clear()
	_ghost = null
	_minimap.echo_target_active = false


## Back from the editor to the car view (tree still paused): the result menu offers racing the new echo
## (or recording again if discarded) or leaving race mode.
func _on_editor_finished(track: EchoTrack) -> void:
	_editor = null
	_hud.visible = true
	state = State.FREE
	_car.freeze = false
	_camera.snap()
	_menu_paused = true
	_ghost_run = null
	_track = track
	_saved = track != null
	_won = false
	if track:
		track.name = _next_name()
		tracks.append(track)
		track.save()
		_add_point(track)
		_update_minimap_points()
		_run = track.runs[0]
		_finish_time = _run.time
	_open_result_menu()


func _next_name() -> String:
	var n := 0
	for t in tracks:
		if t.name.begins_with("Echo "):
			n = maxi(n, t.name.trim_prefix("Echo ").to_int())
	return "Echo %d" % (n + 1)


func _update_nearby() -> void:
	var pos := _car.global_position
	var best: EchoTrack = null
	var best_d := EchoPoint.RADIUS
	for t in tracks:
		var o := t.start.origin
		var d := Vector2(o.x - pos.x, o.z - pos.z).length()
		if d < best_d and absf(o.y - pos.y) < 8.0:
			best = t
			best_d = d
	if best != _nearby:
		_nearby = best
		ui.show_prompt("" if best == null else "Y / Tab   race %s   (best %s)" % [best.name,
			EchoRun.format_time(best.best_time())])


func _update_minimap_points() -> void:
	var pts := PackedVector3Array()
	for t in tracks:
		pts.append(t.start.origin)
	_minimap.echo_points = pts


# --- Menus ---------------------------------------------------------------------------------------

func open_context_menu() -> void:
	match state:
		State.FREE:
			if _nearby:
				_open_track_menu(_nearby)
			else:
				_open_menu("ECHO RACE", "Record a run from right here. Press Y again whenever you want to end it, " +
					"then place its checkpoints. %d echo point%s on the map." % [tracks.size(), "" if tracks.size() == 1 else "s"], [
					{"text": "Start a race here", "action": start_recording},
					{"text": "Close", "action": _close_menu},
				])
		State.COUNTDOWN, State.RECORDING, State.RACING, State.FINISHED:
			_open_race_menu()


func _open_race_menu() -> void:
	if _track == null:
		var long_enough := state == State.RECORDING and _run != null and _run.duration() >= min_run_seconds
		_open_menu("RECORDING", "%s recorded." % EchoRun.format_time(_time), [
			{"text": "End the race & place checkpoints", "action": end_recording, "enabled": long_enough},
			{"text": "Restart from the start", "action": restart},
			{"text": "Exit race mode", "action": exit_race},
			{"text": "Resume", "action": _close_menu},
		])
		return
	var items: Array[Dictionary] = []
	if state == State.FINISHED and _won and not _saved:
		items.append({"text": "Save as a new echo", "action": save_new_echo})
	items.append_array([
		{"text": "Restart from the start", "action": restart},
		{"text": "Exit race mode", "action": exit_race},
		{"text": "Resume", "action": _close_menu},
	])
	_open_menu(_track.name.to_upper(), "Racing the %s echo." % EchoRun.format_time(_ghost_run.time), items)


## End-of-race menu. Also shown after the editor (`_ghost_run` null): race the freshly saved echo, or record
## again after a discard, or leave race mode.
func _open_result_menu() -> void:
	if _ghost_run == null:
		if _track:
			_open_menu("%s SAVED" % _track.name.to_upper(), "%s · %.2f km · %d checkpoints. Its neon beacon now marks the start on the map." % [
				EchoRun.format_time(_finish_time), _track.length / 1000.0, _track.checkpoints.size() - 2], [
				{"text": "Race the new echo", "action": race_echo.bind(_track, _run)},
				{"text": "Exit race mode", "action": exit_race},
			], exit_race)
		else:
			_open_menu("RUN DISCARDED", "The recording was thrown away.", [
				{"text": "Record again from the same start", "action": restart},
				{"text": "Exit race mode", "action": exit_race},
			], exit_race)
		return
	var d := _finish_time - _ghost_run.time
	var items: Array[Dictionary] = []
	if _won and not _saved:
		items.append({"text": "Save as a new echo", "action": save_new_echo})
	if _saved:
		items.append({"text": "Race the new echo", "action": race_echo.bind(_track, _run)})
	items.append_array([
		{"text": "Race the same echo again", "action": restart},
		{"text": "Exit race mode", "action": exit_race},
	])
	_open_menu("FINISH  " + EchoRun.format_time(_finish_time), "%s the %s echo by %.3f s." % [
		"You beat" if _won else "You lost to", EchoRun.format_time(_ghost_run.time), absf(d)], items)


func _open_track_menu(t: EchoTrack) -> void:
	var items: Array[Dictionary] = []
	for i in t.runs.size():
		var r := t.runs[i]
		items.append({"text": "#%d   %s   ·  %s" % [i + 1, EchoRun.format_time(r.time), r.date], "action": race_echo.bind(t, r)})
	items.append_array([
		{"text": "Record a new race from here", "action": start_recording},
		{"text": "Delete this echo point", "action": _confirm_delete.bind(t)},
		{"text": "Close", "action": _close_menu},
	])
	_open_menu(t.name.to_upper(), "%.2f km · %d checkpoints · %s. Pick the echo to race:" % [t.length / 1000.0,
		t.checkpoints.size() - 2, t.style_name()], items)


func _confirm_delete(t: EchoTrack) -> void:
	_open_menu("DELETE %s?" % t.name.to_upper(), "Its %d echo%s will be lost." % [t.runs.size(),
		"" if t.runs.size() == 1 else "es"], [
		{"text": "Yes, delete it", "action": _delete_track.bind(t)},
		{"text": "No", "action": _open_track_menu.bind(t)},
	], _open_track_menu.bind(t), 1)


func _delete_track(t: EchoTrack) -> void:
	t.erase()
	tracks.erase(t)
	if _points.has(t.id):
		(_points[t.id] as EchoPoint).queue_free()
		_points.erase(t.id)
	_nearby = null
	ui.show_prompt("")
	_update_minimap_points()
	_close_menu()


func _open_menu(title: String, subtitle: String, items: Array[Dictionary], on_cancel := Callable(), selected := 0) -> void:
	if not get_tree().paused:
		get_tree().paused = true
		_menu_paused = true
	ui.open_menu(title, subtitle, items, on_cancel if on_cancel.is_valid() else _close_menu, selected)


func _close_menu() -> void:
	ui.close_menu()
	if _menu_paused:
		get_tree().paused = false
		_menu_paused = false
