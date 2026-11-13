class_name CarVisuals
extends Node3D
## Procedural low-poly sports car body, animated wheels, brake lights, headlights (night), tyre smoke and
## nitro flames from the twin exhausts while boosting.
## Reads state from the parent CarController; never affects physics.

@export var paint_color := Color(0.96, 0.36, 0.09)
@export var trim_color := Color(0.09, 0.09, 0.10)
@export var smoke_slip_threshold := 3.0  ## Lateral slip (m/s) above which tyres smoke.
@export var max_visual_spin := 45.0      ## Caps wheel spin (rad/s) to avoid strobing.
@export var headlight_energy := 6.0      ## Energy of each headlight spot at full night.
@export var nitro_length := 2.2          ## Flame length (m) at full boost.
@export var nitro_light_energy := 2.5    ## Blue glow thrown on the road behind the car.

const EXHAUST_X := 0.42
const EXHAUST_Y := -0.13
const EXHAUST_Z := 2.27

const _FLAME_CODE := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;
uniform float intensity = 0.0;
uniform vec3 inner : source_color = vec3(0.85, 0.92, 1.0);
uniform vec3 outer : source_color = vec3(0.15, 0.35, 1.0);
uniform vec3 tip : source_color = vec3(0.7, 0.2, 1.0);
uniform float energy = 4.0;
void fragment() {
	float along = clamp(1.0 - UV.y, 0.0, 1.0);  // 0 at the pipe, 1 at the tip.
	float edge = pow(clamp(abs(dot(NORMAL, VIEW)), 0.0, 1.0), 1.3);
	float flicker = 0.8 + 0.2 * sin(TIME * 63.0 + along * 18.0) * sin(TIME * 41.0);
	// Shock diamonds: bright bands travelling down the flame.
	float bands = 0.75 + 0.25 * smoothstep(0.4, 1.0, sin(along * 22.0 - TIME * 40.0));
	vec3 col = mix(inner, outer, smoothstep(0.0, 0.35, along));
	col = mix(col, tip, smoothstep(0.45, 1.0, along));
	ALBEDO = col * energy * intensity * edge * flicker * bands * (1.0 - smoothstep(0.55, 1.0, along));
}
"""

var _car: CarController
var _wheel_pivots: Array[Node3D] = []
var _wheel_spinners: Array[Node3D] = []
var _smoke: Array[GPUParticles3D] = []
var _smoke_materials: Array[ParticleProcessMaterial] = []
var _tail_material: StandardMaterial3D
var _head_material: StandardMaterial3D
var _headlights: Array[SpotLight3D] = []
var _flames: Array[MeshInstance3D] = []
var _flame_material: ShaderMaterial
var _nitro_light: OmniLight3D
var _nitro_sparks: GPUParticles3D
var _nitro := 0.0  ## Smoothed 0..1 flame strength.

## 0 = off (day) .. 1 = full headlights (night); set by DayNight.
var headlights := 0.0:
	set(v):
		headlights = clampf(v, 0.0, 1.0)
		_apply_headlights()
var _visual_spin: Array[float] = [0.0, 0.0, 0.0, 0.0]


func _ready() -> void:
	_car = get_parent() as CarController
	# Children are ready before their parent: wait until the controller has created its wheels.
	if not _car.is_node_ready():
		set_physics_process(false)
		await _car.ready
		set_physics_process(true)
	_build_body()
	_build_wheels()
	_build_smoke()
	_build_headlights()
	_build_nitro()


func _physics_process(delta: float) -> void:
	for i in _car.wheels.size():
		var w := _car.wheels[i]
		var pivot := _wheel_pivots[i]
		pivot.position = Vector3(w.mount.x, w.mount.y - w.suspension_length, w.mount.z)
		pivot.rotation.y = -w.steer_angle
		var spin := clampf(w.forward_speed / _car.wheel_radius, -max_visual_spin, max_visual_spin)
		if _car.input.handbrake and not w.is_front:
			spin = 0.0
		_visual_spin[i] = wrapf(_visual_spin[i] + spin * delta, 0.0, TAU)
		_wheel_spinners[i].rotation.x = -_visual_spin[i]

	for k in _smoke.size():
		var w := _car.wheels[2 + k]
		var sliding := absf(w.lateral_slip) > smoke_slip_threshold
		var locked := _car.input.handbrake and absf(_car.speed) > 5.0
		_smoke[k].emitting = w.grounded and (sliding or locked)
		_smoke[k].position = Vector3(w.mount.x, w.mount.y - w.suspension_length - _car.wheel_radius + 0.15, w.mount.z + 0.2)
		_smoke_materials[k].color = Color(0.92, 0.92, 0.92) if w.surface == &"road" else Color(0.62, 0.53, 0.40)

	_tail_material.emission_energy_multiplier = (4.0 if _car.is_braking else 1.2) + headlights * 1.5
	_update_nitro(delta)


## Twin exhaust flames (additive cones with shock diamonds), a blue glow and sparks while boosting.
func _build_nitro() -> void:
	var shader := Shader.new()
	shader.code = _FLAME_CODE
	_flame_material = ShaderMaterial.new()
	_flame_material.shader = shader
	for xs in [-1.0, 1.0]:
		for layer in 2:  # Wide blue outer flame, then a short white-hot core.
			var cone := CylinderMesh.new()
			cone.top_radius = 0.0
			cone.bottom_radius = 0.15 if layer == 0 else 0.07
			cone.height = 1.0
			cone.radial_segments = 10
			cone.rings = 1
			cone.cap_top = false
			cone.cap_bottom = false
			var mi := MeshInstance3D.new()
			mi.mesh = cone
			mi.material_override = _flame_material
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.set_meta(&"core", layer == 1)
			mi.position = Vector3(xs * EXHAUST_X, EXHAUST_Y, EXHAUST_Z)
			mi.visible = false
			add_child(mi)
			_flames.append(mi)
	_nitro_light = OmniLight3D.new()
	_nitro_light.light_color = Color(0.35, 0.55, 1.0)
	_nitro_light.omni_range = 5.0
	_nitro_light.omni_attenuation = 1.6
	_nitro_light.position = Vector3(0, 0.1, EXHAUST_Z + 0.8)
	_nitro_light.visible = false
	add_child(_nitro_light)

	_nitro_sparks = GPUParticles3D.new()
	_nitro_sparks.amount = 40
	_nitro_sparks.lifetime = 0.22
	_nitro_sparks.emitting = false
	_nitro_sparks.local_coords = false
	_nitro_sparks.position = Vector3(0, EXHAUST_Y, EXHAUST_Z + 0.1)
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(EXHAUST_X, 0.03, 0.05)
	pm.direction = Vector3(0, 0.15, 1)
	pm.spread = 14.0
	pm.initial_velocity_min = 6.0
	pm.initial_velocity_max = 12.0
	pm.gravity = Vector3(0, -4.0, 0)
	pm.scale_min = 0.5
	pm.scale_max = 1.0
	var fade := Gradient.new()
	fade.set_color(0, Color(0.8, 0.9, 1.0, 1.0))
	fade.set_color(1, Color(0.3, 0.3, 1.0, 0.0))
	var ramp := GradientTexture1D.new()
	ramp.gradient = fade
	pm.color_ramp = ramp
	_nitro_sparks.process_material = pm
	var spark := QuadMesh.new()
	spark.size = Vector2(0.03, 0.03)
	var spark_mat := StandardMaterial3D.new()
	spark_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	spark_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	spark_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	spark_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	spark_mat.vertex_color_use_as_albedo = true
	spark_mat.albedo_color = Color(2.0, 2.0, 2.0)
	spark.material = spark_mat
	_nitro_sparks.draw_pass_1 = spark
	add_child(_nitro_sparks)


func _update_nitro(delta: float) -> void:
	var target := 1.0 if _car.is_boosting else 0.0
	_nitro = move_toward(_nitro, target, delta * (8.0 if target > _nitro else 4.0))
	var on := _nitro > 0.01
	_nitro_light.visible = on
	_nitro_sparks.emitting = _car.is_boosting
	for mi in _flames:
		mi.visible = on
	if not on:
		return
	_flame_material.set_shader_parameter(&"intensity", _nitro)
	_nitro_light.light_energy = nitro_light_energy * _nitro * randf_range(0.75, 1.0)
	for mi in _flames:
		var core: bool = mi.get_meta(&"core")
		var length := nitro_length * _nitro * randf_range(0.8, 1.1) * (0.45 if core else 1.0)
		var width := lerpf(0.6, 1.0, _nitro)
		# Cylinder axis (+Y) rotated onto +Z (backwards), stretched to the flame length.
		mi.basis = Basis(Vector3.RIGHT, PI * 0.5) * Basis.from_scale(Vector3(width, length, width))
		mi.position.z = EXHAUST_Z + length * 0.5


## Two headlight spots (no shadows), only visible when `headlights` > 0.
func _build_headlights() -> void:
	for xs in [-1.0, 1.0]:
		var spot := SpotLight3D.new()
		spot.position = Vector3(xs * 0.58, 0.2, -2.2)
		spot.rotation.x = deg_to_rad(-4.0)
		spot.light_color = Color(1.0, 0.94, 0.82)
		spot.spot_range = 70.0
		spot.spot_angle = 28.0
		spot.spot_attenuation = 0.6
		spot.spot_angle_attenuation = 2.0
		spot.light_specular = 0.3
		spot.shadow_enabled = false
		add_child(spot)
		_headlights.append(spot)
	_apply_headlights()


func _apply_headlights() -> void:
	for spot in _headlights:
		spot.visible = headlights > 0.01
		spot.light_energy = headlight_energy * headlights
	if _head_material:
		_head_material.emission_energy_multiplier = 1.5 + headlights * 4.0


func _build_body() -> void:
	var paint := MeshBuilder.new()
	var trim := MeshBuilder.new()
	var glass := MeshBuilder.new()
	var head := MeshBuilder.new()
	var tail := MeshBuilder.new()

	# Main hull (side profile in z/y, forward is -Z), bevelled by the narrower outer slices.
	var hull := PackedVector2Array([
		Vector2(-2.12, -0.24), Vector2(-2.25, 0.02), Vector2(-2.08, 0.2), Vector2(-1.2, 0.34),
		Vector2(0.4, 0.42), Vector2(1.7, 0.45), Vector2(2.18, 0.37), Vector2(2.24, 0.05), Vector2(2.14, -0.24)])
	paint.add_loft(hull, [Vector3(-0.84, 0.97, 0.82), Vector3(-0.74, 1.0, 1.0), Vector3(0.74, 1.0, 1.0), Vector3(0.84, 0.97, 0.82)], Color.WHITE)

	# Cabin (glass) with a painted roof.
	var cabin := PackedVector2Array([Vector2(-0.62, 0.38), Vector2(0.05, 0.8), Vector2(0.92, 0.83), Vector2(1.78, 0.44)])
	glass.add_loft(cabin, [Vector3(-0.72, 0.9, 0.86), Vector3(-0.62, 1.0, 1.0), Vector3(0.62, 1.0, 1.0), Vector3(0.72, 0.9, 0.86)], Color.WHITE)
	var roof := PackedVector2Array([Vector2(0.02, 0.795), Vector2(0.95, 0.825), Vector2(0.95, 0.865), Vector2(0.06, 0.84)])
	paint.add_loft(roof, [Vector3(-0.6, 1.0, 1.0), Vector3(0.6, 1.0, 1.0)], Color.WHITE)

	# Fenders over each wheel.
	for z in [_car.front_axle_z, _car.rear_axle_z]:
		for xs in [-1.0, 1.0]:
			var fender := PackedVector2Array([Vector2(-0.55, 0.02), Vector2(-0.38, 0.2), Vector2(0.38, 0.2), Vector2(0.55, 0.02)])
			var x: float = xs * 0.83
			var shifted := PackedVector2Array()
			for p in fender:
				shifted.append(Vector2(p.x + z, p.y))
			paint.add_loft(shifted, [Vector3(x - 0.12, 1.0, 1.0), Vector3(x + 0.12, 1.0, 1.0)], Color.WHITE)

	# Rear wing
	paint.add_box(Vector3(0, 0.66, 2.0), Vector3(1.6, 0.05, 0.34), Color.WHITE, Basis(Vector3.RIGHT, 0.08))
	for xs in [-0.55, 0.55]:
		trim.add_box(Vector3(xs, 0.55, 2.0), Vector3(0.06, 0.2, 0.12), trim_color)

	# Trim: splitter, diffuser, side skirts, grille, mirrors
	trim.add_box(Vector3(0, -0.22, -2.1), Vector3(1.55, 0.06, 0.3), trim_color)
	trim.add_box(Vector3(0, -0.12, 2.2), Vector3(1.3, 0.16, 0.12), trim_color)
	for xs in [-1.0, 1.0]:
		trim.add_box(Vector3(xs * EXHAUST_X, EXHAUST_Y, EXHAUST_Z - 0.04), Vector3(0.14, 0.11, 0.12), Color(0.32, 0.32, 0.34))
	trim.add_box(Vector3(0, 0.0, -2.2), Vector3(0.9, 0.14, 0.08), trim_color)
	for xs in [-1.0, 1.0]:
		trim.add_box(Vector3(xs * 0.8, -0.2, 0.03), Vector3(0.08, 0.1, 1.9), trim_color)
		trim.add_box(Vector3(xs * 0.8, 0.55, -0.4), Vector3(0.18, 0.1, 0.16), trim_color)

	# Lights
	for xs in [-1.0, 1.0]:
		head.add_box(Vector3(xs * 0.58, 0.14, -2.13), Vector3(0.42, 0.08, 0.12), Color.WHITE, Basis(Vector3.RIGHT, -0.5))
		tail.add_box(Vector3(xs * 0.58, 0.28, 2.17), Vector3(0.48, 0.07, 0.08), Color.WHITE)

	var paint_mat := StandardMaterial3D.new()
	paint_mat.albedo_color = paint_color
	paint_mat.metallic = 0.35
	paint_mat.roughness = 0.28
	var trim_mat := StandardMaterial3D.new()
	trim_mat.vertex_color_use_as_albedo = true
	trim_mat.vertex_color_is_srgb = true
	trim_mat.roughness = 0.6
	var glass_mat := StandardMaterial3D.new()
	glass_mat.albedo_color = Color(0.1, 0.13, 0.17)
	glass_mat.metallic = 0.6
	glass_mat.roughness = 0.08
	var head_mat := StandardMaterial3D.new()
	_head_material = head_mat
	head_mat.albedo_color = Color(1.0, 0.97, 0.88)
	head_mat.emission_enabled = true
	head_mat.emission = Color(1.0, 0.95, 0.8)
	head_mat.emission_energy_multiplier = 1.5
	_tail_material = StandardMaterial3D.new()
	_tail_material.albedo_color = Color(0.6, 0.02, 0.02)
	_tail_material.emission_enabled = true
	_tail_material.emission = Color(1.0, 0.08, 0.05)
	_tail_material.emission_energy_multiplier = 1.2

	for part in [[paint, paint_mat], [trim, trim_mat], [glass, glass_mat], [head, head_mat], [tail, _tail_material]]:
		var mi := MeshInstance3D.new()
		mi.mesh = (part[0] as MeshBuilder).commit(part[1])
		add_child(mi)


func _build_wheels() -> void:
	var mb := MeshBuilder.new()
	var r := _car.wheel_radius
	var axis := Basis(Vector3.BACK, PI * 0.5)  # Cylinder Y axis -> X axis
	mb.add_primitive(SceneryMeshes.cylinder(r, r, 0.3, 12), Transform3D(axis, Vector3.ZERO), Color(0.12, 0.12, 0.13))
	mb.add_primitive(SceneryMeshes.cylinder(r * 0.62, r * 0.62, 0.31, 10), Transform3D(axis, Vector3.ZERO), Color(0.75, 0.76, 0.78))
	for k in 3:
		var spoke := Basis(Vector3.RIGHT, k * PI / 3.0)
		mb.add_box(Vector3.ZERO, Vector3(0.32, r * 1.25, 0.07), Color(0.32, 0.33, 0.35), spoke)
	mb.add_primitive(SceneryMeshes.cylinder(r * 0.18, r * 0.18, 0.33, 6), Transform3D(axis, Vector3.ZERO), Color(0.2, 0.2, 0.22))
	var wheel_mesh := mb.commit(Palette.vertex_material(0.55))

	for w in _car.wheels:
		var pivot := Node3D.new()
		pivot.position = w.mount - Vector3.UP * _car.rest_length
		add_child(pivot)
		var spinner := MeshInstance3D.new()
		spinner.mesh = wheel_mesh
		pivot.add_child(spinner)
		_wheel_pivots.append(pivot)
		_wheel_spinners.append(spinner)


func _build_smoke() -> void:
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1, 1, 1, 1))
	gradient.set_color(1, Color(1, 1, 1, 0))
	var puff := GradientTexture2D.new()
	puff.gradient = gradient
	puff.fill = GradientTexture2D.FILL_RADIAL
	puff.fill_from = Vector2(0.5, 0.5)
	puff.fill_to = Vector2(1.0, 0.5)
	puff.width = 64
	puff.height = 64

	var draw_mat := StandardMaterial3D.new()
	draw_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	draw_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	draw_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	draw_mat.vertex_color_use_as_albedo = true
	draw_mat.albedo_texture = puff
	var quad := QuadMesh.new()
	quad.size = Vector2(1.4, 1.4)
	quad.material = draw_mat

	var alpha_ramp := Gradient.new()
	alpha_ramp.set_color(0, Color(1, 1, 1, 0.5))
	alpha_ramp.set_color(1, Color(1, 1, 1, 0.0))
	var ramp_tex := GradientTexture1D.new()
	ramp_tex.gradient = alpha_ramp
	var grow := Curve.new()
	grow.add_point(Vector2(0.0, 0.35))
	grow.add_point(Vector2(1.0, 1.0))
	var grow_tex := CurveTexture.new()
	grow_tex.curve = grow

	for k in 2:
		var pm := ParticleProcessMaterial.new()
		pm.direction = Vector3(0, 1, 0)
		pm.spread = 40.0
		pm.initial_velocity_min = 0.5
		pm.initial_velocity_max = 1.6
		pm.gravity = Vector3(0, 0.6, 0)
		pm.damping_min = 0.8
		pm.damping_max = 1.4
		pm.scale_min = 0.8
		pm.scale_max = 1.4
		pm.scale_curve = grow_tex
		pm.color_ramp = ramp_tex
		var particles := GPUParticles3D.new()
		particles.amount = 48
		particles.lifetime = 1.3
		particles.local_coords = false
		particles.emitting = false
		particles.process_material = pm
		particles.draw_pass_1 = quad
		particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		particles.visibility_aabb = AABB(Vector3(-8, -2, -8), Vector3(16, 8, 16))
		add_child(particles)
		_smoke.append(particles)
		_smoke_materials.append(pm)
