shader_type spatial;
render_mode cull_disabled, specular_disabled;
// Low-poly grass tufts: vertex colours, gentle wind sway, ground-like lighting on both sides.

uniform float sway_strength = 0.07;
uniform float sway_speed = 1.7;

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float phase = TIME * sway_speed + world.x * 0.31 + world.z * 0.23;
	VERTEX.x += sin(phase) * sway_strength * VERTEX.y;
	VERTEX.z += cos(phase * 0.8) * sway_strength * 0.6 * VERTEX.y;
}

void fragment() {
	// Vertex colours are authored in sRGB.
	ALBEDO = pow(COLOR.rgb, vec3(2.2));
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	ROUGHNESS = 1.0;
}
