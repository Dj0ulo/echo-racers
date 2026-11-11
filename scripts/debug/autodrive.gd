extends Node
## Debug helper, enabled with `godot -- --autodrive [--shots=/abs/dir]`.
## A simple pure-pursuit autopilot drives along the road (with a handbrake drift and a
## brake/reverse test), prints handling telemetry, optionally saves screenshots, then quits.

const DURATION := 40.0
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
	if _time > 22.0 and _time < 22.6:  # Handbrake flick into a drift, then the autopilot counter-steers
		handbrake = true
		steer = 0.8
		throttle = 0.6
	elif _time > 22.6 and _time < 25.0:
		throttle = 0.8
	if _time > 34.0:  # Brake to a stop, then reverse
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

	if _time >= _next_log:
		_next_log += 1.0
		var right := _car.global_basis.x
		var slip := rad_to_deg(atan2(_car.linear_velocity.dot(right), maxf(absf(speed), 0.5)))
		print("t=%4.1f v=%6.1f km/h off=%5.1f m slip=%6.1f deg yaw=%5.2f up.y=%.2f wheels=%d drift=%s steer=%5.2f" % [
			_time, speed * 3.6, off_road, slip, _car.angular_velocity.y, _car.global_basis.y.y,
			_car.grounded_wheels, _car.is_drifting, steer])
	if _time > DURATION:
		print("Rendering: average %.0f FPS, worst frame %.0f FPS" % [_frames / maxf(_time - 2.0, 0.001), _min_fps])
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
