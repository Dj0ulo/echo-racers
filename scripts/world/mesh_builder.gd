class_name MeshBuilder
extends RefCounted
## Accumulates flat-shaded, vertex-coloured triangles and turns them into an ArrayMesh.
## Godot treats clockwise triangles as front faces, so the face normal is (c - a) x (b - a).

var vertices := PackedVector3Array()
var normals := PackedVector3Array()
var colors := PackedColorArray()
var uvs := PackedVector2Array()
var use_uvs := false


func is_empty() -> bool:
	return vertices.is_empty()


func add_triangle(a: Vector3, b: Vector3, c: Vector3, color: Color) -> void:
	var n := (c - a).cross(b - a)
	if n.length_squared() < 1e-12:
		return
	_push(a, b, c, n.normalized(), color, color, color)


## Triangle with per-vertex colours and an explicit normal (used for soft-lit grass).
func add_triangle_shaded(a: Vector3, b: Vector3, c: Vector3, ca: Color, cb: Color, cc: Color, normal: Vector3) -> void:
	_push(a, b, c, normal, ca, cb, cc)


## Adds a triangle whose front face points along `facing` (winding is fixed automatically).
func add_triangle_facing(a: Vector3, b: Vector3, c: Vector3, facing: Vector3, color: Color,
		ua := Vector2.ZERO, ub := Vector2.ZERO, uc := Vector2.ZERO) -> void:
	var n := (c - a).cross(b - a)
	if n.length_squared() < 1e-12:
		return
	if n.dot(facing) < 0.0:
		var tmp := b
		b = c
		c = tmp
		var tmp_uv := ub
		ub = uc
		uc = tmp_uv
		n = -n
	_push(a, b, c, n.normalized(), color, color, color)
	if use_uvs:
		uvs.append(ua)
		uvs.append(ub)
		uvs.append(uc)


func add_quad_facing(a: Vector3, b: Vector3, c: Vector3, d: Vector3, facing: Vector3, color: Color) -> void:
	add_triangle_facing(a, b, c, facing, color)
	add_triangle_facing(a, c, d, facing, color)


## Adds triangles of a convex shape, orienting each so it faces away from `center`.
func add_triangle_outward(a: Vector3, b: Vector3, c: Vector3, center: Vector3, color: Color) -> void:
	add_triangle_facing(a, b, c, (a + b + c) / 3.0 - center, color)


## Adds a Godot primitive mesh (CylinderMesh, SphereMesh, BoxMesh...) as flat-shaded triangles.
## `jitter` displaces vertices deterministically (by position) for an organic low-poly look.
func add_primitive(mesh: PrimitiveMesh, xform: Transform3D, color: Color, jitter := 0.0, shade_variation := 0.0) -> void:
	var arrays := mesh.get_mesh_arrays()
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	if indices.is_empty():
		indices.resize(verts.size())
		for i in verts.size():
			indices[i] = i
	var moved := PackedVector3Array()
	moved.resize(verts.size())
	for i in verts.size():
		var v := verts[i]
		if jitter > 0.0:
			v += hash_vector(v) * jitter
		moved[i] = xform * v
	for t in range(0, indices.size(), 3):
		var a := moved[indices[t]]
		var b := moved[indices[t + 1]]
		var c := moved[indices[t + 2]]
		var col := color
		if shade_variation > 0.0:
			var k := 1.0 + (hash_scalar(a + b + c) * 2.0 - 1.0) * shade_variation
			col = Color(color.r * k, color.g * k, color.b * k, color.a)
		add_triangle(a, b, c, col)


func add_box(center: Vector3, size: Vector3, color: Color, basis := Basis.IDENTITY) -> void:
	var box := BoxMesh.new()
	box.size = size
	add_primitive(box, Transform3D(basis, center), color)


## Extrudes a convex side profile (points are (z, y)) across X.
## Each slice is Vector3(x, scale_z, scale_y): the profile is scaled about its centroid,
## so narrower end slices give bevelled, low-poly edges.
func add_loft(profile: PackedVector2Array, slices: Array[Vector3], color: Color) -> void:
	var centroid := Vector2.ZERO
	for p in profile:
		centroid += p
	centroid /= profile.size()
	var center := Vector3(0.0, centroid.y, centroid.x)
	var rings: Array[PackedVector3Array] = []
	for s in slices:
		var ring := PackedVector3Array()
		for p in profile:
			var q := centroid + (p - centroid) * Vector2(s.y, s.z)
			ring.append(Vector3(s.x, q.y, q.x))
		rings.append(ring)
	var count := profile.size()
	for r in rings.size() - 1:
		for k in count:
			var k2 := (k + 1) % count
			add_triangle_outward(rings[r][k], rings[r][k2], rings[r + 1][k2], center, color)
			add_triangle_outward(rings[r][k], rings[r + 1][k2], rings[r + 1][k], center, color)
	for cap: PackedVector3Array in [rings[0], rings[rings.size() - 1]]:
		for k in range(1, count - 1):
			add_triangle_outward(cap[0], cap[k], cap[k + 1], center, color)


func commit(material: Material = null) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if vertices.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	if use_uvs:
		arrays[Mesh.ARRAY_TEX_UV] = uvs
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if material:
		mesh.surface_set_material(0, material)
	return mesh


func _push(a: Vector3, b: Vector3, c: Vector3, n: Vector3, ca: Color, cb: Color, cc: Color) -> void:
	vertices.append(a)
	vertices.append(b)
	vertices.append(c)
	normals.append(n)
	normals.append(n)
	normals.append(n)
	colors.append(ca)
	colors.append(cb)
	colors.append(cc)


static func hash_scalar(p: Vector3) -> float:
	var h := sin(p.x * 12.9898 + p.y * 78.233 + p.z * 37.719) * 43758.5453
	return h - floorf(h)


static func hash_vector(p: Vector3) -> Vector3:
	return Vector3(
		hash_scalar(p) * 2.0 - 1.0,
		hash_scalar(p + Vector3(17.1, 3.3, 9.7)) * 2.0 - 1.0,
		hash_scalar(p + Vector3(5.9, 41.2, 23.5)) * 2.0 - 1.0)
