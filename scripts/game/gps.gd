class_name Gps
extends Node3D
## Destination and route guidance. A destination set on the WorldMap gets a gold light beam in the world and a
## marker on the minimaps; the route along the road network (RoadGraph, rerouted every `reroute_interval`)
## is drawn on the minimap and as a glowing filament floating ahead of the car, flowing toward the
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

@export var filament_lift := 0.85      ## Height above the road (m); keep it well under the chase camera.
@export var filament_width := 0.8      ## Half-width of its glow (m); the bright core is a fraction of it.
@export var filament_start := 6.0      ## Metres ahead of the car where it begins (fades in).
@export var filament_length := 240.0   ## Metres of route drawn ahead of the car.
@export var filament_wave := 0.12      ## Amplitude of its slow vertical wave (m).
@export var arrive_radius := 28.0      ## Destination reached within this horizontal distance (m).
@export var reroute_interval := 0.8    ## Seconds between route updates while driving.
@export var beam_height := 220.0

var has_destination := false
var destination := Vector3.ZERO
var route := PackedVector3Array()          ## Route points on the road (unlifted), car side first.
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
	var nodes := _graph.find_route(_car.global_position, -_car.global_basis.z, destination)
	route = PackedVector3Array()
	if nodes.is_empty():
		route.append(_car.global_position)
	else:
		route = _smooth(nodes)
	var end := route[route.size() - 1]
	if Vector2(end.x - destination.x, end.z - destination.z).length() > 12.0:
		route.append(destination)  # Off-road destination: last leg straight across the fields.
	_route_dist = PackedFloat32Array([0.0])
	for i in range(1, route.size()):
		_route_dist.append(_route_dist[i - 1] + route[i - 1].distance_to(route[i]))
	route_length = _route_dist[_route_dist.size() - 1]
	_near_i = 0


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
	var s0 := _route_dist[_near_i] + filament_start
	var s1 := minf(s0 + filament_length, route_length)
	if s1 - s0 < 2.0:
		return
	var cam := get_viewport().get_camera_3d()
	var eye := cam.global_position if cam else car_pos + Vector3.UP * 5.0
	var t := Time.get_ticks_msec() * 0.001
	var centre := PackedVector3Array()
	var along := PackedFloat32Array()
	var s := s0
	var i := _near_i
	while true:
		while i < route.size() - 2 and _route_dist[i + 1] < s:
			i += 1
		var seg := maxf(_route_dist[i + 1] - _route_dist[i], 0.001)
		var p := route[i].lerp(route[i + 1], clampf((s - _route_dist[i]) / seg, 0.0, 1.0))
		p.y += filament_lift + filament_wave * sin(s * 0.09 - t * 2.2)
		centre.append(p)
		along.append(s)
		if s >= s1:
			break
		s = minf(s + 2.0, s1)
	if centre.size() < 2:
		return
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var n := centre.size()
	for k in n:
		var p := centre[k]
		var tangent := (centre[mini(k + 1, n - 1)] - centre[maxi(k - 1, 0)]).normalized()
		var side := tangent.cross(eye - p).normalized() * filament_width
		var a := along[k]
		var fade := smoothstep(s0, s0 + 12.0, a) * (1.0 - smoothstep(s1 - 50.0, s1, a))
		if s1 >= route_length - 0.5:
			fade = smoothstep(s0, s0 + 12.0, a)  # Runs all the way to the destination.
		var col := Color(1, 1, 1, fade)
		verts.append_array([p - side, p + side])
		uvs.append_array([Vector2(a, 0.0), Vector2(a, 1.0)])
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
