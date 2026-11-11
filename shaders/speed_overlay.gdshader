shader_type canvas_item;
// Full-screen high-speed overlay for SpeedEffects: a cheap edge-weighted radial blur,
// faint flickering radial speed lines and a soft vignette. Hidden entirely when slow.

uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform float blur_amount = 0.011;
uniform float line_strength = 0.16;
uniform float vignette_strength = 0.32;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 c = uv - vec2(0.5);
	float aspect = SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	float r = length(c * vec2(aspect, 1.0));
	float edge = smoothstep(0.22, 0.8, r);

	// Radial blur toward the screen centre, strongest at the edges.
	// Per-pixel jitter of the tap offsets hides the stepping of the few taps.
	vec2 step_uv = c * blur_amount * intensity * intensity * edge;
	float jitter = hash(FRAGCOORD.xy + fract(TIME) * 61.0);
	vec3 col = vec3(0.0);
	for (int i = 0; i < 6; i++) {
		col += texture(screen_tex, uv - step_uv * (float(i) + jitter)).rgb;
	}
	col /= 6.0;

	// Radial speed lines streaming outward.
	float ang = atan(c.y * aspect, c.x);
	float rays = vnoise(vec2(ang * 38.0, TIME * 9.0));
	rays = smoothstep(0.72, 0.95, rays);
	float dash = smoothstep(0.35, 0.9, vnoise(vec2(ang * 38.0, r * 7.0 - TIME * 22.0)));
	float lines = rays * dash * smoothstep(0.3, 0.85, r) * intensity * line_strength;

	float vig = vignette_strength * intensity * smoothstep(0.45, 0.95, r);
	col = col * (1.0 - vig) + vec3(lines);
	COLOR = vec4(col, 1.0);
}
