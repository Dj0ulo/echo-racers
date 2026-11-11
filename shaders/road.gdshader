shader_type spatial;
// Asphalt with procedural lane markings. UV.x = 0..1 across the road, UV.y = metres along it.

uniform vec4 asphalt_color : source_color = vec4(0.25, 0.26, 0.28, 1.0);
uniform vec4 marking_color : source_color = vec4(0.95, 0.93, 0.86, 1.0);
uniform float road_width = 9.0;
uniform float dash_length = 4.0;
uniform float dash_gap = 5.0;

// Anti-aliased band of half-width `hw` around 0.
float band(float x, float hw) {
	float aa = max(fwidth(x), 1e-4);
	return 1.0 - smoothstep(hw - aa, hw + aa, abs(x));
}

void fragment() {
	float across = (UV.x - 0.5) * road_width;
	float period = dash_length + dash_gap;
	float phase = fract(UV.y / period) * period;
	float dash = smoothstep(0.0, 0.15, phase) * (1.0 - smoothstep(dash_length - 0.15, dash_length, phase));

	float center_line = band(across, 0.1) * dash;
	float edge_line = band(abs(across) - (road_width * 0.5 - 0.45), 0.09);
	float marking = max(center_line, edge_line);

	// Slightly darker, polished tyre tracks in each lane.
	float lane = abs(abs(across) - road_width * 0.25);
	float tracks = band(lane - 0.85, 0.35);

	vec3 col = asphalt_color.rgb * (1.0 - 0.07 * tracks);
	ALBEDO = mix(col, marking_color.rgb, marking);
	ROUGHNESS = mix(0.85 - 0.1 * tracks, 0.6, marking);
	SPECULAR = 0.35;
}
