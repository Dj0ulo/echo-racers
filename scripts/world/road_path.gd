class_name RoadPath
extends RefCounted
## A road: a Catmull-Rom spline through control points, resampled at even spacing. Closed loops and
## open roads (e.g. a link that ends in a T-junction on another road) are both supported.
## Heights follow the terrain but are smoothed along the road so grades stay drivable.
##
## Cross-section (symmetric about the centreline):
##   | shoulder | lane x lanes_per_side | median | lane x lanes_per_side | shoulder |
## A country road is 1 lane per side, no median; the highway is 2 lanes per side with a median.
## A one-way road (interchange ramp) has a single lane centred on the road, driven along increasing distance.

const SAMPLE_SPACING := 2.0

var name := &"road"
var closed := true
var is_highway := false
var half_width := 4.5
var lanes_per_side := 1
var lane_width := 4.05      ## Distance between lane lines (the outer edge line sits at median/2 + lanes * lane_width).
var median_width := 0.0
var dash_length := 4.0
var dash_gap := 5.0
var terrain_blend := 14.0   ## Minimum distance over which the terrain blends back to its natural height.
var terrain_reach := 22.0   ## Max distance past the road edge the terrain may be reshaped (embankments, cuttings).
var one_way := false
## Distance ranges (x = from, y = to) carried by a bridge: the terrain is not shaped to the road there.
var bridges := PackedVector2Array()
## Distance ranges (x = from, y = to, z = side: +1 right, -1 left) where the outer edge line is dashed
## (where a ramp diverges from or merges into this road).
var edge_dashes := PackedVector3Array()

var points := PackedVector3Array()    ## Centreline samples (with height).
var tangents := PackedVector3Array()  ## Horizontal unit tangents.
var distances := PackedFloat32Array() ## Distance along the road at each sample.
var advisory_speed := PackedFloat32Array()  ## Comfortable speed (m/s) from local curvature, used by traffic.
var length := 0.0
var step := SAMPLE_SPACING            ## Exact spacing between samples.


func sample_count() -> int:
	return points.size()


## Builds the road. `pins` optionally holds {"start": height, "end": height} to force the end heights
## of an open road (to meet the road it joins); the correction fades out over `pin_blend` metres.
func build(control_points: PackedVector2Array, height_func: Callable, smoothing_window := 30, smoothing_passes := 3,
		pins := {}, pin_blend := 70.0) -> void:
	var dense := _sample_spline(control_points, 48)
	_resample(dense)
	_compute_heights(height_func, smoothing_window, smoothing_passes)
	_apply_pins(pins, pin_blend)
	_compute_tangents()
	_compute_advisory_speeds()


## Lateral offset (from the centreline, + = right of the tangent) of every lane. Lanes with a positive
## offset run along increasing distance; negative ones run the other way (right-hand traffic).
func lane_offsets() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if one_way:
		out.append(0.0)
		return out
	for k in lanes_per_side:
		var offset := median_width * 0.5 + (k + 0.5) * lane_width
		out.append(offset)
		out.append(-offset)
	return out


func is_bridge(i: int) -> bool:
	var d := distances[wrap_index(i)]
	for r in bridges:
		if d >= r.x and d <= r.y:
			return true
	return false


## Blends the road heights to `height` over [center - half_flat, center + half_flat], fading back to the
## current profile over `blend` metres on either side (used for bridge approaches).
func flatten(center: float, half_flat: float, blend: float, height: float) -> void:
	for i in points.size():
		var w := 1.0 - smoothstep(half_flat, half_flat + blend, absf(distances[i] - center))
		points[i].y = lerpf(points[i].y, height, w)


## Unit vector pointing to the right of the driving direction at sample `i`.
func right_at(i: int) -> Vector3:
	var t := tangents[i]
	return Vector3(-t.z, 0.0, t.x)


func wrap_index(i: int) -> int:
	return posmod(i, points.size()) if closed else clampi(i, 0, points.size() - 1)


func transform_at(i: int, lift := 0.0, lateral := 0.0, reverse := false) -> Transform3D:
	i = wrap_index(i)
	var dir := -tangents[i] if reverse else tangents[i]
	var basis := Basis.looking_at(dir, Vector3.UP)
	return Transform3D(basis, points[i] + right_at(i) * lateral + Vector3.UP * lift)


func nearest_index(pos: Vector3) -> int:
	var best := 0
	var best_d := INF
	for i in points.size():
		var d := Vector2(points[i].x - pos.x, points[i].z - pos.z).length_squared()
		if d < best_d:
			best_d = d
			best = i
	return best


func wrap_distance(s: float) -> float:
	return fposmod(s, length) if closed else clampf(s, 0.0, length)


## Interpolated centreline sample at distance `s`: returns [position, horizontal tangent, sample index].
func sample_at(s: float) -> Array:
	s = wrap_distance(s)
	var f := s / step
	var i := mini(int(f), points.size() - 1)
	var j := wrap_index(i + 1)
	var t := clampf(f - i, 0.0, 1.0)
	var p := points[i].lerp(points[j], t)
	var tangent := tangents[i].lerp(tangents[j], t).normalized()
	return [p, tangent, i]


func _sample_spline(control: PackedVector2Array, steps: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := control.size()
	var segments := n if closed else n - 1
	for i in segments:
		var p1 := control[i]
		var p2 := control[(i + 1) % n]
		var p0: Vector2
		var p3: Vector2
		if closed:
			p0 = control[posmod(i - 1, n)]
			p3 = control[(i + 2) % n]
		else:
			p0 = control[i - 1] if i > 0 else p1 * 2.0 - p2
			p3 = control[i + 2] if i + 2 < n else p2 * 2.0 - p1
		for s in steps:
			var t := float(s) / steps
			# Open roads (links, ramps, outer roads) mix very short and long control segments, where the uniform
			# spline overshoots and loops; the centripetal form doesn't.
			out.append(_catmull_rom(p0, p1, p2, p3, t) if closed else _catmull_rom_centripetal(p0, p1, p2, p3, t))
	if not closed:
		out.append(control[n - 1])
	return out


func _resample(dense: PackedVector2Array) -> void:
	points.clear()
	distances.clear()
	var n := dense.size()
	var seg_count := n if closed else n - 1
	var total := 0.0
	for i in seg_count:
		total += dense[i].distance_to(dense[(i + 1) % n])
	var count := maxi(int(round(total / SAMPLE_SPACING)), 2)
	step = total / count
	length = total
	var seg := 0
	var seg_start := 0.0
	var seg_len := dense[0].distance_to(dense[1])
	var samples := count if closed else count + 1
	for k in samples:
		var target := k * step
		while seg_start + seg_len < target and seg < seg_count - 1:
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
	# Moving average (circular on loops so they stay seamless) using a running sum.
	for _pass in passes:
		var smoothed := PackedFloat32Array()
		smoothed.resize(n)
		var sum := 0.0
		for k in range(-window, window + 1):
			sum += h[wrap_index(k)]
		for i in n:
			smoothed[i] = sum / (window * 2 + 1)
			sum += h[wrap_index(i + window + 1)] - h[wrap_index(i - window)]
		h = smoothed
	for i in n:
		points[i].y = h[i]


func _apply_pins(pins: Dictionary, blend: float) -> void:
	if closed or pins.is_empty():
		return
	var n := points.size()
	var start_fix: float = pins.get("start", points[0].y) - points[0].y
	var end_fix: float = pins.get("end", points[n - 1].y) - points[n - 1].y
	for i in n:
		var d := distances[i]
		var ws := 1.0 - smoothstep(0.0, blend, d)
		var we := 1.0 - smoothstep(0.0, blend, length - d)
		points[i].y += start_fix * ws + end_fix * we


func _compute_tangents() -> void:
	var n := points.size()
	tangents.resize(n)
	for i in n:
		var d := points[wrap_index(i + 1)] - points[wrap_index(i - 1)]
		tangents[i] = Vector3(d.x, 0.0, d.z).normalized()


func _compute_advisory_speeds() -> void:
	const LATERAL_ACCEL := 3.2  # m/s^2: relaxed everyday driving.
	const SPAN := 4              # Samples either side used to measure the heading change.
	var n := points.size()
	var raw := PackedFloat32Array()
	raw.resize(n)
	for i in n:
		var a := tangents[wrap_index(i - SPAN)]
		var b := tangents[wrap_index(i + SPAN)]
		var curvature := a.angle_to(b) / (2.0 * SPAN * step)
		raw[i] = sqrt(LATERAL_ACCEL / maxf(curvature, 1e-5))
	# Look ahead/behind ~70 m so cars slow down before a bend, in either driving direction.
	var reach := int(70.0 / step)
	advisory_speed.resize(n)
	for i in n:
		var v := raw[i]
		for k in range(-reach, reach + 1, 3):
			v = minf(v, raw[wrap_index(i + k)] + absf(k) * step * 0.12)
		advisory_speed[i] = v


## Smallest turn radius (m) and steepest grade (%) along the road, for the generation log.
func stats() -> Vector2:
	var min_radius := INF
	var max_grade := 0.0
	var n := points.size()
	for i in n:
		var a := tangents[wrap_index(i - 5)]
		var b := tangents[wrap_index(i + 5)]
		var ang := a.angle_to(b)
		if ang > 1e-5:
			min_radius = minf(min_radius, 10.0 * step / ang)
		if closed or i < n - 1:
			var j := wrap_index(i + 1)
			max_grade = maxf(max_grade, absf(points[j].y - points[i].y) / step * 100.0)
	return Vector2(min_radius, max_grade)


static func _catmull_rom_centripetal(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, u: float) -> Vector2:
	var t1 := sqrt(maxf(p0.distance_to(p1), 1e-3))
	var t2 := t1 + sqrt(maxf(p1.distance_to(p2), 1e-3))
	var t3 := t2 + sqrt(maxf(p2.distance_to(p3), 1e-3))
	var t := lerpf(t1, t2, u)
	var a1 := p0.lerp(p1, t / t1)
	var a2 := p1.lerp(p2, (t - t1) / (t2 - t1))
	var a3 := p2.lerp(p3, (t - t2) / (t3 - t2))
	var b1 := a1.lerp(a2, t / t2)
	var b2 := a2.lerp(a3, (t - t1) / (t3 - t1))
	return b1.lerp(b2, (t - t1) / (t2 - t1))


static func _catmull_rom(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * ((2.0 * p1) + (p2 - p0) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (3.0 * p1 - p0 - 3.0 * p2 + p3) * t3)
