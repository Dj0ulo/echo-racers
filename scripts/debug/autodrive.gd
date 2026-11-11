extends Node
## Debug helper, enabled with `godot -- --autodrive [--shots=/abs/dir]`.
## A simple pure-pursuit autopilot drives along the road (with handbrake drift scenarios and a
## brake/reverse test), prints handling telemetry, optionally saves screenshots, then quits.
##
## Drift scenarios (each logged at 10 Hz and summarised):
##  - "flick":    handbrake flick into a corner, then the autopilot counter-steers on throttle.
##  - "sustain":  handbrake flick, then full throttle with a player-like counter-steer that aims to
##                 hold ~25 deg of slip for 2 s: throttle must be able to keep the drift alive.
##  - "spin test": long handbrake pull at speed with full lock held INTO the slide and full throttle
##                 (no counter-steer) — the car must not spin out.

const DURATION := 44.0
const BRAKE_TEST_TIME := 38.0
const SHOT_TIMES := [12.0, 22.5, 23.0, 30.0]

var _car: CarController
var _world: WorldGenerator
var _time := 0.0
var _next_log := 0.0
var _shots_dir := ""
var _shot_index := 0
var _max_speed := 0.0
var _max_off_road := 0.0
var _max_yaw_rate := 0.0
var _drift_time := 0.0
var _frames := 0
var _min_fps := INF

## Scripted drift events: name, start time, handbrake duration, steer while handbraking,
## how long to keep that steer after release (no counter-steer), throttle, optional sustain phase.
const DRIFT_EVENTS := [
	{"name": "flick", "t": 22.0, "hb": 0.6, "steer": 0.8, "hold": 0.0, "throttle": 0.6, "after_throttle": 0.8},
	{"name": "spin test", "t": 27.0, "hb": 0.9, "steer": 1.0, "hold": 1.0, "throttle": 1.0, "after_throttle": 1.0},
	# Starts from a fresh spot on the road (reset 1.5 s before) so it doesn't depend on the spin test.
	{"name": "sustain", "t": 33.0, "hb": 0.5, "steer": 0.8, "hold": 0.0, "throttle": 1.0, "after_throttle": 1.0,
		"sustain": 2.0, "reset_kmh": 80.0, "follow_bend": true},
]
const EVENT_TRACK := 3.5  ## Seconds tracked after the handbrake is released.
var _ev: Dictionary = {}  ## Stats of the event in progress.
var _ev_index := -1
var _ev_log_next := 0.0
var _ev_dir := 1.0  ## Flick direction for "follow_bend" events (sign of the autopilot steer at the start).
var _summaries: PackedStringArray = []
var _resets_done := {}


func _ready() -> void:
	_car = get_parent().get_node("Car")
	_world = get_parent().get_node("World")
	_car.input.player_controlled = false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shots="):
			_shots_dir = arg.trim_prefix("--shots=")


func _physics_process(delta: float) -> void:
	_time += delta
	var road := _world.road
	var pos := _car.global_position
	var idx := road.nearest_index(pos)
	var speed := _car.speed
	var lookahead := clampi(int(6 + absf(speed) * 0.5), 6, 40)
	var target := road.points[(idx + lookahead) % road.sample_count()]
	var local := _car.global_transform.affine_inverse() * target
	var steer := clampf(atan2(local.x, -local.z) * 2.5, -1.0, 1.0)

	# Target speed from upcoming curvature.
	var t0 := road.tangents[idx]
	var t1 := road.tangents[(idx + 30) % road.sample_count()]
	var bend := t0.angle_to(t1)
	var target_speed := lerpf(170.0, 70.0, clampf(bend / 1.2, 0.0, 1.0)) / 3.6

	var throttle := 1.0 if speed < target_speed else 0.0
	var brake := 0.0 if speed < target_speed + 3.0 else 1.0
	var handbrake := false
	for i in DRIFT_EVENTS.size():
		var e: Dictionary = DRIFT_EVENTS[i]
		var rel: float = _time - e.t
		if e.has("reset_kmh") and rel > -1.5 and not _resets_done.has(i):
			_resets_done[i] = true
			get_parent().reset_car()
			_car.linear_velocity = -_car.global_basis.z * e.reset_kmh / 3.6
		if rel < 0.0 or rel > e.hb + EVENT_TRACK:
			continue
		if i != _ev_index:
			_ev_dir = signf(steer) if steer != 0.0 else 1.0
			_begin_event(i)
		var flick_steer: float = e.steer * (_ev_dir if e.get("follow_bend", false) else 1.0)
		if rel < e.hb:
			handbrake = true
			steer = flick_steer
			throttle = e.throttle
		elif rel < e.hb + e.hold:
			steer = flick_steer  # Keep steering into the slide: the assists alone must prevent a spin.
			throttle = e.throttle
		elif rel < e.hb + e.get("sustain", 0.0):
			# Counter-steer proportionally to hold ~25 deg of slip, flat out.
			var slip := _slip_deg()
			steer = clampf(signf(slip) * (0.25 + (absf(slip) - 25.0) / 25.0), -1.0, 1.0)
			throttle = 1.0
		elif rel < e.hb + 2.4:
			throttle = e.after_throttle  # Autopilot steering = natural counter-steer.
		brake = 0.0
	if _time > BRAKE_TEST_TIME:  # Brake to a stop, then reverse
		throttle = 0.0
		brake = 1.0
		steer = 0.0
	_car.input.throttle = throttle
	_car.input.brake = brake
	_car.input.steer = steer
	_car.input.handbrake = handbrake

	var off_road := Vector2(road.points[idx].x - pos.x, road.points[idx].z - pos.z).length()
	_max_off_road = maxf(_max_off_road, off_road)
	_max_speed = maxf(_max_speed, _car.get_speed_kmh())
	_max_yaw_rate = maxf(_max_yaw_rate, absf(_car.angular_velocity.y))
	if _car.is_drifting:
		_drift_time += delta
	_track_event(delta, steer, handbrake)

	if _time >= _next_log:
		_next_log += 1.0
		var right := _car.global_basis.x
		var slip := rad_to_deg(atan2(_car.linear_velocity.dot(right), maxf(absf(speed), 0.5)))
		print("t=%4.1f v=%6.1f km/h off=%5.1f m slip=%6.1f deg yaw=%5.2f up.y=%.2f wheels=%d drift=%s steer=%5.2f" % [
			_time, speed * 3.6, off_road, slip, _car.angular_velocity.y, _car.global_basis.y.y,
			_car.grounded_wheels, _car.is_drifting, steer])
	if _time > DURATION:
		print("Rendering: average %.0f FPS, worst frame %.0f FPS" % [_frames / maxf(_time - 2.0, 0.001), _min_fps])
		_end_event()
		for line in _summaries:
			print(line)
		print("Autodrive done: max speed %.1f km/h, max distance from centreline %.1f m, max yaw rate %.2f rad/s, drift time %.1f s" % [
			_max_speed, _max_off_road, _max_yaw_rate, _drift_time])
		get_tree().quit()


func _process(delta: float) -> void:
	if _time > 2.0:
		_frames += 1
		_min_fps = minf(_min_fps, 1.0 / maxf(delta, 1e-6))
	if _shots_dir.is_empty() or _shot_index >= SHOT_TIMES.size() or _time < SHOT_TIMES[_shot_index]:
		return
	var image := get_viewport().get_texture().get_image()
	if image:
		var path := "%s/shot_%d.png" % [_shots_dir, _shot_index]
		image.save_png(path)
		print("Saved ", path)
	_shot_index += 1


func _slip_deg() -> float:
	var v := _car.linear_velocity
	var fwd := -_car.global_basis.z
	return rad_to_deg(atan2(v.dot(_car.global_basis.x), maxf(absf(v.dot(fwd)), 0.5)))


func _begin_event(i: int) -> void:
	_end_event()
	_ev_index = i
	_ev = {"name": DRIFT_EVENTS[i].name, "t0": _time, "v0": _car.get_speed_kmh(), "peak_slip": 0.0,
		"peak_yaw": 0.0, "release": -1.0, "recovered": -1.0, "overshoot": 0.0, "slip_sign": 0.0,
		"drift_time": 0.0, "spun": false, "v_min": INF}
	_ev_log_next = _time
	print("--- drift event '%s' at %.1f km/h ---" % [_ev.name, _ev.v0])


func _track_event(delta: float, steer: float, handbrake: bool) -> void:
	if _ev.is_empty():
		return
	var e: Dictionary = DRIFT_EVENTS[_ev_index]
	var rel: float = _time - e.t
	if rel > e.hb + EVENT_TRACK:
		_end_event()
		return
	var slip := _slip_deg()
	var yaw := _car.angular_velocity.y
	if absf(slip) > absf(_ev.peak_slip):
		_ev.peak_slip = slip
		_ev.slip_sign = signf(slip)
	_ev.peak_yaw = maxf(_ev.peak_yaw, absf(yaw))
	_ev.v_min = minf(_ev.v_min, _car.get_speed_kmh())
	if absf(slip) > 100.0 or _car.speed < -1.0:
		_ev.spun = true
	if _car.is_drifting:
		_ev.drift_time += delta
	if not handbrake and _ev.release < 0.0 and rel > 0.1:
		_ev.release = rel
	if _ev.release >= 0.0 and _ev.recovered < 0.0 and absf(slip) < 5.0 and not _car.is_drifting:
		_ev.recovered = rel
	if _ev.recovered >= 0.0 and signf(slip) == -_ev.slip_sign:
		_ev.overshoot = maxf(_ev.overshoot, absf(slip))  # Snap-back to the other side.
	if _time >= _ev_log_next:
		_ev_log_next += 0.1
		print("  +%.1fs v=%6.1f slip=%6.1f yaw=%5.2f grip=%.2f drift=%s hb=%s steer=%5.2f thr=%.1f" % [
			rel, _car.speed * 3.6, slip, yaw, _car.rear_grip_factor, _car.is_drifting, handbrake, steer,
			_car.input.throttle])


func _end_event() -> void:
	if _ev.is_empty():
		return
	_summaries.append(("Drift '%s' @%.0f km/h: peak slip %.1f deg, peak yaw %.2f rad/s, drift %.1f s, " +
		"recovered (|slip|<5) %s after release, snap-back %.1f deg, min speed %.0f km/h, spun=%s") % [
		_ev.name, _ev.v0, _ev.peak_slip, _ev.peak_yaw, _ev.drift_time,
		("%.2f s" % (_ev.recovered - _ev.release)) if _ev.recovered >= 0.0 else "never",
		_ev.overshoot, _ev.v_min, _ev.spun])
	_ev = {}
