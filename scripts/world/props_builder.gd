class_name PropsBuilder
extends RefCounted
## Roadside objects and landmarks: marker posts, fences, highway guard rails and median barrier,
## farms, hay bales, wind turbines, clouds.

const MARKER_SPACING := 12   ## In road samples (2 m each).
const RAIL_SPACING := 3      ## Highway guard rail / barrier section length, in road samples.


## Appends the areas it occupies to `clear_zones`. Returns the turbine rotors so they can be animated.
static func build(parent: Node3D, terrain: TerrainData, roads: Array[RoadPath], clear_zones: Array[Vector3], world_seed: int) -> Array[Node3D]:
	var root := Node3D.new()
	root.name = "Props"
	parent.add_child(root)
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed * 13 + 3
	var body := StaticBody3D.new()
	body.name = "PropColliders"
	body.set_meta(&"surface", &"grass")
	root.add_child(body)
	var rails := Node3D.new()
	rails.name = "RailColliders"
	rails.set_meta(&"surface", &"road")
	root.add_child(rails)
	var rail_colliders := ColliderBatch.new(250.0)

	var markers: Array[Transform3D] = []
	var fences: Array[Transform3D] = []
	var rail_xforms: Array[Transform3D] = []
	var barrier_xforms: Array[Transform3D] = []
	var ramps: Array[RoadPath] = []
	for road in roads:
		if road.one_way:
			ramps.append(road)
	for road in roads:
		if road.is_highway:
			_build_guard_rails(terrain, road, ramps, rail_xforms, barrier_xforms, rail_colliders)
		else:
			_build_marker_posts(terrain, road, markers)
			if not road.one_way:
				_build_fences(body, terrain, road, rng, fences)
	_add_multimesh(root, SceneryMeshes.marker_post(), markers, true)
	_add_multimesh(root, SceneryMeshes.fence_section(), fences, true)
	_add_multimesh(root, SceneryMeshes.guard_rail_section(), rail_xforms, true)
	_add_multimesh(root, SceneryMeshes.median_barrier_section(), barrier_xforms, true)
	rail_colliders.commit(rails)

	_build_farms(root, body, terrain, roads, clear_zones)
	_build_hay_fields(root, body, terrain, clear_zones, rng)
	_build_clouds(root, rng)
	return _build_turbines(root, terrain, clear_zones)


static func _build_marker_posts(terrain: TerrainData, road: RoadPath, xforms: Array[Transform3D]) -> void:
	for i in range(0, road.sample_count(), MARKER_SPACING):
		if road.is_bridge(i):
			continue
		for side: float in [-1.0, 1.0]:
			var p := road.points[i] + road.right_at(i) * side * (road.half_width + 1.1)
			# Skip posts that would land on (or right next to) another road.
			if terrain.get_road_distance(p.x, p.z) < 0.8:
				continue
			var basis := Basis.looking_at(road.tangents[i], Vector3.UP)
			xforms.append(Transform3D(basis, Vector3(p.x, terrain.get_height(p.x, p.z) - 0.05, p.z)))


## Guard rails along both outer edges (with gaps where interchange ramps leave or join the highway) and a
## continuous concrete barrier on the median.
static func _build_guard_rails(terrain: TerrainData, road: RoadPath, ramps: Array[RoadPath],
		rail_xforms: Array[Transform3D], barrier_xforms: Array[Transform3D], colliders: ColliderBatch) -> void:
	var n := road.sample_count()
	for s in range(0, n, RAIL_SPACING):
		var e := (s + RAIL_SPACING) % n
		var a := road.points[s]
		var b := road.points[e]
		for side: float in [-1.0, 1.0]:
			var offset := road.half_width + 0.5
			var pa := a + road.right_at(s) * side * offset
			var pb := b + road.right_at(e) * side * offset
			if _near_ramp(pa, ramps, 1.5) or _near_ramp(pb, ramps, 1.5):
				continue
			# Follow the verge, but never climb an embankment (e.g. against a bridge abutment).
			pa.y = clampf(terrain.get_height(pa.x, pa.z), a.y - 0.2, a.y + 0.4)
			pb.y = clampf(terrain.get_height(pb.x, pb.z), b.y - 0.2, b.y + 0.4)
			var span := pb - pa
			var basis := Basis.looking_at(span, Vector3.UP)
			# The beam is modelled on the section's left (-X): run left-hand rails backwards so it faces the road.
			var rail := Transform3D(basis.scaled_local(Vector3(1.0, 1.0, span.length())), pa)
			if side < 0.0:
				rail = Transform3D(Basis.looking_at(-span, Vector3.UP).scaled_local(Vector3(1.0, 1.0, span.length())), pb)
			rail_xforms.append(rail)
			colliders.add_box((pa + pb) * 0.5 + Vector3.UP * 0.55, basis, Vector3(0.25, 1.1, span.length() + 0.05))
		var m_span := b - a
		var m_basis := Basis.looking_at(m_span, Vector3.UP)
		barrier_xforms.append(Transform3D(m_basis.scaled_local(Vector3(1.0, 1.0, m_span.length())), a + Vector3.DOWN * 0.02))
		colliders.add_box((a + b) * 0.5 + Vector3.UP * 0.42, m_basis, Vector3(0.5, 0.85, m_span.length() + 0.05))


## True if `p` is within `margin` of a ramp's asphalt (horizontally, and not far below or above it).
static func _near_ramp(p: Vector3, ramps: Array[RoadPath], margin: float) -> bool:
	for ramp in ramps:
		var reach := ramp.half_width + margin
		var pts := ramp.points
		# Cheap rejection against the ramp's ends and middle before the per-sample test.
		var mid := pts[pts.size() / 2]
		if Vector2(p.x - mid.x, p.z - mid.z).length() > ramp.length * 0.5 + reach + 20.0:
			continue
		for i in range(0, pts.size(), 2):
			var q := pts[i]
			if Vector2(p.x - q.x, p.z - q.z).length_squared() < reach * reach and absf(p.y - q.y) < 2.0:
				return true
	return false


static func _build_fences(body: StaticBody3D, terrain: TerrainData, road: RoadPath, rng: RandomNumberGenerator,
		xforms: Array[Transform3D]) -> void:
	var n := road.sample_count()
	var count := maxi(int(road.length / 340.0), 1)
	for k in count:
		var side := 1.0 if k % 2 == 0 else -1.0
		var offset := road.half_width + 5.5
		var first := int((k + rng.randf_range(0.1, 0.6)) / count * n)
		var prev := Vector3.INF
		for s in range(first, first + 70, 2):
			if not road.closed and s >= n:
				break
			var i := s % n
			var p := road.points[i] + road.right_at(i) * side * offset
			if terrain.get_road_distance(p.x, p.z) < 5.0 or road.is_bridge(i):
				prev = Vector3.INF
				continue
			p.y = terrain.get_height(p.x, p.z)
			if prev != Vector3.INF:
				var span := p - prev
				var basis := Basis.looking_at(span, Vector3.UP)
				basis = basis.scaled_local(Vector3(1.0, 1.0, span.length()))
				xforms.append(Transform3D(basis, prev))
				var shape := CollisionShape3D.new()
				var box := BoxShape3D.new()
				box.size = Vector3(0.2, 1.2, span.length())
				shape.shape = box
				shape.transform = Transform3D(Basis.looking_at(span, Vector3.UP), (prev + p) * 0.5 + Vector3.UP * 0.6)
				body.add_child(shape)
			prev = p


static func _build_farms(root: Node3D, body: StaticBody3D, terrain: TerrainData, roads: Array[RoadPath],
		clear_zones: Array[Vector3]) -> void:
	for road in roads:
		if road.is_highway or road.one_way:
			continue
		var sites := [[0.2, 1.0], [0.47, -1.0], [0.8, 1.0]] if road.closed else [[0.35, 1.0], [0.7, -1.0]]
		var n := road.sample_count()
		for site in sites:
			var placed := false
			for attempt in 40:
				var i := (int(site[0] * n) + attempt * 3) % n
				var side: float = site[1]
				var center := road.points[i] + road.right_at(i) * side * (road.half_width + 22.0)
				if terrain.get_road_distance(center.x, center.z) < 18.0:
					continue
				if terrain.get_normal(center.x, center.z, 6.0).y < 0.93:
					continue
				if VegetationBuilder._in_clear_zone(center.x, center.z, clear_zones):
					continue
				_place_farm(root, body, terrain, center, road.points[i], clear_zones)
				placed = true
				break
			if not placed:
				push_warning("PropsBuilder: no flat site found for a farm on %s near %.2f" % [road.name, site[0]])


static func _place_farm(root: Node3D, body: StaticBody3D, terrain: TerrainData, center: Vector3, face_target: Vector3,
		clear_zones: Array[Vector3]) -> void:
	var width := 8.0
	var depth := 11.0
	var to_road := Vector3(face_target.x - center.x, 0.0, face_target.z - center.z).normalized()
	var basis := Basis.looking_at(to_road, Vector3.UP)
	var lowest := INF
	var highest := -INF
	for corner in [Vector3(-1, 0, -1), Vector3(1, 0, -1), Vector3(-1, 0, 1), Vector3(1, 0, 1)]:
		var p: Vector3 = center + basis * Vector3(corner.x * width * 0.5, 0.0, corner.z * depth * 0.5)
		var h := terrain.get_height(p.x, p.z)
		lowest = minf(lowest, h)
		highest = maxf(highest, h)
	var base_y := lowest - 0.3
	var wall_height := 5.5 + (highest - lowest)
	var barn := MeshInstance3D.new()
	barn.name = "Barn"
	barn.mesh = SceneryMeshes.barn(width, depth, wall_height)
	barn.transform = Transform3D(basis, Vector3(center.x, base_y, center.z))
	root.add_child(barn)
	_add_box_collider(body, barn.transform * Vector3(0, wall_height * 0.5 + 1.0, 0), basis,
			Vector3(width, wall_height + 2.0, depth))

	var silo_pos := center + basis * Vector3(width * 0.5 + 3.2, 0.0, 2.5)
	var silo_y := terrain.get_height(silo_pos.x, silo_pos.z) - 0.5
	var silo := MeshInstance3D.new()
	silo.name = "Silo"
	silo.mesh = SceneryMeshes.silo(2.0, 12.0)
	silo.position = Vector3(silo_pos.x, silo_y, silo_pos.z)
	root.add_child(silo)
	var cyl := CylinderShape3D.new()
	cyl.radius = 2.0
	cyl.height = 13.0
	var shape := CollisionShape3D.new()
	shape.shape = cyl
	shape.position = silo.position + Vector3.UP * 6.5
	body.add_child(shape)

	clear_zones.append(Vector3(center.x, center.z, 14.0))


static func _build_hay_fields(root: Node3D, body: StaticBody3D, terrain: TerrainData,
		clear_zones: Array[Vector3], rng: RandomNumberGenerator) -> void:
	var xforms: Array[Transform3D] = []
	var bale_shape := CylinderShape3D.new()
	bale_shape.radius = 0.75
	bale_shape.height = 1.3
	var fields := 0
	var limit := TerrainData.MOUNTAIN_START - 100.0  # Fields stay in the lowlands.
	for _attempt in 8000:
		if fields >= 60:
			break
		var cx := rng.randf_range(-limit, limit)
		var cz := rng.randf_range(-limit, limit)
		# Fields sit near (but off) the roads, where they can be seen.
		var rd := terrain.get_road_distance(cx, cz)
		if rd < 10.0 or (rd > 1e6 and rng.randf() < 0.7):
			continue
		if terrain.forest_density(cx, cz) > -0.05 or terrain.get_normal(cx, cz, 8.0).y < 0.95:
			continue
		if VegetationBuilder._in_clear_zone(cx, cz, clear_zones):
			continue
		fields += 1
		clear_zones.append(Vector3(cx, cz, 18.0))
		for _b in rng.randi_range(4, 9):
			var x := cx + rng.randf_range(-14.0, 14.0)
			var z := cz + rng.randf_range(-14.0, 14.0)
			if terrain.get_road_distance(x, z) < 6.0:
				continue
			var n := terrain.get_normal(x, z)
			var yaw := Basis(Vector3.UP, rng.randf() * TAU)
			var basis := Basis(Quaternion(Vector3.UP, n)) * yaw
			var pos := Vector3(x, terrain.get_height(x, z) - 0.05, z)
			xforms.append(Transform3D(basis, pos))
			var shape := CollisionShape3D.new()
			shape.shape = bale_shape
			shape.transform = Transform3D(basis * Basis(Vector3.BACK, PI * 0.5), pos + n * 0.75)
			body.add_child(shape)
	_add_multimesh(root, SceneryMeshes.hay_bale(), xforms, true)


## Two wind farms on open ground between the country loop and the highway.
static func _build_turbines(root: Node3D, terrain: TerrainData, clear_zones: Array[Vector3]) -> Array[Node3D]:
	var rotors: Array[Node3D] = []
	var tower_mesh := SceneryMeshes.turbine_tower(48.0)
	var rotor_mesh := SceneryMeshes.turbine_rotor(21.0)
	var wind := Basis(Vector3.UP, deg_to_rad(35.0))
	var spots: Array[Vector2] = []
	for n in 5:
		spots.append(Vector2(-560.0 + n * 115.0, -470.0 + (n % 2) * 60.0))
	for n in 4:
		spots.append(Vector2(420.0 + (n % 2) * 70.0, 330.0 + n * 120.0))
	for k in spots.size():
		var spot := spots[k]
		var x := spot.x
		var z := spot.y
		# Nudge off any road.
		for _try in 12:
			if terrain.get_road_distance(x, z) > 30.0:
				break
			x += 25.0
		var y := terrain.get_height(x, z) - 1.0
		var tower := MeshInstance3D.new()
		tower.name = "WindTurbine%d" % k
		tower.mesh = tower_mesh
		tower.transform = Transform3D(wind, Vector3(x, y, z))
		root.add_child(tower)
		var rotor := MeshInstance3D.new()
		rotor.name = "Rotor"
		rotor.mesh = rotor_mesh
		rotor.position = Vector3(0.0, 48.9, -1.9)
		rotor.rotation.z = k * 0.9
		tower.add_child(rotor)
		rotors.append(rotor)
		clear_zones.append(Vector3(x, z, 6.0))
	return rotors


static func _build_clouds(root: Node3D, rng: RandomNumberGenerator) -> void:
	var mb := MeshBuilder.new()
	for _k in 120:
		var angle := rng.randf() * TAU
		var radius := rng.randf_range(150.0, 5200.0)
		SceneryMeshes.cloud(rng, Vector3(cos(angle) * radius, rng.randf_range(300.0, 420.0), sin(angle) * radius), mb)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	mat.emission_enabled = true
	mat.emission = Color(0.55, 0.6, 0.68)
	mat.emission_energy_multiplier = 0.6
	mat.disable_receive_shadows = true
	var clouds := MeshInstance3D.new()
	clouds.name = "Clouds"
	clouds.mesh = mb.commit(mat)
	clouds.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(clouds)


static func _add_box_collider(body: StaticBody3D, center: Vector3, basis: Basis, size: Vector3) -> void:
	var box := BoxShape3D.new()
	box.size = size
	var shape := CollisionShape3D.new()
	shape.shape = box
	shape.transform = Transform3D(basis, center)
	body.add_child(shape)


static func _add_multimesh(root: Node3D, mesh: Mesh, xforms: Array[Transform3D], cast_shadows: bool) -> void:
	if xforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mmi)
