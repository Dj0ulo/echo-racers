class_name TerrainData
extends RefCounted
## Height field of the playable area plus the analytic height function used for distant scenery.
## Pipeline: noise hills -> every road carved in -> sampled on a regular grid that is shared by the
## visual mesh and the HeightMapShape3D collider, so wheels sit exactly on what you see.
## The grid is computed in horizontal bands on the WorkerThreadPool.
##
## Map: the original country (inside the highway ring, CORE_HALF) -> a band of rolling countryside ->
## mountains rising from MOUNTAIN_START to the map edge, which form the natural boundary.
## The grid is split into CHUNK_CELLS chunks. Chunks away from every road (and outside the core) are
## coarse: only one vertex out of `step` per axis is sampled (step 2 next to detailed chunks, 4 further
## away), the others are interpolated on the triangles of that coarser grid. Those chunks are meshed
## with 4x / 16x fewer triangles while the collider (still the full-resolution grid) matches them exactly.

const CELLS := 1024                    ## Power of two: Jolt handles this heightmap natively.
const CELL_SIZE := 4.5
const VERTS := CELLS + 1
const HALF_SIZE := CELLS * CELL_SIZE * 0.5  ## 2304 m
const CORE_HALF := 1152.0              ## Always detailed (the original map, inside and around the highway).
const CHUNK_CELLS := 32                ## Mesh chunk size (frustum culling, coarse/detailed decision).
const CHUNKS := CELLS / CHUNK_CELLS
const MAX_STEP := 4                    ## Coarsest chunks use one vertex out of MAX_STEP per axis.
const BAND_ROWS := 16                  ## Grid rows per worker task (a multiple of MAX_STEP).
const COUNTRYSIDE_START := 1000.0      ## Rounded-square radius where the outer countryside hills begin.
const MOUNTAIN_START := 1600.0         ## ... and where the mountains start to rise.
const MOUNTAIN_FULL := 2350.0

const ROAD_CORE := 0.3         ## Past the asphalt edge, terrain is still fully dropped below the road.
const ROAD_CORE_DROP := 0.35   ## Terrain under the asphalt sits below the road mesh.
const ROAD_SHOULDER := 2.5     ## Gravel shoulder width past the asphalt edge.
const ROAD_SHOULDER_DROP := 0.08
const EMBANKMENT_SLOPE := 2.0  ## Horizontal metres per metre of height difference when blending back.
const FAR_DROP := 1.2          ## Distant terrain sits slightly lower to hide the seam.

var heights := PackedFloat32Array()
## Distance from each grid vertex to the nearest road *edge* (negative on the asphalt), 1e9 when far.
var road_distance := PackedFloat32Array()

var _hills := FastNoiseLite.new()
var _detail := FastNoiseLite.new()
var _mountains := FastNoiseLite.new()
var _patches := FastNoiseLite.new()
var _forest := FastNoiseLite.new()
var _rocks := FastNoiseLite.new()
var _bands := {}
var _bands_mutex := Mutex.new()
## Vertex step of each chunk: 1 = detailed (full resolution), 2 or 4 = coarse.
var chunk_step := PackedByteArray()


func _init(world_seed: int) -> void:
	_hills.seed = world_seed
	_hills.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_hills.frequency = 0.0032
	_hills.fractal_octaves = 4
	_hills.fractal_gain = 0.45

	_detail.seed = world_seed + 1
	_detail.frequency = 0.02
	_detail.fractal_octaves = 2

	_mountains.seed = world_seed + 2
	_mountains.frequency = 0.0015
	_mountains.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	_mountains.fractal_octaves = 4
	_mountains.fractal_gain = 0.38

	_rocks.seed = world_seed + 5
	_rocks.frequency = 0.005
	_rocks.fractal_octaves = 2

	_patches.seed = world_seed + 3
	_patches.frequency = 0.011
	_patches.fractal_octaves = 2

	_forest.seed = world_seed + 4
	_forest.frequency = 0.0045
	_forest.fractal_octaves = 3


## Terrain height before the roads are carved in. Valid everywhere (used for far scenery too).
func natural_height(x: float, z: float) -> float:
	var h := _hills.get_noise_2d(x, z) * 20.0 + _detail.get_noise_2d(x, z) * 2.0
	# Rounded-square radius: the map is square, so are its countryside and mountain bands.
	var ax := absf(x)
	var az := absf(z)
	var rim := pow(ax * ax * ax * ax + az * az * az * az, 0.25)
	# Outer countryside: broader, taller rolling hills past the highway.
	var outer := smoothstep(COUNTRYSIDE_START, COUNTRYSIDE_START + 500.0, rim)
	if outer > 0.0:
		h += outer * (_hills.get_noise_2d(x * 0.6 + 3100.0, z * 0.6) * 28.0 + 10.0)
	# Mountains: ridged peaks rising towards the map edge, and even higher ranges beyond it.
	var m := smoothstep(MOUNTAIN_START, MOUNTAIN_FULL, rim)
	if m > 0.0:
		var ridge := clampf(_mountains.get_noise_2d(x, z) * 0.5 + 0.5, 0.0, 1.0)
		h += m * (60.0 + ridge * ridge * 360.0) + m * m * 110.0
		h += m * _rocks.get_noise_2d(x, z) * 8.0
		h += smoothstep(MOUNTAIN_FULL, MOUNTAIN_FULL + 1600.0, rim) * ridge * 160.0
	return h


func patch_noise(x: float, z: float) -> float:
	return _patches.get_noise_2d(x, z)


func forest_density(x: float, z: float) -> float:
	return _forest.get_noise_2d(x, z)


func build(roads: Array[RoadPath]) -> void:
	_mark_detailed_chunks(roads)
	_bands.clear()
	var band_count := ceili(float(VERTS) / BAND_ROWS)
	var task := WorkerThreadPool.add_group_task(_build_band.bind(roads), band_count, -1, true, "TerrainData bands")
	WorkerThreadPool.wait_for_group_task_completion(task)
	heights = PackedFloat32Array()
	road_distance = PackedFloat32Array()
	for b in band_count:
		heights.append_array(_bands[b][0])
		road_distance.append_array(_bands[b][1])
	_bands.clear()


## A chunk is detailed if it lies in the core or any road (with its terrain reach) comes near it; other chunks
## are coarse, the coarsest ones not touching any detailed chunk.
func _mark_detailed_chunks(roads: Array[RoadPath]) -> void:
	var detailed := PackedByteArray()
	detailed.resize(CHUNKS * CHUNKS)
	var chunk_size := CHUNK_CELLS * CELL_SIZE
	for cj in CHUNKS:
		for ci in CHUNKS:
			var x0 := -HALF_SIZE + ci * chunk_size
			var z0 := -HALF_SIZE + cj * chunk_size
			if maxf(absf(x0), absf(x0 + chunk_size)) <= CORE_HALF + 0.1 and maxf(absf(z0), absf(z0 + chunk_size)) <= CORE_HALF + 0.1:
				detailed[cj * CHUNKS + ci] = 1
	for road in roads:
		var reach := road.half_width + road.terrain_reach + CELL_SIZE * 2.0
		for k in range(0, road.sample_count(), 4):
			var p := road.points[k]
			var ci0 := clampi(floori((p.x - reach + HALF_SIZE) / chunk_size), 0, CHUNKS - 1)
			var ci1 := clampi(floori((p.x + reach + HALF_SIZE) / chunk_size), 0, CHUNKS - 1)
			var cj0 := clampi(floori((p.z - reach + HALF_SIZE) / chunk_size), 0, CHUNKS - 1)
			var cj1 := clampi(floori((p.z + reach + HALF_SIZE) / chunk_size), 0, CHUNKS - 1)
			for cj in range(cj0, cj1 + 1):
				for ci in range(ci0, ci1 + 1):
					detailed[cj * CHUNKS + ci] = 1
	chunk_step.resize(CHUNKS * CHUNKS)
	for cj in CHUNKS:
		for ci in CHUNKS:
			var step := MAX_STEP
			for dj in range(maxi(cj - 1, 0), mini(cj + 2, CHUNKS)):
				for di in range(maxi(ci - 1, 0), mini(ci + 2, CHUNKS)):
					if detailed[dj * CHUNKS + di] == 1:
						step = 1 if (di == ci and dj == cj) else mini(step, 2)
			chunk_step[cj * CHUNKS + ci] = step


## Grid step a vertex is sampled at: the coarsest step of the chunks it touches, so a finer chunk next to a
## coarser one shares its edge exactly (no cracks).
func _vertex_step(i: int, j: int) -> int:
	var ci_a := mini(i / CHUNK_CELLS, CHUNKS - 1)
	var ci_b := maxi(ci_a - 1, 0) if i % CHUNK_CELLS == 0 else ci_a
	var cj_a := mini(j / CHUNK_CELLS, CHUNKS - 1)
	var cj_b := maxi(cj_a - 1, 0) if j % CHUNK_CELLS == 0 else cj_a
	return maxi(maxi(chunk_step[cj_a * CHUNKS + ci_a], chunk_step[cj_a * CHUNKS + ci_b]),
			maxi(chunk_step[cj_b * CHUNKS + ci_a], chunk_step[cj_b * CHUNKS + ci_b]))


## Height of vertex (i, j) on the triangles of the step-`st` grid (diagonal from (I + st, J) to (I, J + st)),
## from the even-vertex heights in `coarse`. On the last row / column the far neighbour does not exist,
## but its weight is zero.
func _interpolate(coarse: Dictionary, i: int, j: int, st: int) -> float:
	var di := i % st
	var dj := j % st
	var c0 := (i - di) / 2
	var c1 := mini(c0 + st / 2, CELLS / 2)
	var r0: PackedFloat32Array = coarse[j - dj]
	var r1: PackedFloat32Array = coarse.get(j - dj + st, r0)
	var u := float(di) / st
	var v := float(dj) / st
	var h10 := r0[c1]
	var h01 := r1[c0]
	if u + v <= 1.0:
		var h00 := r0[c0]
		return h00 + (h10 - h00) * u + (h01 - h00) * v
	var h11 := r1[c1]
	return h11 + (h01 - h11) * (1.0 - u) + (h10 - h11) * (1.0 - v)


## Worker task: natural heights for a band of rows, roads rasterised into it, then carved in.
func _build_band(band: int, roads: Array[RoadPath]) -> void:
	var j0 := band * BAND_ROWS
	var j1 := mini(j0 + BAND_ROWS, VERTS)
	var count := (j1 - j0) * VERTS
	var h := PackedFloat32Array()
	h.resize(count)
	var dist := PackedFloat32Array()
	dist.resize(count)
	dist.fill(1e9)
	var road_h := PackedFloat32Array()
	road_h.resize(count)
	var owner := PackedByteArray()
	owner.resize(count)

	# Final heights of the even vertices (the step-2 grid) for rows j0..j1 (one past the band, for
	# interpolation): first the step-4 grid, then the other even vertices (interpolated on the step-4 grid
	# where they touch a step-4 chunk), then every remaining vertex.
	var j_last := mini(j1, VERTS - 1)
	var coarse := {}  # even row -> PackedFloat32Array of the even columns
	for j in range(j0, j_last + 1, 2):
		var row := PackedFloat32Array()
		row.resize(CELLS / 2 + 1)
		coarse[j] = row
	for j in range(j0, j_last + 1, MAX_STEP):
		var row: PackedFloat32Array = coarse[j]
		for i in range(0, VERTS, MAX_STEP):
			row[i / 2] = natural_height(-HALF_SIZE + i * CELL_SIZE, -HALF_SIZE + j * CELL_SIZE)
	for j in range(j0, j_last + 1, 2):
		var row: PackedFloat32Array = coarse[j]
		for i in range(0, VERTS, 2):
			if i % MAX_STEP == 0 and j % MAX_STEP == 0:
				continue
			var st := _vertex_step(i, j)
			row[i / 2] = _interpolate(coarse, i, j, st) if st == MAX_STEP \
					else natural_height(-HALF_SIZE + i * CELL_SIZE, -HALF_SIZE + j * CELL_SIZE)
	for j in range(j0, j1):
		var row := (j - j0) * VERTS
		for i in VERTS:
			if i % 2 == 0 and j % 2 == 0:
				h[row + i] = coarse[j][i / 2]
				continue
			var st := _vertex_step(i, j)
			h[row + i] = _interpolate(coarse, i, j, st) if st > 1 \
					else natural_height(-HALF_SIZE + i * CELL_SIZE, -HALF_SIZE + j * CELL_SIZE)

	var z_min := -HALF_SIZE + j0 * CELL_SIZE
	var z_max := -HALF_SIZE + (j1 - 1) * CELL_SIZE
	for r in roads.size():
		_rasterize_road(roads[r], r, j0, j1, z_min, z_max, dist, road_h, owner)

	for idx in count:
		var e := dist[idx]
		if e >= 1e8:
			continue
		var road := roads[owner[idx]]
		var rh := road_h[idx]
		if e <= ROAD_CORE:
			h[idx] = rh - ROAD_CORE_DROP
		elif e <= ROAD_SHOULDER:
			h[idx] = lerpf(rh - ROAD_CORE_DROP, rh - ROAD_SHOULDER_DROP, (e - ROAD_CORE) / (ROAD_SHOULDER - ROAD_CORE))
		else:
			var natural := h[idx]
			var blend := clampf(absf(natural - rh) * EMBANKMENT_SLOPE, road.terrain_blend, road.terrain_reach - ROAD_SHOULDER)
			var t := (e - ROAD_SHOULDER) / blend
			if t < 1.0:
				h[idx] = lerpf(rh - ROAD_SHOULDER_DROP, natural, smoothstep(0.0, 1.0, t))

	_bands_mutex.lock()
	_bands[band] = [h, dist]
	_bands_mutex.unlock()


## For every vertex of the band near the road, keep the distance to the road edge and the road height there
## (if this road is the closest one so far).
func _rasterize_road(road: RoadPath, road_index: int, j0: int, j1: int, z_min: float, z_max: float,
		dist: PackedFloat32Array, road_h: PackedFloat32Array, owner: PackedByteArray) -> void:
	var pts := road.points
	var hw := road.half_width
	var reach := hw + road.terrain_reach
	var n := pts.size()
	var segments := n if road.closed else n - 1
	# Rasterise chords spanning several samples: much less overlap between neighbouring boxes,
	# and the chord error stays at a few centimetres for the curve radii used.
	var stride := 5 if road.is_highway else 2
	var s := 0
	while s < segments:
		var e := mini(s + stride, segments)
		var a := pts[s]
		var b := pts[e % n]
		s = e
		if maxf(a.z, b.z) + reach < z_min or minf(a.z, b.z) - reach > z_max:
			continue
		var a2 := Vector2(a.x, a.z)
		var ab := Vector2(b.x, b.z) - a2
		var len2 := maxf(ab.length_squared(), 1e-6)
		var i_lo := maxi(floori((minf(a.x, b.x) - reach + HALF_SIZE) / CELL_SIZE), 0)
		var i_hi := mini(ceili((maxf(a.x, b.x) + reach + HALF_SIZE) / CELL_SIZE), CELLS)
		var j_lo := maxi(floori((minf(a.z, b.z) - reach + HALF_SIZE) / CELL_SIZE), j0)
		var j_hi := mini(ceili((maxf(a.z, b.z) + reach + HALF_SIZE) / CELL_SIZE), j1 - 1)
		for j in range(j_lo, j_hi + 1):
			var z := -HALF_SIZE + j * CELL_SIZE
			var row := (j - j0) * VERTS
			for i in range(i_lo, i_hi + 1):
				var p := Vector2(-HALF_SIZE + i * CELL_SIZE, z)
				var t := clampf((p - a2).dot(ab) / len2, 0.0, 1.0)
				var d := p.distance_to(a2 + ab * t) - hw
				var idx := row + i
				if d < dist[idx]:
					dist[idx] = d
					road_h[idx] = lerpf(a.y, b.y, t)
					owner[idx] = road_index


func is_inside(x: float, z: float) -> bool:
	return absf(x) <= HALF_SIZE and absf(z) <= HALF_SIZE


func vertex_position(i: int, j: int) -> Vector3:
	return Vector3(-HALF_SIZE + i * CELL_SIZE, heights[j * VERTS + i], -HALF_SIZE + j * CELL_SIZE)


## Height matching the rendered triangles (same diagonal split as the terrain mesh).
func get_height(x: float, z: float) -> float:
	if not is_inside(x, z):
		return natural_height(x, z) - FAR_DROP
	return _sample_grid(heights, x, z)


## Distance to the nearest road edge (negative on the asphalt).
func get_road_distance(x: float, z: float) -> float:
	if not is_inside(x, z):
		return 1e9
	return _sample_grid(road_distance, x, z)


func get_normal(x: float, z: float, e := 1.0) -> Vector3:
	var hl := get_height(x - e, z)
	var hr := get_height(x + e, z)
	var hd := get_height(x, z - e)
	var hu := get_height(x, z + e)
	return Vector3(hl - hr, 2.0 * e, hd - hu).normalized()


func create_collision_shape() -> HeightMapShape3D:
	var shape := HeightMapShape3D.new()
	shape.map_width = VERTS
	shape.map_depth = VERTS
	# The collision node is scaled by CELL_SIZE, so heights are stored pre-divided.
	var data := heights.duplicate()
	for i in data.size():
		data[i] /= CELL_SIZE
	shape.map_data = data
	return shape


func _sample_grid(grid: PackedFloat32Array, x: float, z: float) -> float:
	var fx := (x + HALF_SIZE) / CELL_SIZE
	var fz := (z + HALF_SIZE) / CELL_SIZE
	var i := clampi(int(fx), 0, CELLS - 1)
	var j := clampi(int(fz), 0, CELLS - 1)
	var tx := clampf(fx - i, 0.0, 1.0)
	var tz := clampf(fz - j, 0.0, 1.0)
	var h00 := grid[j * VERTS + i]
	var h10 := grid[j * VERTS + i + 1]
	var h01 := grid[(j + 1) * VERTS + i]
	var h11 := grid[(j + 1) * VERTS + i + 1]
	if tx + tz <= 1.0:
		return h00 + (h10 - h00) * tx + (h01 - h00) * tz
	return h11 + (h01 - h11) * (1.0 - tx) + (h10 - h11) * (1.0 - tz)
