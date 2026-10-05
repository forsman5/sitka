extends Node3D
## Blank test plane for first-person movement tuning.

const PLANE_SIZE := 200.0

func _ready() -> void:
	_build_ground()
	_build_markers()
	_build_environment()

	var player := OnFootPlayer.new()
	player.name = "Player"
	player.position = Vector3(0, 0.1, 0)
	add_child(player)

	var hint := Label.new()
	hint.text = "WASD move · Shift sprint · Space jump · Esc release mouse / back to menu"
	hint.position = Vector2(12, 8)
	var layer := CanvasLayer.new()
	layer.add_child(hint)
	add_child(layer)

func _build_ground() -> void:
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(PLANE_SIZE, 1.0, PLANE_SIZE)
	col.shape = box
	col.position.y = -0.5
	body.add_child(col)

	var mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(PLANE_SIZE, PLANE_SIZE)
	mesh.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.32, 0.5, 0.28)
	mat.uv1_scale = Vector3(PLANE_SIZE / 2.0, PLANE_SIZE / 2.0, 1)
	mat.albedo_texture = _checker_texture()
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS_ANISOTROPIC
	mesh.material_override = mat
	body.add_child(mesh)
	add_child(body)

## Small checker so motion and speed are readable on an otherwise blank plane.
func _checker_texture() -> ImageTexture:
	var img := Image.create(2, 2, false, Image.FORMAT_RGB8)
	img.set_pixel(0, 0, Color(1, 1, 1))
	img.set_pixel(1, 1, Color(1, 1, 1))
	img.set_pixel(1, 0, Color(0.85, 0.85, 0.85))
	img.set_pixel(0, 1, Color(0.85, 0.85, 0.85))
	return ImageTexture.create_from_image(img)

## A few boxes of known size for judging scale and jump height.
func _build_markers() -> void:
	var heights := [0.5, 1.0, 1.5, 2.5]
	for i in heights.size():
		var h: float = heights[i]
		var body := StaticBody3D.new()
		body.position = Vector3(4.0 + i * 3.0, h * 0.5, -8.0)
		var col := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(2, h, 2)
		col.shape = box
		body.add_child(col)
		var mesh := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = box.size
		mesh.mesh = bm
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.7, 0.55, 0.4)
		mesh.material_override = mat
		body.add_child(mesh)
		add_child(body)

func _build_environment() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -30, 0)
	sun.shadow_enabled = true
	add_child(sun)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.55, 0.7, 0.9)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.75, 0.85)
	env.ambient_light_energy = 0.6
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
