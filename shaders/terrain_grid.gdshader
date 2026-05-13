shader_type spatial;
render_mode diffuse_lambert;

uniform vec4 base_color : source_color = vec4(0.25, 0.42, 0.25, 1.0);
uniform vec4 line_color : source_color = vec4(0.15, 0.28, 0.15, 1.0);
uniform float cell_size : hint_range(0.5, 10.0, 0.5) = 2.0;
uniform float line_width : hint_range(0.01, 0.3, 0.01) = 0.06;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = world_pos.xz;
	vec2 grid = fract(p / cell_size);
	float lw = line_width / cell_size;
	float gx = step(1.0 - lw, grid.x) + step(grid.x, lw);
	float gz = step(1.0 - lw, grid.y) + step(grid.y, lw);
	ALBEDO = mix(base_color.rgb, line_color.rgb, clamp(gx + gz, 0.0, 1.0));
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
}
