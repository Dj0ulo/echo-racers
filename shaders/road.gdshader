shader_type spatial;
// Asphalt with procedural lane markings. UV.x = 0..1 across the road, UV.y = metres along it.
// Cross-section: | shoulder | lanes | median | lanes | shoulder |. Without a median a dashed centre
// line is drawn; with one, two solid lines bound a hatched median.

uniform vec4 asphalt_color : source_color = vec4(0.25, 0.26, 0.28, 1.0);
uniform vec4 marking_color : source_color = vec4(0.95, 0.93, 0.86, 1.0);
uniform float road_width = 9.0;
uniform int lanes_per_side = 1;
uniform float lane_width = 4.05;
uniform float median_width = 0.0;
uniform float dash_length = 4.0;
uniform float dash_gap = 5.0;

// Anti-aliased band of half-width `hw` around 0.
float band(float x, float hw) {
	float aa = max(fwidth(x), 1e-4);
	return 1.0 - smoothstep(hw - aa, hw + aa, abs(x));
}

void fragment() {
	float across = (UV.x - 0.5) * road_width;
	float side = abs(across);
	float period = dash_length + dash_gap;
	float phase = fract(UV.y / period) * period;
	float dash = smoothstep(0.0, 0.15, phase) * (1.0 - smoothstep(dash_length - 0.15, dash_length, phase));

	float half_median = median_width * 0.5;
	float lanes = float(lanes_per_side);
	float edge_pos = half_median + lanes * lane_width;
	float edge_line = band(side - edge_pos, 0.09);
	float marking = edge_line;
	if (median_width > 0.01) {
		marking = max(marking, band(side - half_median, 0.09));
		// Diagonal hatching inside the median.
		float hatch = fract((UV.y + across * 2.0) / 6.0);
		float in_median = 1.0 - smoothstep(half_median - 0.25, half_median - 0.15, side);
		marking = max(marking, band(hatch - 0.5, 0.05) * in_median * 0.85);
	} else {
		marking = max(marking, band(across, 0.1) * dash);
	}
	// Dashed lines between lanes of the same direction.
	for (int k = 1; k < lanes_per_side; k++) {
		marking = max(marking, band(side - (half_median + float(k) * lane_width), 0.08) * dash);
	}

	// Slightly darker, polished tyre tracks in each lane.
	float in_lane = clamp((side - half_median) / lane_width, 0.0, lanes);
	float lane_pos = (fract(in_lane) - 0.5) * lane_width;
	float tracks = band(abs(lane_pos) - 0.85, 0.35) * step(side, edge_pos) * step(half_median, side);

	vec3 col = asphalt_color.rgb * (1.0 - 0.07 * tracks);
	// Shoulders are a touch lighter.
	col *= 1.0 + 0.06 * step(edge_pos + 0.1, side);
	ALBEDO = mix(col, marking_color.rgb, marking);
	ROUGHNESS = mix(0.85 - 0.1 * tracks, 0.6, marking);
	SPECULAR = 0.35;
}
