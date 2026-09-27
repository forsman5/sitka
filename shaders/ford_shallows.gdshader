shader_type spatial;
render_mode cull_disabled;
uniform vec4 water_color : source_color = vec4(0.208, 0.435, 0.608, 1.0);
uniform vec4 gravel_color : source_color = vec4(0.42, 0.48, 0.43, 1.0);

// A wet gravel bed visible through shallow water, with broken soft edges.
void fragment() {
	float edge = abs(UV.x * 2.0 - 1.0);
	float irregularity = 0.08 * sin(UV.y * 13.0) + 0.05 * sin(UV.y * 29.0);
	float coverage = 1.0 - smoothstep(0.55 + irregularity, 0.98 + irregularity, edge);
	if (coverage < 0.08) { discard; }
	vec2 cell = vec2(UV.x * 13.0, UV.y * 15.0);
	vec2 id = floor(cell);
	float random = fract(sin(dot(id, vec2(127.1, 311.7))) * 43758.5453);
	float pebble = 1.0 - smoothstep(0.18, 0.42, length(fract(cell) - vec2(0.5)));
	vec3 gravel = gravel_color.rgb * mix(0.7, 1.1, random);
	ALBEDO = mix(water_color.rgb, gravel, coverage * (0.35 + pebble * 0.45));
	ROUGHNESS = 0.65;
}
