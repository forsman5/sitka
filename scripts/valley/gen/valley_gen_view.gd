extends Control

## Valley generator experiment: pick a landscape and spec, browse seeds as shaded
## relief, an orbitable 3D mesh, or a contact sheet of eight seeds, and copy or
## save the spec of a seed you like.

const Generator = preload("res://scripts/valley/gen/valley_generator.gd")
const Relief = preload("res://scripts/valley/gen/valley_gen_relief.gd")
const Terrain = preload("res://scripts/valley/gen/valley_gen_terrain.gd")
const Spec = preload("res://scripts/valley/gen/valley_spec.gd")

const MAP_SCALE := 4
const SHEET_COUNT := 8
const MAIN_MENU := "res://scenes/ui/main_menu.tscn"
## Saved specs go here from the editor / a desktop run from the project folder;
## exported builds fall back to user://.
const SPEC_DIR := "res://data/valley_specs"
const USER_SPEC_DIR := "user://valley_specs"

enum Mode { MAP, VIEW_3D, SHEET }

var _spec: Spec = Spec.preset("river_valley", 1)
var _mode := Mode.MAP
var _result: Dictionary = {}
var _sheet_serial := 0

var _landscape_box: OptionButton
var _seed_box: SpinBox
var _river_check: CheckBox
var _tribs_box: SpinBox
var _relief_slider: HSlider
var _relief_label: Label
var _spec_text: TextEdit
var _report: RichTextLabel
var _status: Label
var _map: TextureRect
var _labels: Control
var _container: SubViewportContainer
var _viewport: SubViewport
var _world: Node3D
var _camera: Camera3D
var _sheet_scroll: ScrollContainer
var _sheet_grid: GridContainer
var _yaw := 0.6
var _pitch := -0.85
var _distance := 340.0

func _ready() -> void:
	_build_ui()
	_build_3d_stage()
	_generate()

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.09, 0.1, 0.12)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(backdrop)
	var root := HBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(350, 0)
	side.add_theme_constant_override("separation", 5)
	root.add_child(side)
	var title := Label.new()
	title.text = "Valley generator (sketch)"
	title.add_theme_font_size_override("font_size", 18)
	side.add_child(title)

	_landscape_box = OptionButton.new()
	for name in Spec.LANDSCAPES:
		_landscape_box.add_item(name.replace("_", " ").capitalize())
	_landscape_box.item_selected.connect(_on_landscape_selected)
	side.add_child(_landscape_box)

	var seed_row := HBoxContainer.new()
	side.add_child(seed_row)
	seed_row.add_child(_button("<", func() -> void: _set_seed(_spec.seed - 1)))
	_seed_box = SpinBox.new()
	_seed_box.min_value = 0
	_seed_box.max_value = 999999
	_seed_box.value = _spec.seed
	_seed_box.prefix = "seed"
	_seed_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_seed_box.value_changed.connect(func(v: float) -> void: _set_seed(int(v)))
	seed_row.add_child(_seed_box)
	seed_row.add_child(_button(">", func() -> void: _set_seed(_spec.seed + 1)))
	seed_row.add_child(_button("Random", func() -> void: _set_seed(randi() % 100000)))

	var shape_row := HBoxContainer.new()
	side.add_child(shape_row)
	_river_check = CheckBox.new()
	_river_check.text = "Main river"
	_river_check.toggled.connect(func(on: bool) -> void:
		_spec.main_river = on
		if not on:
			_spec.tributaries = 0
		_generate())
	shape_row.add_child(_river_check)
	_tribs_box = SpinBox.new()
	_tribs_box.min_value = 0
	_tribs_box.max_value = Spec.MAX_TRIBUTARIES
	_tribs_box.prefix = "rivers+"
	_tribs_box.value_changed.connect(func(v: float) -> void:
		_spec.tributaries = int(v)
		if _spec.tributaries > 0:
			_spec.main_river = true
		_generate())
	shape_row.add_child(_tribs_box)

	var relief_row := HBoxContainer.new()
	side.add_child(relief_row)
	_relief_label = Label.new()
	relief_row.add_child(_relief_label)
	_relief_slider = HSlider.new()
	_relief_slider.min_value = 0.4
	_relief_slider.max_value = 1.8
	_relief_slider.step = 0.1
	_relief_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_relief_slider.value_changed.connect(func(v: float) -> void: _relief_label.text = "relief %.1f" % v)
	_relief_slider.drag_ended.connect(func(changed: bool) -> void:
		if changed:
			_spec.relief = _relief_slider.value
			_generate())
	relief_row.add_child(_relief_slider)

	var mode_row := HBoxContainer.new()
	side.add_child(mode_row)
	mode_row.add_child(_button("Relief", func() -> void: _show(Mode.MAP)))
	mode_row.add_child(_button("3D", func() -> void: _show(Mode.VIEW_3D)))
	mode_row.add_child(_button("8 seeds", func() -> void: _show(Mode.SHEET)))

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side.add_child(_status)
	_report = RichTextLabel.new()
	_report.bbcode_enabled = true
	_report.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side.add_child(_report)

	var spec_title := Label.new()
	spec_title.text = "Spec (edit, then Apply; Copy/Save to keep it)"
	side.add_child(spec_title)
	_spec_text = TextEdit.new()
	_spec_text.custom_minimum_size = Vector2(0, 170)
	_spec_text.add_theme_font_size_override("font_size", 11)
	side.add_child(_spec_text)
	var spec_row := HBoxContainer.new()
	side.add_child(spec_row)
	spec_row.add_child(_button("Apply", _apply_spec_text))
	spec_row.add_child(_button("Copy spec", _copy_spec))
	spec_row.add_child(_button("Save spec", _save_spec))
	side.add_child(_button("Back to main menu", func() -> void: get_tree().change_scene_to_file(MAIN_MENU)))

	var stage := Control.new()
	stage.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stage.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(stage)

	_map = TextureRect.new()
	_map.set_anchors_preset(Control.PRESET_FULL_RECT)
	_map.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_map.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_map.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_map.resized.connect(_layout_labels)
	stage.add_child(_map)
	_labels = Control.new()
	_labels.set_anchors_preset(Control.PRESET_FULL_RECT)
	_labels.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stage.add_child(_labels)

	_container = SubViewportContainer.new()
	_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	_container.stretch = true
	_container.gui_input.connect(_on_3d_input)
	stage.add_child(_container)
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.msaa_3d = Viewport.MSAA_4X
	_container.add_child(_viewport)

	_sheet_scroll = ScrollContainer.new()
	_sheet_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	stage.add_child(_sheet_scroll)
	_sheet_grid = GridContainer.new()
	_sheet_grid.columns = 2
	_sheet_grid.add_theme_constant_override("h_separation", 8)
	_sheet_grid.add_theme_constant_override("v_separation", 8)
	_sheet_scroll.add_child(_sheet_grid)

func _button(text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(action)
	return button

func _build_3d_stage() -> void:
	_world = Node3D.new()
	_viewport.add_child(_world)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.55, 0.7, 0.85)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.75, 0.78, 0.85)
	environment.ambient_light_energy = 1.0
	var env_node := WorldEnvironment.new()
	env_node.environment = environment
	_viewport.add_child(env_node)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -35, 0)
	sun.light_energy = 1.3
	_viewport.add_child(sun)
	_camera = Camera3D.new()
	_camera.far = 2000.0
	_camera.fov = 45.0
	_viewport.add_child(_camera)
	_update_camera()

func _update_camera() -> void:
	var target := Vector3(0, 12, 0)
	var offset := Vector3(0, 0, _distance).rotated(Vector3.RIGHT, _pitch).rotated(Vector3.UP, _yaw)
	_camera.position = target + offset
	_camera.look_at(target)

func _on_3d_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		_yaw -= event.relative.x * 0.006
		_pitch = clampf(_pitch - event.relative.y * 0.006, -1.45, -0.15)
		_update_camera()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_distance = maxf(_distance * 0.9, 60.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_distance = minf(_distance * 1.1, 900.0)
		_update_camera()

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not _spec_text.has_focus():
		if event.keycode == KEY_RIGHT:
			_set_seed(_spec.seed + 1)
		elif event.keycode == KEY_LEFT:
			_set_seed(maxi(_spec.seed - 1, 0))

# -- spec controls -------------------------------------------------------------

func _on_landscape_selected(index: int) -> void:
	_spec = Spec.preset(Spec.LANDSCAPES[index], _spec.seed)
	_generate()

func _set_seed(value: int) -> void:
	value = maxi(value, 0)
	if value == _spec.seed and not _result.is_empty():
		return
	_spec.seed = value
	_generate()

## Mirrors the spec into the controls and the JSON box without re-triggering them.
func _sync_controls() -> void:
	_landscape_box.select(maxi(Spec.LANDSCAPES.find(_spec.landscape), 0))
	_seed_box.set_value_no_signal(_spec.seed)
	_river_check.set_pressed_no_signal(_spec.main_river)
	_tribs_box.set_value_no_signal(_spec.tributaries)
	_relief_slider.set_value_no_signal(_spec.relief)
	_relief_label.text = "relief %.1f" % _spec.relief
	_spec_text.text = _spec.to_json()

func _apply_spec_text() -> void:
	var parsed := Spec.from_json(_spec_text.text)
	if parsed["spec"] == null:
		_status.text = "Spec not applied: %s" % ", ".join(parsed["errors"])
		return
	_spec = parsed["spec"]
	_generate()

func _copy_spec() -> void:
	DisplayServer.clipboard_set(_spec.to_json())
	_status.text = "Copied the %s spec (seed %d) to the clipboard." % [_spec.landscape, _spec.seed]

func _save_spec() -> void:
	var file_name := "%s_%d.json" % [_spec.landscape, _spec.seed]
	for dir in [SPEC_DIR, USER_SPEC_DIR]:
		DirAccess.make_dir_recursive_absolute(dir)
		var file := FileAccess.open("%s/%s" % [dir, file_name], FileAccess.WRITE)
		if file != null:
			file.store_string(_spec.to_json() + "\n")
			file.close()
			_status.text = "Saved %s" % ProjectSettings.globalize_path("%s/%s" % [dir, file_name])
			return
	_status.text = "Could not save the spec; use Copy spec instead."

# -- generating and showing ----------------------------------------------------

func _generate() -> void:
	var result := Generator.generate(_spec)
	if result.has("spec_errors"):
		_status.text = "Invalid spec: %s" % ", ".join(result["spec_errors"])
		return
	_result = result
	_sync_controls()
	_map.texture = ImageTexture.create_from_image(Relief.relief_image(_result, MAP_SCALE))
	_build_3d_world()
	_refresh_report()
	_layout_labels()
	_show(_mode)

func _show(mode: Mode) -> void:
	_mode = mode
	_map.visible = mode == Mode.MAP
	_labels.visible = mode == Mode.MAP
	_container.visible = mode == Mode.VIEW_3D
	_sheet_scroll.visible = mode == Mode.SHEET
	if mode == Mode.SHEET:
		_build_sheet()

func _refresh_report() -> void:
	var report: Dictionary = _result["report"]
	_status.text = "Seed %d: %s (%d ms)" % [_spec.seed, "passes validation" if report["ok"] else "REJECTED by validation", _result["ms"]]
	var text := ""
	for c in report["checks"]:
		var mark := "[color=#6fd07a]pass[/color]" if c["ok"] else "[color=#e56b6b]FAIL[/color]"
		text += "%s [b]%s[/b]\n   %s\n" % [mark, c["name"], c["detail"]]
	text += "\n[b]Settlements[/b]\n"
	for site in _result["sites"] as Array[Dictionary]:
		text += "%s - %s\n" % [site["name"], site["role"]]
	text += "\n%d roads, %d fords, %d trees" % [_result["roads"].size(), _result["map"].crossings.size(), _result["trees"].size()]
	_report.text = text

func _layout_labels() -> void:
	for child in _labels.get_children():
		child.queue_free()
	if _result.is_empty() or _map.size.x <= 0.0:
		return
	var image_size := Vector2(Terrain.W, Terrain.H) * float(MAP_SCALE)
	var factor := minf(_map.size.x / image_size.x, _map.size.y / image_size.y)
	var offset := (_map.size - image_size * factor) * 0.5
	for site in _result["sites"] as Array[Dictionary]:
		var label := Label.new()
		label.text = "%s\n%s" % [site["name"], site["role"]]
		label.add_theme_font_size_override("font_size", 12)
		label.add_theme_color_override("font_outline_color", Color.BLACK)
		label.add_theme_constant_override("outline_size", 4)
		label.position = offset + Relief.to_pixel(site["pos"], MAP_SCALE) * factor + Vector2(8, 6) * (1.0 + float(site["pad"]) / 40.0)
		_labels.add_child(label)

func _build_3d_world() -> void:
	for child in _world.get_children():
		child.queue_free()
	var terrain: Terrain = _result["terrain"]
	var tint := Relief.tint_grid(_result, true)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	for gz in Terrain.H:
		for gx in Terrain.W:
			var x := gx * Terrain.STEP - Terrain.SIZE.x * 0.5
			var z := gz * Terrain.STEP - Terrain.SIZE.y * 0.5
			var i := gz * Terrain.W + gx
			# Sea floor is drawn as a flat surface; the tint carries the depth.
			vertices.append(Vector3(x, maxf(terrain.heights[i], -0.3) if terrain.has_sea else terrain.heights[i], z))
			var dx := terrain.get_height(x + Terrain.STEP, z) - terrain.get_height(x - Terrain.STEP, z)
			var dz := terrain.get_height(x, z + Terrain.STEP) - terrain.get_height(x, z - Terrain.STEP)
			normals.append(Vector3(-dx, 2.0 * Terrain.STEP, -dz).normalized())
			colors.append(tint.get_pixel(gx, gz))
	for gz in Terrain.H - 1:
		for gx in Terrain.W - 1:
			var a := gz * Terrain.W + gx
			indices.append_array([a, a + Terrain.W, a + 1, a + 1, a + Terrain.W, a + Terrain.W + 1])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var ground := MeshInstance3D.new()
	ground.mesh = mesh
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.vertex_color_is_srgb = true
	material.roughness = 1.0
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	ground.material_override = material
	_world.add_child(ground)

	for site in _result["sites"] as Array[Dictionary]:
		var pos: Vector2 = site["pos"]
		var big: bool = site["role"] in ["town", "port"]
		var post := MeshInstance3D.new()
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = 2.0 if big else 1.4
		cylinder.bottom_radius = cylinder.top_radius
		cylinder.height = 9.0 if big else 6.0
		post.mesh = cylinder
		var post_material := StandardMaterial3D.new()
		post_material.albedo_color = site["accent"]
		post.material_override = post_material
		post.position = Vector3(pos.x, site["height"] + cylinder.height * 0.5, pos.y)
		_world.add_child(post)
		var label := Label3D.new()
		label.text = "%s (%s)" % [site["name"], site["role"]]
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.pixel_size = 0.11
		label.font_size = 40
		label.outline_size = 12
		label.position = Vector3(pos.x, site["height"] + cylinder.height + 5.0, pos.y)
		_world.add_child(label)

	var trees: PackedVector2Array = _result["trees"]
	if not trees.is_empty():
		var cone := CylinderMesh.new()
		cone.top_radius = 0.0
		cone.bottom_radius = 1.3
		cone.height = 4.5
		var tree_material := StandardMaterial3D.new()
		tree_material.albedo_color = Color(0.1, 0.3, 0.12)
		cone.material = tree_material
		var multi := MultiMesh.new()
		multi.transform_format = MultiMesh.TRANSFORM_3D
		multi.mesh = cone
		multi.instance_count = trees.size()
		for i in trees.size():
			multi.set_instance_transform(i, Transform3D(Basis.IDENTITY, Vector3(trees[i].x, terrain.get_height(trees[i].x, trees[i].y) + 2.2, trees[i].y)))
		var instance := MultiMeshInstance3D.new()
		instance.multimesh = multi
		_world.add_child(instance)

func _build_sheet() -> void:
	_sheet_serial += 1
	var serial := _sheet_serial
	for child in _sheet_grid.get_children():
		child.queue_free()
	var first := _spec.seed - _spec.seed % SHEET_COUNT
	var passed := 0
	for i in SHEET_COUNT:
		_status.text = "Generating contact sheet %d/%d..." % [i + 1, SHEET_COUNT]
		await get_tree().process_frame
		if serial != _sheet_serial or not is_inside_tree():
			return
		var value := first + i
		var variant: Spec = Spec.from_dict(_spec.to_dict())
		variant.seed = value
		var result: Dictionary = _result if value == _spec.seed else Generator.generate(variant)
		var ok: bool = result["report"]["ok"]
		passed += 1 if ok else 0
		var button := Button.new()
		button.icon = ImageTexture.create_from_image(Relief.thumbnail(result, 3))
		button.text = "seed %d  %s" % [value, "pass" if ok else "rejected: " + _first_failure(result)]
		button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		button.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
		button.pressed.connect(func() -> void:
			_spec.seed = value
			_mode = Mode.MAP
			_generate())
		_sheet_grid.add_child(button)
	_status.text = "Seeds %d-%d: %d/%d pass validation." % [first, first + SHEET_COUNT - 1, passed, SHEET_COUNT]

static func _first_failure(result: Dictionary) -> String:
	for c in result["report"]["checks"]:
		if not c["ok"]:
			return c["name"]
	return ""
