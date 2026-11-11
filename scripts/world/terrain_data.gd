class_name TerrainData
extends RefCounted
## Height field of the playable area plus the analytic height function used for distant scenery.
## Pipeline: noise hills -> every road carved in -> sampled on a regular grid that is shared by the
## visual mesh and the HeightMapShape3D collider, so wheels sit exactly on what you see.
## The grid is computed in horizontal bands on the WorkerThreadPool.

const CELLS := 512                     ## Power of two: Jolt handles this heightmap natively.
const CELL_SIZE := 4.5
const VERTS := CELLS + 1
const HALF_SIZE := CELLS * CELL_SIZE * 0.5  ## 1152 m
const BAND_ROWS := 16                  ## Grid rows per worker task.

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
var _bands := {}
var _bands_mutex := Mutex.new()


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
	_mountains.frequency = 0.0011
	_mountains.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	_mountains.fractal_octaves = 5

	_patches.seed = world_seed + 3
	_patches.frequency = 0.011
	_patches.fractal_octaves = 2

	_forest.seed = world_seed + 4
	_forest.frequency = 0.0045
	_forest.fractal_octaves = 3


## Terrain height before the roads are carved in. Valid everywhere (used for far scenery too).
func natural_height(x: float, z: float) -> float:
	var h := _hills.get_noise_2d(x, z) * 20.0 + _detail.get_noise_2d(x, z) * 2.0
	# Rounded-square rim: the playground edges rise into enclosing hills.
	var ax := absf(x)
	var az := absf(z)
	var rim := pow(ax * ax * ax * ax + az * az * az * az, 0.25)
	h += smoothstep(HALF_SIZE - 90.0, HALF_SIZE + 80.0, rim) * 40.0
	# Distant mountain ranges.
	var radial := sqrt(x * x + z * z)
	var m := smoothstep(HALF_SIZE + 150.0, HALF_SIZE + 1500.0, radial)
	if m > 0.0:
		var ridge := clampf(_mountains.get_noise_2d(x, z) * 0.5 + 0.5, 0.0, 1.0)
		h += m * (40.0 + ridge * ridge * 420.0)
	return h


func patch_noise(x: float, z: float) -> float:
	return _patches.get_noise_2d(x, z)


func forest_density(x: float, z: float) -> float:
	return _forest.get_noise_2d(x, z)


func build(roads: Array[RoadPath]) -> void:
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

	for j in range(j0, j1):
		var z := -HALF_SIZE + j * CELL_SIZE
		var row := (j - j0) * VERTS
		for i in VERTS:
			h[row + i] = natural_height(-HALF_SIZE + i * CELL_SIZE, z)

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
