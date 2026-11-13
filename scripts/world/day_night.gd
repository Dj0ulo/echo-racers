class_name DayNight
extends Node
## Day/night cycle: `day_minutes` of daylight (06:00-18:00) then `night_minutes` of night. One directional
## light is the sun by day and a cool full-moon light by night (it swaps over while both are below the
## horizon). A custom sky shader draws the gradient, a warm sunrise/sunset glow around the sun near the
## horizon, the sun and moon disks and stars; sky colours, fog, ambient light, exposure, the clouds' glow and
## the car's headlights all follow the sun's elevation through the `_KEYS` table.
## While another camera is current (world map, echo editor) the world is shown in daylight so it stays readable.
## Debug: `-- --time=<hour>` sets the starting hour, `--timescale=<x>` speeds the cycle up.

const _SKY_CODE := """
shader_type sky;
uniform vec3 top_color : source_color;
uniform vec3 horizon_color : source_color;
uniform vec3 ground_color : source_color;
uniform vec3 glow_color : source_color;
uniform float glow_strength = 0.0;
uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0);
uniform vec3 sun_color : source_color = vec3(1.0);
uniform float sun_disk = 0.0;
uniform vec3 moon_dir = vec3(0.0, -1.0, 0.0);
uniform float moon_disk = 0.0;
uniform float stars = 0.0;

float hash(vec3 p) {
	p = fract(p * 0.3183099 + vec3(0.71, 0.113, 0.419));
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

void sky() {
	vec3 d = EYEDIR;
	float e = d.y;
	vec3 col = e >= 0.0
		? mix(horizon_color, top_color, pow(clamp(e, 0.0, 1.0), 0.4))
		: mix(horizon_color, ground_color, clamp(pow(-e, 0.35), 0.0, 1.0));
	// Sunrise/sunset glow: a wide warm band along the horizon on the sun's side, and a halo round the sun.
	float sd = dot(d, sun_dir);
	float band = exp(-abs(e) * 7.0);
	col += glow_color * glow_strength * (pow(sd * 0.5 + 0.5, 5.0) * band + pow(max(sd, 0.0), 24.0) * 0.7);
	if (!AT_CUBEMAP_PASS) {
		col += sun_color * sun_disk * smoothstep(0.9993, 0.9996, sd) * 6.0;
		float md = dot(d, moon_dir);
		col += vec3(0.85, 0.9, 1.0) * moon_disk * (smoothstep(0.99955, 0.99975, md) * 1.6 + pow(max(md, 0.0), 300.0) * 0.12);
		if (stars > 0.0 && e > 0.0) {
			vec3 p = d * 260.0;
			vec3 c = floor(p);
			float h = hash(c);
			float s = step(0.9965, h) * smoothstep(0.42, 0.0, length(fract(p) - 0.5));
			col += vec3(0.85, 0.9, 1.0) * s * stars * (0.4 + 2.6 * fract(h * 97.0)) * smoothstep(0.0, 0.25, e);
		}
	}
	COLOR = col;
}
"""

## Look of the world against the sun's elevation (sine of its angle above the horizon), interpolated linearly.
const _KEYS := [
	{"s": -1.0, "top": Color(0.006, 0.011, 0.035), "hor": Color(0.03, 0.045, 0.09), "glow": Color(0.3, 0.2, 0.4), "gs": 0.0,
		"stars": 1.0, "amb": Color(0.09, 0.12, 0.22), "sky_amb": 0.35, "exp": 1.35, "cloud": 0.05},
	{"s": -0.2, "top": Color(0.006, 0.011, 0.035), "hor": Color(0.03, 0.045, 0.09), "glow": Color(0.3, 0.2, 0.4), "gs": 0.0,
		"stars": 1.0, "amb": Color(0.09, 0.12, 0.22), "sky_amb": 0.35, "exp": 1.35, "cloud": 0.05},
	{"s": -0.09, "top": Color(0.025, 0.045, 0.14), "hor": Color(0.3, 0.17, 0.3), "glow": Color(0.9, 0.3, 0.32), "gs": 0.45,
		"stars": 0.35, "amb": Color(0.14, 0.13, 0.22), "sky_amb": 0.5, "exp": 1.25, "cloud": 0.3},
	{"s": 0.0, "top": Color(0.09, 0.15, 0.38), "hor": Color(0.98, 0.5, 0.28), "glow": Color(1.0, 0.42, 0.14), "gs": 1.4,
		"stars": 0.0, "amb": Color(0.42, 0.34, 0.38), "sky_amb": 0.7, "exp": 1.12, "cloud": 0.9},
	{"s": 0.12, "top": Color(0.2, 0.36, 0.7), "hor": Color(0.96, 0.72, 0.52), "glow": Color(1.0, 0.6, 0.28), "gs": 0.8,
		"stars": 0.0, "amb": Color(0.5, 0.48, 0.48), "sky_amb": 1.0, "exp": 1.0, "cloud": 0.7},
	{"s": 0.35, "top": Color(0.28, 0.5, 0.82), "hor": Color(0.74, 0.81, 0.89), "glow": Color(1.0, 0.9, 0.7), "gs": 0.12,
		"stars": 0.0, "amb": Color(0.5, 0.5, 0.5), "sky_amb": 1.0, "exp": 1.0, "cloud": 0.6},
	{"s": 1.0, "top": Color(0.28, 0.5, 0.82), "hor": Color(0.74, 0.81, 0.89), "glow": Color(1.0, 0.9, 0.7), "gs": 0.12,
		"stars": 0.0, "amb": Color(0.5, 0.5, 0.5), "sky_amb": 1.0, "exp": 1.0, "cloud": 0.6},
]

@export var day_minutes := 10.0        ## Real minutes from sunrise (06:00) to sunset (18:00).
@export var night_minutes := 10.0      ## Real minutes from sunset to sunrise.
@export var start_hour := 10.0
@export var max_sun_elevation := 58.0  ## Degrees above the horizon at noon.
@export var sun_energy := 1.3
@export var moon_energy := 0.38
@export var moon_color := Color(0.62, 0.72, 1.0)
@export var update_interval := 0.2     ## Seconds between lighting updates (each one re-renders the sky radiance).

var hour := 10.0                       ## Time of day, 0..24.
var time_scale := 1.0

var _env: Environment
var _light: DirectionalLight3D
var _sky: ShaderMaterial
var _clouds: StandardMaterial3D
var _car_visuals: CarVisuals
var _chase_camera: Camera3D
var _wait := 0.0
var _was_day_view := false


func setup(env: Environment, light: DirectionalLight3D, world: Node, car: Node, chase_camera: Camera3D) -> void:
	_env = env
	_light = light
	_chase_camera = chase_camera
	_car_visuals = car.get_node_or_null(^"Visuals") as CarVisuals
	var clouds := world.find_child("Clouds", true, false) as MeshInstance3D
	if clouds and clouds.mesh:
		_clouds = clouds.mesh.surface_get_material(0) as StandardMaterial3D
	var shader := Shader.new()
	shader.code = _SKY_CODE
	_sky = ShaderMaterial.new()
	_sky.shader = shader
	_sky.set_shader_parameter(&"ground_color", Color(0.36, 0.42, 0.36))
	_env.sky.sky_material = _sky
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	hour = start_hour
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--time="):
			hour = fposmod(arg.trim_prefix("--time=").to_float(), 24.0)
		elif arg.begins_with("--timescale="):
			time_scale = arg.trim_prefix("--timescale=").to_float()
	process_mode = Node.PROCESS_MODE_ALWAYS
	_apply_light(hour)
	_apply(hour)


func _process(delta: float) -> void:
	if _env == null:
		return
	if not get_tree().paused:
		var minutes := day_minutes if hour >= 6.0 and hour < 18.0 else night_minutes
		hour = fposmod(hour + delta * time_scale * 12.0 / (maxf(minutes, 0.01) * 60.0), 24.0)
	var day_view := get_viewport().get_camera_3d() != _chase_camera
	var h := 13.0 if day_view else hour
	_apply_light(h)  # Every frame: stepping the light makes long dusk shadows jump.
	_wait -= delta
	if _wait > 0.0 and day_view == _was_day_view:
		return
	_wait = update_interval
	_was_day_view = day_view
	_apply(h)


## Direction toward the sun at hour `h`: rises in the east (+x), culminates in the south (+z), sets in the west.
func sun_direction(h: float) -> Vector3:
	var a := (h - 6.0) / 24.0 * TAU
	var el := deg_to_rad(max_sun_elevation)
	return Vector3(cos(a), sin(a) * sin(el), sin(a) * cos(el) + 0.25).normalized()


func is_night() -> bool:
	return sun_direction(hour).y < -0.04


## Sun/moon light direction, colour and energy (cheap: no sky radiance update).
func _apply_light(h: float) -> void:
	var sun := sun_direction(h)
	var moon := -sun
	var s := sun.y
	# One light: the sun until it is just below the horizon, then the moon (opposite it, so just rising).
	var swap := -0.04
	var dir := sun if s > swap else moon
	var sun_k := smoothstep(swap, 0.1, s)
	var moon_k := smoothstep(swap, swap - 0.16, s)
	var warm := smoothstep(0.3, 0.0, s)
	_light.light_color = Color(1.0, 0.94, 0.84).lerp(Color(1.0, 0.5, 0.24), warm) if s > swap else moon_color
	_light.light_energy = sun_energy * sun_k if s > swap else moon_energy * moon_k
	_light.visible = _light.light_energy > 0.005
	if dir.y > 0.0005:
		var up := Vector3.UP if absf(dir.y) < 0.99 else Vector3.FORWARD
		_light.global_basis = Basis.looking_at(-dir, up)


## Sky, fog, ambient, clouds and headlights (throttled: each change re-renders the sky radiance).
func _apply(h: float) -> void:
	var sun := sun_direction(h)
	var moon := -sun
	var s := sun.y
	var k := _sample(s)
	var warm := smoothstep(0.3, 0.0, s)
	var hor: Color = k.hor
	_sky.set_shader_parameter(&"top_color", k.top)
	_sky.set_shader_parameter(&"horizon_color", hor)
	_sky.set_shader_parameter(&"glow_color", k.glow)
	_sky.set_shader_parameter(&"glow_strength", k.gs)
	_sky.set_shader_parameter(&"stars", k.stars)
	_sky.set_shader_parameter(&"sun_dir", sun)
	_sky.set_shader_parameter(&"sun_color", Color(1.0, 0.95, 0.85).lerp(Color(1.0, 0.45, 0.15), warm))
	_sky.set_shader_parameter(&"sun_disk", smoothstep(-0.03, 0.0, s))
	_sky.set_shader_parameter(&"moon_dir", moon)
	_sky.set_shader_parameter(&"moon_disk", smoothstep(0.05, -0.12, s))
	_sky.set_shader_parameter(&"ground_color", Color(0.36, 0.42, 0.36) * clampf(k.cloud / 0.6, 0.08, 1.0))
	_env.fog_light_color = hor
	_env.fog_sky_affect = lerpf(0.3, 0.12, warm)  # Let the sunset gradient show through.
	_env.ambient_light_color = k.amb
	_env.ambient_light_sky_contribution = k.sky_amb
	_env.tonemap_exposure = k.exp
	if _clouds:
		var c: float = k.cloud
		_clouds.emission = Color(0.55, 0.6, 0.68).lerp(hor * 0.9, warm * 0.8)
		_clouds.emission_energy_multiplier = c
		_clouds.albedo_color = Color.WHITE * clampf(c / 0.6, 0.15, 1.0)
	if _car_visuals:
		_car_visuals.headlights = smoothstep(0.08, -0.04, s)


func _sample(s: float) -> Dictionary:
	var i := 0
	while i < _KEYS.size() - 2 and s > _KEYS[i + 1].s:
		i += 1
	var a: Dictionary = _KEYS[i]
	var b: Dictionary = _KEYS[i + 1]
	var t := clampf((s - a.s) / (b.s - a.s), 0.0, 1.0)
	var out := {}
	for key: String in a:
		if a[key] is Color:
			out[key] = (a[key] as Color).lerp(b[key], t)
		else:
			out[key] = lerpf(a[key], b[key], t)
	return out
