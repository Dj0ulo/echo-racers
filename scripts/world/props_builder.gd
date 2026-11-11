class_name PropsBuilder
extends RefCounted
## Roadside objects and landmarks: marker posts, fences, farms, hay bales, wind turbines, clouds.

const MARKER_SPACING := 12   ## In road samples (2 m each).


## Appends the areas it occupies to `clear_zones`. Returns the turbine rotors so they can be animated.
static func build(parent: Node3D, terrain: TerrainData, road: RoadPath, clear_zones: Array[Vector3], world_seed: int) -> Array[Node3D]:
	var root := Node3D.new()
	root.name = "Props"
	parent.add_child(root)
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed * 13 + 3
	var body := StaticBody3D.new()
	body.name = "PropColliders"
	body.set_meta(&"surface", &"grass")
	root.add_child(body)

	_build_marker_posts(root, terrain, road)
	_build_farms(root, body, terrain, road, clear_zones)
	_build_fences(root, body, terrain, road)
	_build_hay_fields(root, body, terrain, road, clear_zones, rng)
	_build_clouds(root, rng)
	return _build_turbines(root, terrain)


static func _build_marker_posts(root: Node3D, terrain: TerrainData, road: RoadPath) -> void:
	var xforms: Array[Transform3D] = []
	for i in range(0, road.sample_count(), MARKER_SPACING):
		for side: float in [-1.0, 1.0]:
			var p := road.points[i] + road.right_at(i) * side * (road.half_width + 1.1)
			# Skip posts that would land on another part of the road.
			if terrain.get_road_distance(p.x, p.z) < road.half_width + 0.8:
				continue
			var basis := Basis.looking_at(road.tangents[i], Vector3.UP)
			xforms.append(Transform3D(basis, Vector3(p.x, terrain.get_height(p.x, p.z) - 0.05, p.z)))
	_add_multimesh(root, SceneryMeshes.marker_post(), xforms, true)


static func _build_fences(root: Node3D, body: StaticBody3D, terrain: TerrainData, road: RoadPath) -> void:
	var xforms: Array[Transform3D] = []
	var n := road.sample_count()
	var starts := [0.08, 0.3, 0.55, 0.72, 0.9]
	for k in starts.size():
		var side := 1.0 if k % 2 == 0 else -1.0
		var offset := road.half_width + 5.5
		var first := int(starts[k] * n)
		var prev := Vector3.INF
		for s in range(first, first + 70, 2):
			var i := s % n
			var p := road.points[i] + road.right_at(i) * side * offset
			if terrain.get_road_distance(p.x, p.z) < offset - 0.5:
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
	_add_multimesh(root, SceneryMeshes.fence_section(), xforms, true)


static func _build_farms(root: Node3D, body: StaticBody3D, terrain: TerrainData, road: RoadPath, clear_zones: Array[Vector3]) -> void:
	var n := road.sample_count()
	var sites := [[0.2, 1.0], [0.47, -1.0], [0.8, 1.0]]
	for site in sites:
		var placed := false
		for attempt in 40:
			var i := (int(site[0] * n) + attempt * 3) % n
			var side: float = site[1]
			var center := road.points[i] + road.right_at(i) * side * (road.half_width + 22.0)
			if terrain.get_road_distance(center.x, center.z) < road.half_width + 18.0:
				continue
			if terrain.get_normal(center.x, center.z, 6.0).y < 0.93:
				continue
			_place_farm(root, body, terrain, center, road.points[i], clear_zones)
			placed = true
			break
		if not placed:
			push_warning("PropsBuilder: no flat site found for a farm near %.2f" % site[0])


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


static func _build_hay_fields(root: Node3D, body: StaticBody3D, terrain: TerrainData, road: RoadPath,
		clear_zones: Array[Vector3], rng: RandomNumberGenerator) -> void:
	var xforms: Array[Transform3D] = []
	var bale_shape := CylinderShape3D.new()
	bale_shape.radius = 0.75
	bale_shape.height = 1.3
	var fields := 0
	var limit := TerrainData.HALF_SIZE - 40.0
	for _attempt in 600:
		if fields >= 7:
			break
		var cx := rng.randf_range(-limit, limit)
		var cz := rng.randf_range(-limit, limit)
		var rd := terrain.get_road_distance(cx, cz)
		if rd < road.half_width + 14.0 or rd > 70.0:
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
			if terrain.get_road_distance(x, z) < road.half_width + 6.0:
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


static func _build_turbines(root: Node3D, terrain: TerrainData) -> Array[Node3D]:
	var rotors: Array[Node3D] = []
	var tower_mesh := SceneryMeshes.turbine_tower(48.0)
	var rotor_mesh := SceneryMeshes.turbine_rotor(21.0)
	var wind := Basis(Vector3.UP, deg_to_rad(35.0))
	var spots := [Vector2(-0.6, 1.0), Vector2(-0.2, 1.05), Vector2(0.25, 1.0), Vector2(1.0, -0.35), Vector2(1.05, 0.05)]
	for k in spots.size():
		var dir: Vector2 = spots[k].normalized()
		var dist := 410.0 + 25.0 * (k % 2)
		var x := dir.x * dist
		var z := dir.y * dist
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
	return rotors


static func _build_clouds(root: Node3D, rng: RandomNumberGenerator) -> void:
	var mb := MeshBuilder.new()
	for _k in 30:
		var angle := rng.randf() * TAU
		var radius := rng.randf_range(150.0, 2000.0)
		SceneryMeshes.cloud(rng, Vector3(cos(angle) * radius, rng.randf_range(230.0, 330.0), sin(angle) * radius), mb)
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
