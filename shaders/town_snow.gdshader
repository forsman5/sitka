shader_type spatial;

// Snow for the household town view. Used two ways with one shared material:
// as a material_overlay on building meshes (only faces that point up turn
// white, so roofs get a cap and walls stay clear) and on a flat plane just
// above the ground (every face points up, so it is a full layer).
// `cover` is 0 (bare) .. 1 (full snow); the town view drives it from the season.

uniform float cover : hint_range(0.0, 1.0) = 0.0;
// Highest alpha snow reaches; the ground layer stays a little see-through so
// roads and fields read under it.
uniform float opacity : hint_range(0.0, 1.0) = 1.0;
uniform vec3 snow_color : source_color = vec3(0.94, 0.96, 1.0);
// World-space normal.y at which snow starts to settle, and how quickly it
// reaches full cover (steeper roofs get less).
uniform float settle_min = 0.45;
uniform float settle_range = 0.2;
// Lift off the surface so the overlay does not z-fight with the mesh below.
uniform float lift = 0.04;

varying float up;

void vertex() {
	up = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz).y;
	// `lift` is in world units whatever the model was scaled to.
	VERTEX += NORMAL * lift / max(length(MODEL_MATRIX[0].xyz), 0.0001);
}

void fragment() {
	ALBEDO = snow_color;
	ROUGHNESS = 1.0;
	ALPHA = smoothstep(settle_min, settle_min + settle_range, up) * cover * opacity;
}
