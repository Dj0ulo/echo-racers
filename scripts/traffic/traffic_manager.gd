class_name TrafficManager
extends Node3D
## Spawns AI traffic on the looped roads (country loop + highway) and drives it every physics tick.
## Each car follows a lane at a fixed lateral offset (right-hand traffic, both directions) using the
## Intelligent Driver Model: it cruises at its preferred speed (capped by the road's curvature-based
## advisory speed), keeps a time gap to the car ahead in its lane and brakes for the player's car (and
## for crashed cars) when they are in the way.
##
## Crashes are momentum-based. Traffic cars are kinematic and invisible to the physics engine's contact
## solver; instead this node tests the player's body box against every nearby traffic car (and crashed
## cars against other traffic) as oriented boxes in the ground plane, and exchanges a horizontal impulse
## at the contact point: restitution + Coulomb friction, both masses and yaw inertias, so a light car
## gets punted, a truck barely budges and off-centre hits spin either car. On top of that impulse, a
## hard hit from the player launches the traffic car (arcade, not physical): how high, how far and how
## fast it tumbles grows with the impact energy (~ closing speed squared) and the player/car mass ratio,
## so a hatch hit at 200 km/h barrel-rolls away while a truck only lurches.
## A hit car switches to its CRASHED state (see TrafficCar): it slides, spins and brakes to a stop,
## waits, then eases back into its lane.
##
## Disabled under `--autodrive` (keeps handling telemetry deterministic) unless `--traffic` or
## `--crashtest` is also given. Under `--autodrive`, every crash involving the player is logged.

## Emitted on every fresh impact between the player and a traffic car (closing speed in m/s).
signal player_crashed(car: TrafficCar, closing_speed: float)

@export var world_path := NodePath("../World")
@export var player_path := NodePath("../Car")
@export var country_cars_per_lane := 6
@export var highway_cars_per_lane := 6
@export var traffic_seed := 4711
@export_group("Launch")
@export var launch_min_kmh := 60.0     ## Closing speed (km/h) from which a player hit throws traffic in the air.
@export var launch_full_kmh := 170.0   ## Closing speed for a full launch (energy scales with its square).
@export var launch_up_speed := 10.0    ## Upward speed (m/s) of a full launch on a car as heavy as the player.
@export var launch_spin := 9.0         ## Roll/flip rate (rad/s) of a full launch.
@export var launch_push := 0.45        ## Extra outward speed, as a fraction of the closing speed.
@export var launch_keep_speed := 0.65  ## Share of the speed the hit took off the player given back on a full launch.
@export_group("")

const MAX_ACCEL := 1.8       ## m/s^2
const COMFORT_DECEL := 3.0   ## m/s^2
const MAX_DECEL := 9.0       ## m/s^2 (emergency)
const TIME_GAP := 1.3        ## s
const MIN_GAP := 3.0         ## m, bumper to bumper when stopped
const PLAYER_HALF_LENGTH := 2.15  ## Player body box (car.tscn BodyShape).
const PLAYER_HALF_WIDTH := 0.875
const PLAYER_BOTTOM := -0.25      ## Body box vertical extent relative to the player's origin.
const PLAYER_TOP := 0.84
const PLAYER_LOOKAHEAD := 160.0
const SPAWN_CLEARANCE := 70.0  ## No traffic spawns this close to the player.

const RESTITUTION := 0.28        ## Bounciness of a fresh impact (crumpling bodywork, not billiard balls).
const FRICTION := 0.35           ## Body-to-body Coulomb friction (side swipes drag and deflect).
const BOUNCE_MIN_SPEED := 1.0    ## m/s closing speed below which contacts are plastic (pushing, resting).
const PAIR_COOLDOWN := 0.35      ## s between two "fresh" impacts of the same pair (no double bounce/sound).
const PENETRATION_SLOP := 0.02   ## m
const PENETRATION_FIX := 0.8     ## Fraction of the overlap removed per tick.
const PLAYER_MAX_KICK_YAW := 4.0 ## rad/s: an impact never spins the player faster than this.


class Lane:
	var road: RoadPath
	var offset := 0.0   ## Lateral offset from the centreline (+ = right of the road tangent).
	var dir := 1.0      ## +1 drives towards increasing distance, -1 the other way.
	var cars: Array[TrafficCar] = []


## A body taking part in a contact: the player's car or a traffic car (horizontal plane only).
class Body:
	var car: TrafficCar     ## null for the player.
	var center := Vector3.ZERO  ## Box centre.
	var com := Vector3.ZERO
	var fwd := Vector3.FORWARD  ## Horizontal unit axes.
	var right := Vector3.RIGHT
	var half_l := 2.0
	var half_w := 0.9
	var bottom := 0.0
	var top := 1.0
	var inv_mass := 0.0
	var inv_inertia := 0.0  ## Inverse yaw inertia.
	var vel := Vector3.ZERO
	var yaw_rate := 0.0
	var movable := true


var lanes: Array[Lane] = []
var debug_log := false
var _cars: Array[TrafficCar] = []
var _lane_of := {}  ## TrafficCar -> Lane
var _player: RigidBody3D
var _player_audio: Node
var _world: WorldGenerator
var _time := 0.0
var _cooldowns := {}  ## Pair key -> time until which impacts of that pair are not "fresh".


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if "--autodrive" in args and not "--traffic" in args and not "--crashtest" in args:
		set_physics_process(false)
		return
	debug_log = "--autodrive" in args
	_world = get_node(world_path) as WorldGenerator
	_player = get_node_or_null(player_path) as RigidBody3D
	if _player:
		_player_audio = _player.get_node_or_null("Audio")
	var rng := RandomNumberGenerator.new()
	rng.seed = traffic_seed
	for road in _world.roads:
		if not road.closed:
			continue  # Link roads end in junctions: no routing, so no traffic there.
		var per_lane := highway_cars_per_lane if road.is_highway else country_cars_per_lane
		for offset in road.lane_offsets():
			var lane := Lane.new()
			lane.road = road
			lane.offset = offset
			lane.dir = signf(offset)
			lanes.append(lane)
			_populate(lane, per_lane, rng)
	print("Traffic: %d cars on %d lanes" % [_cars.size(), lanes.size()])


func _populate(lane: Lane, count: int, rng: RandomNumberGenerator) -> void:
	var road := lane.road
	var spacing := road.length / count
	# Main places the player at the spawn point after this node is ready.
	var player_pos := _world.get_spawn_transform().origin
	var fast_lane := road.is_highway and absf(lane.offset) < road.median_width * 0.5 + road.lane_width
	for k in count:
		var s := (k + rng.randf_range(0.0, 0.6)) * spacing
		var kind := _pick_kind(rng, road.is_highway, fast_lane)
		var car := TrafficCar.new()
		car.name = "Traffic_%s_%d" % [road.name, get_child_count()]
		car.setup(kind, TrafficCarMesh.PAINTS[rng.randi() % TrafficCarMesh.PAINTS.size()])
		if road.is_highway:
			car.cruise = (rng.randf_range(122.0, 145.0) if fast_lane else rng.randf_range(92.0, 112.0)) / 3.6
			if kind == TrafficCarMesh.Kind.TRUCK:
				car.cruise = rng.randf_range(82.0, 90.0) / 3.6
		else:
			car.cruise = rng.randf_range(62.0, 82.0) / 3.6
		# Keep the spawn area around the player clear.
		for _try in 20:
			var p: Vector3 = road.sample_at(s)[0]
			if p.distance_to(player_pos) > SPAWN_CLEARANCE:
				break
			s += 15.0
		car.s = road.wrap_distance(s)
		car.speed = minf(car.cruise, road.advisory_speed[road.sample_at(car.s)[2]])
		add_child(car)
		lane.cars.append(car)
		_cars.append(car)
		_lane_of[car] = lane
		_place(car, lane)
		car.reset_physics_interpolation()
	_sort_lane(lane)


static func _pick_kind(rng: RandomNumberGenerator, highway: bool, fast_lane: bool) -> int:
	var r := rng.randf()
	if highway and not fast_lane and r < 0.2:
		return TrafficCarMesh.Kind.TRUCK
	r = rng.randf()
	if r < 0.4:
		return TrafficCarMesh.Kind.SEDAN
	if r < 0.68:
		return TrafficCarMesh.Kind.HATCH
	if r < 0.85:
		return TrafficCarMesh.Kind.VAN
	return TrafficCarMesh.Kind.PICKUP


func _physics_process(delta: float) -> void:
	_time += delta
	var player_body := _player_body()
	# Things every driving car must brake for when they are in its path: the player and crashed cars.
	var obstacles: Array[Body] = []
	if player_body:
		obstacles.append(player_body)
	for car in _cars:
		if car.state != TrafficCar.State.DRIVING:
			obstacles.append(_car_body(car))

	for lane in lanes:
		_sort_lane(lane)
		var cars := lane.cars
		var n := cars.size()
		var road_len := lane.road.length
		for k in n:
			var car := cars[k]
			if car.state == TrafficCar.State.CRASHED:
				_step_crashed(car, lane, delta)
				continue
			# Leader in the lane (cars are sorted by travel order, the lane is a loop).
			var leader := cars[(k + 1) % n]
			var gap := INF
			var lead_speed := 0.0
			if leader != car:
				gap = fposmod((leader.s - car.s) * lane.dir, road_len) - (car.length + leader.length) * 0.5
				lead_speed = leader.speed
			var leader_gap := gap
			for ob in obstacles:
				if ob.car == car or ob.car == leader:
					continue
				var ob_gap := _gap_to(car, ob)
				if ob_gap < gap:
					gap = ob_gap
					lead_speed = maxf(ob.vel.dot(-car.global_basis.z), 0.0)
			_drive(car, lane, gap, lead_speed, leader_gap < 0.5, delta)
			if car.state == TrafficCar.State.RECOVERING and car.step_recovery(delta) and debug_log:
				print("Traffic: %s back in its lane" % car.name)
			_place(car, lane)

	_collide(player_body)


## Distance (bumper to bumper) from `car` to obstacle `ob` along the car's lane, INF if not in its path.
func _gap_to(car: TrafficCar, ob: Body) -> float:
	var to_ob := ob.center - car.global_position
	if to_ob.length_squared() > PLAYER_LOOKAHEAD * PLAYER_LOOKAHEAD:
		return INF
	var fwd := -car.global_basis.z
	var right := car.global_basis.x
	var along := to_ob.dot(fwd)
	var ob_half_w := absf(ob.fwd.dot(right)) * ob.half_l + absf(ob.right.dot(right)) * ob.half_w
	var ob_half_l := absf(ob.fwd.dot(fwd)) * ob.half_l + absf(ob.right.dot(fwd)) * ob.half_w
	if absf(to_ob.dot(right)) < car.width * 0.5 + ob_half_w + 0.4 and along > -car.length * 0.3:
		return along - car.length * 0.5 - ob_half_l
	return INF


## Intelligent Driver Model longitudinal control.
## `hard_stop`: the lane leader is right in front (cars of a lane never overlap). Anything else in the way
## (the player, a crashed car) only gets emergency braking: if that is not enough, it is a crash.
func _drive(car: TrafficCar, lane: Lane, gap: float, lead_speed: float, hard_stop: bool, delta: float) -> void:
	var road := lane.road
	var idx: int = road.sample_at(car.s)[2]
	var desired := minf(car.cruise, road.advisory_speed[idx])
	if car.state == TrafficCar.State.RECOVERING:
		desired = minf(desired, TrafficCar.RECOVER_SPEED)
	var v := car.speed
	var a := MAX_ACCEL * (1.0 - pow(v / maxf(desired, 0.1), 4.0))
	if gap < INF:
		var s_star := MIN_GAP + maxf(0.0, v * TIME_GAP + v * (v - lead_speed) / (2.0 * sqrt(MAX_ACCEL * COMFORT_DECEL)))
		a -= MAX_ACCEL * pow(s_star / maxf(gap, 0.1), 2.0)
	a = clampf(a, -MAX_DECEL, MAX_ACCEL)
	v = maxf(v + a * delta, 0.0)
	if hard_stop:
		v = 0.0  # Never push into the car right in front.
	car.speed = v
	car.accel = a
	car.s = road.wrap_distance(car.s + v * delta * lane.dir)
	car.set_braking(a < -1.0 or (v < 0.5 and gap < 20.0))


func _lane_xform(car: TrafficCar, lane: Lane) -> Transform3D:
	var road := lane.road
	var here: Array = road.sample_at(car.s)
	var ahead: Array = road.sample_at(car.s + 2.0 * lane.dir)
	var behind: Array = road.sample_at(car.s - 2.0 * lane.dir)
	var tangent: Vector3 = here[1]
	var right := Vector3(-tangent.z, 0.0, tangent.x)
	var pos: Vector3 = here[0] + right * lane.offset
	var fwd: Vector3 = (ahead[0] as Vector3) - (behind[0] as Vector3)
	if fwd.length_squared() < 1e-6:
		fwd = tangent * lane.dir
	return Transform3D(Basis.looking_at(fwd.normalized(), Vector3.UP), pos)


func _place(car: TrafficCar, lane: Lane) -> void:
	var xform := _lane_xform(car, lane)
	if car.state == TrafficCar.State.RECOVERING:
		xform = Transform3D(Basis(Vector3.UP, car.recover_yaw) * xform.basis, xform.origin + car.recover_offset)
	car.global_transform = xform


## Orders cars so that cars[k + 1] is the one ahead of cars[k] in the driving direction.
func _sort_lane(lane: Lane) -> void:
	if lane.dir > 0.0:
		lane.cars.sort_custom(func(a: TrafficCar, b: TrafficCar) -> bool: return a.s < b.s)
	else:
		lane.cars.sort_custom(func(a: TrafficCar, b: TrafficCar) -> bool: return a.s > b.s)


# --- Crashed cars ------------------------------------------------------------------------------

func _step_crashed(car: TrafficCar, lane: Lane, delta: float) -> void:
	var road := lane.road
	var smp: Array = road.sample_at(car.s)
	var centre: Vector3 = smp[0]
	var tangent: Vector3 = smp[1]
	var right := Vector3(-tangent.z, 0.0, tangent.x)
	var lateral := (car.global_position - centre).dot(right)
	var ground_y := centre.y
	if absf(lateral) > road.half_width:
		ground_y = _world.terrain.get_height(car.global_position.x, car.global_position.z)
	var done := car.step_crash(delta, ground_y)
	if road.median_width > 0.0:
		_keep_between_barriers(car, lane, centre, right)
	car.s = _project(road, car.s, car.global_position)
	car.speed = maxf(car.crash_vel.dot(tangent * lane.dir), 0.0)  # For the IDM of the cars behind.
	if done:
		car.begin_recovery(_lane_xform(car, lane))
		_place(car, lane)
		if debug_log:
			print("Traffic: %s recovering (%.1f m, %.0f deg off its lane)" % [car.name, car.recover_offset.length(),
				rad_to_deg(car.recover_yaw)])


## Highway: a sliding car glances off the median barrier and the outer guard rail instead of crossing them.
func _keep_between_barriers(car: TrafficCar, lane: Lane, centre: Vector3, right: Vector3) -> void:
	var road := lane.road
	var side := right * signf(lane.offset)  # Points away from the median, on this carriageway.
	var l := (car.global_position - centre).dot(side)
	var lo := road.median_width * 0.5 + 0.2 + car.width * 0.5
	var hi := road.half_width + 0.4 - car.width * 0.5
	var v := car.crash_vel.dot(side)
	if l < lo:
		car.global_position += side * (lo - l)
		if v < 0.0:
			car.crash_vel -= side * v * 1.3
	elif l > hi:
		car.global_position -= side * (l - hi)
		if v > 0.0:
			car.crash_vel -= side * v * 1.3


## Distance along the centreline of the point nearest to `pos`, refined from the guess `s`.
static func _project(road: RoadPath, s: float, pos: Vector3) -> float:
	for _i in 3:
		var smp: Array = road.sample_at(s)
		s = road.wrap_distance(s + (pos - (smp[0] as Vector3)).dot(smp[1]))
	return s


# --- Contacts ------------------------------------------------------------------------------------

func _player_body() -> Body:
	if _player == null:
		return null
	var b := Body.new()
	var xform := _player.global_transform
	b.center = xform.origin
	b.com = xform * _player.center_of_mass
	b.fwd = _flat_dir(-xform.basis.z, Vector3.FORWARD)
	b.right = Vector3(-b.fwd.z, 0.0, b.fwd.x)
	b.half_l = PLAYER_HALF_LENGTH
	b.half_w = PLAYER_HALF_WIDTH
	b.bottom = xform.origin.y + PLAYER_BOTTOM
	b.top = xform.origin.y + PLAYER_TOP
	b.inv_mass = 1.0 / _player.mass
	b.inv_inertia = 1.0 / (_player.mass * 1.8)
	var state := PhysicsServer3D.body_get_direct_state(_player.get_rid())
	if state:
		b.inv_inertia = (state.inverse_inertia_tensor * Vector3.UP).y
	b.vel = _player.linear_velocity
	b.yaw_rate = _player.angular_velocity.y
	return b


func _car_body(car: TrafficCar) -> Body:
	var b := Body.new()
	b.car = car
	b.center = car.global_position
	b.com = car.global_position
	b.fwd = _flat_dir(-car.global_basis.z, Vector3.FORWARD)
	b.right = Vector3(-b.fwd.z, 0.0, b.fwd.x)
	b.half_l = car.length * 0.5
	b.half_w = car.width * 0.5
	b.bottom = car.global_position.y + 0.25
	b.top = car.global_position.y + car.height
	b.inv_mass = 1.0 / car.mass
	b.inv_inertia = 1.0 / car.yaw_inertia
	b.vel = car.get_velocity()
	b.yaw_rate = car.get_yaw_rate()
	return b


static func _flat_dir(v: Vector3, fallback: Vector3) -> Vector3:
	v.y = 0.0
	return v.normalized() if v.length_squared() > 1e-4 else fallback


func _collide(player_body: Body) -> void:
	# Player against every traffic car close enough to touch.
	if player_body:
		for car in _cars:
			if car.is_airborne():
				continue  # Thrown clear: the player ploughs on underneath.
			var reach := car.length * 0.5 + PLAYER_HALF_LENGTH + 1.0
			if car.global_position.distance_squared_to(player_body.center) < reach * reach:
				_try_contact(_car_body(car), player_body)
	# Crashed / recovering cars against other traffic (a punted car can shunt the next one).
	for i in _cars.size():
		var a := _cars[i]
		if a.state == TrafficCar.State.DRIVING:
			continue
		for j in _cars.size():
			var b := _cars[j]
			if b == a or (b.state != TrafficCar.State.DRIVING and j < i):
				continue
			var reach := (a.length + b.length) * 0.5 + 1.0
			if a.global_position.distance_squared_to(b.global_position) < reach * reach:
				_try_contact(_car_body(a), _car_body(b))


## Oriented-box overlap in the ground plane (separating axes). Returns [normal from a to b, depth,
## contact point] or an empty array.
static func _overlap(a: Body, b: Body) -> Array:
	if a.bottom >= b.top or b.bottom >= a.top:
		return []
	var d := b.center - a.center
	d.y = 0.0
	var best_depth := INF
	var best_axis := Vector3.ZERO
	for axis: Vector3 in [a.fwd, a.right, b.fwd, b.right]:
		var ra := a.half_l * absf(a.fwd.dot(axis)) + a.half_w * absf(a.right.dot(axis))
		var rb := b.half_l * absf(b.fwd.dot(axis)) + b.half_w * absf(b.right.dot(axis))
		var dist := d.dot(axis)
		var depth := ra + rb - absf(dist)
		if depth <= 0.0:
			return []
		if depth < best_depth:
			best_depth = depth
			best_axis = axis * (1.0 if dist >= 0.0 else -1.0)
	# Contact point: average of the corners of either box that lie inside the other.
	var sum := Vector3.ZERO
	var count := 0
	for pair in [[a, b], [b, a]]:
		var p: Body = pair[0]
		var q: Body = pair[1]
		for sx: float in [-1.0, 1.0]:
			for sz: float in [-1.0, 1.0]:
				var corner := p.center + p.fwd * (p.half_l * sz) + p.right * (p.half_w * sx)
				var rel := corner - q.center
				if absf(rel.dot(q.fwd)) <= q.half_l + 0.05 and absf(rel.dot(q.right)) <= q.half_w + 0.05:
					sum += corner
					count += 1
	var point := sum / count if count > 0 else (a.center + b.center) * 0.5
	return [best_axis, best_depth, point]


## Cross product's Y component (yaw torque arm) for horizontal vectors.
static func _cross_y(r: Vector3, v: Vector3) -> float:
	return r.z * v.x - r.x * v.z


static func _point_velocity(body: Body, r: Vector3) -> Vector3:
	return body.vel + Vector3(body.yaw_rate * r.z, 0.0, -body.yaw_rate * r.x)


## Detects and resolves a contact between traffic car body `a` and body `b` (player or traffic).
func _try_contact(a: Body, b: Body) -> void:
	var hit := _overlap(a, b)
	if hit.is_empty():
		return
	var n: Vector3 = hit[0]
	var depth: float = hit[1]
	var point: Vector3 = hit[2]
	var ra := point - a.com
	ra.y = 0.0
	var rb := point - b.com
	rb.y = 0.0
	var vrel := _point_velocity(b, rb) - _point_velocity(a, ra)
	vrel.y = 0.0
	var vn := vrel.dot(n)
	var closing := -vn

	var key := "%d:%d" % [a.car.get_instance_id(), b.car.get_instance_id() if b.car else 0]
	var fresh: bool = _time >= float(_cooldowns.get(key, 0.0)) and closing > BOUNCE_MIN_SPEED
	if fresh:
		_cooldowns[key] = _time + PAIR_COOLDOWN
		if _cooldowns.size() > 64:
			for k in _cooldowns.keys():
				if float(_cooldowns[k]) < _time:
					_cooldowns.erase(k)

	var pre_a := a.vel
	var pre_b := b.vel
	var pre_b_yaw := b.yaw_rate
	if vn < 0.0:
		# Approaching: the impact pushes both cars, hard driving cars become crashed ones.
		for body in [a, b]:
			if body.car:
				body.car.begin_crash()
				body.car.hold_time = maxf(body.car.hold_time, 1.0)
				body.movable = true
		var e := RESTITUTION if fresh else 0.0
		var k_n := a.inv_mass + b.inv_mass + a.inv_inertia * pow(_cross_y(ra, n), 2) + b.inv_inertia * pow(_cross_y(rb, n), 2)
		var j := -(1.0 + e) * vn / k_n
		var impulse := n * j
		var vt := vrel - n * vn
		var vt_len := vt.length()
		if vt_len > 0.01:
			var t := vt / vt_len
			var k_t := a.inv_mass + b.inv_mass + a.inv_inertia * pow(_cross_y(ra, t), 2) + b.inv_inertia * pow(_cross_y(rb, t), 2)
			impulse -= t * minf(vt_len / k_t, FRICTION * j)
		_apply(a, -impulse, ra)
		_apply(b, impulse, rb)
		if fresh:
			var severity := clampf(closing / 20.0, 0.0, 1.0)
			for body in [a, b]:
				if body.car:
					body.car.hold_time = maxf(body.car.hold_time, lerpf(1.5, 5.0, severity))
			if b.car == null:
				_launch(a.car, b, n, closing, pre_b)
	else:
		# Touching without closing in: only separate, never shove a car that is driving along.
		a.movable = a.car.state == TrafficCar.State.CRASHED
		b.movable = b.car == null or b.car.state == TrafficCar.State.CRASHED

	_separate(a, b, n, depth)

	if fresh and b.car == null:
		player_crashed.emit(a.car, closing)
		var strength := clampf(closing / 15.0, 0.1, 1.0)
		if _player_audio and _player_audio.has_method(&"play_impact"):
			_player_audio.play_impact(strength, clampf(a.car.mass / 6000.0, 0.0, 1.0))
		if debug_log:
			print(("Crash: %.1f km/h closing into %s (%.0f kg, %s) | player %.1f -> %.1f km/h, yaw %.2f -> %.2f rad/s, " +
				"vy %.2f | traffic %.1f -> %.1f km/h, yaw %.2f rad/s") % [
				closing * 3.6, TrafficCarMesh.Kind.keys()[a.car.kind], a.car.mass,
				"fresh" if fresh else "contact", pre_b.length() * 3.6, _player.linear_velocity.length() * 3.6,
				pre_b_yaw, _player.angular_velocity.y, _player.linear_velocity.y,
				pre_a.length() * 3.6, a.car.crash_vel.length() * 3.6, a.car.crash_yaw_rate])


## Throws `car` after a fresh hit by the player body `pb` (contact normal `n` from the car to the player).
## `player_pre` is the player's velocity before the impact.
func _launch(car: TrafficCar, pb: Body, n: Vector3, closing: float, player_pre: Vector3) -> void:
	var v0 := launch_min_kmh / 3.6
	var v1 := maxf(launch_full_kmh / 3.6, v0 + 1.0)
	var e := clampf((closing * closing - v0 * v0) / (v1 * v1 - v0 * v0), 0.0, 1.0)  # Energy fraction.
	if e <= 0.0:
		return
	var mass_k := clampf(_player.mass / car.mass, 0.1, 1.0)
	# Thrown away from the player, biased along the player's travel.
	var away := -n
	var travel := _flat_dir(pb.vel, away)
	var dir := _flat_dir(away + travel, away)
	var fwd := Vector3(-sin(car.heading), 0.0, -cos(car.heading))
	var right := Vector3(cos(car.heading), 0.0, -sin(car.heading))
	var spin := launch_spin * lerpf(0.4, 1.0, e) * sqrt(mass_k) * randf_range(0.8, 1.2)
	var vy := launch_up_speed * lerpf(0.35, 1.0, e) * mass_k
	car.launch(vy, -dir.dot(right) * spin, -dir.dot(fwd) * spin * 0.6,
		dir * closing * launch_push * e * mass_k)
	car.hold_time = maxf(car.hold_time, 5.0)
	# The car is thrown clear, so the player ploughs through instead of stopping dead.
	var keep := launch_keep_speed * e * mass_k
	var lost := player_pre - _player.linear_velocity
	lost.y = 0.0
	_player.linear_velocity += lost * keep
	pb.vel = _player.linear_velocity
	if debug_log:
		print("Launch: %s at %.0f km/h, energy %.2f, vy %.1f m/s, spin %.1f rad/s" % [
			TrafficCarMesh.Kind.keys()[car.kind], closing * 3.6, e, vy, spin])


## Applies a horizontal impulse at offset `r` from the body's centre of mass.
func _apply(body: Body, impulse: Vector3, r: Vector3) -> void:
	var dv := impulse * body.inv_mass
	var dw := _cross_y(r, impulse) * body.inv_inertia
	body.vel += dv
	body.yaw_rate += dw
	if body.car:
		body.car.apply_crash_impulse(impulse, r)
		return
	_player.linear_velocity += dv
	var w := _player.angular_velocity
	var new_y := w.y + dw
	if absf(new_y) > PLAYER_MAX_KICK_YAW and absf(new_y) > absf(w.y):
		new_y = signf(new_y) * maxf(PLAYER_MAX_KICK_YAW, absf(w.y))
	_player.angular_velocity = Vector3(w.x, new_y, w.z)
	body.yaw_rate = new_y


## Pushes the overlapping boxes apart, shared by inverse mass between the bodies that may move.
func _separate(a: Body, b: Body, n: Vector3, depth: float) -> void:
	var fix := maxf(depth - PENETRATION_SLOP, 0.0) * PENETRATION_FIX
	var wa := a.inv_mass if a.movable else 0.0
	var wb := b.inv_mass if b.movable else 0.0
	if fix <= 0.0 or wa + wb <= 0.0:
		return
	var move_a := -n * fix * wa / (wa + wb)
	var move_b := n * fix * wb / (wa + wb)
	a.car.global_position += move_a
	a.center += move_a
	if b.car:
		b.car.global_position += move_b
	else:
		_player.global_position += move_b
	b.center += move_b


# --- Debug (autodrive crash test) --------------------------------------------------------------

## Moves `car` into `lane` at distance `s`, driving at `speed`, and makes it drive normally again.
func debug_place(car: TrafficCar, lane: Lane, s: float, speed: float) -> void:
	var old: Lane = _lane_of[car]
	old.cars.erase(car)
	lane.cars.append(car)
	_lane_of[car] = lane
	car.state = TrafficCar.State.DRIVING
	car.recover_offset = Vector3.ZERO
	car.recover_yaw = 0.0
	car.hold_time = 0.0
	car.crash_vel = Vector3.ZERO
	car.crash_yaw_rate = 0.0
	car.s = lane.road.wrap_distance(s)
	car.speed = speed
	_place(car, lane)
	car.reset_physics_interpolation()
	_sort_lane(lane)


## Moves every car of `road` within `radius` of distance `s` (except `keep`) far down the road.
func debug_clear(road: RoadPath, s: float, radius: float, keep: Array) -> void:
	var k := 0
	for lane in lanes:
		if lane.road != road:
			continue
		for car in lane.cars.duplicate():
			if car in keep:
				continue
			var d := absf(wrapf(car.s - s, -road.length * 0.5, road.length * 0.5))
			if d < radius:
				debug_place(car, lane, s + radius * 2.0 + k * 35.0, car.speed)
				k += 1
