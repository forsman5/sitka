extends Node3D
## Blank test plane for first-person movement tuning.

const PLANE_SIZE := 200.0

## Esc often releases mouse capture itself (browser pointer lock, embedded game
## window) before the game sees a key press, so a lost capture also opens the menu.
const ESC_DEBOUNCE_MSEC := 250

var _pause_layer: CanvasLayer
var _auto_paused_at: int = -ESC_DEBOUNCE_MSEC

func _ready() -> void:
	_build_ground()
	_build_markers()
	_spawn_flock()
	_build_environment()

	var player := OnFootPlayer.new()
	player.name = "Player"
	player.position = Vector3(0, 0.1, 0)
	add_child(player)

	var hint := Label.new()
	hint.text = "WASD move · Shift sprint · Space jump · F5 camera view · Esc menu"
	hint.position = Vector2(12, 8)
	var layer := CanvasLayer.new()
	layer.add_child(hint)
	add_child(layer)
	_build_pause_menu()

func _build_pause_menu() -> void:
	_pause_layer = CanvasLayer.new()
	_pause_layer.layer = 20
	_pause_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	_pause_layer.visible = false
	add_child(_pause_layer)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pause_layer.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pause_layer.add_child(center)

	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(220, 0)
	box.add_theme_constant_override("separation", 12)
	center.add_child(box)

	var title := Label.new()
	title.text = "Paused"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	box.add_child(title)

	var resume := Button.new()
	resume.text = "Resume"
	resume.pressed.connect(_set_paused.bind(false))
	box.add_child(resume)

	var quit := Button.new()
	quit.text = "Main Menu"
	quit.pressed.connect(_to_main_menu)
	box.add_child(quit)

func _process(_delta: float) -> void:
	if not get_tree().paused and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		_auto_paused_at = Time.get_ticks_msec()
		_set_paused(true)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		# The same Esc press may already have opened the menu via lost capture.
		if Time.get_ticks_msec() - _auto_paused_at < ESC_DEBOUNCE_MSEC:
			return
		_set_paused(not get_tree().paused)

func _set_paused(paused: bool) -> void:
	get_tree().paused = paused
	_pause_layer.visible = paused
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if paused else Input.MOUSE_MODE_CAPTURED

func _to_main_menu() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")

## A small flock a short walk ahead of the spawn point.
func _spawn_flock() -> void:
	var center := Vector3(-6, 0, -18)
	for i in randi_range(3, 5):
		var sheep := OnFootSheep.new()
		sheep.position = center + Vector3(randf_range(-3, 3), 0.1, randf_range(-3, 3))
		sheep.rotation.y = randf() * TAU
		add_child(sheep)

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
