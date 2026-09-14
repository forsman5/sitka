class_name AuthoredValleyTerrain
extends Node3D

## Runtime view of the editable Blender blockout. The EXR is the source for
## visuals, height queries, and physics collision, so scenery and future
## placement tools describe the same authored landform.

const HEIGHTMAP_PATH := "res://assets/river_valley_height.exr"
const BIOME_MASK_PATH := "res://assets/river_valley_biomes.exr"
const WORLD_SIZE := Vector2(320.0, 240.0)
const HEIGHT_MIN := 2.602
const HEIGHT_MAX := 40.710

var _width := 0
var _depth := 0
var _heights := PackedFloat32Array()

func build() -> void:
	var height_texture := load(HEIGHTMAP_PATH) as Texture2D
	var biome_texture := load(BIOME_MASK_PATH) as Texture2D
	if height_texture == null or biome_texture == null:
		push_error("Authored valley terrain images are missing.")
		return
	var image := height_texture.get_image()
	image.convert(Image.FORMAT_RF)
	_width = image.get_width()
	_depth = image.get_height()
	_heights.resize(_width * _depth)

	for z in range(_depth):
		for x in range(_width):
			# Blender writes the first height row at its bottom edge. Flip the
			# image row so Godot's positive Z matches the authored map layout.
			var source_z := _depth - 1 - z
			_heights[z * _width + x] = lerpf(HEIGHT_MIN, HEIGHT_MAX, image.get_pixel(x, source_z).r)

	_build_visual_mesh(biome_texture)
	_build_collision()

func get_height(world_x: float, world_z: float) -> float:
	if _heights.is_empty():
		return 0.0
	var grid_x := clampf((world_x / WORLD_SIZE.x + 0.5) * float(_width - 1), 0.0, float(_width - 1))
	var grid_z := clampf((world_z / WORLD_SIZE.y + 0.5) * float(_depth - 1), 0.0, float(_depth - 1))
	var x0 := int(floor(grid_x))
	var z0 := int(floor(grid_z))
	var x1: int = min(x0 + 1, _width - 1)
	var z1: int = min(z0 + 1, _depth - 1)
	var tx := grid_x - float(x0)
	var tz := grid_z - float(z0)
	var h0: float = lerpf(_heights[z0 * _width + x0], _heights[z0 * _width + x1], tx)
	var h1: float = lerpf(_heights[z1 * _width + x0], _heights[z1 * _width + x1], tx)
	return lerpf(h0, h1, tz)

func _build_visual_mesh(biome_texture: Texture2D) -> void:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	vertices.resize(_width * _depth)
	normals.resize(_width * _depth)
	uvs.resize(_width * _depth)
	for z in range(_depth):
		for x in range(_width):
			var index := z * _width + x
			vertices[index] = Vector3(
				(float(x) / float(_width - 1) - 0.5) * WORLD_SIZE.x,
				_heights[index],
				(float(z) / float(_depth - 1) - 0.5) * WORLD_SIZE.y,
			)
			var previous_x: int = max(x - 1, 0)
			var next_x: int = min(x + 1, _width - 1)
			var previous_z: int = max(z - 1, 0)
			var next_z: int = min(z + 1, _depth - 1)
			var step_x := WORLD_SIZE.x / float(_width - 1)
			var step_z := WORLD_SIZE.y / float(_depth - 1)
			var height_left: float = _heights[z * _width + previous_x]
			var height_right: float = _heights[z * _width + next_x]
			var height_back: float = _heights[previous_z * _width + x]
			var height_forward: float = _heights[next_z * _width + x]
			var derivative_x: float = (height_right - height_left) / (float(next_x - previous_x) * step_x)
			var derivative_z: float = (height_forward - height_back) / (float(next_z - previous_z) * step_z)
			normals[index] = Vector3(-derivative_x, 1.0, -derivative_z).normalized()
			uvs[index] = Vector2(float(x) / float(_width - 1), 1.0 - float(z) / float(_depth - 1))
	for z in range(_depth - 1):
		for x in range(_width - 1):
			var a := z * _width + x
			indices.append_array([a, a + _width, a + 1, a + 1, a + _width, a + _width + 1])

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var visual := MeshInstance3D.new()
	visual.name = "AuthoredTerrainVisual"
	visual.mesh = mesh
	visual.material_override = _terrain_material(biome_texture)
	add_child(visual)

func _build_collision() -> void:
	var shape := HeightMapShape3D.new()
	shape.map_width = _width
	shape.map_depth = _depth
	shape.map_data = _heights
	var body := StaticBody3D.new()
	body.name = "AuthoredTerrainCollision"
	# This project uses Jolt, which supports the required non-uniform static
	# heightmap scaling. Heights are already expressed in Godot world units.
	body.scale = Vector3(WORLD_SIZE.x / float(_width - 1), 1.0, WORLD_SIZE.y / float(_depth - 1))
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)
	add_child(body)

func _terrain_material(biome_texture: Texture2D) -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode diffuse_lambert, specular_schlick_ggx, cull_disabled;
uniform sampler2D biome_mask;
void fragment() {
	vec4 mask = texture(biome_mask, UV);
	vec3 grass = vec3(0.29, 0.42, 0.19);
	vec3 field = vec3(0.56, 0.51, 0.22);
	vec3 woodland = vec3(0.12, 0.28, 0.12);
	vec3 pasture = vec3(0.40, 0.49, 0.22);
	vec3 wet_bank = vec3(0.19, 0.29, 0.14);
	vec3 color = mix(grass, woodland, mask.r * 0.78);
	color = mix(color, pasture, mask.g * 0.64);
	color = mix(color, field, mask.b * 0.64);
	color = mix(color, wet_bank, mask.a * 0.72);
	ALBEDO = color;
	ROUGHNESS = 0.96;
}
"""
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("biome_mask", biome_texture)
	return material
