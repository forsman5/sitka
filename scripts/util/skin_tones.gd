class_name SkinTones extends RefCounted
## Random skin tones for the Casual_Male model. Its "Skin" surface has no usable
## texture, so without an override material it renders pitch black.

const TONES: Array[Dictionary] = [
	{"color": Color(0.87, 0.72, 0.59), "weight": 50.0}, # white
	{"color": Color(0.70, 0.56, 0.40), "weight": 25.0}, # olive
	{"color": Color(0.30, 0.20, 0.14), "weight": 13.0}, # black
	{"color": Color(0.52, 0.36, 0.25), "weight": 12.0}, # brown
]

static func pick() -> Color:
	var roll := randf() * 100.0
	var acc := 0.0
	for entry in TONES:
		acc += entry["weight"] as float
		if roll < acc:
			return entry["color"] as Color
	return TONES[-1]["color"] as Color

## Overrides the "Skin" surface of `skin_mesh` with a flat colour.
static func apply(skin_mesh: MeshInstance3D, color: Color) -> void:
	for i in skin_mesh.mesh.get_surface_count():
		if skin_mesh.mesh.surface_get_name(i) == "Skin":
			var mat := StandardMaterial3D.new()
			mat.albedo_color = color
			skin_mesh.set_surface_override_material(i, mat)
			return

## Finds the body mesh inside an instanced Casual_Male model and tints it randomly.
static func apply_random(model: Node) -> void:
	var body := model.find_child("Body2", true, false) as MeshInstance3D
	if body != null:
		apply(body, pick())
