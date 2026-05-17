shader_type spatial;
render_mode unshaded;

uniform sampler2D height_map : hint_default_black;
uniform float height_tex_min   = -4.0;
uniform float height_tex_range = 10.0;

uniform vec4 grassland_color : source_color = vec4(0.25, 0.42, 0.25, 1.0);
uniform vec4 forest_color    : source_color = vec4(0.16, 0.28, 0.16, 1.0);
uniform vec4 town_color      : source_color = vec4(0.50, 0.46, 0.36, 1.0);
uniform vec4 beach_color     : source_color = vec4(0.78, 0.72, 0.52, 1.0);
uniform vec4 underwater_color: source_color = vec4(0.08, 0.14, 0.24, 1.0);
uniform float cell_size  : hint_range(0.5, 10.0, 0.5) = 2.0;
uniform float line_width : hint_range(0.01, 0.3, 0.01) = 0.06;
uniform vec2  building_positions[32];
uniform float building_radii[32];
uniform int   building_count = 0;
uniform vec2  forest_center = vec2(-35.0, 0.0);
uniform float forest_radius = 28.0;
uniform float beach_height : hint_range(0.0, 2.0, 0.1) = 0.55;
uniform float world_half = 75.0;
uniform float world_size = 150.0;

varying float v_height;
varying vec2  v_world_xz;

void vertex() {
	vec2 uv_h = VERTEX.xz / world_size + 0.5;
	float n   = texture(height_map, uv_h).r;
	float h   = height_tex_min + n * height_tex_range;
	VERTEX.y    = h;
	v_height    = h;
	v_world_xz  = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

void fragment() {
	vec2  tile_pos    = v_world_xz;
	float height      = v_height;
	float dist_forest = distance(tile_pos, forest_center);

	bool in_town = false;
	for (int i = 0; i < building_count; i++) {
		if (distance(tile_pos, building_positions[i]) <= building_radii[i]) {
			in_town = true;
			break;
		}
	}

	vec3 biome;
	if (height < 0.0) {
		biome = underwater_color.rgb;
	} else if (in_town) {
		biome = town_color.rgb;
	} else if (height < beach_height) {
		float t = smoothstep(0.0, beach_height, height);
		vec3 land = dist_forest <= forest_radius ? forest_color.rgb : grassland_color.rgb;
		biome = mix(beach_color.rgb, land, t);
	} else if (dist_forest <= forest_radius) {
		biome = forest_color.rgb;
	} else {
		biome = grassland_color.rgb;
	}

	if (height >= 0.0) {
		vec2  grid = fract(tile_pos / cell_size);
		float lw   = line_width / cell_size;
		float gx   = step(1.0 - lw, grid.x) + step(grid.x, lw);
		float gz   = step(1.0 - lw, grid.y) + step(grid.y, lw);
		ALBEDO = mix(biome, biome * 0.6, clamp(gx + gz, 0.0, 1.0));
	} else {
		ALBEDO = biome;
	}
}
