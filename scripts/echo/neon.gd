class_name Neon
extends RefCounted
## Shared neon look of the echo mode: colours plus additive glow, light-beam, hologram and ribbon shaders. The
## environment's glow turns their above-1 brightness into bloom. Materials are per instance so callers can
## animate their colour/energy.

const CYAN := Color(0.25, 0.85, 1.0)
const BLUE := Color(0.22, 0.45, 1.0)
const START := Color(0.35, 1.0, 0.7)
const FINISH := Color(1.0, 0.35, 0.85)
const REC := Color(1.0, 0.25, 0.3)

const _GLOW_CODE := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;
uniform vec4 color : source_color = vec4(0.25, 0.85, 1.0, 1.0);
uniform float energy = 2.0;
void fragment() {
	ALBEDO = color.rgb * energy;
}
"""

## Hollow light column: bright silhouette edges, fades out toward the top, slow upward scan bands.
const _BEAM_CODE := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;
uniform vec4 color : source_color = vec4(0.25, 0.85, 1.0, 1.0);
uniform float energy = 1.0;
uniform float height = 1.0;
uniform float bands = 6.0;
varying float h;
void vertex() {
	h = VERTEX.y / height + 0.5;
}
void fragment() {
	float t = clamp(h, 0.0, 1.0);
	float fade = pow(1.0 - t, 1.6);
	float rim = 1.0 - abs(dot(NORMAL, VIEW));
	float scan = 0.75 + 0.25 * sin((t * bands - TIME * 0.6) * 6.2832);
	ALBEDO = color.rgb * energy * fade * (0.12 + 0.9 * rim * rim) * scan;
}
"""

## See-through car: faint faces, glowing silhouette, scrolling scan lines.
const _HOLO_CODE := """
shader_type spatial;
render_mode unshaded, blend_add, cull_back, depth_draw_never, shadows_disabled;
uniform vec4 color : source_color = vec4(0.35, 0.8, 1.0, 1.0);
uniform float energy = 1.0;
void fragment() {
	float rim = 1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float scan = 0.8 + 0.2 * sin(FRAGCOORD.y * 0.7 + TIME * 9.0);
	ALBEDO = color.rgb * energy * (0.14 + 1.4 * rim * rim) * scan;
}
"""

## Vertex-coloured path ribbon drawn over everything (top-view editor).
const _RIBBON_CODE := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, shadows_disabled, fog_disabled;
uniform float energy = 1.4;
void fragment() {
	ALBEDO = COLOR.rgb * energy;
	ALPHA = 0.92;
}
"""

static var _shaders := {}


static func glow_material(color: Color, energy := 2.0) -> ShaderMaterial:
	return _material(_GLOW_CODE, {&"color": color, &"energy": energy})


static func beam_material(color: Color, height: float, energy := 1.0, bands := 6.0) -> ShaderMaterial:
	return _material(_BEAM_CODE, {&"color": color, &"energy": energy, &"height": height, &"bands": bands})


static func hologram_material(color: Color, energy := 1.0) -> ShaderMaterial:
	return _material(_HOLO_CODE, {&"color": color, &"energy": energy})


static func ribbon_material() -> ShaderMaterial:
	return _material(_RIBBON_CODE, {})


## A few glowing sparks drifting upward from a box (or a flat ring when `ring_radius` > 0).
static func sparks(color: Color, extents: Vector3, amount := 10, ring_radius := 0.0) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = amount
	p.lifetime = 1.8
	p.randomness = 0.5
	var pm := ParticleProcessMaterial.new()
	if ring_radius > 0.0:
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
		pm.emission_ring_axis = Vector3.UP
		pm.emission_ring_radius = ring_radius
		pm.emission_ring_inner_radius = ring_radius * 0.92
		pm.emission_ring_height = 0.2
	else:
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		pm.emission_box_extents = extents
	pm.direction = Vector3.UP
	pm.spread = 18.0
	pm.initial_velocity_min = 0.6
	pm.initial_velocity_max = 2.4
	pm.gravity = Vector3(0, 0.5, 0)
	pm.scale_min = 0.5
	pm.scale_max = 1.0
	var ramp := Gradient.new()
	ramp.set_color(0, Color.WHITE)
	ramp.set_color(1, Color.BLACK)
	var ramp_tex := GradientTexture1D.new()
	ramp_tex.gradient = ramp
	pm.color_ramp = ramp_tex
	p.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(0.18, 0.18)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(color.r * 3.0, color.g * 3.0, color.b * 3.0)
	mat.disable_fog = true
	quad.material = mat
	p.draw_pass_1 = quad
	var reach := maxf(ring_radius, maxf(extents.x, extents.z)) + 2.0
	p.visibility_aabb = AABB(Vector3(-reach, -1.0, -reach), Vector3(reach * 2.0, 8.0, reach * 2.0))
	return p


static func _material(code: String, params: Dictionary) -> ShaderMaterial:
	if not _shaders.has(code):
		var shader := Shader.new()
		shader.code = code
		_shaders[code] = shader
	var mat := ShaderMaterial.new()
	mat.shader = _shaders[code]
	for key: StringName in params:
		mat.set_shader_parameter(key, params[key])
	return mat
