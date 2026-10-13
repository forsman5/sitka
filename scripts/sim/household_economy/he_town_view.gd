extends Control

## Top-down view of one household-economy town. Purely a renderer: it draws
## the sites of an HETownLayout and the live state from business reports, and
## owns only camera and selection. The dashboard feeds it through sync() after
## every refresh; rebuilding this view never moves a site because the layout,
## not this node, owns the positions.
##
## Art is visual-only: the RTS building models are instanced for their
## meshes, none of the RTS building scripts run. The ranch "barn" mirrors
## scenes/entities/building/barn.tscn (a 6x3x4 brown box) without its script.
## Camera: the same RTSCamera rig the RTS and valley scenes use (wheel zoom,
## middle-drag / WASD pan, Q/E rotate, Alt+mouse tilt), instanced inside this
## view's own viewport. Input reaches it by forwarding events from this
## control; a plain left click selects a site.

signal business_selected(business_id: int)
signal details_requested(business_id: int)

const HETownLayout = preload("res://scripts/sim/household_economy/he_town_layout.gd")

const MODEL_DIR := "res://assets/models/buildings/"
## type_key -> {"model": file name or "barn", "width": world units}. Anything
## not listed uses DEFAULT_ART.
const ART := {
	"government": {"model": "building_castle_blue.gltf", "width": 12.0},
	"farm": {"model": "building_home_A_blue.gltf", "width": 6.0},
	"woodlot": {"model": "building_home_B_blue.gltf", "width": 5.0},
	"trader": {"model": "building_tavern_blue.gltf", "width": 7.0},
	"cattle_ranch": {"model": "barn", "width": 8.0},
	"sheep_farm": {"model": "barn", "width": 7.0},
}
const DEFAULT_ART := {"model": "building_home_B_blue.gltf", "width": 6.0}
const BARN_SIZE := Vector3(6.0, 3.0, 4.0)
const BARN_COLOR := Color(0.55, 0.27, 0.07)

const CAMERA_SCENE := preload("res://scenes/camera/rts_camera.tscn")
const ZOOM_MIN := 20.0
const ZOOM_MAX := 170.0
const ZOOM_DEFAULT := 100.0
## Half the side of the ground plane; the camera may pan anywhere on it.
const GROUND_HALF_EXTENT := 200.0

const GROUND_COLOR := Color(0.36, 0.52, 0.27)
const FIELD_COLOR := Color(0.58, 0.44, 0.24)
const FURROW_COLOR := Color(0.42, 0.31, 0.16)
const PASTURE_COLOR := Color(0.5, 0.72, 0.34)
const PASTURE_EDGE_COLOR := Color(0.36, 0.58, 0.25)
const STAND_COLOR := Color(0.2, 0.38, 0.2)
const PLAZA_COLOR := Color(0.7, 0.62, 0.46)
const VACANT_OVERLAY := Color(0.45, 0.45, 0.45, 0.55)
const SELECTION_COLOR := Color(1.0, 0.9, 0.2, 0.45)

static var _scene_cache: Dictionary = {}

var _layout: HETownLayout
var _reports: Dictionary = {} # business_id -> report
var _site_nodes: Dictionary = {} # site_id -> {"root": Node3D, "signature": String, "label": Label3D}
var _selected_site_id: int = -1
var _left_down := false
var _rig: Node3D

var _viewport: SubViewport
var _camera: Camera3D
var _sites_root: Node3D
var _selection_marker: MeshInstance3D
var _info_panel: PanelContainer
var _info_title: Label
var _info_body: Label
var _details_button: Button
var _unplaced_label: Label

func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_world()
	_build_overlay()
	_refresh_info()

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Brings the drawn town in line with `layout` and the current business
## reports. Cheap when nothing changed.
func sync(layout: HETownLayout, reports: Array) -> void:
	_layout = layout
	_reports.clear()
	for report in reports:
		_reports[int(report["business_id"])] = report
	if _sites_root == null:
		return
	for site in layout.get_sites():
		if not site["built"]:
			continue
		_sync_site(site)
	var unplaced := layout.unplaced_business_ids()
	_unplaced_label.visible = not unplaced.is_empty()
	_unplaced_label.text = "%d business(es) have no room in the town" % unplaced.size()
	_refresh_info()

## Selects the site holding `business_id` (no-op if it has none).
func select_business(business_id: int) -> void:
	if _layout == null:
		return
	var site := _layout.site_of_business(business_id)
	if not site.is_empty():
		_select_site(site["site_id"])

func clear_selection() -> void:
	_selected_site_id = -1
	_refresh_info()

func selected_business_id() -> int:
	if _layout == null or _selected_site_id == -1:
		return -1
	return int(_layout.get_site(_selected_site_id).get("business_id", -1))

func site_node_count() -> int:
	return _site_nodes.size()

func camera() -> Camera3D:
	return _camera

# ---------------------------------------------------------------------------
# Scene construction
# ---------------------------------------------------------------------------

func _build_world() -> void:
	var container := SubViewportContainer.new()
	container.stretch = true
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(container)
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.handle_input_locally = false
	_viewport.msaa_3d = Viewport.MSAA_4X
	container.add_child(_viewport)

	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.5, 0.68, 0.82)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(1.0, 1.0, 1.0)
	environment.ambient_light_energy = 0.55
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	_viewport.add_child(world_environment)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-58.0, -35.0, 0.0)
	sun.light_energy = 1.0
	sun.shadow_enabled = true
	_viewport.add_child(sun)

	_rig = CAMERA_SCENE.instantiate()
	_rig.zoom_min = ZOOM_MIN
	_rig.zoom_max = ZOOM_MAX
	_rig.pivot_height = 60.0
	_rig.pan_limit = Vector2.ONE * GROUND_HALF_EXTENT
	_viewport.add_child(_rig)
	_camera = _rig.get_node("Camera3D")
	_camera.size = ZOOM_DEFAULT
	# The rig polls the keyboard globally; keep it quiet while the dashboard
	# is showing instead.
	visibility_changed.connect(func() -> void: _rig.set_process(is_visible_in_tree()))

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2.ONE * GROUND_HALF_EXTENT * 2.0
	ground.mesh = plane
	ground.material_override = _flat_material(GROUND_COLOR)
	ground.name = "Ground"
	_viewport.add_child(ground)

	_sites_root = Node3D.new()
	_sites_root.name = "Sites"
	_viewport.add_child(_sites_root)

	_selection_marker = MeshInstance3D.new()
	_selection_marker.mesh = BoxMesh.new()
	var marker_material := StandardMaterial3D.new()
	marker_material.albedo_color = SELECTION_COLOR
	marker_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	marker_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_selection_marker.material_override = marker_material
	_selection_marker.visible = false
	_selection_marker.name = "Selection"
	_viewport.add_child(_selection_marker)

func _build_overlay() -> void:
	var hint := Label.new()
	hint.text = "Wheel: zoom   Middle-drag / WASD: pan   Q/E: rotate   Alt+mouse: tilt   Click: select"
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	hint.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	hint.add_theme_constant_override("outline_size", 4)
	hint.position = Vector2(10, 6)
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hint)

	_unplaced_label = Label.new()
	_unplaced_label.add_theme_color_override("font_color", Color(0.95, 0.6, 0.3))
	_unplaced_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_unplaced_label.add_theme_constant_override("outline_size", 4)
	_unplaced_label.position = Vector2(10, 28)
	_unplaced_label.visible = false
	_unplaced_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_unplaced_label)

	_info_panel = PanelContainer.new()
	_info_panel.anchor_top = 1.0
	_info_panel.anchor_bottom = 1.0
	_info_panel.offset_left = 10.0
	_info_panel.offset_bottom = -10.0
	_info_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_info_panel.custom_minimum_size = Vector2(260, 0)
	var box := VBoxContainer.new()
	_info_panel.add_child(box)
	_info_title = Label.new()
	_info_title.add_theme_font_size_override("font_size", 16)
	box.add_child(_info_title)
	_info_body = Label.new()
	_info_body.add_theme_color_override("font_color", Color(0.75, 0.75, 0.8))
	box.add_child(_info_body)
	_details_button = Button.new()
	_details_button.text = "Open business details"
	_details_button.pressed.connect(_on_details_pressed)
	box.add_child(_details_button)
	add_child(_info_panel)

static func _flat_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 1.0
	return material

# ---------------------------------------------------------------------------
# Sites
# ---------------------------------------------------------------------------

func _sync_site(site: Dictionary) -> void:
	var site_id: int = site["site_id"]
	var occupied: bool = site["business_id"] != HETownLayout.NO_BUSINESS
	var signature := "%s|%s" % [site["type_key"], occupied]
	var entry: Dictionary = _site_nodes.get(site_id, {})
	if entry.is_empty() or entry["signature"] != signature:
		if not entry.is_empty():
			(entry["root"] as Node3D).queue_free()
		entry = _build_site(site, occupied)
		entry["signature"] = signature
		_site_nodes[site_id] = entry
	var label_text := str(site["label"])
	if not occupied:
		label_text += " (vacant)" if label_text != "" else "Vacant"
	(entry["label"] as Label3D).text = label_text

func _build_site(site: Dictionary, occupied: bool) -> Dictionary:
	var root := Node3D.new()
	root.name = "Site%d" % site["site_id"]
	var position: Vector2 = site["position"]
	root.position = Vector3(position.x, 0.0, position.y)
	_sites_root.add_child(root)

	var body := Node3D.new()
	body.name = "Body"
	body.rotation.y = -float(site["rotation"])
	root.add_child(body)

	var footprint: Vector2 = site["footprint"]
	var type_key: String = site["type_key"]
	var building_offset := Vector3.ZERO
	match type_key:
		"farm":
			_add_field(body, footprint)
			building_offset = Vector3(-footprint.x * 0.5 + 4.5, 0.0, 0.0)
		"woodlot":
			_add_stand(body, footprint, int(site["site_id"]))
			building_offset = Vector3(-footprint.x * 0.5 + 4.0, 0.0, 0.0)
		"cattle_ranch", "sheep_farm":
			_add_pasture(body, footprint)
			building_offset = Vector3(-footprint.x * 0.5 + 5.5, 0.0, 0.0)
		_:
			_add_plaza(body, footprint)
	var art: Dictionary = ART.get(type_key, DEFAULT_ART)
	var building := _make_building(art, occupied)
	building.position = building_offset
	body.add_child(building)
	_place_on_ground(building, art, building_offset)

	var label := Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.fixed_size = false
	label.pixel_size = 0.06
	label.font_size = 40
	label.outline_size = 10
	label.modulate = Color.WHITE if occupied else Color(0.8, 0.8, 0.8)
	label.position = Vector3(0.0, 9.0, 0.0) + Vector3(building_offset.x, 0.0, 0.0).rotated(Vector3.UP, body.rotation.y)
	root.add_child(label)
	return {"root": root, "label": label}

func _make_building(art: Dictionary, occupied: bool) -> Node3D:
	if art["model"] == "barn":
		var barn := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = BARN_SIZE
		barn.mesh = mesh
		barn.material_override = _flat_material(BARN_COLOR if occupied else BARN_COLOR.lerp(Color(0.5, 0.5, 0.5), 0.6))
		var holder := Node3D.new()
		barn.position = Vector3(0.0, BARN_SIZE.y * 0.5, 0.0)
		holder.add_child(barn)
		return holder
	var path: String = MODEL_DIR + art["model"]
	if not _scene_cache.has(path):
		_scene_cache[path] = load(path)
	var model := (_scene_cache[path] as PackedScene).instantiate() as Node3D
	if not occupied:
		var overlay := _flat_material(VACANT_OVERLAY)
		overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		for node in model.find_children("*", "MeshInstance3D", true, false):
			(node as MeshInstance3D).material_overlay = overlay
	return model

## Scales a freshly built model to the art's width and sits it on the ground.
func _place_on_ground(building: Node3D, art: Dictionary, offset: Vector3) -> void:
	var bounds := AABB()
	var first := true
	var to_local := building.global_transform.affine_inverse()
	for node in building.find_children("*", "MeshInstance3D", true, false):
		var mesh_node := node as MeshInstance3D
		var box: AABB = (to_local * mesh_node.global_transform) * mesh_node.get_aabb()
		bounds = box if first else bounds.merge(box)
		first = false
	if first:
		return
	var factor: float = float(art["width"]) / maxf(maxf(bounds.size.x, bounds.size.z), 0.001)
	if art["model"] == "barn":
		factor = float(art["width"]) / BARN_SIZE.x
	building.scale = Vector3.ONE * factor
	var center := bounds.get_center()
	building.position = offset + Vector3(-center.x, -bounds.position.y, -center.z) * factor

func _add_patch(parent: Node3D, size: Vector2, color: Color, y: float, offset := Vector3.ZERO) -> void:
	var patch := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(size.x, 0.1, size.y)
	patch.mesh = mesh
	patch.material_override = _flat_material(color)
	patch.position = offset + Vector3(0.0, y, 0.0)
	parent.add_child(patch)

func _add_field(body: Node3D, footprint: Vector2) -> void:
	_add_patch(body, footprint, FIELD_COLOR, 0.05)
	var rows := 7
	var usable_x := footprint.x - 10.0
	for i in rows:
		var z := lerpf(-footprint.y * 0.5 + 1.5, footprint.y * 0.5 - 1.5, float(i) / float(rows - 1))
		_add_patch(body, Vector2(usable_x, 0.7), FURROW_COLOR, 0.12, Vector3(5.0, 0.0, z))

func _add_pasture(body: Node3D, footprint: Vector2) -> void:
	_add_patch(body, footprint, PASTURE_EDGE_COLOR, 0.04)
	_add_patch(body, footprint - Vector2.ONE * 2.0, PASTURE_COLOR, 0.09)

func _add_stand(body: Node3D, footprint: Vector2, seed_value: int) -> void:
	_add_patch(body, footprint, STAND_COLOR, 0.05)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value + 7919
	for i in 9:
		var tree := MeshInstance3D.new()
		var cone := CylinderMesh.new()
		cone.top_radius = 0.0
		cone.bottom_radius = 1.2
		cone.height = 4.0
		tree.mesh = cone
		tree.material_override = _flat_material(Color(0.12, 0.3, 0.14))
		tree.position = Vector3(
			rng.randf_range(-footprint.x * 0.5 + 8.0, footprint.x * 0.5 - 2.0),
			2.0,
			rng.randf_range(-footprint.y * 0.5 + 2.0, footprint.y * 0.5 - 2.0))
		body.add_child(tree)

func _add_plaza(body: Node3D, footprint: Vector2) -> void:
	_add_patch(body, footprint * 0.85, PLAZA_COLOR, 0.05)

# ---------------------------------------------------------------------------
# Selection and info
# ---------------------------------------------------------------------------

func _select_site(site_id: int) -> void:
	_selected_site_id = site_id
	_refresh_info()
	business_selected.emit(selected_business_id())

func _site_at(point: Vector2) -> int:
	if _layout == null:
		return -1
	for site in _layout.get_sites():
		if site["built"] and _layout.site_rect(site).has_point(point):
			return site["site_id"]
	return -1

func _refresh_info() -> void:
	if _info_panel == null:
		return
	var site: Dictionary = {}
	if _layout != null and _selected_site_id != -1:
		site = _layout.get_site(_selected_site_id)
	_selection_marker.visible = not site.is_empty()
	_info_panel.visible = not site.is_empty()
	if site.is_empty():
		return
	var rect := _layout.site_rect(site)
	(_selection_marker.mesh as BoxMesh).size = Vector3(rect.size.x + 1.0, 0.15, rect.size.y + 1.0)
	_selection_marker.position = Vector3(rect.get_center().x, 0.2, rect.get_center().y)
	var business_id: int = site["business_id"]
	_details_button.visible = business_id != HETownLayout.NO_BUSINESS
	if business_id == HETownLayout.NO_BUSINESS:
		_info_title.text = "%s (vacant)" % str(site["label"]) if site["label"] != "" else "Vacant site"
		_info_body.text = "Empty building. The next new business moves in here."
		return
	var report: Dictionary = _reports.get(business_id, {})
	_info_title.text = str(site["label"])
	_info_body.text = _state_text(report)

static func _state_text(report: Dictionary) -> String:
	if report.is_empty():
		return ""
	var lines: Array[String] = []
	lines.append("Workers: %d of %d (max %d)" % [report["employed_workers"], report["capacity"], report["max_capacity"]])
	if report.has("herd_size"):
		lines.append("Herd: %.0f head" % report["herd_size"])
	if report.has("treasury"):
		lines.append("Treasury: %.0f gold" % report["treasury"])
	else:
		lines.append("Cash: %.0f gold (%+.1f today)" % [report["balance"], report["last_cash_change"]])
	if report.has("output_commodity") and str(report["output_commodity"]) != "":
		lines.append("Makes: %s" % report["output_commodity"])
	return "\n".join(lines)

func _on_details_pressed() -> void:
	var business_id := selected_business_id()
	if business_id != HETownLayout.NO_BUSINESS:
		details_requested.emit(business_id)

# ---------------------------------------------------------------------------
# Camera and input
# ---------------------------------------------------------------------------

## The ground point (y = 0) under a position in this control, or null when
## the camera has no usable ray there.
func ground_point(screen_position: Vector2) -> Variant:
	if _camera == null or not _camera.is_inside_tree():
		return null
	var origin := _camera.project_ray_origin(screen_position)
	var direction := _camera.project_ray_normal(screen_position)
	if absf(direction.y) < 0.0001:
		return null
	return origin + direction * (-origin.y / direction.y)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var button := event as InputEventMouseButton
		if button.pressed:
			_left_down = true
		elif _left_down:
			_left_down = false
			_click(button.position)
		return
	# Everything else (wheel, middle-drag, Alt tilt) belongs to the camera rig.
	_viewport.push_input(event)

func _click(position: Vector2) -> void:
	var point: Variant = ground_point(position)
	if point == null:
		return
	var site_id := _site_at(Vector2(point.x, point.z))
	if site_id == -1:
		_selected_site_id = -1
		_refresh_info()
		business_selected.emit(-1)
		return
	_select_site(site_id)

## Rotates the view by `degrees` about the town centre (same as Q/E).
func rotate_view(degrees: float) -> void:
	_rig.call("rotate_view", degrees)
