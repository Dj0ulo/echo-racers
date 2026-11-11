shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, skip_vertex_transform, fog_disabled;
// Wind streaks for SpeedEffects: a unit quad stretched along the particle's local Z axis
// (the travel direction) and turned to face the camera around that axis.

uniform float stretch = 3.0;      // Streak length (m).
uniform float width = 0.025;      // Streak width (m).
uniform float intensity = 0.0;    // Overall brightness, driven by speed.
uniform vec3 tint : source_color = vec3(0.92, 0.96, 1.0);

varying float near_fade;

void vertex() {
	vec3 center = (MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 axis = normalize((MODELVIEW_MATRIX * vec4(0.0, 0.0, 1.0, 0.0)).xyz);
	vec3 side = cross(axis, normalize(center));
	side = length(side) > 0.001 ? normalize(side) : vec3(1.0, 0.0, 0.0);
	VERTEX = center + axis * VERTEX.y * stretch + side * VERTEX.x * width;
	NORMAL = vec3(0.0, 0.0, 1.0);
	// Streaks brushing right past the lens would read as big blobs: fade them out.
	near_fade = smoothstep(2.0, 6.0, -center.z);
}

void fragment() {
	float across = 1.0 - abs(UV.x * 2.0 - 1.0);
	float along = sin(UV.y * 3.14159);           // Tapered at both ends.
	float a = across * along * COLOR.a * intensity * near_fade;
	ALBEDO = tint * a;
	ALPHA = a;
}
