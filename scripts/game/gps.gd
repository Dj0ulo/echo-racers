class_name Gps
extends Node3D
## Destination and route guidance. A destination set on the WorldMap gets a gold light beam in the world and a
## marker on the minimaps. The route (rerouted every `reroute_interval`) always starts at the car: it crosses
## the fields to the road network (RoadGraph) where that pays off, follows it, and leaves it again across
## country when the destination is off-road, or skips the roads entirely when going straight is shorter
## (off-road metres cost `offroad_cost`). It is drawn on the minimap and as a glowing filament that rises
## from the car into the sky and flies loosely above the route (smoothed, cutting the bends) toward the
## destination. The filament and minimap route are hidden outside free roam (echo races, recording, editor).

const COLOR := Color(1.0, 0.72, 0.22)

const _FILAMENT_CODE := """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;
uniform vec4 color : source_color = vec4(1.0, 0.72, 0.22, 1.0);
uniform float energy = 2.2;
void fragment() {
	float across = 1.0 - abs(UV.y * 2.0 - 1.0);
	float core = smoothstep(0.3, 0.7, across);
	float halo = pow(across, 1.5);
	float pulse = 0.75 + 0.25 * pow(0.5 + 0.5 * sin(UV.x * 0.22 - TIME * 8.0), 6.0);
	ALBEDO = mix(color.rgb * energy, vec3(1.0, 0.93, 0.6) * energy, smoothstep(0.8, 0.97, across)) * pulse;
	ALPHA = clamp(core + halo * 0.6, 0.0, 1.0) * COLOR.a;
}
"""

@export var filament_lift := 7.0       ## Cruising height above the ground (m), well above the chase camera.
@export var filament_start_lift := 1.4 ## Height at the car, where it starts (m).
@export var filament_rise := 35.0      ## Metres over which it climbs from the car to `filament_lift`.
@export var filament_width := 1.0      ## Half-width of its glow (m); the bright core is a fraction of it.
@export var filament_length := 300.0   ## Metres of route drawn ahead of the car.
@export var filament_smooth := 12      ## Half-window (in 2 m samples) of the smoothing that cuts the road's bends.
@export var filament_wave := 0.35      ## Amplitude of its slow vertical wave (m).
@export var offroad_cost := 1.6        ## An off-road metre costs this many road metres when choosing the route.
@export var arrive_radius := 28.0      ## Destination reached within this horizontal distance (m).
@export var reroute_interval := 0.8    ## Seconds between route updates while driving.
@export var beam_height := 220.0

var has_destination := false
var destination := Vector3.ZERO
var route := PackedVector3Array()          ## Route points on the ground (unlifted), from the car.
var route_length := 0.0                    ## Metres along `route`.

var _car: CarController
var _world: WorldGenerator
var _minimap: Minimap
var _echo: EchoManager
var _graph: RoadGraph
var _route_dist := PackedFloat32Array()
var _reroute := 0.0
var _beacon: Node3D
var _filament: MeshInstance3D
var _mesh := ArrayMesh.new()
var _near_i := 0


func setup(world: WorldGenerator, car: CarController, minimap: Minimap, echo: EchoManager) -> void:
	_world = world
	_car = car
	_minimap = minimap
	_echo = echo
	_filament = MeshInstance3D.new()
	_filament.mesh = _mesh
	_filament.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_filament.extra_cull_margin = 16384.0
	var mat := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = _FILAMENT_CODE
	mat.shader = shader
	mat.set_shader_parameter(&"color", COLOR)
	_filament.material_override = mat
	add_child(_filament)
	_beacon = _build_beacon()
	_beacon.visible = false
	add_child(_beacon)


func set_destination(p: Vector3) -> void:
	if _graph == null:
		var t := Time.get_ticks_msec()
		_graph = RoadGraph.new()
		_graph.build(_world.roads)
		print("GPS road graph built in %d ms" % (Time.get_ticks_msec() - t))
	has_destination = true
	destination = p
	_beacon.global_position = p
	_beacon.visible = true
	_minimap.destination = p
	_minimap.destination_active = true
	reroute()


func clear_destination() -> void:
	has_destination = false
	route = PackedVector3Array()
	route_length = 0.0
	_beacon.visible = false
	_filament.visible = false
	_minimap.destination_active = false
	_minimap.route = PackedVector3Array()


func reroute() -> void:
	_reroute = reroute_interval
	if not has_destination:
		return
	var car_pos := _car.global_position
	var road := _graph.find_route(car_pos, -_car.global_basis.z, destination)
	if road.size() >= 2:
		road = _smooth(road)
	# Pick where to join (i) and leave (j) the road route: minimise off-road legs (weighted) + road between.
	var dist := PackedFloat32Array()
	dist.resize(road.size())
	for k in range(1, road.size()):
		dist[k] = dist[k - 1] + road[k - 1].distance_to(road[k])
	var best := offroad_cost * _flat(car_pos, destination)
	var bi := -1
	var bj := -1
	var join_best := INF
	var join_i := -1
	for k in road.size():
		var join := offroad_cost * _flat(car_pos, road[k]) - dist[k]
		if join < join_best:
			join_best = join
			join_i = k
		var total := join_best + dist[k] + offroad_cost * _flat(road[k], destination)
		if total < best - 1.0:
			best = total
			bi = join_i
			bj = k
	route = PackedVector3Array([car_pos])
	if bi < 0:
		_append_offroad(destination)
	else:
		_append_offroad(road[bi])
		for k in range(bi + 1, bj + 1):
			route.append(road[k])
		_append_offroad(destination)
	_route_dist = PackedFloat32Array([0.0])
	for i in range(1, route.size()):
		_route_dist.append(_route_dist[i - 1] + route[i - 1].distance_to(route[i]))
	route_length = _route_dist[_route_dist.size() - 1]
	_near_i = 0


func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


## Straight leg across country from the last route point to `p`, following the terrain every ~8 m.
func _append_offroad(p: Vector3) -> void:
	var a := route[route.size() - 1]
	var n := int(_flat(a, p) / 8.0)
	for k in range(1, n):
		var q := a.lerp(p, float(k) / n)
		q.y = maxf(_world.terrain.get_height(q.x, q.z), minf(a.y, p.y))
		route.append(q)
	if _flat(a, p) > 0.5:
		route.append(p)


func _process(delta: float) -> void:
	if not has_destination:
		return
	var free := _echo == null or _echo.state == EchoManager.State.FREE
	var car_pos := _car.global_position
	if free and Vector2(car_pos.x - destination.x, car_pos.z - destination.z).length() < arrive_radius:
		clear_destination()
		if _echo:
			_echo.ui.toast("Destination reached")
		return
	_reroute -= delta
	if _reroute <= 0.0:
		reroute()
	_beacon.visible = free
	_minimap.route = route if free else PackedVector3Array()
	_filament.visible = free and route.size() >= 2
	if _filament.visible:
		_build_filament()


## Chaikin corner cutting (2 passes) so the 8 m graph nodes make a smooth line.
func _smooth(pts: PackedVector3Array) -> PackedVector3Array:
	for _pass in 2:
		if pts.size() < 3:
			return pts
		var out := PackedVector3Array([pts[0]])
		for i in pts.size() - 1:
			out.append(pts[i].lerp(pts[i + 1], 0.25))
			out.append(pts[i].lerp(pts[i + 1], 0.75))
		out.append(pts[pts.size() - 1])
		pts = out
	return pts


func _build_filament() -> void:
	_mesh.clear_surfaces()
	var car_pos := _car.global_position
	# Closest route point to the car, searched in a window ahead of the previous one.
	var best_d := INF
	var lo := maxi(_near_i - 4, 0)
	var hi := mini(_near_i + 60, route.size() - 1)
	for i in range(lo, hi + 1):
		var d := route[i].distance_squared_to(car_pos)
		if d < best_d:
			best_d = d
			_near_i = i
	# Ground line: the car itself, then the route from just past the nearest point, every 2 m.
	var ground := PackedVector3Array([car_pos])
	var s := _route_dist[_near_i] + 3.0
	var s1 := minf(s + filament_length, route_length)
	var i := _near_i
	while s < s1:
		while i < route.size() - 2 and _route_dist[i + 1] < s:
			i += 1
		var seg := maxf(_route_dist[i + 1] - _route_dist[i], 0.001)
		ground.append(route[i].lerp(route[i + 1], clampf((s - _route_dist[i]) / seg, 0.0, 1.0)))
		s += 2.0
	ground.append(route[route.size() - 1] if s1 >= route_length - 0.5 else _sample(s1))
	var n := ground.size()
	if n < 3:
		return
	# Merge from the car into the route (other lane, off to the side) over `filament_rise` metres.
	var offset := car_pos - ground[1]
	offset.y = 0.0
	for k in range(1, n):
		ground[k] += offset * (1.0 - smoothstep(0.0, filament_rise, 2.0 * k))
	# Smooth (window shrinking at both ends so it still starts at the car and ends on the route), then lift.
	var t := Time.get_ticks_msec() * 0.001
	var centre := PackedVector3Array()
	var along := PackedFloat32Array()
	var a := 0.0
	for k in n:
		var w := mini(filament_smooth, mini(k, n - 1 - k))
		var sum := Vector3.ZERO
		var top := -INF
		for m in range(k - w, k + w + 1):
			sum += ground[m]
			top = maxf(top, ground[m].y)
		var p := sum / (2 * w + 1)
		p.y = maxf(p.y, top - 2.0)
		if k > 0:
			a += Vector2(p.x - centre[k - 1].x, p.z - centre[k - 1].z).length()
		var rise := smoothstep(0.0, filament_rise, a)
		p.y += lerpf(filament_start_lift, filament_lift + filament_wave * sin(a * 0.06 - t * 1.6), rise)
		centre.append(p)
		along.append(a)
	var total := along[n - 1]
	var to_end := s1 >= route_length - 0.5
	var u0 := _route_dist[_near_i]  # Pulses keep flowing along the route, not with the car.
	var cam := get_viewport().get_camera_3d()
	var eye := cam.global_position if cam else car_pos + Vector3.UP * 5.0
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	for k in n:
		var p := centre[k]
		var tangent := (centre[mini(k + 1, n - 1)] - centre[maxi(k - 1, 0)]).normalized()
		var side := tangent.cross(eye - p).normalized() * filament_width
		var u := along[k]
		var fade := smoothstep(0.0, 10.0, u) * 0.85 + 0.15 * smoothstep(0.0, 2.0, u)
		if not to_end:
			fade *= 1.0 - smoothstep(total - 60.0, total, u)
		var col := Color(1, 1, 1, fade)
		verts.append_array([p - side, p + side])
		uvs.append_array([Vector2(u0 + u, 0.0), Vector2(u0 + u, 1.0)])
		cols.append_array([col, col])
	var idx := PackedInt32Array()
	for k in n - 1:
		var b := k * 2
		idx.append_array([b, b + 1, b + 2, b + 1, b + 3, b + 2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)


func _sample(s: float) -> Vector3:
	var i := clampi(_route_dist.bsearch(s) - 1, 0, route.size() - 2)
	var seg := maxf(_route_dist[i + 1] - _route_dist[i], 0.001)
	return route[i].lerp(route[i + 1], clampf((s - _route_dist[i]) / seg, 0.0, 1.0))


func _build_beacon() -> Node3D:
	var root := Node3D.new()
	root.name = "DestinationBeacon"
	var beam := CylinderMesh.new()
	beam.top_radius = 3.0
	beam.bottom_radius = 3.0
	beam.height = beam_height
	beam.cap_top = false
	beam.cap_bottom = false
	beam.radial_segments = 24
	beam.rings = 1
	var mi := MeshInstance3D.new()
	mi.mesh = beam
	mi.material_override = Neon.beam_material(COLOR, beam_height, 1.8, 10.0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position.y = beam_height * 0.5
	root.add_child(mi)
	for r: float in [arrive_radius * 0.5, arrive_radius * 0.25]:
		var torus := TorusMesh.new()
		torus.inner_radius = r - 0.25
		torus.outer_radius = r + 0.25
		torus.rings = 64
		torus.ring_segments = 6
		var ring := MeshInstance3D.new()
		ring.mesh = torus
		ring.material_override = Neon.glow_material(COLOR, 2.4)
		ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		ring.position.y = 0.4
		root.add_child(ring)
	return root
