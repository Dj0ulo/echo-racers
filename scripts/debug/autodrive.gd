extends Node
## Debug helper, enabled with `godot -- --autodrive [--shots=/abs/dir] [--road=highway] [--traffic]`.
## `--road=<name>` drives another road of the network (in its inner right-hand lane on multi-lane roads);
## traffic stays off unless `--traffic` is given.
## `--route=a,b,c,...` drives through several roads in turn (e.g. `highway,ramp_north_off1,link_north,
## ramp_north_on2,highway` exits the highway, crosses the bridge and joins the other carriageway), switching
## where each road meets the next (a loop is driven in the direction of the ramp it leads to or comes from;
## otherwise prefix the first road with `-` to drive it backwards). No drift events.
## `--view=x,y,z,tx,ty,tz` (repeatable, needs --shots) also saves a still from a free camera at (x, y, z)
## looking at (tx, ty, tz) before the drive starts (view_<k>.png); `--view=overview` is a whole-map view.
## A simple pure-pursuit autopilot drives along the road (with handbrake drift scenarios and a
## brake/reverse test), prints handling telemetry, optionally saves screenshots, then quits.
##
## `--shots` images are downscaled to `--shot-width=<px>` (default 960) wide, keeping the aspect ratio.
## `--quiet` suppresses the periodic telemetry lines (1 Hz lap, 10 Hz drift events, crash-test timelines);
## summaries, "Saved" lines and errors are still printed.
##
## `--crashtest` replaces the lap with scripted crashes against traffic on a highway straight (rear-ending a
## hatch and a truck, an off-centre T-bone, being T-boned, a side swipe, then two 180-200 km/h hits that
## launch the traffic car) and prints pre/post velocities and the hit car's peak air height.
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
var _road: RoadPath
var _lane_offset := 0.0
var _max_target_kmh := 170.0
var _views: Array[PackedFloat32Array] = []
var _view_cam: Camera3D
var _view_frame := 0
var _route := false
var _quiet := false
var _shot_width := 960

## Crash test scenarios (highway, carriageway with increasing distance). Distances are relative to the
## player's start; "lat" shifts the traffic car sideways off its lane centre; "yaw" is relative to the lane.
## A traffic car with "slide" is put in its crashed (free sliding) state with that velocity along the lane.
const CRASH_TESTS := [
	{"name": "rear-end hatch", "kind": TrafficCarMesh.Kind.HATCH, "lane": 1, "ahead": 30.0, "speed": 15.0,
		"p_lane": 1, "p_speed": 30.0},
	{"name": "rear-end truck", "kind": TrafficCarMesh.Kind.TRUCK, "lane": 1, "ahead": 30.0, "speed": 15.0,
		"p_lane": 1, "p_speed": 30.0},
	{"name": "T-bone parked sedan off-centre", "kind": TrafficCarMesh.Kind.SEDAN, "lane": 1, "ahead": 25.0,
		"speed": 0.0, "slide": 0.0, "yaw": 90.0, "lat": 1.4, "p_lane": 1, "p_speed": 20.0},
	{"name": "van T-bones stopped player", "kind": TrafficCarMesh.Kind.VAN, "lane": 1, "ahead": -22.0,
		"speed": 0.0, "slide": 18.0, "yaw": 0.0, "lat": 1.0, "p_lane": 1, "p_speed": 0.0, "p_yaw": 90.0},
	{"name": "side swipe pickup", "kind": TrafficCarMesh.Kind.PICKUP, "lane": 1, "ahead": 8.0, "speed": 26.0,
		"p_lane": 0, "p_speed": 32.0, "p_target_lane": 1},
	{"name": "launch: 200 km/h rear-end hatch", "kind": TrafficCarMesh.Kind.HATCH, "lane": 1, "ahead": 60.0,
		"speed": 12.0, "p_lane": 1, "p_speed": 56.0},
	{"name": "launch: 180 km/h T-bone sedan", "kind": TrafficCarMesh.Kind.SEDAN, "lane": 1, "ahead": 60.0,
		"speed": 0.0, "slide": 0.0, "yaw": 90.0, "lat": 0.6, "p_lane": 1, "p_speed": 50.0},
]
const CRASH_TEST_TIME := 9.0
var _crash_mode := false
var _traffic: TrafficManager
var _ct_index := -1
var _ct_time := 0.0
var _ct_s0 := 0.0
var _ct_lanes: Array = []
var _ct_car: TrafficCar
var _ct_car_start := Vector3.ZERO
var _ct_hit_time := -1.0
var _ct_stats := {}


func _ready() -> void:
	_car = get_parent().get_node("Car")
	_world = get_parent().get_node("World")
	_car.input.player_controlled = false
	_road = _world.road
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shots="):
			_shots_dir = arg.trim_prefix("--shots=")
		elif arg.begins_with("--shot-width="):
			_shot_width = maxi(int(arg.trim_prefix("--shot-width=")), 16)
		elif arg == "--quiet":
			_quiet = true
		elif arg.begins_with("--view="):
			var spec := arg.trim_prefix("--view=")
			if spec == "overview":
				spec = "-2900,3000,2900,0,0,0"
			_views.append(PackedFloat32Array(Array(spec.split_floats(","))))
		elif arg.begins_with("--road="):
			var road_name := arg.trim_prefix("--road=")
			for r in _world.roads:
				if String(r.name) == road_name:
					_road = r
		elif arg.begins_with("--route="):
			_road = _build_route(arg.trim_prefix("--route=").split(","))
			_route = true
	if "--crashtest" in OS.get_cmdline_user_args():
		_setup_crash_test()
		return
	if _road != _world.road and not _route:
		if _road.median_width > 0.0:
			_lane_offset = _road.lane_offsets()[0]
			_max_target_kmh = 260.0
	if _road != _world.road:
		_car.reset_to(_road.transform_at(0, 0.9, _lane_offset))
		get_parent().get_node("ChaseCamera").snap()
		print("Autodrive on road '%s' (%.0f m), lane offset %.2f m" % [_road.name, _road.length, _lane_offset])


## Concatenates the right-hand lanes of the named roads into one open path. Each road is entered where the
## previous one ends (nearest sample) and left at the sample nearest to the next road's start; open roads
## run towards their exit, loops keep the heading they were entered with. Starts 300 m before the first exit.
func _build_route(names: PackedStringArray) -> RoadPath:
	var parts: Array[RoadPath] = []
	var first_reversed := names[0].begins_with("-")
	for road_name in names:
		var found: RoadPath = null
		for r in _world.roads:
			if String(r.name) == road_name.trim_prefix("-"):
				found = r
		assert(found != null, "unknown road " + road_name)
		parts.append(found)
	var route := RoadPath.new()
	route.name = StringName("route")
	route.closed = false
	var pts := PackedVector3Array()
	var heading := Vector3.ZERO
	for k in parts.size():
		var r := parts[k]
		var n := r.sample_count()
		var entry := -1 if pts.is_empty() else r.nearest_index(pts[pts.size() - 1])
		var exit := -1
		if r.one_way:
			exit = n - 1
		elif k + 1 < parts.size():
			var nxt := parts[k + 1]
			exit = r.nearest_index(nxt.points[0] if nxt.one_way or nxt.closed else nxt.points[nxt.nearest_index(
					r.points[entry if entry >= 0 else 0])])
		var dir := 1
		if r.closed:
			if entry < 0:
				dir = -1 if first_reversed else 1
				if k + 1 < parts.size() and parts[k + 1].one_way:  # Drive the carriageway the ramp leaves.
					dir = 1 if r.tangents[exit].dot(parts[k + 1].tangents[0]) >= 0.0 else -1
				entry = r.wrap_index(exit - dir * 150)
			else:
				dir = 1 if r.tangents[entry].dot(heading) >= 0.0 else -1
			if exit < 0:
				exit = r.wrap_index(entry + dir * 600)
		else:
			if entry < 0:
				entry = 0
			if exit < 0:
				exit = n - 1 if r.one_way or r.tangents[entry].dot(heading) >= 0.0 else 0
			dir = 1 if exit >= entry else -1
		var offset := 0.0
		if not r.one_way:
			var lanes := r.lane_offsets()
			offset = lanes[lanes.size() - 2]  # Outermost lane running along the road.
		var i := entry
		while true:
			pts.append(r.points[i] + r.right_at(i) * offset * dir)
			if i == exit:
				break
			i = r.wrap_index(i + dir)
		heading = r.tangents[exit] * dir
	route.points = pts
	route.distances.resize(pts.size())
	for j in pts.size():
		route.distances[j] = 0.0 if j == 0 else route.distances[j - 1] + pts[j].distance_to(pts[j - 1])
	route.length = route.distances[pts.size() - 1]
	route.step = route.length / maxf(pts.size() - 1, 1)
	route._compute_tangents()
	_max_target_kmh = 130.0
	print("Route %s: %.0f m" % [",".join(names), route.length])
	return route


func _physics_process(delta: float) -> void:
	_time += delta
	if _crash_mode:
		_crash_test_step(delta)
		return
	var road := _road
	var pos := _car.global_position
	var idx := road.nearest_index(pos)
	var speed := _car.speed
	var lookahead := clampi(int(6 + absf(speed) * 0.5), 6, 40)
	var ti := road.wrap_index(idx + lookahead)
	var target := road.points[ti] + road.right_at(ti) * _lane_offset
	var local := _car.global_transform.affine_inverse() * target
	var steer := clampf(atan2(local.x, -local.z) * 2.5, -1.0, 1.0)

	# Target speed from upcoming curvature.
	var t0 := road.tangents[idx]
	var t1 := road.tangents[road.wrap_index(idx + 30)]
	var bend := t0.angle_to(t1)
	var target_speed := lerpf(_max_target_kmh, 70.0, clampf(bend / 1.2, 0.0, 1.0)) / 3.6
	if _route:  # Right-angle turns at the ramp terminals: brake in time for the local curvature ahead.
		target_speed = _max_target_kmh / 3.6
		for ahead in range(0, 100, 4):
			var j := road.wrap_index(idx + ahead)
			var turn := road.tangents[road.wrap_index(j - 4)].angle_to(road.tangents[road.wrap_index(j + 4)])
			var radius := 8.0 * road.step / maxf(turn, 1e-3)
			var v_turn := sqrt(4.0 * radius)  # ~0.4 g of cornering.
			target_speed = minf(target_speed, sqrt(v_turn * v_turn + 2.0 * 5.0 * ahead * road.step))

	var throttle := 1.0 if speed < target_speed else 0.0
	var brake := 0.0 if speed < target_speed + 3.0 else 1.0
	var handbrake := false
	for i in (0 if _route else DRIFT_EVENTS.size()):
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

	var lane_point := road.points[idx] + road.right_at(idx) * _lane_offset
	var off_road := Vector2(lane_point.x - pos.x, lane_point.z - pos.z).length()
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
		if not _quiet:
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
	if _take_views():
		return
	if _time > 2.0:
		_frames += 1
		_min_fps = minf(_min_fps, 1.0 / maxf(delta, 1e-6))
	if _shots_dir.is_empty() or _shot_index >= SHOT_TIMES.size() or _time < SHOT_TIMES[_shot_index]:
		return
	var image := get_viewport().get_texture().get_image()
	if image:
		var path := "%s/shot_%d.png" % [_shots_dir, _shot_index]
		_save_image(image, path)
	_shot_index += 1


## Downscales to `_shot_width` (aspect ratio kept, never upscaled), saves as PNG and logs the path.
func _save_image(image: Image, path: String) -> void:
	if image.get_width() > _shot_width:
		image.resize(_shot_width, roundi(image.get_height() * float(_shot_width) / image.get_width()),
				Image.INTERPOLATE_LANCZOS)
	image.save_png(path)
	print("Saved ", path)


## Saves the `--view` stills (a few frames each so the renderer settles), pausing the drive meanwhile.
## Returns true while views are still being taken.
func _take_views() -> bool:
	if _views.is_empty() or _shots_dir.is_empty():
		return false
	var k := _view_frame / 8
	if k >= _views.size():
		_view_cam.queue_free()
		get_parent().get_node("ChaseCamera").make_current()
		_views.clear()
		get_tree().paused = false
		return false
	get_tree().paused = true
	if _view_cam == null:
		_view_cam = Camera3D.new()
		_view_cam.far = 12000.0
		_view_cam.fov = 60.0
		var env: Environment = get_parent().get_node("WorldEnvironment").environment.duplicate()
		env.fog_enabled = false  # Aerial stills are for checking the layout.
		_view_cam.environment = env
		get_parent().add_child(_view_cam)
	var v := _views[k]
	_view_cam.make_current()
	_view_cam.look_at_from_position(Vector3(v[0], v[1], v[2]), Vector3(v[3], v[4], v[5]))
	if _view_frame % 8 == 7:
		var image := get_viewport().get_texture().get_image()
		var path := "%s/view_%d.png" % [_shots_dir, k]
		_save_image(image, path)
	_view_frame += 1
	return true


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
		if not _quiet:
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


# --- Crash test ---------------------------------------------------------------------------------

func _setup_crash_test() -> void:
	_crash_mode = true
	_traffic = get_parent().get_node("Traffic") as TrafficManager
	_road = _world.highway
	# Straightest stretch of the highway: smallest heading change over +-120 m.
	var span := int(120.0 / _road.step)
	var best := INF
	for i in range(0, _road.points.size(), 5):
		var bend := _road.tangents[_road.wrap_index(i - span)].angle_to(_road.tangents[_road.wrap_index(i + span)])
		if bend < best:
			best = bend
			_ct_s0 = _road.distances[i] - 60.0
	for lane in _traffic.lanes:
		if lane.road == _road and lane.dir > 0.0:
			_ct_lanes.append(lane)
	_ct_lanes.sort_custom(func(a, b) -> bool: return absf(a.offset) < absf(b.offset))
	_traffic.player_crashed.connect(_on_player_crashed)
	print("Crash test on the highway at s=%.0f m (bend %.3f rad over 240 m)" % [_ct_s0, best])
	_next_crash_test()


func _next_crash_test() -> void:
	_end_crash_test()
	_ct_index += 1
	if _ct_index >= CRASH_TESTS.size():
		print("Crash test done")
		get_tree().quit()
		return
	var t: Dictionary = CRASH_TESTS[_ct_index]
	_ct_time = 0.0
	_ct_hit_time = -1.0
	_ct_car = null
	for car in _traffic.get_children():
		if car is TrafficCar and car.kind == t.kind:
			_ct_car = car
			break
	var lane = _ct_lanes[t.lane]
	_traffic.debug_clear(_road, _ct_s0, 260.0, [_ct_car])
	_traffic.debug_place(_ct_car, lane, _ct_s0 + t.ahead, t.speed)
	if t.has("slide"):
		_ct_car.begin_crash()
		var basis := Basis(Vector3.UP, deg_to_rad(float(t.get("yaw", 0.0)))) * _ct_car.global_basis
		var pos: Vector3 = _ct_car.global_position + _lane_right() * float(t.get("lat", 0.0))
		_ct_car.global_transform = Transform3D(basis, pos)
		var fwd := -basis.z
		_ct_car.heading = atan2(-fwd.x, -fwd.z)
		_ct_car.crash_vel = _lane_fwd() * t.slide
		_ct_car.hold_time = 3.0
		_ct_car.reset_physics_interpolation()
	elif t.has("lat"):
		_ct_car.global_position += _lane_right() * t.lat
	# Player
	var p_lane = _ct_lanes[t.p_lane]
	_lane_offset = p_lane.offset
	var smp: Array = _road.sample_at(_ct_s0)
	var tangent: Vector3 = smp[1]
	var right := Vector3(-tangent.z, 0.0, tangent.x)
	var basis := Basis(Vector3.UP, deg_to_rad(float(t.get("p_yaw", 0.0)))) * Basis.looking_at(tangent, Vector3.UP)
	_car.reset_to(Transform3D(basis, (smp[0] as Vector3) + right * p_lane.offset + Vector3.UP * 0.9))
	_car.linear_velocity = tangent * t.p_speed
	get_parent().get_node("ChaseCamera").snap()
	_ct_car_start = _ct_car.global_position
	_ct_stats = {"max_vy": 0.0, "min_up": 1.0, "max_yaw": 0.0, "car_max_yaw": 0.0, "car_max_air": 0.0, "car_max_disp": 0.0,
		"p_pre": Vector3.ZERO, "c_pre": Vector3.ZERO}
	print("--- crash test '%s': %s %.0f kg, player %.0f km/h, traffic %.0f km/h ---" % [
		t.name, TrafficCarMesh.Kind.keys()[t.kind], _ct_car.mass, t.p_speed * 3.6,
		(t.get("slide", t.speed) as float) * 3.6])


func _lane_fwd() -> Vector3:
	return _road.sample_at(_ct_s0)[1]


func _lane_right() -> Vector3:
	var t := _lane_fwd()
	return Vector3(-t.z, 0.0, t.x)


func _on_player_crashed(car: TrafficCar, closing: float) -> void:
	if _ct_hit_time < 0.0 and car == _ct_car:
		_ct_hit_time = _ct_time
		_ct_stats.closing = closing


func _crash_test_step(delta: float) -> void:
	var t: Dictionary = CRASH_TESTS[_ct_index]
	_ct_time += delta
	if _ct_hit_time < 0.0:
		_ct_stats.p_pre = _car.linear_velocity
		_ct_stats.c_pre = _ct_car.get_velocity()
	# Drive straight along the lane at the test speed until the hit, then let go of everything.
	var throttle := 0.0
	var steer := 0.0
	if _ct_hit_time < 0.0 and t.p_speed > 0.0:
		var target_offset: float = _ct_lanes[t.get("p_target_lane", t.p_lane)].offset
		var idx := _road.nearest_index(_car.global_position)
		var ti := _road.wrap_index(idx + 8)
		var target := _road.points[ti] + _road.right_at(ti) * target_offset
		var local := _car.global_transform.affine_inverse() * target
		steer = clampf(atan2(local.x, -local.z) * 2.5, -1.0, 1.0)
		throttle = 1.0 if _car.speed < t.p_speed else 0.0
	_car.input.throttle = throttle
	_car.input.brake = 0.0
	_car.input.steer = steer
	_car.input.handbrake = false
	if _ct_hit_time >= 0.0:
		_ct_stats.max_vy = maxf(_ct_stats.max_vy, absf(_car.linear_velocity.y))
		_ct_stats.min_up = minf(_ct_stats.min_up, _car.global_basis.y.y)
		_ct_stats.max_yaw = maxf(_ct_stats.max_yaw, absf(_car.angular_velocity.y))
		_ct_stats.car_max_yaw = maxf(_ct_stats.car_max_yaw, absf(_ct_car.get_yaw_rate()))
		_ct_stats.car_max_air = maxf(_ct_stats.car_max_air, _ct_car.air)
		var rel := _ct_time - _ct_hit_time
		if not _quiet and rel < 1.5 and fmod(rel + 1e-4, 0.25) < delta:
			print("  +%.2fs player %5.1f km/h yaw %5.2f | %s %5.1f km/h yaw %5.2f state=%s" % [
				rel, _car.linear_velocity.length() * 3.6, _car.angular_velocity.y,
				TrafficCarMesh.Kind.keys()[_ct_car.kind], _ct_car.get_velocity().length() * 3.6,
				_ct_car.get_yaw_rate(), TrafficCar.State.keys()[_ct_car.state]])
	if _ct_time > CRASH_TEST_TIME:
		_next_crash_test()


func _end_crash_test() -> void:
	if _ct_index < 0:
		return
	var t: Dictionary = CRASH_TESTS[_ct_index]
	if _ct_hit_time < 0.0:
		print("Crash test '%s': NO IMPACT" % t.name)
		return
	var p_pre: Vector3 = _ct_stats.p_pre
	var c_pre: Vector3 = _ct_stats.c_pre
	var fwd := _lane_fwd()
	print(("Crash test '%s': closing %.1f km/h | player along lane %.1f -> %.1f km/h now, peak yaw %.2f rad/s, " +
		"max |vy| %.2f m/s, min up.y %.2f | traffic along lane %.1f km/h before, peak yaw %.2f rad/s, " +
		"peak air %.1f m, moved %.1f m, state %s") % [
		t.name, _ct_stats.closing * 3.6, p_pre.dot(fwd) * 3.6, _car.linear_velocity.dot(fwd) * 3.6,
		_ct_stats.max_yaw, _ct_stats.max_vy, _ct_stats.min_up, c_pre.dot(fwd) * 3.6, _ct_stats.car_max_yaw,
		_ct_stats.car_max_air,
		_ct_car.global_position.distance_to(_ct_car_start), TrafficCar.State.keys()[_ct_car.state]])
