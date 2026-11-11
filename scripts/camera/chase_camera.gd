class_name ChaseCamera
extends Camera3D
## Third-person chase camera: trails the car's heading with smoothed yaw and height,
## pulls back and widens FOV with speed, looks ahead, and avoids clipping into terrain.

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
@export var base_fov := 68.0
@export var max_fov := 80.0
@export var collision_margin := 0.35
@export_flags_3d_physics var collision_mask := 1

var _target: RigidBody3D
var _focus := Vector3.ZERO
var _yaw_dir := Vector3.FORWARD
var _ray := PhysicsRayQueryParameters3D.new()


func _ready() -> void:
	top_level = true
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_target = get_node(target_path) as RigidBody3D
	_ray.collision_mask = collision_mask
	fov = base_fov
	snap()


## Instantly places the camera behind the target (after spawning or resetting).
func snap() -> void:
	if _target == null:
		return
	var t := _target.global_transform
	_focus = t.origin
	_yaw_dir = _flat_forward(t.basis, _yaw_dir)
	_place(0.0)


func _process(delta: float) -> void:
	if _target == null:
		return
	var t := _target.get_global_transform_interpolated()
	var vel := _target.linear_velocity
	var speed_t := clampf(vel.length() / (full_effect_speed_kmh / 3.6), 0.0, 1.0)

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

	fov = lerpf(fov, lerpf(base_fov, max_fov, speed_t), 1.0 - exp(-3.0 * delta))
	_place(speed_t)


func _place(speed_t: float) -> void:
	var pivot := _focus + Vector3.UP * look_height
	var desired := _focus - _yaw_dir * (distance + extra_distance_at_speed * speed_t) + Vector3.UP * height
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


static func _flat_forward(basis: Basis, fallback: Vector3) -> Vector3:
	var f := -basis.z
	f.y = 0.0
	if f.length_squared() < 0.01:
		return fallback
	return f.normalized()
