extends Control

## Valley generator dev tool: pick a landscape and spec, browse seeds as shaded
## relief, a 3D mesh viewed through the RTS camera, or a contact sheet of eight seeds, and copy or
## save the spec of a seed you like.

const Generator = preload("res://scripts/valley/gen/valley_generator.gd")
const Relief = preload("res://scripts/valley/gen/valley_gen_relief.gd")
const Terrain = preload("res://scripts/valley/gen/valley_gen_terrain.gd")
const Spec = preload("res://scripts/valley/gen/valley_spec.gd")
const Bake = preload("res://scripts/valley/gen/valley_gen_bake.gd")
const BakeScene = preload("res://scripts/valley/baked_valley_renderer.gd")

const MAP_SCALE := 4
const SHEET_COUNT := 8
const MAIN_MENU := "res://scenes/ui/main_menu.tscn"
const CAMERA_SCENE := preload("res://scenes/camera/rts_camera.tscn")
## Saved specs go here from the editor / a desktop run from the project folder;
## exported builds fall back to user://.
const SPEC_DIR := "res://data/valley_specs"
const USER_SPEC_DIR := "user://valley_specs"
## Baked valleys (several MB each) go here; the folder is gitignored, force-add the
## ones worth keeping.
const BAKE_DIR := "res://data/valley_bakes"
const USER_BAKE_DIR := "user://valley_bakes"

signal bake_finished(ok: bool)

enum Mode { MAP, VIEW_3D, SHEET, BAKED }

var _spec: Spec = Spec.preset("river_valley", 1)
var _mode := Mode.MAP
var _result: Dictionary = {}
var _sheet_serial := 0
var _baking := false
var _baker: Variant = null
var _bake: Dictionary = {}
var _baked_world: Node3D
## Overrides for Bake.DEFAULTS (scale, step, erosion, ...); tests use a coarse bake.
var _bake_options := {}
var _bake_button: Button
var _cancel_button: Button
var _save_bake_button: Button
var _baked_mode_button: Button
var _progress_bar: ProgressBar
var _env_node: WorldEnvironment
var _env_strategic: Environment
var _env_baked: Environment
var _sun: DirectionalLight3D

var _landscape_box: OptionButton
var _seed_box: SpinBox
var _river_check: CheckBox
var _tribs_box: SpinBox
var _islands_box: SpinBox
var _routes_check: CheckBox
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
var _rig: Node3D
var _sheet_scroll: ScrollContainer
var _sheet_grid: GridContainer

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
	title.text = "Valley generator (dev tool)"
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

	var sea_row := HBoxContainer.new()
	side.add_child(sea_row)
	_islands_box = SpinBox.new()
	_islands_box.min_value = 1
	_islands_box.max_value = Spec.MAX_ISLANDS
	_islands_box.prefix = "isles"
	_islands_box.tooltip_text = "Island landscape only"
	_islands_box.value_changed.connect(func(v: float) -> void:
		_spec.islands = int(v)
		if _spec.islands > 1:
			_spec.landscape = "island"
		_generate())
	sea_row.add_child(_islands_box)
	_routes_check = CheckBox.new()
	_routes_check.text = "Sea routes"
	_routes_check.toggled.connect(func(on: bool) -> void:
		_spec.sea_routes = on
		_generate())
	sea_row.add_child(_routes_check)

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
	_baked_mode_button = _button("Baked", func() -> void: _show(Mode.BAKED))
	_baked_mode_button.disabled = true
	mode_row.add_child(_baked_mode_button)

	var bake_row := HBoxContainer.new()
	side.add_child(bake_row)
	_bake_button = _button("Bake detailed", func() -> void: _bake_detailed())
	_bake_button.tooltip_text = "3x scale, 1 unit terrain with erosion, about 30k trees, villages. ~10 s on desktop, around 1-2 min in the web build."
	bake_row.add_child(_bake_button)
	_cancel_button = _button("Cancel", func() -> void:
		if _baker != null:
			_baker.cancel())
	_cancel_button.visible = false
	bake_row.add_child(_cancel_button)
	_save_bake_button = _button("Save bake", _save_bake)
	_save_bake_button.disabled = true
	bake_row.add_child(_save_bake_button)
	_progress_bar = ProgressBar.new()
	_progress_bar.visible = false
	_progress_bar.show_percentage = true
	side.add_child(_progress_bar)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side.add_child(_status)
	_report = RichTextLabel.new()
	_report.bbcode_enabled = true
	_report.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side.add_child(_report)

	var camera_hint := Label.new()
	camera_hint.text = "3D (RTS camera): WASD/arrows pan, Q/E rotate, wheel zoom, Alt+mouse tilt, middle-drag pan."
	camera_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	camera_hint.modulate = Color(0.7, 0.7, 0.78)
	side.add_child(camera_hint)
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
	_env_strategic = Environment.new()
	_env_strategic.background_mode = Environment.BG_COLOR
	_env_strategic.background_color = Color(0.55, 0.7, 0.85)
	_env_strategic.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env_strategic.ambient_light_color = Color(0.75, 0.78, 0.85)
	_env_strategic.ambient_light_energy = 1.0
	# The baked view gets a sky, haze and filmic tonemapping so it reads as a place.
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.28, 0.5, 0.82)
	sky_material.sky_horizon_color = Color(0.74, 0.82, 0.9)
	sky_material.ground_horizon_color = Color(0.74, 0.82, 0.9)
	var sky := Sky.new()
	sky.sky_material = sky_material
	_env_baked = Environment.new()
	_env_baked.background_mode = Environment.BG_SKY
	_env_baked.sky = sky
	_env_baked.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env_baked.ambient_light_color = Color(0.82, 0.86, 0.95)
	_env_baked.ambient_light_energy = 0.9
	_env_baked.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	_env_baked.fog_enabled = true
	_env_baked.fog_light_color = Color(0.74, 0.82, 0.9)
	_env_baked.fog_density = 0.00006
	_env_node = WorldEnvironment.new()
	_env_node.environment = _env_strategic
	_viewport.add_child(_env_node)
	_sun = DirectionalLight3D.new()
	_sun.rotation_degrees = Vector3(-50, -35, 0)
	_sun.light_energy = 1.3
	_viewport.add_child(_sun)
	# The same rig the RTS and valley scenes use, bounded to the generated map.
	_rig = CAMERA_SCENE.instantiate()
	_rig.zoom_min = 28.0
	_rig.zoom_max = 420.0
	_rig.pivot_height = 140.0
	_rig.pan_limit = Terrain.SIZE * 0.5
	_rig.max_ground_height = 60.0
	_viewport.add_child(_rig)
	_configure_rig(false)
	_rig._current_tilt = 50.0
	_rig._apply_tilt()
	_rig.center_on(Vector3.ZERO)

## The rig polls keys itself and cannot see focus in the main viewport, so stop
## it reacting to WASD/Q/E typed into the spec box, or while hidden.
func _process(_delta: float) -> void:
	var focus := get_viewport().gui_get_focus_owner()
	_rig.set_process((_mode == Mode.VIEW_3D or _mode == Mode.BAKED) and not (focus is LineEdit or focus is TextEdit))

## Strategic and baked views are different sizes, so the rig is re-bounded.
func _configure_rig(baked: bool) -> void:
	var camera: Camera3D = _rig.get_node("Camera3D")
	camera.far = 6000.0
	if baked and not _bake.is_empty():
		var size: Vector2 = _bake["size"]
		_rig.zoom_min = 40.0
		_rig.zoom_max = 1600.0
		_rig.zoom_step = 40.0
		_rig.pivot_height = 700.0
		_rig.pan_limit = size * 0.5
		_rig.max_ground_height = float(_bake["height_max"])
		camera.size = 760.0
	else:
		_rig.zoom_min = 28.0
		_rig.zoom_max = 420.0
		_rig.zoom_step = 2.0
		_rig.pivot_height = 140.0
		_rig.pan_limit = Terrain.SIZE * 0.5
		_rig.max_ground_height = 60.0
		camera.size = 260.0
	_rig._apply_tilt()
	_rig.center_on(Vector3.ZERO)

func _unhandled_key_input(event: InputEvent) -> void:
	# Arrow keys pan the 3D camera, so they only step seeds in the other views.
	if event is InputEventKey and event.pressed and _mode != Mode.VIEW_3D and _mode != Mode.BAKED and not _spec_text.has_focus():
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
	_islands_box.set_value_no_signal(_spec.islands)
	_routes_check.set_pressed_no_signal(_spec.sea_routes)
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
	if OS.has_feature("web"):
		# The browser's user:// is private storage, so hand the file to the user.
		JavaScriptBridge.download_buffer((_spec.to_json() + "
").to_utf8_buffer(), file_name, "application/json")
		_status.text = "Downloading %s (check your browser's downloads)." % file_name
		return
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
	_discard_bake()
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
	_container.visible = mode == Mode.VIEW_3D or mode == Mode.BAKED
	_sheet_scroll.visible = mode == Mode.SHEET
	var baked := mode == Mode.BAKED and _baked_world != null
	_world.visible = not baked
	if _baked_world != null:
		_baked_world.visible = baked
	_env_node.environment = _env_baked if baked else _env_strategic
	_sun.shadow_enabled = baked
	_sun.directional_shadow_max_distance = 1500.0
	if (baked and _rig.pan_limit != _bake["size"] * 0.5) or (not baked and _rig.pan_limit != Terrain.SIZE * 0.5):
		_configure_rig(baked)
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
	text += "\n%d roads, %d sea routes, %d fords, %d trees" % [_result["roads"].size(), _result["water_routes"].size(), _result["map"].crossings.size(), _result["trees"].size()]
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
		label.pixel_size = 0.16
		label.font_size = 40
		label.outline_size = 12
		label.position = Vector3(pos.x, site["height"] + cylinder.height + 5.0, pos.y)
		_world.add_child(label)

	# Boat lanes: dashes of white discs just above the sea.
	var dashes: Array[Vector2] = []
	var lane_map: ValleyMapDefinition = _result["map"]
	for route_id in lane_map.water_routes:
		var step := 0
		for p in Generator.water_route_samples(lane_map, route_id, 2.0):
			step += 1
			if (step / 3) % 2 == 0:
				dashes.append(p)
	if not dashes.is_empty():
		var disc := CylinderMesh.new()
		disc.top_radius = 1.0
		disc.bottom_radius = 1.0
		disc.height = 0.2
		var disc_material := StandardMaterial3D.new()
		disc_material.albedo_color = Color(1, 1, 1)
		disc_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		disc.material = disc_material
		var lane := MultiMesh.new()
		lane.transform_format = MultiMesh.TRANSFORM_3D
		lane.mesh = disc
		lane.instance_count = dashes.size()
		for i in dashes.size():
			lane.set_instance_transform(i, Transform3D(Basis.IDENTITY, Vector3(dashes[i].x, 0.4, dashes[i].y)))
		var lane_instance := MultiMeshInstance3D.new()
		lane_instance.multimesh = lane
		_world.add_child(lane_instance)

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

# -- detailed bake (dev tool) --------------------------------------------------

func _discard_bake() -> void:
	if _baker != null:
		_baker.cancel()
	if _baked_world != null:
		_baked_world.queue_free()
		_baked_world = null
	_bake = {}
	if _mode == Mode.BAKED:
		_mode = Mode.MAP
	if _baked_mode_button != null:
		_baked_mode_button.disabled = true
		_save_bake_button.disabled = true

func _on_bake_progress(fraction: float, text: String) -> void:
	_progress_bar.value = fraction * 100.0
	_status.text = text

func _set_baking(active: bool) -> void:
	_baking = active
	_bake_button.disabled = active
	_cancel_button.visible = active
	_progress_bar.visible = active
	_progress_bar.value = 0.0

## Coroutine: bakes the current valley, builds its scene, and switches to it.
func _bake_detailed() -> void:
	if _result.is_empty() or _baking:
		return
	_discard_bake()
	_set_baking(true)
	var baker := Bake.new()
	_baker = baker
	var data: Dictionary = await baker.run(_result, get_tree(), _on_bake_progress, _bake_options)
	if baker.cancelled or data.is_empty() or not is_inside_tree():
		_finish_bake(false, "Bake cancelled.")
		return
	var builder := BakeScene.new()
	_baker = builder
	var world: Node3D = await builder.build(data, get_tree(), _on_bake_progress)
	if world == null or not is_inside_tree():
		_finish_bake(false, "Bake cancelled.")
		return
	_bake = data
	_baked_world = world
	_viewport.add_child(world)
	var stats: Dictionary = data["stats"]
	# Finish the UI before announcing, since listeners run as soon as it is emitted.
	_baked_mode_button.disabled = false
	_save_bake_button.disabled = false
	_show(Mode.BAKED)
	_finish_bake(true, "Baked %d x %d units: %d cells, %d trees, %d buildings, %.0f s." % [data["size"].x, data["size"].y, stats["cells"], stats["trees"], stats["buildings"], float(stats["ms"]) / 1000.0])

func _finish_bake(ok: bool, message: String) -> void:
	_baker = null
	_set_baking(false)
	_status.text = message
	bake_finished.emit(ok)

## Saves the bake as a folder of plain files (see Bake.save). On the web build the
## browser's storage is private, so the folder is zipped and downloaded instead.
func _save_bake() -> void:
	if _bake.is_empty():
		return
	var name := "%s_%d" % [_spec.landscape, _spec.seed]
	if OS.has_feature("web"):
		var temp_dir := "%s/%s" % [USER_BAKE_DIR, name]
		var failure := Bake.save(_bake, temp_dir)
		if failure != "":
			_status.text = failure
			return
		var bytes := _zip_dir(temp_dir, name, "user://%s_bake.zip" % name)
		JavaScriptBridge.download_buffer(bytes, "%s_bake.zip" % name, "application/zip")
		_status.text = "Downloading %s_bake.zip (check your browser's downloads)." % name
		return
	var last_error := ""
	for base in [BAKE_DIR, USER_BAKE_DIR]:
		var dir := "%s/%s" % [base, name]
		last_error = Bake.save(_bake, dir)
		if last_error == "":
			_status.text = "Saved bake to %s" % ProjectSettings.globalize_path(dir)
			return
	_status.text = last_error

func _zip_dir(dir: String, folder: String, zip_path: String) -> PackedByteArray:
	var packer := ZIPPacker.new()
	if packer.open(zip_path) != OK:
		return PackedByteArray()
	for file_name in DirAccess.get_files_at(dir):
		packer.start_file("%s/%s" % [folder, file_name])
		packer.write_file(FileAccess.get_file_as_bytes("%s/%s" % [dir, file_name]))
		packer.close_file()
	packer.close()
	return FileAccess.get_file_as_bytes(zip_path)
