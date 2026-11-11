class_name TerrainBuilder
extends RefCounted
## Builds the flat-shaded terrain meshes (playable area + distant mountains) and the terrain collider.

const FAR_CELL := 44.0   ## TerrainData.HALF_SIZE is a multiple of this so the far grid lines up with the inner one.
const FAR_CELLS := 68    ## Far terrain spans +-FAR_CELL * FAR_CELLS (~3 km).
const SKIRT_DEPTH := 20.0


static func build(parent: Node3D, terrain: TerrainData) -> void:
	var inner := MeshInstance3D.new()
	inner.name = "Terrain"
	inner.mesh = _build_inner_mesh(terrain)
	inner.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(inner)

	var far := MeshInstance3D.new()
	far.name = "FarTerrain"
	far.mesh = _build_far_mesh(terrain)
	far.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(far)

	var body := StaticBody3D.new()
	body.name = "TerrainBody"
	body.set_meta(&"surface", &"grass")
	var shape := CollisionShape3D.new()
	shape.shape = terrain.create_collision_shape()
	shape.scale = Vector3.ONE * TerrainData.CELL_SIZE
	body.add_child(shape)
	parent.add_child(body)

	_add_boundary_walls(parent)


static func _build_inner_mesh(terrain: TerrainData) -> ArrayMesh:
	var mb := MeshBuilder.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var n := TerrainData.VERTS
	for j in TerrainData.CELLS:
		for i in TerrainData.CELLS:
			var p00 := terrain.vertex_position(i, j)
			var p10 := terrain.vertex_position(i + 1, j)
			var p01 := terrain.vertex_position(i, j + 1)
			var p11 := terrain.vertex_position(i + 1, j + 1)
			var r00 := terrain.road_distance[j * n + i]
			var r10 := terrain.road_distance[j * n + i + 1]
			var r01 := terrain.road_distance[(j + 1) * n + i]
			var r11 := terrain.road_distance[(j + 1) * n + i + 1]
			_add_terrain_triangle(mb, terrain, p00, p10, p01, (r00 + r10 + r01) / 3.0, rng.randf_range(-0.04, 0.04))
			_add_terrain_triangle(mb, terrain, p10, p11, p01, (r10 + r11 + r01) / 3.0, rng.randf_range(-0.04, 0.04))

	# Skirt around the edge hides any crack against the coarser far terrain.
	var last := TerrainData.CELLS
	for k in TerrainData.CELLS:
		_add_skirt(mb, terrain.vertex_position(k, 0), terrain.vertex_position(k + 1, 0), Vector3.FORWARD)
		_add_skirt(mb, terrain.vertex_position(k, last), terrain.vertex_position(k + 1, last), Vector3.BACK)
		_add_skirt(mb, terrain.vertex_position(0, k), terrain.vertex_position(0, k + 1), Vector3.LEFT)
		_add_skirt(mb, terrain.vertex_position(last, k), terrain.vertex_position(last, k + 1), Vector3.RIGHT)
	return mb.commit(Palette.vertex_material(0.95))


static func _add_terrain_triangle(mb: MeshBuilder, terrain: TerrainData, a: Vector3, b: Vector3, c: Vector3,
		road_d: float, shade: float) -> void:
	var n := (c - a).cross(b - a).normalized()
	var cx := (a.x + b.x + c.x) / 3.0
	var cz := (a.z + b.z + c.z) / 3.0
	var h := (a.y + b.y + c.y) / 3.0
	var slope := 1.0 - n.y

	var p := terrain.patch_noise(cx, cz) * 0.5 + 0.5
	var col := Palette.GRASS_LIGHT.lerp(Palette.GRASS_DARK, smoothstep(0.3, 0.75, p))
	col = col.lerp(Palette.GRASS_DRY, clampf((h - 12.0) / 45.0, 0.0, 0.45))
	col = col.lerp(Palette.GRASS_DARK.darkened(0.12), smoothstep(0.05, 0.4, terrain.forest_density(cx, cz)) * 0.6)
	col = col.lerp(Palette.DIRT, smoothstep(0.2, 0.34, slope))
	col = col.lerp(Palette.ROCK, smoothstep(0.38, 0.58, slope))
	var edge := terrain.road_half_width
	if road_d < edge + 1.7:
		col = Palette.GRAVEL
	elif road_d < edge + 3.4:
		col = col.lerp(Palette.GRAVEL, 0.35)
	var k := 1.0 + shade
	mb.add_triangle(a, b, c, Color(col.r * k, col.g * k, col.b * k))


static func _add_skirt(mb: MeshBuilder, a: Vector3, b: Vector3, outward: Vector3) -> void:
	var down := Vector3.DOWN * SKIRT_DEPTH
	mb.add_quad_facing(a, b, b + down, a + down, outward, Palette.GRASS_DARK)


static func _build_far_mesh(terrain: TerrainData) -> ArrayMesh:
	var mb := MeshBuilder.new()
	var size := FAR_CELLS * 2 + 1
	var grid := PackedFloat32Array()
	grid.resize(size * size)
	for j in size:
		for i in size:
			var x := (i - FAR_CELLS) * FAR_CELL
			var z := (j - FAR_CELLS) * FAR_CELL
			grid[j * size + i] = terrain.natural_height(x, z) - TerrainData.FAR_DROP
	var inner := TerrainData.HALF_SIZE
	var rng := RandomNumberGenerator.new()
	rng.seed = 777
	for j in size - 1:
		for i in size - 1:
			var x0 := (i - FAR_CELLS) * FAR_CELL
			var z0 := (j - FAR_CELLS) * FAR_CELL
			var x1 := x0 + FAR_CELL
			var z1 := z0 + FAR_CELL
			# Skip cells fully covered by the detailed terrain.
			if maxf(absf(x0), absf(x1)) <= inner and maxf(absf(z0), absf(z1)) <= inner:
				continue
			var p00 := Vector3(x0, grid[j * size + i], z0)
			var p10 := Vector3(x1, grid[j * size + i + 1], z0)
			var p01 := Vector3(x0, grid[(j + 1) * size + i], z1)
			var p11 := Vector3(x1, grid[(j + 1) * size + i + 1], z1)
			_add_far_triangle(mb, terrain, p00, p10, p01, rng.randf_range(-0.04, 0.04))
			_add_far_triangle(mb, terrain, p10, p11, p01, rng.randf_range(-0.04, 0.04))
	return mb.commit(Palette.vertex_material(1.0))


static func _add_far_triangle(mb: MeshBuilder, terrain: TerrainData, a: Vector3, b: Vector3, c: Vector3, shade: float) -> void:
	var n := (c - a).cross(b - a).normalized()
	var h := (a.y + b.y + c.y) / 3.0
	var cx := (a.x + b.x + c.x) / 3.0
	var cz := (a.z + b.z + c.z) / 3.0
	var slope := 1.0 - n.y
	var p := terrain.patch_noise(cx, cz) * 0.5 + 0.5
	var col := Palette.GRASS_LIGHT.lerp(Palette.GRASS_DARK, smoothstep(0.3, 0.75, p))
	col = col.lerp(Palette.MOUNTAIN_GREEN, smoothstep(60.0, 140.0, h))
	col = col.lerp(Palette.ROCK, maxf(smoothstep(130.0, 200.0, h + p * 30.0), smoothstep(0.35, 0.55, slope)))
	col = col.lerp(Palette.ROCK_DARK, smoothstep(0.55, 0.75, slope) * 0.6)
	var snow := smoothstep(255.0, 275.0, h + p * 40.0) * (1.0 - smoothstep(0.55, 0.7, slope))
	col = col.lerp(Palette.SNOW, snow)
	var k := 1.0 + shade
	mb.add_triangle(a, b, c, Color(col.r * k, col.g * k, col.b * k))


## Invisible walls keep the car inside the detailed area.
static func _add_boundary_walls(parent: Node3D) -> void:
	var body := StaticBody3D.new()
	body.name = "BoundaryWalls"
	var e := TerrainData.HALF_SIZE - 2.0
	var length := TerrainData.HALF_SIZE * 2.0
	for wall in [
			[Vector3(e + 2.0, 100.0, 0.0), Vector3(4.0, 400.0, length)],
			[Vector3(-e - 2.0, 100.0, 0.0), Vector3(4.0, 400.0, length)],
			[Vector3(0.0, 100.0, e + 2.0), Vector3(length, 400.0, 4.0)],
			[Vector3(0.0, 100.0, -e - 2.0), Vector3(length, 400.0, 4.0)]]:
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = wall[1]
		shape.shape = box
		shape.position = wall[0]
		body.add_child(shape)
	parent.add_child(body)
