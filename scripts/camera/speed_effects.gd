class_name SpeedEffects
extends Node3D
## High-speed feedback attached to the ChaseCamera: wind streaks flying past the lens
## (GPU particles in camera space) and a full-screen overlay (edge radial blur, speed lines,
## vignette). Both are driven by the camera's `speed_fx` (plus a boost bump from `boost_fx`) and
## fully hidden when slow.

const STREAK_SHADER := preload("res://shaders/speed_streak.gdshader")
const OVERLAY_SHADER := preload("res://shaders/speed_overlay.gdshader")

@export var streak_count := 56
@export var streak_base_velocity := 40.0     ## Particle velocity at speed_scale 1 (m/s).
@export var streak_min_length := 1.2
@export var streak_max_length := 7.0
@export var streak_brightness := 0.55
@export var overlay_enabled := true
@export var boost_intensity := 0.4          ## Added to the effect intensity while boosting.
@export var boost_min_speed_kmh := 40.0     ## Boost effects fade in from here (no streaks at a standstill).

var _camera: ChaseCamera
var _streaks: GPUParticles3D
var _streak_mat: ShaderMaterial
var _overlay_layer: CanvasLayer
var _overlay: ColorRect
var _overlay_mat: ShaderMaterial
var _intensity := 0.0


func _ready() -> void:
	_camera = get_parent() as ChaseCamera
	_build_streaks()
	if overlay_enabled:
		_build_overlay()
	_apply(0.0, 0.0)


func _process(delta: float) -> void:
	if _camera == null or _camera.get_target() == null:
		return
	var target := _camera.get_target()
	# Extra smoothing so effects never pop on/off with small speed changes.
	var speed_ms := target.linear_velocity.length()
	var boost := _camera.boost_fx * boost_intensity * clampf(speed_ms * 3.6 / boost_min_speed_kmh - 0.5, 0.0, 1.0)
	# Streaks/overlay only make sense facing the road ahead: fade them out when free-looking
	# sideways or in the rear view.
	var goal := clampf(_camera.speed_fx + boost, 0.0, 1.0) * _camera.view_alignment
	_intensity = lerpf(_intensity, goal, 1.0 - exp(-4.0 * delta))
	_apply(_intensity, speed_ms)


func _apply(k: float, speed_ms: float) -> void:
	var on := k > 0.01
	_streaks.emitting = on
	_streaks.amount_ratio = clampf(k * 1.2, 0.0, 1.0)
	# Particles live in camera space, so their velocity must match the car's speed.
	_streaks.speed_scale = maxf(speed_ms / streak_base_velocity, 0.3)
	_streak_mat.set_shader_parameter(&"intensity", k * streak_brightness)
	_streak_mat.set_shader_parameter(&"stretch", lerpf(streak_min_length, streak_max_length, k))
	if _overlay:
		_overlay.visible = on
		_overlay_mat.set_shader_parameter(&"intensity", k)


func _build_streaks() -> void:
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	pm.emission_ring_axis = Vector3(0, 0, 1)
	pm.emission_ring_radius = 7.0
	pm.emission_ring_inner_radius = 2.2
	pm.emission_ring_height = 34.0
	pm.emission_shape_offset = Vector3(0, 0.6, -24.0)
	pm.direction = Vector3(0, 0, 1)
	pm.spread = 0.0
	pm.gravity = Vector3.ZERO
	pm.initial_velocity_min = streak_base_velocity * 0.9
	pm.initial_velocity_max = streak_base_velocity * 1.1
	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0.0, 0.25, 0.7, 1.0])
	fade.colors = PackedColorArray([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 0.8), Color(1, 1, 1, 0)])
	var ramp := GradientTexture1D.new()
	ramp.gradient = fade
	pm.color_ramp = ramp

	_streak_mat = ShaderMaterial.new()
	_streak_mat.shader = STREAK_SHADER
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	quad.material = _streak_mat

	_streaks = GPUParticles3D.new()
	_streaks.name = "WindStreaks"
	_streaks.amount = streak_count
	_streaks.lifetime = 1.0
	_streaks.local_coords = true
	_streaks.process_material = pm
	_streaks.draw_pass_1 = quad
	_streaks.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_streaks.visibility_aabb = AABB(Vector3(-10, -10, -45), Vector3(20, 20, 60))
	add_child(_streaks)


func _build_overlay() -> void:
	_overlay_mat = ShaderMaterial.new()
	_overlay_mat.shader = OVERLAY_SHADER
	_overlay_layer = CanvasLayer.new()
	_overlay_layer.name = "SpeedOverlay"
	_overlay_layer.layer = 0  # Below the HUD (layer 1).
	add_child(_overlay_layer)
	_overlay = ColorRect.new()
	_overlay.material = _overlay_mat
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay_layer.add_child(_overlay)
