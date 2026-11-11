class_name TerrainData
extends RefCounted
## Height field of the playable area plus the analytic height function used for distant scenery.
## Pipeline: noise hills -> road carved in -> sampled on a regular grid that is shared by the
## visual mesh and the HeightMapShape3D collider, so wheels sit exactly on what you see.

const CELLS := 256                     ## Power of two: Jolt handles this heightmap natively.
const CELL_SIZE := 2.75
const VERTS := CELLS + 1
const HALF_SIZE := CELLS * CELL_SIZE * 0.5  ## 352 m

const ROAD_CORE_DROP := 0.35   ## Terrain under the asphalt sits below the road mesh.
const ROAD_SHOULDER := 1.5     ## Gravel shoulder width past the asphalt edge.
const ROAD_SHOULDER_DROP := 0.08
const ROAD_BLEND := 14.0       ## Distance over which terrain blends back to natural height.
const FAR_DROP := 1.2          ## Distant terrain sits slightly lower to hide the seam.

var heights := PackedFloat32Array()
var road_distance := PackedFloat32Array()
var road_half_width := 4.5

var _hills := FastNoiseLite.new()
var _detail := FastNoiseLite.new()
var _mountains := FastNoiseLite.new()
var _patches := FastNoiseLite.new()
var _forest := FastNoiseLite.new()


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
	_mountains.frequency = 0.0016
	_mountains.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	_mountains.fractal_octaves = 5

	_patches.seed = world_seed + 3
	_patches.frequency = 0.011
	_patches.fractal_octaves = 2

	_forest.seed = world_seed + 4
	_forest.frequency = 0.0065
	_forest.fractal_octaves = 3


## Terrain height before the road is carved in. Valid everywhere (used for far scenery too).
func natural_height(x: float, z: float) -> float:
	var h := _hills.get_noise_2d(x, z) * 20.0 + _detail.get_noise_2d(x, z) * 2.0
	# Rounded-square rim: the playground edges rise into enclosing hills.
	var ax := absf(x)
	var az := absf(z)
	var rim := pow(ax * ax * ax * ax + az * az * az * az, 0.25)
	h += smoothstep(255.0, 360.0, rim) * 34.0
	# Distant mountain ranges.
	var radial := sqrt(x * x + z * z)
	var m := smoothstep(450.0, 1150.0, radial)
	if m > 0.0:
		var ridge := clampf(_mountains.get_noise_2d(x, z) * 0.5 + 0.5, 0.0, 1.0)
		h += m * (40.0 + ridge * ridge * 380.0)
	return h


func patch_noise(x: float, z: float) -> float:
	return _patches.get_noise_2d(x, z)


func forest_density(x: float, z: float) -> float:
	return _forest.get_noise_2d(x, z)


func build(road: RoadPath) -> void:
	road_half_width = road.half_width
	var count := VERTS * VERTS
	heights.resize(count)
	road_distance.resize(count)
	road_distance.fill(1e9)
	var road_height := PackedFloat32Array()
	road_height.resize(count)

	for j in VERTS:
		var z := -HALF_SIZE + j * CELL_SIZE
		for i in VERTS:
			heights[j * VERTS + i] = natural_height(-HALF_SIZE + i * CELL_SIZE, z)

	_rasterize_road(road, road_height)

	var core := road.half_width + 0.25
	var shoulder := road.half_width + ROAD_SHOULDER
	var reach := shoulder + ROAD_BLEND
	for idx in count:
		var d := road_distance[idx]
		if d >= reach:
			continue
		var rh := road_height[idx]
		if d <= core:
			heights[idx] = rh - ROAD_CORE_DROP
		elif d <= shoulder:
			heights[idx] = lerpf(rh - ROAD_CORE_DROP, rh - ROAD_SHOULDER_DROP, (d - core) / (shoulder - core))
		else:
			heights[idx] = lerpf(rh - ROAD_SHOULDER_DROP, heights[idx], smoothstep(shoulder, reach, d))


## For every grid vertex near the road, store the distance to the centreline and the road height there.
func _rasterize_road(road: RoadPath, road_height: PackedFloat32Array) -> void:
	var reach := road.half_width + ROAD_SHOULDER + ROAD_BLEND
	var n := road.points.size()
	for s in n:
		var a := road.points[s]
		var b := road.points[(s + 1) % n]
		var a2 := Vector2(a.x, a.z)
		var ab := Vector2(b.x, b.z) - a2
		var len2 := maxf(ab.length_squared(), 1e-6)
		var i0 := maxi(floori((minf(a.x, b.x) - reach + HALF_SIZE) / CELL_SIZE), 0)
		var i1 := mini(ceili((maxf(a.x, b.x) + reach + HALF_SIZE) / CELL_SIZE), CELLS)
		var j0 := maxi(floori((minf(a.z, b.z) - reach + HALF_SIZE) / CELL_SIZE), 0)
		var j1 := mini(ceili((maxf(a.z, b.z) + reach + HALF_SIZE) / CELL_SIZE), CELLS)
		for j in range(j0, j1 + 1):
			var z := -HALF_SIZE + j * CELL_SIZE
			for i in range(i0, i1 + 1):
				var p := Vector2(-HALF_SIZE + i * CELL_SIZE, z)
				var t := clampf((p - a2).dot(ab) / len2, 0.0, 1.0)
				var d := p.distance_to(a2 + ab * t)
				var idx := j * VERTS + i
				if d < road_distance[idx]:
					road_distance[idx] = d
					road_height[idx] = lerpf(a.y, b.y, t)


func is_inside(x: float, z: float) -> bool:
	return absf(x) <= HALF_SIZE and absf(z) <= HALF_SIZE


func vertex_position(i: int, j: int) -> Vector3:
	return Vector3(-HALF_SIZE + i * CELL_SIZE, heights[j * VERTS + i], -HALF_SIZE + j * CELL_SIZE)


## Height matching the rendered triangles (same diagonal split as the terrain mesh).
func get_height(x: float, z: float) -> float:
	if not is_inside(x, z):
		return natural_height(x, z) - FAR_DROP
	return _sample_grid(heights, x, z)


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
