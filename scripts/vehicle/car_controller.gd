class_name CarController
extends RigidBody3D
## Arcade car physics on a plain RigidBody3D.
## Each wheel casts a ray for spring/damper suspension, then applies tyre forces at the contact:
## drive/brake along the wheel and a clamped lateral grip force. Lower rear grip while handbraking
## (and briefly after) gives controllable drifts.

signal flipped

class Wheel:
	var mount: Vector3        ## Suspension top, in body space.
	var is_front: bool
	var is_left: bool
	var grounded := false
	var suspension_length := 0.0
	var compression := 0.0
	var load := 0.0           ## Suspension force (N).
	var contact_point := Vector3.ZERO
	var contact_normal := Vector3.UP
	var steer_angle := 0.0    ## Radians, positive = right.
	var forward_speed := 0.0  ## m/s along the wheel heading.
	var lateral_slip := 0.0   ## m/s sideways.
	var spin_angle := 0.0
	var surface := &"grass"

	func _init(mount_point: Vector3, front: bool, left: bool) -> void:
		mount = mount_point
		is_front = front
		is_left = left


@export_group("Layout")
@export var front_axle_z := -1.32
@export var rear_axle_z := 1.38
@export var track_half_width := 0.86
@export var mount_height := 0.0
@export var wheel_radius := 0.36

@export_group("Suspension")
@export var rest_length := 0.45
@export var spring_stiffness := 32000.0  ## N/m per wheel.
@export var spring_damping := 3000.0     ## N/(m/s) per wheel.
@export var anti_roll := 16000.0         ## N/m of left/right compression difference.

@export_group("Engine & Brakes")
@export var max_speed_kmh := 200.0
@export var engine_force := 10500.0      ## Total drive force at standstill (N).
@export var max_reverse_speed_kmh := 45.0
@export var reverse_force := 6000.0
@export_range(0.0, 1.0) var front_drive_ratio := 0.35
@export var brake_force := 16000.0
@export var coast_deceleration := 1.8    ## m/s^2 engine braking when off throttle.
@export var air_drag := 0.38
@export var downforce := 2.0             ## N per (m/s)^2.

@export_group("Steering")
@export var max_steer_angle := 32.0      ## Degrees at low speed.
@export var high_speed_steer_angle := 7.0
@export var steer_falloff_speed_kmh := 170.0
@export var steer_speed := 5.0           ## Input ramp, full lock per second.
@export var steer_return_speed := 8.0

@export_group("Grip")
@export var tire_stiffness := 9000.0     ## Lateral force per m/s of slip, per wheel.
@export var front_grip := 1.55           ## Friction coefficient.
@export var rear_grip := 1.5
@export var handbrake_grip := 0.45       ## Rear grip multiplier while the handbrake is held.
@export var handbrake_brake := 0.12      ## Fraction of brake force applied per rear wheel by the handbrake.
@export var drift_grip := 0.62           ## Rear grip multiplier while a drift is sustained.
@export var drift_recovery_speed := 1.4  ## Grip multiplier regained per second.
@export var drift_exit_angle := 7.0      ## Degrees of body slip under which a drift ends.
@export var drift_yaw_assist := 0.8      ## Extra yaw acceleration from steering while drifting (rad/s^2).
@export var drift_yaw_damping := 1.2     ## Resists spinning while drifting.
@export var max_drift_angle := 45.0      ## Degrees; beyond this the car is pushed back toward the travel direction.
@export var grass_grip := 0.78
@export var grass_drag := 1.3            ## Extra rolling resistance on grass (m/s^2).
@export var tire_force_height := 0.3     ## Raises tyre forces toward the CoM to limit body roll.

@export_group("Stability")
@export var gravity_multiplier := 1.5
@export var air_stabilization := 3.0

var wheels: Array[Wheel] = []
var input: VehicleInput
var speed := 0.0          ## Signed forward speed (m/s).
var steer_angle := 0.0    ## Current front wheel angle (rad).
var is_drifting := false
var is_braking := false
var grounded_wheels := 0

var _steer_input := 0.0
var _rear_grip_factor := 1.0
var _flip_timer := 0.0
var _ray := PhysicsRayQueryParameters3D.new()


func _ready() -> void:
	input = $Input as VehicleInput
	gravity_scale = gravity_multiplier
	for z in [front_axle_z, rear_axle_z]:
		for x in [-track_half_width, track_half_width]:
			wheels.append(Wheel.new(Vector3(x, mount_height, z), z == front_axle_z, x < 0.0))
	_ray.collision_mask = collision_mask
	_ray.exclude = [get_rid()]


func reset_to(xform: Transform3D) -> void:
	global_transform = xform
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	_steer_input = 0.0
	_rear_grip_factor = 1.0
	is_drifting = false
	reset_physics_interpolation()


func get_speed_kmh() -> float:
	return absf(speed) * 3.6


func _physics_process(delta: float) -> void:
	input.update_input()
	var xform := global_transform
	var up := xform.basis.y
	var forward := -xform.basis.z
	var vel := linear_velocity
	speed = vel.dot(forward)
	var abs_speed := absf(speed)

	_update_steering(delta, abs_speed)

	# Throttle/brake: pressing "brake" slows down, then reverses once nearly stopped.
	var drive := 0.0
	var braking := 0.0
	if speed > 1.0:
		drive = input.throttle
		braking = input.brake
	elif speed < -1.0:
		drive = -input.brake
		braking = input.throttle
	else:
		drive = input.throttle - input.brake
	is_braking = braking > 0.05

	var drive_force := 0.0
	if drive > 0.0:
		var ratio := maxf(speed, 0.0) / (max_speed_kmh / 3.6)
		drive_force = engine_force * drive * clampf(1.0 - ratio * ratio, 0.0, 1.0)
	elif drive < 0.0:
		var ratio := maxf(-speed, 0.0) / (max_reverse_speed_kmh / 3.6)
		drive_force = reverse_force * drive * clampf(1.0 - ratio, 0.0, 1.0)
	# Hold the car still when there is no input at all.
	if absf(drive) < 0.05 and braking < 0.05 and abs_speed < 1.0:
		braking = 1.0

	_update_drift_state(delta, vel, forward, abs_speed)

	_cast_suspension(xform, up)
	_apply_anti_roll()

	var com := xform * center_of_mass
	for w in wheels:
		if w.grounded:
			_apply_wheel_forces(w, xform, up, forward, com, drive_force, drive, braking)
		_update_wheel_spin(w, delta, drive)

	# Body forces
	if grounded_wheels > 0:
		apply_central_force(-up * downforce * vel.length_squared())
		if is_drifting:
			_apply_drift_assist(up, forward, vel)
	else:
		# Airborne: gently level the car so jumps land on the wheels.
		var axis := up.cross(Vector3.UP)
		apply_torque(axis * air_stabilization * mass)
	apply_central_force(-vel * vel.length() * air_drag)

	_check_flipped(delta, up, abs_speed)


func _update_steering(delta: float, abs_speed: float) -> void:
	var target := input.steer
	var rate := steer_speed
	if absf(target) < absf(_steer_input) or signf(target) != signf(_steer_input):
		rate = steer_return_speed
	_steer_input = move_toward(_steer_input, target, rate * delta)
	var speed_t := clampf(abs_speed * 3.6 / steer_falloff_speed_kmh, 0.0, 1.0)
	var max_angle := lerpf(max_steer_angle, high_speed_steer_angle, sqrt(speed_t))
	steer_angle = deg_to_rad(max_angle) * _steer_input


func _update_drift_state(delta: float, vel: Vector3, forward: Vector3, abs_speed: float) -> void:
	if input.handbrake and abs_speed > 4.0:
		is_drifting = true
	if is_drifting and not input.handbrake:
		var right := global_transform.basis.x
		var slip_angle := rad_to_deg(atan2(absf(vel.dot(right)), maxf(absf(vel.dot(forward)), 0.1)))
		if slip_angle < drift_exit_angle or abs_speed < 4.0:
			is_drifting = false
	var target := 1.0
	if input.handbrake:
		target = handbrake_grip
	elif is_drifting:
		target = drift_grip
	var rate := drift_recovery_speed if target > _rear_grip_factor else 6.0
	_rear_grip_factor = move_toward(_rear_grip_factor, target, rate * delta)


## Arcade drift help: steering adds yaw, while damping and an angle limiter keep the slide catchable.
func _apply_drift_assist(up: Vector3, forward: Vector3, vel: Vector3) -> void:
	var right := forward.cross(up)
	var slip_deg := rad_to_deg(atan2(vel.dot(right), maxf(absf(vel.dot(forward)), 1.0)))
	var yaw_rate := angular_velocity.dot(up)
	var yaw_accel := -_steer_input * drift_yaw_assist - yaw_rate * drift_yaw_damping
	var excess := absf(slip_deg) - max_drift_angle
	if excess > 0.0:
		yaw_accel -= signf(slip_deg) * excess * 0.2
	# Approximate yaw inertia of the body as mass * 1.75 m^2.
	apply_torque(up * yaw_accel * mass * 1.75)


func _cast_suspension(xform: Transform3D, up: Vector3) -> void:
	var space := get_world_3d().direct_space_state
	grounded_wheels = 0
	for w in wheels:
		var origin := xform * w.mount
		_ray.from = origin
		_ray.to = origin - up * (rest_length + wheel_radius)
		var hit := space.intersect_ray(_ray)
		if hit.is_empty():
			w.grounded = false
			w.suspension_length = rest_length
			w.compression = 0.0
			w.load = 0.0
			continue
		grounded_wheels += 1
		w.grounded = true
		w.contact_point = hit.position
		w.contact_normal = hit.normal
		w.suspension_length = clampf(origin.distance_to(hit.position) - wheel_radius, 0.0, rest_length)
		w.compression = rest_length - w.suspension_length
		var collider: Object = hit.collider
		w.surface = collider.get_meta(&"surface", &"grass") if collider else &"grass"

		var point_vel := linear_velocity + angular_velocity.cross(hit.position - xform * center_of_mass)
		var spring := w.compression * spring_stiffness
		var damper := -point_vel.dot(up) * spring_damping
		var bump_start := rest_length * 0.85
		if w.compression > bump_start:
			spring += (w.compression - bump_start) * spring_stiffness * 4.0
		w.load = maxf(spring + damper, 0.0)


func _apply_anti_roll() -> void:
	for axle in [0, 2]:
		var left := wheels[axle]
		var right := wheels[axle + 1]
		var force := (left.compression - right.compression) * anti_roll
		if left.grounded:
			left.load = maxf(left.load + force, 0.0)
		if right.grounded:
			right.load = maxf(right.load - force, 0.0)


func _apply_wheel_forces(w: Wheel, xform: Transform3D, up: Vector3, forward: Vector3, com: Vector3,
		drive_force: float, drive: float, braking: float) -> void:
	var offset := w.contact_point - xform.origin
	apply_force(up * w.load, offset)

	var n := w.contact_normal
	var wheel_fwd := forward
	if w.is_front:
		wheel_fwd = forward.rotated(up, -steer_angle)
	wheel_fwd = (wheel_fwd - n * wheel_fwd.dot(n)).normalized()
	var wheel_right := wheel_fwd.cross(n)
	var point_vel := linear_velocity + angular_velocity.cross(w.contact_point - com)
	var v_long := point_vel.dot(wheel_fwd)
	var v_lat := point_vel.dot(wheel_right)
	w.forward_speed = v_long
	w.lateral_slip = v_lat
	w.steer_angle = steer_angle if w.is_front else 0.0

	var on_grass := w.surface != &"road"
	var grip := front_grip if w.is_front else rear_grip * _rear_grip_factor
	if on_grass:
		grip *= grass_grip
	var max_force := w.load * grip
	var quarter_mass := mass * 0.25

	# Longitudinal
	var share := (front_drive_ratio if w.is_front else 1.0 - front_drive_ratio) * 0.5
	var f_long := drive_force * share
	var stop := clampf(v_long * 3.0, -1.0, 1.0)  # Smooth near zero to avoid jitter.
	if braking > 0.0:
		f_long -= stop * brake_force * 0.25 * braking
	if input.handbrake and not w.is_front:
		f_long -= stop * brake_force * handbrake_brake
	if absf(drive) < 0.05:
		f_long -= clampf(v_long, -1.0, 1.0) * coast_deceleration * quarter_mass
	if on_grass:
		f_long -= clampf(v_long, -1.0, 1.0) * grass_drag * quarter_mass
	f_long = clampf(f_long, -max_force, max_force)

	# Lateral, sharing the friction budget with longitudinal force (softened friction circle).
	var lat_limit := sqrt(maxf(max_force * max_force - 0.5 * f_long * f_long, 0.0))
	var f_lat := clampf(-v_lat * tire_stiffness, -lat_limit, lat_limit)

	var force_point := w.contact_point + up * tire_force_height - xform.origin
	apply_force(wheel_fwd * f_long + wheel_right * f_lat, force_point)


func _update_wheel_spin(w: Wheel, delta: float, drive: float) -> void:
	var spin_speed: float
	if not w.grounded:
		spin_speed = drive * 30.0
	elif input.handbrake and not w.is_front:
		spin_speed = 0.0
	else:
		spin_speed = w.forward_speed / wheel_radius
	w.spin_angle = wrapf(w.spin_angle + spin_speed * delta, 0.0, TAU)
	if not w.grounded:
		w.steer_angle = steer_angle if w.is_front else 0.0


func _check_flipped(delta: float, up: Vector3, abs_speed: float) -> void:
	if up.y < 0.3 and abs_speed < 3.0:
		_flip_timer += delta
		if _flip_timer > 2.5:
			_flip_timer = 0.0
			flipped.emit()
	else:
		_flip_timer = 0.0
