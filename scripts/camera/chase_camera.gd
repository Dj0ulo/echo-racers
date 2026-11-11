class_name ChaseCamera
extends Camera3D
## Third-person chase camera: trails the car's heading with smoothed yaw and height,
## pulls back, lowers and widens FOV with speed, lags on acceleration, adds a subtle
## noise-based high-speed shake, looks ahead, and avoids clipping into terrain.
## Exposes `speed_fx` (0..1, ramps in above `fx_start_speed_kmh`) for SpeedEffects.

@export var target_path: NodePath
@export var distance := 6.2
@export var height := 2.0
@export var look_height := 1.0
@export var extra_distance_at_speed := 1.6  ## Added distance at full speed.
@export var look_ahead := 5.0               ## Metres ahead of the car at full speed.
@export var full_effect_speed_kmh := 180.0
@export var rotation_smoothing := 4.5       ## Higher = camera swings behind the car faster.
@export var height_smoothing := 6.0
@export var velocity_alignment := 0.3       ## How much the camera follows the travel direction vs. the car heading.
@export var collision_margin := 0.35
@export_flags_3d_physics var collision_mask := 1

@export_group("Speed Feel")
@export var fx_start_speed_kmh := 80.0      ## High-speed effects ramp in from here...
@export var fx_full_speed_kmh := 190.0      ## ...to full strength here.
@export var base_fov := 68.0
@export var mid_fov := 72.0                 ## FOV reached at `fx_start_speed_kmh`.
@export var max_fov := 86.0
@export var fov_smoothing := 3.0
@export var fov_kick := 4.0                 ## Extra degrees on a sudden hard acceleration.
@export var height_drop_at_speed := 0.45    ## Camera lowers by this much at full speed.
@export var accel_lag := 0.07               ## Metres of pull-back per m/s^2 of forward acceleration.
@export var max_accel_lag := 0.9
@export var shake_strength := 0.35          ## Degrees of rotational shake at full speed.
@export var shake_offset := 0.035           ## Metres of positional shake at full speed.
@export var shake_frequency := 9.0

## 0..1 high-speed intensity (smoothstep between fx_start and fx_full), read by SpeedEffects.
var speed_fx := 0.0
## Smoothed forward acceleration (m/s^2).
var forward_accel := 0.0

var _target: RigidBody3D
var _focus := Vector3.ZERO
var _yaw_dir := Vector3.FORWARD
var _ray := PhysicsRayQueryParameters3D.new()
var _prev_speed := 0.0
var _accel_fast := 0.0
var _accel_slow := 0.0
var _kick := 0.0
var _smooth_fov := 68.0
var _lag := 0.0
var _time := 0.0
var _noise := FastNoiseLite.new()


func _ready() -> void:
	top_level = true
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_target = get_node(target_path) as RigidBody3D
	_ray.collision_mask = collision_mask
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = 1.0
	_noise.fractal_octaves = 2
	fov = base_fov
	snap()


func get_target() -> RigidBody3D:
	return _target


## Instantly places the camera behind the target (after spawning or resetting).
func snap() -> void:
	if _target == null:
		return
	var t := _target.global_transform
	_focus = t.origin
	_yaw_dir = _flat_forward(t.basis, _yaw_dir)
	_prev_speed = _forward_speed()
	_accel_fast = 0.0
	_accel_slow = 0.0
	forward_accel = 0.0
	_kick = 0.0
	_lag = 0.0
	speed_fx = 0.0
	_smooth_fov = base_fov
	fov = base_fov
	_place(0.0)


# Acceleration is derived at the physics rate (velocity only changes on physics ticks).
func _physics_process(delta: float) -> void:
	if _target == null:
		return
	var s := _forward_speed()
	var accel := clampf((s - _prev_speed) / delta, -40.0, 40.0)
	_prev_speed = s
	_accel_fast = lerpf(_accel_fast, accel, 1.0 - exp(-8.0 * delta))
	_accel_slow = lerpf(_accel_slow, accel, 1.0 - exp(-1.2 * delta))
	forward_accel = _accel_fast


func _process(delta: float) -> void:
	if _target == null:
		return
	_time += delta
	var t := _target.get_global_transform_interpolated()
	var vel := _target.linear_velocity
	var speed_kmh := vel.length() * 3.6
	var speed_t := clampf(speed_kmh / full_effect_speed_kmh, 0.0, 1.0)
	speed_fx = smoothstep(fx_start_speed_kmh, fx_full_speed_kmh, speed_kmh)

	# Follow horizontally exactly, smooth vertically so bumps don't shake the view.
	var ky := 1.0 - exp(-height_smoothing * delta)
	_focus = Vector3(t.origin.x, lerpf(_focus.y, t.origin.y, ky), t.origin.z)

	var heading := _flat_forward(t.basis, _yaw_dir)
	var flat_vel := Vector3(vel.x, 0.0, vel.z)
	var desired_dir := heading
	if flat_vel.length() > 4.0 and flat_vel.normalized().dot(heading) > 0.2:
		desired_dir = heading.lerp(flat_vel.normalized(), velocity_alignment).normalized()
	var kr := 1.0 - exp(-rotation_smoothing * delta)
	_yaw_dir = _yaw_dir.slerp(desired_dir, kr)
	_yaw_dir.y = 0.0
	_yaw_dir = _yaw_dir.normalized()

	# FOV: gentle widening up to fx_start, then a stronger ramp; plus a short kick on the
	# onset of hard acceleration (high-pass of the acceleration signal).
	var slow_t := clampf(speed_kmh / fx_start_speed_kmh, 0.0, 1.0)
	var target_fov := lerpf(base_fov, mid_fov, slow_t) + (max_fov - mid_fov) * speed_fx
	var onset := clampf((maxf(_accel_fast, 0.0) - maxf(_accel_slow, 0.0) - 1.0) / 5.0, 0.0, 1.0)
	var kick_target := onset * fov_kick * clampf(speed_kmh / 40.0, 0.0, 1.0)
	var kk := 1.0 - exp(-(10.0 if kick_target > _kick else 2.5) * delta)
	_kick = lerpf(_kick, kick_target, kk)
	_smooth_fov = lerpf(_smooth_fov, target_fov, 1.0 - exp(-fov_smoothing * delta))
	fov = _smooth_fov + _kick

	# Camera lags behind under acceleration and creeps in under braking.
	var lag_target := clampf(forward_accel * accel_lag, -max_accel_lag * 0.6, max_accel_lag)
	_lag = lerpf(_lag, lag_target, 1.0 - exp(-3.0 * delta))
	_place(speed_t)
	_apply_shake()


func _place(speed_t: float) -> void:
	var drop := height_drop_at_speed * speed_fx
	var pivot := _focus + Vector3.UP * (look_height - drop * 0.3)
	var back := distance + extra_distance_at_speed * speed_t + _lag
	var desired := _focus - _yaw_dir * back + Vector3.UP * (height - drop)
	_ray.from = pivot
	_ray.to = desired
	_ray.exclude = [_target.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(_ray)
	if not hit.is_empty():
		desired = hit.position + (pivot - desired).normalized() * collision_margin + Vector3.UP * collision_margin
	global_position = desired
	var look_target := pivot + _yaw_dir * look_ahead * speed_t
	if not global_position.is_equal_approx(look_target):
		look_at(look_target, Vector3.UP)


## Smooth, low-amplitude noise shake that only appears at high speed.
func _apply_shake() -> void:
	var amount := speed_fx * speed_fx
	if amount <= 0.001:
		return
	var tt := _time * shake_frequency
	var pitch := _noise.get_noise_2d(tt, 0.0)
	var yaw := _noise.get_noise_2d(tt, 37.0)
	var roll := _noise.get_noise_2d(tt * 0.6, 91.0)
	var deg := deg_to_rad(shake_strength) * amount
	rotate_object_local(Vector3.RIGHT, pitch * deg)
	rotate_object_local(Vector3.UP, yaw * deg * 0.6)
	rotate_object_local(Vector3.FORWARD, roll * deg * 0.5)
	global_position += global_basis * Vector3(yaw, pitch, 0.0) * shake_offset * amount


func _forward_speed() -> float:
	return _target.linear_velocity.dot(-_target.global_basis.z)


static func _flat_forward(basis: Basis, fallback: Vector3) -> Vector3:
	var f := -basis.z
	f.y = 0.0
	if f.length_squared() < 0.01:
		return fallback
	return f.normalized()
