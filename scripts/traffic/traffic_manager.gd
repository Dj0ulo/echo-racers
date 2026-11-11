class_name TrafficManager
extends Node3D
## Spawns AI traffic on the looped roads (country loop + highway) and drives it every physics tick.
## Each car follows a lane at a fixed lateral offset (right-hand traffic, both directions) using the
## Intelligent Driver Model: it cruises at its preferred speed (capped by the road's curvature-based
## advisory speed), keeps a time gap to the car ahead in its lane and brakes for the player's car when it
## is in the way. Movement is kinematic (AnimatableBody3D), so cars never clip through the player:
## they stop behind it, and a crash pushes the player car instead.
##
## Disabled under `--autodrive` (keeps handling telemetry deterministic) unless `--traffic` is also given.

@export var world_path := NodePath("../World")
@export var player_path := NodePath("../Car")
@export var country_cars_per_lane := 6
@export var highway_cars_per_lane := 6
@export var traffic_seed := 4711

const MAX_ACCEL := 1.8       ## m/s^2
const COMFORT_DECEL := 3.0   ## m/s^2
const MAX_DECEL := 9.0       ## m/s^2 (emergency)
const TIME_GAP := 1.3        ## s
const MIN_GAP := 3.0         ## m, bumper to bumper when stopped
const PLAYER_HALF_LENGTH := 2.2
const PLAYER_HALF_WIDTH := 0.9
const PLAYER_LOOKAHEAD := 160.0
const SPAWN_CLEARANCE := 70.0  ## No traffic spawns this close to the player.


class Lane:
	var road: RoadPath
	var offset := 0.0   ## Lateral offset from the centreline (+ = right of the road tangent).
	var dir := 1.0      ## +1 drives towards increasing distance, -1 the other way.
	var cars: Array[TrafficCar] = []


var lanes: Array[Lane] = []
var _player: RigidBody3D
var _world: WorldGenerator


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if "--autodrive" in args and not "--traffic" in args:
		set_physics_process(false)
		return
	_world = get_node(world_path) as WorldGenerator
	_player = get_node_or_null(player_path) as RigidBody3D
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
	var total := 0
	for lane in lanes:
		total += lane.cars.size()
	print("Traffic: %d cars on %d lanes" % [total, lanes.size()])


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
	var player_pos := _player.global_position if _player else Vector3.INF
	var player_vel := _player.linear_velocity if _player else Vector3.ZERO
	var player_basis := _player.global_basis if _player else Basis()
	for lane in lanes:
		_sort_lane(lane)
		var cars := lane.cars
		var n := cars.size()
		var road_len := lane.road.length
		for k in n:
			var car := cars[k]
			# Leader in the lane (cars are sorted by travel order, the lane is a loop).
			var leader := cars[(k + 1) % n]
			var gap := INF
			var lead_speed := 0.0
			if leader != car:
				gap = fposmod((leader.s - car.s) * lane.dir, road_len) - (car.length + leader.length) * 0.5
				lead_speed = leader.speed
			# The player's car, if it is in this car's path.
			var to_player := player_pos - car.global_position
			if to_player.length_squared() < PLAYER_LOOKAHEAD * PLAYER_LOOKAHEAD:
				var fwd := -car.global_basis.z
				var right := car.global_basis.x
				var along := to_player.dot(fwd)
				var pf := -player_basis.z
				var pr := player_basis.x
				var p_half_w := absf(pf.dot(right)) * PLAYER_HALF_LENGTH + absf(pr.dot(right)) * PLAYER_HALF_WIDTH
				var p_half_l := absf(pf.dot(fwd)) * PLAYER_HALF_LENGTH + absf(pr.dot(fwd)) * PLAYER_HALF_WIDTH
				if absf(to_player.dot(right)) < car.width * 0.5 + p_half_w + 0.4 and along > -car.length * 0.3:
					var player_gap := along - car.length * 0.5 - p_half_l
					if player_gap < gap:
						gap = player_gap
						lead_speed = maxf(player_vel.dot(fwd), 0.0)
			_drive(car, lane, gap, lead_speed, delta)
			_place(car, lane)


## Intelligent Driver Model longitudinal control.
func _drive(car: TrafficCar, lane: Lane, gap: float, lead_speed: float, delta: float) -> void:
	var road := lane.road
	var idx: int = road.sample_at(car.s)[2]
	var desired := minf(car.cruise, road.advisory_speed[idx])
	var v := car.speed
	var a := MAX_ACCEL * (1.0 - pow(v / maxf(desired, 0.1), 4.0))
	if gap < INF:
		var s_star := MIN_GAP + maxf(0.0, v * TIME_GAP + v * (v - lead_speed) / (2.0 * sqrt(MAX_ACCEL * COMFORT_DECEL)))
		a -= MAX_ACCEL * pow(s_star / maxf(gap, 0.1), 2.0)
	a = clampf(a, -MAX_DECEL, MAX_ACCEL)
	v = maxf(v + a * delta, 0.0)
	if gap < 0.5:
		v = 0.0  # Never push into whatever is right in front.
	car.speed = v
	car.accel = a
	car.s = road.wrap_distance(car.s + v * delta * lane.dir)
	car.set_braking(a < -1.0 or (v < 0.5 and gap < 20.0))


func _place(car: TrafficCar, lane: Lane) -> void:
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
	car.global_transform = Transform3D(Basis.looking_at(fwd.normalized(), Vector3.UP), pos)


## Orders cars so that cars[k + 1] is the one ahead of cars[k] in the driving direction.
func _sort_lane(lane: Lane) -> void:
	if lane.dir > 0.0:
		lane.cars.sort_custom(func(a: TrafficCar, b: TrafficCar) -> bool: return a.s < b.s)
	else:
		lane.cars.sort_custom(func(a: TrafficCar, b: TrafficCar) -> bool: return a.s > b.s)
