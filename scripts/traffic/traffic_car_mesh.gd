class_name TrafficCarMesh
extends RefCounted
## Lightweight procedural low-poly cars for traffic. Forward is -Z, origin on the ground between the axles.
## Everything except the lights is baked into one vertex-coloured mesh (wheels, glass, bumpers).
## Tail lights have a per-car material (braking); headlight lenses and the additive light pool they throw on
## the road share one material each, driven for the whole fleet by `set_headlights()` (DayNight).

enum Kind { SEDAN, HATCH, VAN, PICKUP, TRUCK }

const GLASS := Color(0.12, 0.15, 0.2)
const TYRE := Color(0.1, 0.1, 0.11)
const RIM := Color(0.62, 0.63, 0.66)
const TRIM := Color(0.14, 0.14, 0.15)
const HEADLIGHT := Color(1.0, 0.97, 0.86)

## Paint colours: muted everyday cars plus a few bright ones.
const PAINTS := [
	Color(0.85, 0.85, 0.83), Color(0.12, 0.12, 0.14), Color(0.55, 0.57, 0.6), Color(0.2, 0.32, 0.6),
	Color(0.7, 0.12, 0.1), Color(0.16, 0.42, 0.3), Color(0.92, 0.75, 0.2), Color(0.35, 0.62, 0.82),
	Color(0.95, 0.95, 0.95), Color(0.45, 0.25, 0.15), Color(0.85, 0.42, 0.12), Color(0.5, 0.15, 0.4),
]

## Per kind: length, width, wheel radius, collision height.
const SPECS := {
	Kind.SEDAN: [4.5, 1.78, 0.33, 1.45],
	Kind.HATCH: [3.9, 1.72, 0.32, 1.45],
	Kind.VAN: [4.9, 1.9, 0.35, 1.95],
	Kind.PICKUP: [5.0, 1.9, 0.38, 1.65],
	Kind.TRUCK: [7.6, 2.4, 0.46, 3.2],
}

## Group of the per-car headlight pool nodes (hidden in daylight).
const HEADLIGHT_GROUP := &"traffic_headlights"
const POOL_LENGTH := 16.0  ## Metres of road lit ahead of the bumper.

const _POOL_CODE := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;
uniform float intensity = 0.0;
void fragment() {
	float across = 1.0 - abs(UV.x * 2.0 - 1.0);
	float along = smoothstep(0.0, 0.12, UV.y) * pow(1.0 - UV.y, 1.6);
	ALBEDO = vec3(1.0, 0.86, 0.6) * intensity * 0.55 * along * smoothstep(0.0, 0.6, across);
}
"""

static var _tail_base: StandardMaterial3D
static var _lens_material: StandardMaterial3D
static var _pool_material: ShaderMaterial
static var _pool_mesh := {}  ## kind -> ArrayMesh
static var headlights := 0.0  ## 0 (day) .. 1 (night), see set_headlights().


static func length_of(kind: int) -> float:
	return SPECS[kind][0]


static func width_of(kind: int) -> float:
	return SPECS[kind][1]


static func height_of(kind: int) -> float:
	return SPECS[kind][3]


## Returns [body mesh, tail-light mesh, headlight-lens mesh]. The tail-light mesh has no material (set one
## per car for braking); the lens mesh uses `lens_material()`.
static func build(kind: int, paint: Color) -> Array:
	var spec: Array = SPECS[kind]
	var length: float = spec[0]
	var width: float = spec[1]
	var radius: float = spec[2]
	var hl := length * 0.5
	var hw := width * 0.5
	var body := MeshBuilder.new()
	var tail := MeshBuilder.new()
	var head := MeshBuilder.new()
	var outer := [Vector3(-hw, 0.95, 0.8), Vector3(-hw + 0.08, 1.0, 1.0), Vector3(hw - 0.08, 1.0, 1.0), Vector3(hw, 0.95, 0.8)]
	var inner := [Vector3(-hw + 0.1, 0.92, 0.9), Vector3(-hw + 0.17, 1.0, 1.0), Vector3(hw - 0.17, 1.0, 1.0), Vector3(hw - 0.1, 0.92, 0.9)]
	var lights_y := 0.72
	match kind:
		Kind.SEDAN:
			_loft(body, [[-2.0, 0.3], [-2.25, 0.42], [-2.25, 0.72], [-2.05, 0.88], [-0.9, 0.97], [1.5, 1.0],
				[2.2, 0.95], [2.25, 0.42], [2.0, 0.3]], outer, paint)
			_loft(body, [[-0.9, 0.96], [-0.25, 1.42], [0.95, 1.42], [1.5, 0.99]], inner, GLASS)
			_loft(body, [[-0.18, 1.4], [0.9, 1.4], [0.88, 1.46], [-0.14, 1.46]], inner, paint)
		Kind.HATCH:
			_loft(body, [[-1.75, 0.3], [-1.95, 0.42], [-1.95, 0.7], [-1.75, 0.86], [-0.8, 0.95], [1.85, 0.98],
				[1.95, 0.9], [1.95, 0.42], [1.75, 0.3]], outer, paint)
			_loft(body, [[-0.8, 0.94], [-0.15, 1.42], [1.55, 1.42], [1.9, 0.96]], inner, GLASS)
			_loft(body, [[-0.08, 1.4], [1.5, 1.4], [1.5, 1.46], [-0.04, 1.46]], inner, paint)
		Kind.VAN:
			_loft(body, [[-2.2, 0.32], [-2.45, 0.45], [-2.45, 0.85], [-2.25, 1.02], [2.45, 1.06], [2.45, 0.45],
				[2.25, 0.32]], outer, paint)
			_loft(body, [[-2.25, 1.0], [-1.55, 1.85], [-1.15, 1.9], [-1.15, 1.0]], inner, GLASS)
			_loft(body, [[-1.2, 1.0], [-1.2, 1.95], [2.45, 1.95], [2.45, 1.0]], outer, paint)
			lights_y = 0.8
		Kind.PICKUP:
			_loft(body, [[-2.3, 0.4], [-2.5, 0.52], [-2.5, 0.88], [-2.3, 1.02], [2.5, 1.04], [2.5, 0.52],
				[2.3, 0.4]], outer, paint)
			_loft(body, [[-1.2, 1.0], [-0.6, 1.62], [0.35, 1.62], [0.45, 1.0]], inner, GLASS)
			_loft(body, [[-0.55, 1.6], [0.33, 1.6], [0.33, 1.66], [-0.5, 1.66]], inner, paint)
			for xs in [-1.0, 1.0]:
				body.add_box(Vector3(xs * (hw - 0.06), 1.17, 1.5), Vector3(0.1, 0.3, 2.0), paint)
			body.add_box(Vector3(0, 1.17, 2.46), Vector3(width - 0.1, 0.3, 0.08), paint)
			lights_y = 0.85
		Kind.TRUCK:
			_loft(body, [[-3.5, 0.55], [-3.8, 0.7], [-3.8, 1.5], [-3.6, 2.45], [-2.3, 2.5], [-2.3, 0.55]], outer, paint)
			_loft(body, [[-3.78, 1.55], [-3.62, 2.35], [-3.1, 2.38], [-3.1, 1.55]], inner, GLASS)
			body.add_box(Vector3(0, 0.62, 0.6), Vector3(1.2, 0.3, 6.2), TRIM)
			body.add_box(Vector3(0, 1.95, 0.75), Vector3(width, 2.5, 5.9), Color(0.92, 0.92, 0.9).lerp(paint, 0.15))
			lights_y = 0.9
	# Bumpers, lights and wheels.
	body.add_box(Vector3(0, 0.36, -hl + 0.02), Vector3(width - 0.2, 0.14, 0.1), TRIM)
	body.add_box(Vector3(0, 0.36, hl - 0.02), Vector3(width - 0.2, 0.14, 0.1), TRIM)
	for xs in [-1.0, 1.0]:
		head.add_box(Vector3(xs * (hw - 0.3), lights_y - 0.1, -hl - 0.01), Vector3(0.36, 0.12, 0.06), HEADLIGHT)
		tail.add_box(Vector3(xs * (hw - 0.28), lights_y, hl + 0.01), Vector3(0.34, 0.12, 0.06), Color.WHITE)
	var axle := hl - 0.8 if kind != Kind.TRUCK else hl - 1.1
	var axis := Basis(Vector3.BACK, PI * 0.5)
	for z in [-axle, axle]:
		for xs in [-1.0, 1.0]:
			var c := Vector3(xs * (hw - 0.14), radius, z)
			body.add_primitive(SceneryMeshes.cylinder(radius, radius, 0.26, 8), Transform3D(axis, c), TYRE)
			body.add_primitive(SceneryMeshes.cylinder(radius * 0.55, radius * 0.55, 0.27, 6), Transform3D(axis, c), RIM)
	return [body.commit(Palette.vertex_material(0.5)), tail.commit(), head.commit(lens_material())]


## Shared emissive material of every traffic car's headlight lenses.
static func lens_material() -> StandardMaterial3D:
	if _lens_material == null:
		_lens_material = StandardMaterial3D.new()
		_lens_material.vertex_color_use_as_albedo = true
		_lens_material.emission_enabled = true
		_lens_material.emission = Color(1.0, 0.95, 0.8)
		_set_lens_energy()
	return _lens_material


## Flat trapezoid of additive light on the ground ahead of a car of this kind (shared material).
static func pool_mesh(kind: int) -> ArrayMesh:
	if _pool_mesh.has(kind):
		return _pool_mesh[kind]
	var spec: Array = SPECS[kind]
	var hl: float = spec[0] * 0.5
	var hw: float = spec[1] * 0.5
	var z0 := -hl - 0.2
	var z1 := z0 - POOL_LENGTH
	var verts := PackedVector3Array([Vector3(-hw, 0.06, z0), Vector3(hw, 0.06, z0),
		Vector3(-hw - 2.2, 0.06, z1), Vector3(hw + 2.2, 0.06, z1)])
	var uvs := PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 1, 3, 2])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if _pool_material == null:
		var shader := Shader.new()
		shader.code = _POOL_CODE
		_pool_material = ShaderMaterial.new()
		_pool_material.shader = shader
		_pool_material.set_shader_parameter(&"intensity", headlights)
	mesh.surface_set_material(0, _pool_material)
	_pool_mesh[kind] = mesh
	return mesh


## Headlights of the whole traffic fleet: 0 = day .. 1 = full night.
static func set_headlights(v: float) -> void:
	headlights = clampf(v, 0.0, 1.0)
	_set_lens_energy()
	if _pool_material:
		_pool_material.set_shader_parameter(&"intensity", headlights)


static func _set_lens_energy() -> void:
	if _lens_material:
		_lens_material.emission_energy_multiplier = 0.15 + headlights * 5.0


static func tail_material() -> StandardMaterial3D:
	if _tail_base == null:
		_tail_base = StandardMaterial3D.new()
		_tail_base.albedo_color = Color(0.6, 0.03, 0.03)
		_tail_base.emission_enabled = true
		_tail_base.emission = Color(1.0, 0.08, 0.05)
		_tail_base.emission_energy_multiplier = 0.6
	return _tail_base.duplicate() as StandardMaterial3D


## Extrudes a side profile ([z, y] pairs) across X using MeshBuilder.add_loft.
static func _loft(mb: MeshBuilder, profile: Array, slices: Array, color: Color) -> void:
	var pts := PackedVector2Array()
	for p: Array in profile:
		pts.append(Vector2(p[0], p[1]))
	var typed: Array[Vector3] = []
	for s: Vector3 in slices:
		typed.append(s)
	mb.add_loft(pts, typed, color)
