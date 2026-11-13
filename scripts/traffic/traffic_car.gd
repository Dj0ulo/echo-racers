class_name TrafficCar
extends AnimatableBody3D
## One AI traffic car. Moved kinematically along its lane by TrafficManager while DRIVING.
## Collisions with the player (and between traffic cars) are not solved by the physics engine: the
## manager detects box overlaps and exchanges momentum itself (see TrafficManager._resolve_contact), so
## each car has a mass and is knocked about by a crash:
##  - CRASHED: the car leaves its lane and slides freely (own velocity + yaw rate, tyre friction and the
##    driver braking), stops, then waits a few seconds;
##  - RECOVERING: it is back on its lane's path, with the pose offset it had when it stopped fading out
##    while it pulls away slowly, then DRIVING again.
## Collision layer 3 ("traffic", value 4) only, mask 0: the physics engine never pushes anything with
## these bodies, and the player's suspension rays and the chase camera (layer 1) ignore them.

enum State { DRIVING, CRASHED, RECOVERING }

const TRAFFIC_LAYER := 4
const VEHICLE_MASK := 0

## Kerb mass (kg) per TrafficCarMesh.Kind.
const MASSES := {
	TrafficCarMesh.Kind.SEDAN: 1400.0,
	TrafficCarMesh.Kind.HATCH: 1100.0,
	TrafficCarMesh.Kind.VAN: 2200.0,
	TrafficCarMesh.Kind.PICKUP: 2000.0,
	TrafficCarMesh.Kind.TRUCK: 6000.0,
}

const SLIDE_DECEL := 7.5        ## m/s^2, sideways tyre scrub while sliding.
const BRAKE_DECEL := 5.5        ## m/s^2, the driver stands on the brakes after a crash.
const YAW_DECEL := 2.5          ## rad/s^2, tyre friction against the spin.
const YAW_DAMP := 1.2           ## 1/s, extra exponential yaw-rate decay.
const STOPPED_SPEED := 0.4
const MAX_KICK_YAW := 3.5       ## rad/s, cap on the spin an impact can give.
const RECOVER_SPEED := 10.0     ## m/s cap while drifting back into the lane.

var kind := 0
var length := 4.5
var width := 1.8
var height := 1.45
var mass := 1400.0
var yaw_inertia := 2600.0       ## kg m^2 (solid box approximation).
var s := 0.0          ## Distance along the road centreline.
var speed := 0.0      ## m/s, always >= 0 (cars only drive forwards along their lane).
var cruise := 20.0    ## Preferred speed on a straight, m/s.
var accel := 0.0

var state := State.DRIVING
var crash_vel := Vector3.ZERO   ## Horizontal world velocity while CRASHED.
var crash_yaw_rate := 0.0       ## rad/s around +Y while CRASHED.
var heading := 0.0              ## Yaw (forward = -Z rotated by heading) while CRASHED.
var hold_time := 0.0            ## Seconds to stay stopped before recovering.
var recover_offset := Vector3.ZERO  ## World offset from the lane pose, fading out while RECOVERING.
var recover_yaw := 0.0              ## Heading offset from the lane pose, fading out while RECOVERING.

var _tail_material: StandardMaterial3D
var _braking := false


func setup(car_kind: int, paint: Color) -> void:
	kind = car_kind
	length = TrafficCarMesh.length_of(kind)
	width = TrafficCarMesh.width_of(kind)
	height = TrafficCarMesh.height_of(kind)
	mass = MASSES[kind]
	yaw_inertia = mass * (length * length + width * width) / 12.0
	collision_layer = TRAFFIC_LAYER
	collision_mask = VEHICLE_MASK
	sync_to_physics = false  # The script owns the pose (crash physics reads it back every tick).
	var meshes := TrafficCarMesh.build(kind, paint)
	var body := MeshInstance3D.new()
	body.name = "Body"
	body.mesh = meshes[0]
	body.visibility_range_end = 1100.0
	add_child(body)
	_tail_material = TrafficCarMesh.tail_material()
	var tail := MeshInstance3D.new()
	tail.name = "TailLights"
	tail.mesh = meshes[1]
	tail.material_override = _tail_material
	tail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	tail.visibility_range_end = 600.0
	add_child(tail)
	var lenses := MeshInstance3D.new()
	lenses.name = "HeadLights"
	lenses.mesh = meshes[2]
	lenses.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	lenses.visibility_range_end = 900.0
	add_child(lenses)
	var pool := MeshInstance3D.new()
	pool.name = "HeadlightPool"
	pool.mesh = TrafficCarMesh.pool_mesh(kind)
	pool.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pool.visibility_range_end = 300.0
	pool.visible = TrafficCarMesh.headlights > 0.01
	pool.add_to_group(TrafficCarMesh.HEADLIGHT_GROUP)
	add_child(pool)

	var box := BoxShape3D.new()
	box.size = Vector3(width, height - 0.25, length)
	var shape := CollisionShape3D.new()
	shape.shape = box
	shape.position = Vector3(0.0, 0.25 + (height - 0.25) * 0.5, 0.0)
	add_child(shape)


func set_braking(braking: bool) -> void:
	if braking != _braking:
		_braking = braking
		_tail_material.emission_energy_multiplier = 4.0 if braking else 0.6


## Current horizontal velocity of the car's centre (world space).
func get_velocity() -> Vector3:
	if state == State.CRASHED:
		return crash_vel
	return -global_basis.z * speed


func get_yaw_rate() -> float:
	return crash_yaw_rate if state == State.CRASHED else 0.0


## Leaves the lane: from now on the car slides freely, starting with its current motion.
func begin_crash() -> void:
	if state != State.CRASHED:
		crash_vel = get_velocity()
		crash_vel.y = 0.0
		crash_yaw_rate = 0.0
		var fwd := -global_basis.z
		heading = atan2(-fwd.x, -fwd.z)
		state = State.CRASHED
	set_braking(true)


## Horizontal impulse `impulse` (N s) applied at `r` (offset from the car centre, horizontal).
func apply_crash_impulse(impulse: Vector3, r: Vector3) -> void:
	crash_vel += impulse / mass
	crash_yaw_rate += (r.z * impulse.x - r.x * impulse.z) / yaw_inertia
	crash_yaw_rate = clampf(crash_yaw_rate, -MAX_KICK_YAW, MAX_KICK_YAW)


## Free sliding after a crash. Returns true once the car has stopped and waited `hold_time`.
func step_crash(delta: float, ground_y: float) -> bool:
	var fwd := Vector3(-sin(heading), 0.0, -cos(heading))
	var right := Vector3(cos(heading), 0.0, -sin(heading))
	var v_long := move_toward(crash_vel.dot(fwd), 0.0, BRAKE_DECEL * delta)
	var v_lat := move_toward(crash_vel.dot(right), 0.0, SLIDE_DECEL * delta)
	crash_vel = fwd * v_long + right * v_lat
	crash_yaw_rate = move_toward(crash_yaw_rate, 0.0, YAW_DECEL * delta) * exp(-YAW_DAMP * delta)
	heading = wrapf(heading + crash_yaw_rate * delta, -PI, PI)
	var pos := global_position + crash_vel * delta
	pos.y = lerpf(pos.y, ground_y, minf(1.0, 12.0 * delta))
	global_transform = Transform3D(Basis(Vector3.UP, heading), pos)
	speed = 0.0
	if crash_vel.length() < STOPPED_SPEED and absf(crash_yaw_rate) < 0.1:
		crash_vel = Vector3.ZERO
		crash_yaw_rate = 0.0
		hold_time -= delta
		return hold_time <= 0.0
	return false


## Switches back to lane following; `lane_xform` is the lane pose at the car's (projected) distance.
func begin_recovery(lane_xform: Transform3D) -> void:
	state = State.RECOVERING
	recover_offset = global_position - lane_xform.origin
	var fwd := -lane_xform.basis.z
	recover_yaw = wrapf(heading - atan2(-fwd.x, -fwd.z), -PI, PI)
	speed = 0.0
	crash_vel = Vector3.ZERO
	crash_yaw_rate = 0.0


## Fades the recovery offset; returns true once the car is back in its lane.
func step_recovery(delta: float) -> bool:
	var k := exp(-(0.7 + speed * 0.06) * delta)
	recover_offset *= k
	recover_yaw *= k
	if recover_offset.length() < 0.03 and absf(recover_yaw) < 0.005:
		recover_offset = Vector3.ZERO
		recover_yaw = 0.0
		state = State.DRIVING
		return true
	return false
