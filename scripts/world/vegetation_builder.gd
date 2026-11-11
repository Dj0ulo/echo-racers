class_name VegetationBuilder
extends RefCounted
## Scatters trees, rocks, grass and flowers using chunked MultiMeshInstance3D nodes:
## few draw calls, while chunks still get frustum-culled (and distance-culled for grass).

const TREE_CHUNK := 176.0
const FAR_TREE_CHUNK := 300.0
const GRASS_CHUNK := 44.0
const GRASS_VISIBLE_RANGE := 85.0


## `clear_zones` holds Vector3(x, z, radius) circles (buildings, fields) where nothing should grow.
static func build(parent: Node3D, terrain: TerrainData, road: RoadPath, clear_zones: Array[Vector3], world_seed: int) -> void:
	var root := Node3D.new()
	root.name = "Vegetation"
	parent.add_child(root)
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed * 31 + 7

	var meshes := {
		&"pine": SceneryMeshes.pine_tree(),
		&"broad": SceneryMeshes.broadleaf_tree(Palette.LEAF),
		&"broad_light": SceneryMeshes.broadleaf_tree(Palette.LEAF_LIGHT),
		&"autumn": SceneryMeshes.broadleaf_tree(Palette.LEAF_AUTUMN),
		&"rock": SceneryMeshes.rock(),
		&"grass": SceneryMeshes.grass_tuft(),
		&"flower_y": SceneryMeshes.grass_tuft(Palette.FLOWER_YELLOW),
		&"flower_w": SceneryMeshes.grass_tuft(Palette.FLOWER_WHITE),
		&"flower_p": SceneryMeshes.grass_tuft(Palette.FLOWER_PURPLE),
	}

	var colliders := StaticBody3D.new()
	colliders.name = "VegetationColliders"
	colliders.set_meta(&"surface", &"grass")
	root.add_child(colliders)

	var trees := {}
	_scatter_trees(terrain, road, clear_zones, rng, trees, colliders)
	_scatter_far_trees(terrain, rng, trees)
	_emit(root, trees, meshes, true, 0.0)

	var rocks := {}
	_scatter_rocks(terrain, road, clear_zones, rng, rocks, colliders)
	_emit(root, rocks, meshes, true, 0.0)

	var grass := {}
	_scatter_grass(terrain, road, clear_zones, rng, grass)
	_emit(root, grass, meshes, false, GRASS_VISIBLE_RANGE)


static func _scatter_trees(terrain: TerrainData, road: RoadPath, clear_zones: Array[Vector3],
		rng: RandomNumberGenerator, buckets: Dictionary, colliders: StaticBody3D) -> void:
	var trunk := CylinderShape3D.new()
	trunk.radius = 0.4
	trunk.height = 6.0
	var limit := TerrainData.HALF_SIZE - 3.0
	var keep_clear := road.half_width + 6.5
	for _i in 11000:
		var x := rng.randf_range(-limit, limit)
		var z := rng.randf_range(-limit, limit)
		var forest := terrain.forest_density(x, z)
		var chance := 0.012 + smoothstep(0.0, 0.35, forest) * 0.7
		if rng.randf() > chance:
			continue
		if terrain.get_road_distance(x, z) < keep_clear or _in_clear_zone(x, z, clear_zones):
			continue
		if terrain.get_normal(x, z).y < 0.84:
			continue
		var y := terrain.get_height(x, z)
		var kind := _pick_tree(rng, forest, y)
		_add(buckets, kind, x, z, TREE_CHUNK, _random_xform(rng, x, y - 0.1, z, 0.75, 1.3))
		var shape := CollisionShape3D.new()
		shape.shape = trunk
		shape.position = Vector3(x, y + 3.0, z)
		colliders.add_child(shape)


## Visual-only forests on the hills outside the drivable area.
static func _scatter_far_trees(terrain: TerrainData, rng: RandomNumberGenerator, buckets: Dictionary) -> void:
	for _i in 9000:
		var angle := rng.randf() * TAU
		var radius := rng.randf_range(TerrainData.HALF_SIZE + 6.0, 950.0)
		var x := cos(angle) * radius
		var z := sin(angle) * radius
		if terrain.is_inside(x, z):
			continue
		var forest := terrain.forest_density(x, z)
		if rng.randf() > smoothstep(-0.1, 0.3, forest) * 0.6:
			continue
		var y := terrain.get_height(x, z)
		if y > 150.0 or terrain.get_normal(x, z, 6.0).y < 0.8:
			continue
		var kind := _pick_tree(rng, forest, y)
		_add(buckets, kind, x, z, FAR_TREE_CHUNK, _random_xform(rng, x, y - 0.3, z, 1.0, 1.6))


static func _pick_tree(rng: RandomNumberGenerator, forest: float, height: float) -> StringName:
	var pine_chance := 0.35 + clampf(forest, 0.0, 0.5) + clampf((height - 20.0) / 60.0, 0.0, 0.4)
	if rng.randf() < pine_chance:
		return &"pine"
	var r := rng.randf()
	if r < 0.08:
		return &"autumn"
	return &"broad_light" if r < 0.45 else &"broad"


static func _scatter_rocks(terrain: TerrainData, road: RoadPath, clear_zones: Array[Vector3],
		rng: RandomNumberGenerator, buckets: Dictionary, colliders: StaticBody3D) -> void:
	var limit := TerrainData.HALF_SIZE - 3.0
	var placed := 0
	var attempts := 0
	while placed < 320 and attempts < 8000:
		attempts += 1
		var x := rng.randf_range(-limit, limit)
		var z := rng.randf_range(-limit, limit)
		var n := terrain.get_normal(x, z)
		# Prefer slopes and road cuts.
		if rng.randf() > 0.12 + (1.0 - n.y) * 3.0:
			continue
		if terrain.get_road_distance(x, z) < road.half_width + 3.0 or _in_clear_zone(x, z, clear_zones):
			continue
		var s := rng.randf_range(0.4, 1.0)
		if rng.randf() < 0.25:
			s *= 2.2
		var y := terrain.get_height(x, z)
		var basis := Basis(Vector3.UP, rng.randf() * TAU) * Basis(Vector3.RIGHT, rng.randf_range(-0.3, 0.3))
		basis = basis.scaled(Vector3(s * rng.randf_range(0.9, 1.5), s, s * rng.randf_range(0.9, 1.3)))
		_add(buckets, &"rock", x, z, TREE_CHUNK, Transform3D(basis, Vector3(x, y - 0.2 * s, z)))
		if s > 0.9:
			var sphere := SphereShape3D.new()
			sphere.radius = 0.75 * s
			var shape := CollisionShape3D.new()
			shape.shape = sphere
			shape.position = Vector3(x, y, z)
			colliders.add_child(shape)
		placed += 1


static func _scatter_grass(terrain: TerrainData, road: RoadPath, clear_zones: Array[Vector3],
		rng: RandomNumberGenerator, buckets: Dictionary) -> void:
	var flowers := FastNoiseLite.new()
	flowers.seed = rng.randi()
	flowers.frequency = 0.02
	var chunks := int(TerrainData.HALF_SIZE * 2.0 / GRASS_CHUNK)
	for cj in chunks:
		for ci in chunks:
			var x0 := -TerrainData.HALF_SIZE + ci * GRASS_CHUNK
			var z0 := -TerrainData.HALF_SIZE + cj * GRASS_CHUNK
			for _k in 230:
				var x := x0 + rng.randf() * GRASS_CHUNK
				var z := z0 + rng.randf() * GRASS_CHUNK
				var patch := terrain.patch_noise(x * 1.7, z * 1.7)
				if rng.randf() > 0.35 + patch * 0.5:
					continue
				if terrain.get_road_distance(x, z) < road.half_width + 2.2 or _in_clear_zone(x, z, clear_zones):
					continue
				if terrain.get_normal(x, z).y < 0.8:
					continue
				var kind := &"grass"
				var f := flowers.get_noise_2d(x, z)
				if f > 0.25 and rng.randf() < 0.6:
					kind = [&"flower_y", &"flower_w", &"flower_p"][int(absf(f * 97.0)) % 3]
				var y := terrain.get_height(x, z)
				_add(buckets, kind, x, z, GRASS_CHUNK, _random_xform(rng, x, y - 0.03, z, 0.7, 1.4))


static func _random_xform(rng: RandomNumberGenerator, x: float, y: float, z: float, min_s: float, max_s: float) -> Transform3D:
	var s := rng.randf_range(min_s, max_s)
	var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.9, 1.15), s))
	return Transform3D(basis, Vector3(x, y, z))


static func _in_clear_zone(x: float, z: float, zones: Array[Vector3]) -> bool:
	for zone in zones:
		if Vector2(x - zone.x, z - zone.y).length_squared() < zone.z * zone.z:
			return true
	return false


static func _add(buckets: Dictionary, kind: StringName, x: float, z: float, chunk_size: float, xform: Transform3D) -> void:
	var key := "%s|%d|%d" % [kind, floori(x / chunk_size), floori(z / chunk_size)]
	if not buckets.has(key):
		buckets[key] = []
	buckets[key].append(xform)


static func _emit(root: Node3D, buckets: Dictionary, meshes: Dictionary, cast_shadows: bool, visible_range: float) -> void:
	for key: String in buckets:
		var kind := StringName(key.get_slice("|", 0))
		var xforms: Array = buckets[key]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = meshes[kind]
		mm.instance_count = xforms.size()
		for i in xforms.size():
			mm.set_instance_transform(i, xforms[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if visible_range > 0.0:
			mmi.visibility_range_end = visible_range
			mmi.visibility_range_end_margin = 10.0
		root.add_child(mmi)
