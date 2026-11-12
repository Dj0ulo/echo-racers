class_name TerrainBuilder
extends RefCounted
## Builds the flat-shaded terrain meshes (playable area + distant mountains) and the terrain collider.

const FAR_CELL := 96.0   ## TerrainData.HALF_SIZE is a multiple of this so the far grid lines up with the inner one.
const FAR_CELLS := 64    ## Far terrain spans +-FAR_CELL * FAR_CELLS (~6.1 km).
const SKIRT_DEPTH := 30.0
## The terrain is split in TerrainData.CHUNK_CELLS chunks so off-screen parts get frustum-culled;
## chunks far from roads are meshed at half resolution (see TerrainData).


static func build(parent: Node3D, terrain: TerrainData) -> void:
	var root := Node3D.new()
	root.name = "Terrain"
	parent.add_child(root)
	var chunks_per_side := TerrainData.CHUNKS
	var builders: Array[MeshBuilder] = []
	builders.resize(chunks_per_side * chunks_per_side)
	var mutex := Mutex.new()
	var task := WorkerThreadPool.add_group_task(_build_chunk.bind(terrain, builders, mutex, chunks_per_side),
			builders.size(), -1, true, "Terrain chunks")
	WorkerThreadPool.wait_for_group_task_completion(task)
	var material := Palette.vertex_material(0.95)
	for k in builders.size():
		var chunk := MeshInstance3D.new()
		chunk.name = "Chunk%d" % k
		chunk.mesh = builders[k].commit(material)
		chunk.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(chunk)

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


## Worker task: flat-shaded triangles of one chunk (plus the outer skirt if it touches the edge).
static func _build_chunk(k: int, terrain: TerrainData, builders: Array[MeshBuilder], mutex: Mutex, per_side: int) -> void:
	var mb := MeshBuilder.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242 + k
	var n := TerrainData.VERTS
	var cc := TerrainData.CHUNK_CELLS
	var ci0 := (k % per_side) * cc
	var cj0 := floori(float(k) / per_side) * cc
	var step: int = terrain.chunk_step[k]
	# Local references: reading another object's packed arrays per vertex is slow from worker threads.
	var dist := terrain.road_distance
	var hts := terrain.heights
	var patches := terrain._patches
	var forest := terrain._forest
	var cs := TerrainData.CELL_SIZE
	var origin := -TerrainData.HALF_SIZE
	for j in range(cj0, cj0 + cc, step):
		var z0 := origin + j * cs
		var z1 := z0 + cs * step
		for i in range(ci0, ci0 + cc, step):
			var x0 := origin + i * cs
			var x1 := x0 + cs * step
			var k00 := j * n + i
			var k01 := k00 + n * step
			var p00 := Vector3(x0, hts[k00], z0)
			var p10 := Vector3(x1, hts[k00 + step], z0)
			var p01 := Vector3(x0, hts[k01], z1)
			var p11 := Vector3(x1, hts[k01 + step], z1)
			var r00 := dist[k00]
			var r10 := dist[k00 + step]
			var r01 := dist[k01]
			var r11 := dist[k01 + step]
			# Colour noise sampled once per cell (it varies over tens of metres).
			var cx := (x0 + x1) * 0.5
			var cz := (z0 + z1) * 0.5
			var pn := patches.get_noise_2d(cx, cz) * 0.5 + 0.5
			var fn := forest.get_noise_2d(cx, cz)
			_add_terrain_triangle(mb, pn, fn, p00, p10, p01, minf(r00, minf(r10, r01)), (r00 + r10 + r01) / 3.0,
					rng.randf_range(-0.04, 0.04))
			_add_terrain_triangle(mb, pn, fn, p10, p11, p01, minf(r10, minf(r11, r01)), (r10 + r11 + r01) / 3.0,
					rng.randf_range(-0.04, 0.04))

	# Skirt around the outer edge hides any crack against the coarser far terrain.
	var last := TerrainData.CELLS
	for c in range(0, cc, step):
		var i := ci0 + c
		var j := cj0 + c
		if cj0 == 0:
			_add_skirt(mb, terrain.vertex_position(i, 0), terrain.vertex_position(i + step, 0), Vector3.FORWARD)
		if cj0 + cc == last:
			_add_skirt(mb, terrain.vertex_position(i, last), terrain.vertex_position(i + step, last), Vector3.BACK)
		if ci0 == 0:
			_add_skirt(mb, terrain.vertex_position(0, j), terrain.vertex_position(0, j + step), Vector3.LEFT)
		if ci0 + cc == last:
			_add_skirt(mb, terrain.vertex_position(last, j), terrain.vertex_position(last, j + step), Vector3.RIGHT)
	mutex.lock()
	builders[k] = mb
	mutex.unlock()


## `p`, `forest`: patch and forest noise at the cell. `road_min` / `road_avg`: smallest and mean distance of
## the corners to a road edge.
static func _add_terrain_triangle(mb: MeshBuilder, p: float, forest: float, a: Vector3, b: Vector3, c: Vector3,
		road_min: float, road_avg: float, shade: float) -> void:
	var n := (c - a).cross(b - a).normalized()
	var h := (a.y + b.y + c.y) / 3.0
	var slope := 1.0 - n.y

	var col := Palette.GRASS_LIGHT.lerp(Palette.GRASS_DARK, smoothstep(0.3, 0.75, p))
	col = col.lerp(Palette.GRASS_DRY, clampf((h - 12.0) / 45.0, 0.0, 0.45) * (1.0 - smoothstep(60.0, 110.0, h)))
	col = col.lerp(Palette.GRASS_DARK.darkened(0.12), smoothstep(0.05, 0.4, forest) * 0.6)
	col = col.lerp(Palette.DIRT, smoothstep(0.2, 0.34, slope) * (1.0 - smoothstep(90.0, 150.0, h)))
	col = col.lerp(Palette.ROCK, smoothstep(0.38, 0.58, slope))
	col = _mountain_tint(col, h, slope, p)
	if road_avg < 1.8 or road_min < -1.0:
		col = Palette.GRAVEL
	elif road_avg < 4.0:
		col = col.lerp(Palette.GRAVEL, 0.4)
	var k := 1.0 + shade
	mb.add_triangle(a, b, c, Color(col.r * k, col.g * k, col.b * k))


## Alpine colours by altitude: dark green pastures, then bare rock, dark crags and snow-capped peaks.
static func _mountain_tint(col: Color, h: float, slope: float, p: float) -> Color:
	if h < 55.0:
		return col
	col = col.lerp(Palette.MOUNTAIN_GREEN, smoothstep(55.0, 130.0, h + p * 20.0))
	col = col.lerp(Palette.ROCK, maxf(smoothstep(140.0, 210.0, h + p * 30.0), smoothstep(0.32, 0.5, slope)))
	col = col.lerp(Palette.ROCK_DARK, smoothstep(0.5, 0.72, slope) * 0.6)
	var snow := smoothstep(300.0, 330.0, h + p * 50.0) * (1.0 - smoothstep(0.55, 0.7, slope))
	return col.lerp(Palette.SNOW, snow)


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
	col = col.lerp(Palette.ROCK, smoothstep(0.35, 0.55, slope))
	col = _mountain_tint(col, h, slope, p)
	var k := 1.0 + shade
	mb.add_triangle(a, b, c, Color(col.r * k, col.g * k, col.b * k))


## Invisible walls keep the car inside the detailed area.
static func _add_boundary_walls(parent: Node3D) -> void:
	var body := StaticBody3D.new()
	body.name = "BoundaryWalls"
	var e := TerrainData.HALF_SIZE - 2.0
	var length := TerrainData.HALF_SIZE * 2.0
	for wall in [
			[Vector3(e + 2.0, 300.0, 0.0), Vector3(4.0, 1200.0, length)],
			[Vector3(-e - 2.0, 300.0, 0.0), Vector3(4.0, 1200.0, length)],
			[Vector3(0.0, 300.0, e + 2.0), Vector3(length, 1200.0, 4.0)],
			[Vector3(0.0, 300.0, -e - 2.0), Vector3(length, 1200.0, 4.0)]]:
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = wall[1]
		shape.shape = box
		shape.position = wall[0]
		body.add_child(shape)
	parent.add_child(body)
