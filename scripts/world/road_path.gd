class_name RoadPath
extends RefCounted
## Closed road loop: a Catmull-Rom spline through control points, resampled at even spacing.
## Heights follow the terrain but are smoothed along the road so grades stay drivable.

const SAMPLE_SPACING := 2.0

var half_width := 4.5
var points := PackedVector3Array()    ## Centreline samples (with height).
var tangents := PackedVector3Array()  ## Horizontal unit tangents.
var distances := PackedFloat32Array() ## Distance along the loop at each sample.
var length := 0.0


func build(control_points: PackedVector2Array, height_func: Callable, smoothing_window := 30, smoothing_passes := 3) -> void:
	var dense := _sample_spline(control_points, 48)
	_resample(dense)
	_compute_heights(height_func, smoothing_window, smoothing_passes)
	_compute_tangents()


func sample_count() -> int:
	return points.size()


## Unit vector pointing to the right of the driving direction at sample `i`.
func right_at(i: int) -> Vector3:
	var t := tangents[i]
	return Vector3(-t.z, 0.0, t.x)


func transform_at(i: int, lift := 0.0) -> Transform3D:
	i = posmod(i, points.size())
	var basis := Basis.looking_at(tangents[i], Vector3.UP)
	return Transform3D(basis, points[i] + Vector3.UP * lift)


func nearest_index(pos: Vector3) -> int:
	var best := 0
	var best_d := INF
	for i in points.size():
		var d := Vector2(points[i].x - pos.x, points[i].z - pos.z).length_squared()
		if d < best_d:
			best_d = d
			best = i
	return best


func _sample_spline(control: PackedVector2Array, steps: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := control.size()
	for i in n:
		var p0 := control[posmod(i - 1, n)]
		var p1 := control[i]
		var p2 := control[(i + 1) % n]
		var p3 := control[(i + 2) % n]
		for s in steps:
			out.append(_catmull_rom(p0, p1, p2, p3, float(s) / steps))
	return out


func _resample(dense: PackedVector2Array) -> void:
	points.clear()
	distances.clear()
	var n := dense.size()
	var total := 0.0
	for i in n:
		total += dense[i].distance_to(dense[(i + 1) % n])
	var count := int(round(total / SAMPLE_SPACING))
	var step := total / count
	length = total
	var seg := 0
	var seg_start := 0.0
	var seg_len := dense[0].distance_to(dense[1])
	for k in count:
		var target := k * step
		while seg_start + seg_len < target and seg < n - 1:
			seg_start += seg_len
			seg += 1
			seg_len = dense[seg].distance_to(dense[(seg + 1) % n])
		var t := clampf((target - seg_start) / maxf(seg_len, 1e-6), 0.0, 1.0)
		var p := dense[seg].lerp(dense[(seg + 1) % n], t)
		points.append(Vector3(p.x, 0.0, p.y))
		distances.append(target)


func _compute_heights(height_func: Callable, window: int, passes: int) -> void:
	var n := points.size()
	var h := PackedFloat32Array()
	h.resize(n)
	for i in n:
		h[i] = height_func.call(points[i].x, points[i].z)
	# Circular moving average keeps the loop seamless.
	for _pass in passes:
		var smoothed := PackedFloat32Array()
		smoothed.resize(n)
		for i in n:
			var sum := 0.0
			for k in range(-window, window + 1):
				sum += h[posmod(i + k, n)]
			smoothed[i] = sum / (window * 2 + 1)
		h = smoothed
	for i in n:
		points[i].y = h[i]


func _compute_tangents() -> void:
	var n := points.size()
	tangents.resize(n)
	for i in n:
		var d := points[(i + 1) % n] - points[posmod(i - 1, n)]
		tangents[i] = Vector3(d.x, 0.0, d.z).normalized()


static func _catmull_rom(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * ((2.0 * p1) + (p2 - p0) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (3.0 * p1 - p0 - 3.0 * p2 + p3) * t3)
