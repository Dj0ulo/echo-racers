extends Node
## Debug: `godot -- --autodrive --echotest [--quiet] [--shots=/abs/dir]` runs the echo mode end to end while
## the autodrive drives: records a 14 s run, opens the top-view editor and places checkpoints on the run's
## extremes (shot `echo_editor.png`, then `echo_editor_gates.png` zoomed in with light gates), saves it,
## races the echo as a ghost by following its line 6 % faster (the autodrive's scripted drift tests are switched
## off for that leg; shot `echo_race.png`), prints every split and the result, saves the new echo if
## it won, then deletes the scratch course (stored in user://echoes_test, never the player's echoes).

const RECORD_SECONDS := 14.0

var _echo: EchoManager
var _phase := 0
var _wait := 1.0
var _shots := ""
var _seen_cp := 1
var _follow: EchoRun  ## Line driven during the race leg.
var _follow_i := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_echo = (get_parent() as Node).get(&"echo")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shots="):
			_shots = arg.trim_prefix("--shots=")


func _process(delta: float) -> void:
	_wait -= delta
	if _wait > 0.0:
		return
	match _phase:
		0:  # Through the real input path: Tab opens the menu, Enter picks "Start a race here".
			print("Echo test: start recording at ", _echo._car.global_position.round())
			_press(&"echo_menu")
			_next(0.2)
		1:
			print("Echo test: menu open = %s" % _echo.ui.is_menu_open())
			_press(&"ui_accept")
			_next(0.2)
		2:
			if _echo.state == EchoManager.State.RECORDING and _echo._time >= RECORD_SECONDS:
				print("Echo test: recorded %d samples, %.2f s" % [_echo._run.sample_count(), _echo._run.duration()])
				_press(&"echo_menu")
				_next(0.2)
		3:  # "End the race & place checkpoints".
			_press(&"ui_accept")
			_next(0.6)
		4:
			_echo._editor.auto_checkpoints()
			print("Echo test: auto checkpoints at samples ", _echo._editor.checkpoints)
			_next(1.0)
		5:
			_shot("echo_editor.png")
			var ed := _echo._editor
			ed.toggle_style()
			ed._cursor = ed.checkpoints[0] if not ed.checkpoints.is_empty() else ed._end * 0.5
			ed._zoom = 0.8
			_next(1.5)
		6:
			_shot("echo_editor_gates.png")
			_echo._editor.toggle_style()
			_echo._editor.save()
			_next(0.5)
		7:
			var t: EchoTrack = _echo.tracks.back()
			print("Echo test: saved '%s', %d checkpoints, %.0f m, echo %s" % [t.name, t.checkpoints.size(), t.length,
				EchoRun.format_time(t.best_time())])
			_echo.race_echo(t, t.runs[0])
			var autodrive := get_parent().get_node_or_null(^"Autodrive")
			if autodrive:
				autodrive.set_physics_process(false)
			_follow = t.runs[0]
			_follow_i = 0
			_next(0.1)
		8:
			if _echo._next_cp != _seen_cp and _echo._splits.size() > _seen_cp:
				var k := _seen_cp
				print("Echo test: checkpoint %d at %s (echo %s)" % [k, EchoRun.format_time(_echo._splits[k]),
					EchoRun.format_time(_echo._ghost_run.splits[k])])
				_seen_cp = _echo._next_cp
			if _echo.state == EchoManager.State.RACING and _echo._time >= 7.0 and not _shots.is_empty() \
					and not FileAccess.file_exists(_shots + "/echo_race.png"):
				_shot("echo_race.png")
			if _echo.state == EchoManager.State.FINISHED:
				print("Echo test: finished %s vs %s, won=%s" % [EchoRun.format_time(_echo._finish_time),
					EchoRun.format_time(_echo._ghost_run.time), _echo._won])
				_next(2.5)
			elif _echo._time > RECORD_SECONDS * 2.5:
				print("Echo test: FAILED, no finish after %.0f s (next checkpoint %d)" % [_echo._time, _echo._next_cp])
				_phase = 10
		9:
			if _echo._won:
				_echo.save_new_echo()
			var t: EchoTrack = _echo.tracks.back()
			var times: Array[String] = []
			for r in t.runs:
				times.append(EchoRun.format_time(r.time))
			print("Echo test: %d echoes, best first: %s" % [t.runs.size(), ", ".join(times)])
			var reloaded := EchoTrack.load_all()
			print("Echo test: reload ok = %s" % [reloaded.size() == 1 and reloaded[0].runs.size() == t.runs.size()])
			_next(0.5)
		10:
			for t in EchoTrack.load_all():
				t.erase()
			print("Echo test done")
			get_tree().quit()


## Pure pursuit along the echo's recorded line, 6 % faster than the echo was at that point.
func _physics_process(_delta: float) -> void:
	if _follow == null or get_tree().paused:
		return
	var car := _echo._car
	var pos := car.global_position
	var n := _follow.sample_count()
	var best := INF
	for i in range(_follow_i, mini(_follow_i + 60, n)):
		var d := pos.distance_squared_to(_follow.positions[i])
		if d < best:
			best = d
			_follow_i = i
	var ahead := mini(_follow_i + 6 + int(absf(car.speed) * 0.25), n - 1)
	var local := car.global_transform.affine_inverse() * _follow.positions[ahead]
	var j := mini(_follow_i + 15, n - 2)
	var target_speed := _follow.positions[j].distance_to(_follow.positions[j + 1]) * EchoRun.RATE * 1.06 + 1.0
	car.input.steer = clampf(atan2(local.x, -local.z) * 2.5, -1.0, 1.0)
	car.input.throttle = 1.0 if car.speed < target_speed else 0.0
	car.input.brake = 1.0 if car.speed > target_speed + 3.0 else 0.0
	car.input.handbrake = false
	car.input.boost = false


func _press(action: StringName) -> void:
	for pressed in [true, false]:
		var ev := InputEventAction.new()
		ev.action = action
		ev.pressed = pressed
		Input.parse_input_event(ev)


func _next(wait: float) -> void:
	_phase += 1
	_wait = wait


func _shot(file: String) -> void:
	if _shots.is_empty():
		return
	var image := get_viewport().get_texture().get_image()
	if image == null:
		return
	if image.get_width() > 960:
		image.resize(960, roundi(image.get_height() * 960.0 / image.get_width()), Image.INTERPOLATE_LANCZOS)
	image.save_png(_shots + "/" + file)
	print("Saved ", _shots, "/", file)
