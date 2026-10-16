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
## The person window's "Person details" button: open the dashboard's person
## detail for this member (HESimulation.get_person_summary numbering).
signal person_details_requested(household_id: int, member_number: int)

const HETownLayout = preload("res://scripts/sim/household_economy/he_town_layout.gd")
const HEVillagers = preload("res://scripts/sim/household_economy/he_villagers.gd")
const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const DayNightCycle = preload("res://scripts/world/day_night_cycle.gd")

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
	# Actual house rendering always goes through HOUSE_ART_POOL below; this
	# entry only documents the type and matches the pool's index 0.
	"house": {"model": "building_home_A_blue.gltf", "width": 4.5},
	# Barracks reads as communal housing (bunk rows, multiple doors/windows)
	# rather than a business, closer to a 4-household tenement than the tavern.
	"tenement": {"model": "building_barracks_blue.gltf", "width": 6.5},
}
## Houses cycle through this pool by site id, for variety. Index 0 matches
## ART["house"] so a plain lookup and a pool lookup agree for site 0.
## Blue-only by design: every building in town shares one team color, so
## variety here comes from model shape, not tint.
const HOUSE_ART_POOL: Array[Dictionary] = [
	{"model": "building_home_A_blue.gltf", "width": 4.5},
	{"model": "building_home_B_blue.gltf", "width": 4.5},
	{"model": "tent.gltf", "width": 4.0},
	# This model's mesh bundles a splayed fence/stilt frame and a ground-puddle
	# decal into the same primitives as its door/window trim, so they can't be
	# dropped without losing the trim too. scale_ref sizes the building off its
	# actual walls+roof+chimney footprint instead of the full (fence-inflated)
	# bounds, so the house itself matches the others; the fence yard is wider
	# than the 6x6 house plot and may slightly overlap the plot's margin.
	{"model": "building_house_builder_blue.glb", "width": 4.5, "scale_ref": Vector2(0.98, 1.12)},
]
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
const ROAD_COLOR := Color(0.62, 0.55, 0.42)
const LANE_COLOR := Color(0.66, 0.6, 0.47)
## Front-door footpath to the road, in the road's own colour.
const PATH_WIDTH := 1.4
## How far the path starts inside the building's footprint, so no gap shows.
const PATH_BUILDING_TUCK := 0.3
const VACANT_OVERLAY := Color(0.45, 0.45, 0.45, 0.55)
## A government build still under construction: a bare dirt lot with the RTS
## game's foundation slab (house_foundation.tscn) and corner stakes.
const CONSTRUCTION_GROUND_COLOR := Color(0.5, 0.4, 0.27)
const FOUNDATION_COLOR := Color(0.65, 0.55, 0.38)
const FOUNDATION_HEIGHT := 0.2
const STAKE_COLOR := Color(0.4, 0.28, 0.16)
const STAKE_SIZE := Vector3(0.3, 1.4, 0.3)
const SELECTION_COLOR := Color(1.0, 0.9, 0.2, 0.45)

## Winter snow: one shared shader material (shaders/town_snow.gdshader) whose
## `cover` is driven by the season. Building meshes carry it as an overlay
## (up-facing faces only, so roofs get a cap); a flat plane SNOW_LAYER_HEIGHT
## above the ground carries it across roads, plazas and fields. The plane sits
## above the road/plaza/path tops (0.08-0.10) and below building floors.
const SNOW_SHADER := preload("res://shaders/town_snow.gdshader")
const SNOW_LAYER_HEIGHT := 0.12
## Days over which snow settles before winter starts and melts after it ends.
const SNOW_RAMP_DAYS := 12

static var _scene_cache: Dictionary = {}

var _layout: HETownLayout
var _reports: Dictionary = {} # business_id -> report
var _site_nodes: Dictionary = {} # site_id -> {"root": Node3D, "signature": String, "label": Label3D}
var _selected_site_id: int = -1
var _left_down := false
var _rig: Node3D
var _sun: DirectionalLight3D
var _environment: Environment
var _clock_label: Label
var _time_of_day := 0.25
var _snow_material: ShaderMaterial
var _snow_ground_material: ShaderMaterial
var _snow_tree_material: ShaderMaterial
var _snow_layer: MeshInstance3D
var _snow_cover := 0.0

var _viewport: SubViewport
var _camera: Camera3D
var _sites_root: Node3D
var _roads_root: Node3D
var _roads_for: HETownLayout
var _roads_drawn := 0
var _selection_marker: MeshInstance3D
var _info_panel: PanelContainer
var _info_title: Label
var _info_body: Label
var _details_button: Button
var _home_button: Button
var _person_button: Button
var _household_button: Button
var _villager_layer: HEVillagers
## Selected villager as (household_id, member_number), or (-1, -1). A site and
## a villager are never selected at once.
var _selected_villager := Vector2i(-1, -1)
var _villager_marker: MeshInstance3D
var _shown_activity: Dictionary = {}
var _unplaced_label: Label
var _housing_label: Label
## Supplies a household summary (HESimulation.get_household_summary shape; {}
## when the household is gone). Set by the host so this view never reads the
## simulation itself.
var household_summary_provider := Callable()
## Household shown in the bottom-left household window, or -1.
var _selected_household := -1
var _household_panel: PanelContainer
var _household_title: Label
var _household_content: VBoxContainer
var _household_signature := ""
var _occupant_box: VBoxContainer
var _occupants_shown: Array = []
var _housing: Dictionary = {}
var _dwellings: Dictionary = {} # dwelling_id -> get_dwelling_reports() entry

func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_world()
	_build_overlay()
	_refresh_info()

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Brings the drawn town in line with `layout`, the current business reports,
## the settlement's housing report (get_housing_report; may be empty) and its
## houses (get_dwelling_reports, for who lives where; may be empty) and its
## people (get_villager_reports; may be empty). Cheap when nothing changed.
func sync(layout: HETownLayout, reports: Array, housing: Dictionary = {}, dwellings: Array = [], villagers: Array = []) -> void:
	_layout = layout
	_housing = housing
	_dwellings.clear()
	for dwelling in dwellings:
		_dwellings[int(dwelling["dwelling_id"])] = dwelling
	_reports.clear()
	for report in reports:
		_reports[int(report["business_id"])] = report
	if _sites_root == null:
		return
	_sync_roads(layout)
	for site in layout.get_sites():
		if not site["built"]:
			continue
		_sync_site(site)
	_villager_layer.sync(layout, villagers)
	if _selected_villager.x != -1 and not _villager_layer.villager_position(_selected_villager).is_finite():
		_selected_villager = Vector2i(-1, -1)
	var unplaced := layout.unplaced_business_ids().size() + layout.unplaced_dwelling_ids().size()
	_unplaced_label.visible = unplaced > 0
	_unplaced_label.text = "%d building(s) have no room in the town" % unplaced
	_housing_label.visible = bool(housing.get("modeled", false))
	_housing_label.text = housing_text(housing)
	var strained := int(housing.get("homeless_households", 0)) > 0 or bool(housing.get("saturated", false))
	_housing_label.add_theme_color_override("font_color", Color(0.95, 0.6, 0.3) if strained else Color(1, 1, 1, 0.95))
	_refresh_info()

## "Housing: 41 homes for 30 households" with homeless / full flags.
static func housing_text(housing: Dictionary) -> String:
	if not bool(housing.get("modeled", false)):
		return ""
	var text := "Housing: %d homes for %d households" % [housing["capacity"], housing["households"]]
	if int(housing["homeless_households"]) > 0:
		text += " (%d homeless)" % housing["homeless_households"]
	elif bool(housing["saturated"]):
		text += " (full: births slowed)"
	return text

## "Home of households 3, 7 (2 of 4)" / "Empty (room for 1 household)" from a
## get_dwelling_reports() entry; "" when the entry is missing.
static func occupants_text(dwelling: Dictionary) -> String:
	if dwelling.is_empty():
		return ""
	var occupants: Array = dwelling.get("occupant_household_ids", [])
	var capacity := int(dwelling.get("capacity", 1))
	if occupants.is_empty():
		return "Empty (room for %d household%s)" % [capacity, "" if capacity == 1 else "s"]
	var ids := ", ".join(occupants.map(str))
	var noun := "household" if occupants.size() == 1 else "households"
	if capacity == 1:
		return "Home of %s %s" % [noun, ids]
	return "Home of %s %s (%d of %d)" % [noun, ids, occupants.size(), capacity]

## Sets the town's time of day (0 = midnight, 0.5 = noon): lighting through
## the shared RTS day/night keyframes, plus the HH:MM readout.
func set_time_of_day(t: float) -> void:
	_time_of_day = fposmod(t, 1.0)
	if _villager_layer != null:
		_villager_layer.set_time(_time_of_day)
	if _clock_label == null or _sun == null:
		return
	DayNightCycle.apply_time(_time_of_day, _sun, _environment, 0.15)
	var minutes := int(_time_of_day * 24.0 * 60.0)
	_clock_label.text = "%02d:%02d" % [minutes / 60, minutes % 60]

## The simulation's day, which seeds each villager's daily timetable.
func set_sim_day(day: int) -> void:
	if _villager_layer != null:
		_villager_layer.set_day(day)

func time_of_day() -> float:
	return _time_of_day

## 0..1 snow cover for a simulation day: full through winter, settling over
## the last SNOW_RAMP_DAYS of autumn and melting over the first of spring.
static func snow_cover_for_day(day: int) -> float:
	var winter_start := 3 * HESimulation.DAYS_PER_SEASON
	var day_of_year := posmod(day, HESimulation.DAYS_PER_YEAR)
	if day_of_year >= winter_start:
		return 1.0
	if day_of_year >= winter_start - SNOW_RAMP_DAYS:
		return float(day_of_year - (winter_start - SNOW_RAMP_DAYS) + 1) / float(SNOW_RAMP_DAYS + 1)
	if day_of_year < SNOW_RAMP_DAYS:
		return 1.0 - float(day_of_year + 1) / float(SNOW_RAMP_DAYS + 1)
	return 0.0

## Sets how much of the town is under snow (0 bare .. 1 full).
func set_snow_cover(amount: float) -> void:
	_snow_cover = clampf(amount, 0.0, 1.0)
	if _snow_material == null:
		return
	_snow_material.set_shader_parameter("cover", _snow_cover)
	_snow_ground_material.set_shader_parameter("cover", _snow_cover)
	_snow_tree_material.set_shader_parameter("cover", _snow_cover)
	_snow_layer.visible = _snow_cover > 0.001

func snow_cover() -> float:
	return _snow_cover

## Selects the site holding `business_id` (no-op if it has none).
func select_business(business_id: int) -> void:
	if _layout == null:
		return
	var site := _layout.site_of_business(business_id)
	if not site.is_empty():
		_select_site(site["site_id"])

func clear_selection() -> void:
	_selected_household = -1
	_selected_site_id = -1
	_selected_villager = Vector2i(-1, -1)
	_refresh_info()

## Selects one villager and shows the person window (no-op if not drawn).
func select_villager(household_id: int, member_number: int) -> void:
	var key := Vector2i(household_id, member_number)
	if not _villager_layer.villager_position(key).is_finite():
		return
	_selected_household = -1
	_selected_site_id = -1
	_selected_villager = key
	_refresh_info()

## (household_id, member_number) of the selected villager, or (-1, -1).
func selected_villager() -> Vector2i:
	return _selected_villager

func villager_count() -> int:
	return _villager_layer.villager_count() if _villager_layer != null else 0

func villagers() -> HEVillagers:
	return _villager_layer

## Freezes or resumes the villagers (the dashboard's pause), animations too.
func set_villagers_paused(value: bool) -> void:
	if _villager_layer != null and _villager_layer.paused != value:
		_villager_layer.paused = value
		_update_villager_processing()

## The villager layer (and the AnimationPlayers under it) only runs while this
## view is shown and the town is not paused: its Node3D visibility does not
## follow this Control's, so it would otherwise animate behind the dashboard.
func _update_villager_processing() -> void:
	var active := is_visible_in_tree() and not _villager_layer.paused
	_villager_layer.process_mode = Node.PROCESS_MODE_INHERIT if active else Node.PROCESS_MODE_DISABLED

## Pans the camera so `point` (town coordinates) is centred.
func focus_on(point: Vector2) -> void:
	_rig.call("center_on", Vector3(point.x, 0.0, point.y))

func selected_business_id() -> int:
	if _layout == null or _selected_site_id == -1:
		return -1
	var site := _layout.get_site(_selected_site_id)
	if site.get("under_construction", false):
		return -1
	return int(site.get("business_id", -1))

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
	_environment = environment
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
	_sun = sun
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

	_snow_material = ShaderMaterial.new()
	_snow_material.shader = SNOW_SHADER
	# Conifer cones are steep (side normals point only ~17 degrees above the
	# horizon), so trees let snow settle on much steeper faces than roofs do.
	_snow_tree_material = ShaderMaterial.new()
	_snow_tree_material.shader = SNOW_SHADER
	_snow_tree_material.set_shader_parameter("settle_min", 0.05)
	_snow_tree_material.set_shader_parameter("settle_range", 0.2)
	_snow_tree_material.set_shader_parameter("opacity", 0.9)
	# The ground layer is cooler and part see-through, so roads and fields
	# read beneath it and the brighter roofs stand out against it.
	_snow_ground_material = ShaderMaterial.new()
	_snow_ground_material.shader = SNOW_SHADER
	_snow_ground_material.set_shader_parameter("snow_color", Vector3(0.78, 0.84, 0.92))
	_snow_ground_material.set_shader_parameter("opacity", 0.78)
	_snow_layer = MeshInstance3D.new()
	_snow_layer.mesh = plane
	_snow_layer.material_override = _snow_ground_material
	_snow_layer.position.y = SNOW_LAYER_HEIGHT
	_snow_layer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_snow_layer.name = "Snow"
	_viewport.add_child(_snow_layer)
	set_snow_cover(_snow_cover)

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

	_villager_layer = HEVillagers.new()
	_villager_layer.name = "Villagers"
	_viewport.add_child(_villager_layer)
	visibility_changed.connect(_update_villager_processing)
	_update_villager_processing()
	_villager_marker = MeshInstance3D.new()
	var ring := TorusMesh.new()
	ring.inner_radius = 0.55
	ring.outer_radius = 0.8
	_villager_marker.mesh = ring
	_villager_marker.material_override = marker_material
	_villager_marker.visible = false
	_villager_marker.name = "VillagerSelection"
	_viewport.add_child(_villager_marker)

func _build_overlay() -> void:
	var hint := Label.new()
	hint.text = "Wheel: zoom   Middle-drag / WASD: pan   Q/E: rotate   Alt+mouse: tilt   Click: select"
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	hint.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	hint.add_theme_constant_override("outline_size", 4)
	hint.position = Vector2(10, 6)
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hint)

	_clock_label = Label.new()
	_clock_label.add_theme_font_size_override("font_size", 20)
	_clock_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	_clock_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_clock_label.add_theme_constant_override("outline_size", 5)
	_clock_label.anchor_left = 1.0
	_clock_label.anchor_right = 1.0
	_clock_label.offset_left = -110.0
	_clock_label.offset_right = -12.0
	_clock_label.offset_top = 6.0
	_clock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_clock_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_clock_label)
	set_time_of_day(_time_of_day)

	_housing_label = Label.new()
	_housing_label.add_theme_font_size_override("font_size", 15)
	_housing_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_housing_label.add_theme_constant_override("outline_size", 4)
	_housing_label.anchor_left = 1.0
	_housing_label.anchor_right = 1.0
	_housing_label.offset_left = -420.0
	_housing_label.offset_right = -12.0
	_housing_label.offset_top = 34.0
	_housing_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_housing_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_housing_label.visible = false
	add_child(_housing_label)

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
	_occupant_box = VBoxContainer.new()
	box.add_child(_occupant_box)
	_details_button = Button.new()
	_details_button.text = "Open business details"
	_details_button.pressed.connect(_on_details_pressed)
	box.add_child(_details_button)
	_home_button = Button.new()
	_home_button.text = "Show home"
	_home_button.pressed.connect(_on_home_pressed)
	box.add_child(_home_button)
	_person_button = Button.new()
	_person_button.text = "Person details"
	_person_button.pressed.connect(_on_person_pressed)
	box.add_child(_person_button)
	_household_button = Button.new()
	_household_button.text = "View household"
	_household_button.pressed.connect(_on_view_household_pressed)
	box.add_child(_household_button)
	add_child(_info_panel)

	# The household window shares the info panel's bottom-left slot; the info
	# panel hides while it is open.
	_household_panel = PanelContainer.new()
	_household_panel.anchor_top = 1.0
	_household_panel.anchor_bottom = 1.0
	_household_panel.offset_left = 10.0
	_household_panel.offset_bottom = -10.0
	_household_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_household_panel.custom_minimum_size = Vector2(320, 0)
	_household_panel.visible = false
	var household_box := VBoxContainer.new()
	_household_panel.add_child(household_box)
	var title_row := HBoxContainer.new()
	household_box.add_child(title_row)
	_household_title = Label.new()
	_household_title.add_theme_font_size_override("font_size", 16)
	_household_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(_household_title)
	var close_button := Button.new()
	close_button.text = "X"
	close_button.flat = true
	close_button.tooltip_text = "Close household window"
	close_button.pressed.connect(close_household)
	title_row.add_child(close_button)
	_household_content = VBoxContainer.new()
	household_box.add_child(_household_content)
	add_child(_household_panel)

static func _flat_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 1.0
	return material

# ---------------------------------------------------------------------------
# Sites
# ---------------------------------------------------------------------------

## Roads are only ever added, so the view keeps what it drew and adds the new
## ones (a different layout instance redraws all): a flat ribbon per segment
## plus a disc at every joint to hide the wedge gaps.
func _sync_roads(layout: HETownLayout) -> void:
	if _roads_for == layout and _roads_root != null and layout.road_count() == _roads_drawn:
		return
	var roads := layout.get_roads()
	if _roads_for != layout or _roads_root == null or roads.size() < _roads_drawn:
		_roads_for = layout
		_roads_drawn = 0
		if _roads_root != null:
			_roads_root.queue_free()
		_roads_root = Node3D.new()
		_roads_root.name = "Roads"
		_viewport.add_child(_roads_root)
	for index in range(_roads_drawn, roads.size()):
		_draw_road(roads[index])
	_roads_drawn = roads.size()

func _draw_road(road: Dictionary) -> void:
	var width: float = road["width"]
	var color := ROAD_COLOR if road["class"] == "main" else LANE_COLOR
	var points: PackedVector2Array = road["points"]
	for i in range(points.size() - 1):
		var delta := points[i + 1] - points[i]
		var ribbon := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(delta.length(), 0.1, width)
		ribbon.mesh = mesh
		ribbon.material_override = _flat_material(color)
		var middle := (points[i] + points[i + 1]) * 0.5
		ribbon.position = Vector3(middle.x, 0.03, middle.y)
		ribbon.rotation.y = -delta.angle()
		_roads_root.add_child(ribbon)
	for point in points:
		var disc := MeshInstance3D.new()
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = width * 0.5
		cylinder.bottom_radius = width * 0.5
		cylinder.height = 0.1
		disc.mesh = cylinder
		disc.material_override = _flat_material(color)
		disc.position = Vector3(point.x, 0.03, point.y)
		_roads_root.add_child(disc)

func _sync_site(site: Dictionary) -> void:
	var site_id: int = site["site_id"]
	var occupied: bool = site["business_id"] != HETownLayout.NO_BUSINESS or site["dwelling_id"] != HETownLayout.NO_BUSINESS
	var signature := "%s|%s|%s" % [site["type_key"], occupied, site["under_construction"]]
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
	elif site["under_construction"]:
		label_text += " (under construction)"
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
	var under_construction: bool = site["under_construction"]
	var dressing := "construction" if under_construction else type_key
	match dressing:
		"construction":
			_add_patch(body, footprint, CONSTRUCTION_GROUND_COLOR, 0.05)
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
	if type_key == HETownLayout.HOUSE_TYPE_KEY:
		art = HOUSE_ART_POOL[int(site["site_id"]) % HOUSE_ART_POOL.size()]
	_add_door_path(root, site, art)
	if under_construction:
		_add_foundation(body, float(art["width"]), building_offset)
	else:
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
	# A dense residential zone would drown the map in text; houses are
	# identified by selecting them.
	label.visible = not HETownLayout.is_housing_type(type_key)
	label.position = Vector3(0.0, 9.0, 0.0) + Vector3(building_offset.x, 0.0, 0.0).rotated(Vector3.UP, body.rotation.y)
	root.add_child(label)
	return {"root": root, "label": label}

## A footpath from the building's front face to the site's access point on the
## road centreline. It starts under the building and ends under the road
## ribbon, and is sunk just below both surfaces (road top 0.08, plaza top
## 0.10), so only the stretch of bare ground between them shows and the road
## is never recoloured. Drawn in the site's root space.
func _add_door_path(root: Node3D, site: Dictionary, art: Dictionary) -> void:
	var access: Vector2 = site["access"]
	if not access.is_finite():
		return
	var origin: Vector2 = site["position"]
	var direction := (access - origin).normalized()
	var door := maxf(float(art["width"]) * 0.5 - PATH_BUILDING_TUCK, 0.0)
	var length := origin.distance_to(access) - door
	if length < 0.3:
		return
	var path := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(length, 0.1, PATH_WIDTH)
	path.mesh = mesh
	path.material_override = _flat_material(ROAD_COLOR)
	var middle := direction * (door + length * 0.5)
	path.position = Vector3(middle.x, 0.02, middle.y)
	path.rotation.y = -direction.angle()
	root.add_child(path)

func _make_building(art: Dictionary, occupied: bool) -> Node3D:
	if art["model"] == "barn":
		var barn := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = BARN_SIZE
		barn.mesh = mesh
		barn.material_override = _flat_material(BARN_COLOR if occupied else BARN_COLOR.lerp(Color(0.5, 0.5, 0.5), 0.6))
		barn.material_overlay = _snow_material
		var holder := Node3D.new()
		barn.position = Vector3(0.0, BARN_SIZE.y * 0.5, 0.0)
		holder.add_child(barn)
		return holder
	var path: String = MODEL_DIR + art["model"]
	if not _scene_cache.has(path):
		_scene_cache[path] = load(path)
	var model := (_scene_cache[path] as PackedScene).instantiate() as Node3D
	var overlay: Material = _snow_material
	if not occupied:
		var vacant := _flat_material(VACANT_OVERLAY)
		vacant.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		vacant.next_pass = _snow_material
		overlay = vacant
	for node in model.find_children("*", "MeshInstance3D", true, false):
		(node as MeshInstance3D).material_overlay = overlay
	return model

## Scales a freshly built model to the art's width and sits it on the ground.
## art["scale_ref"] (optional Vector2 x/z), when present, replaces the live
## mesh bounds for the scale-factor math, so a model whose true bounds are
## inflated by non-building decoration (see building_house_builder_blue's
## entry in HOUSE_ART_POOL) can still be sized off its actual footprint.
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
	var ref_size := Vector2(bounds.size.x, bounds.size.z)
	if art.has("scale_ref"):
		ref_size = art["scale_ref"]
	var factor: float = float(art["width"]) / maxf(maxf(ref_size.x, ref_size.y), 0.001)
	if art["model"] == "barn":
		factor = float(art["width"]) / BARN_SIZE.x
	building.scale = Vector3.ONE * factor
	var center := bounds.get_center()
	building.position = offset + Vector3(-center.x, -bounds.position.y, -center.z) * factor

## The slab a building will stand on, `width` square, with a stake at each corner.
func _add_foundation(body: Node3D, width: float, offset: Vector3) -> void:
	var slab := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(width, FOUNDATION_HEIGHT, width)
	slab.mesh = mesh
	slab.material_override = _flat_material(FOUNDATION_COLOR)
	slab.position = offset + Vector3(0.0, 0.1 + FOUNDATION_HEIGHT * 0.5, 0.0)
	body.add_child(slab)
	var corner := width * 0.5 - STAKE_SIZE.x * 0.5
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var stake := MeshInstance3D.new()
			var stake_mesh := BoxMesh.new()
			stake_mesh.size = STAKE_SIZE
			stake.mesh = stake_mesh
			stake.material_override = _flat_material(STAKE_COLOR)
			stake.position = offset + Vector3(sx * corner, 0.1 + STAKE_SIZE.y * 0.5, sz * corner)
			body.add_child(stake)

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
		tree.material_overlay = _snow_tree_material
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
	_selected_household = -1
	_selected_site_id = site_id
	_selected_villager = Vector2i(-1, -1)
	_refresh_info()
	business_selected.emit(selected_business_id())

func _site_at(point: Vector2) -> int:
	if _layout == null:
		return -1
	for site in _layout.get_sites():
		if site["built"] and _layout.site_contains(site, point):
			return site["site_id"]
	return -1

func _refresh_info() -> void:
	if _info_panel == null:
		return
	_refresh_info_panel()
	_set_occupants(_house_occupants() if _selected_villager.x == -1 else [])
	_refresh_household_panel()

func _refresh_info_panel() -> void:
	_home_button.visible = false
	_person_button.visible = false
	_household_button.visible = false
	_villager_marker.visible = _selected_villager.x != -1 and _villager_layer.villager_visible(_selected_villager)
	if _selected_villager.x != -1:
		_selection_marker.visible = false
		_info_panel.visible = true
		_refresh_villager_info()
		return
	var site: Dictionary = {}
	if _layout != null and _selected_site_id != -1:
		site = _layout.get_site(_selected_site_id)
	_selection_marker.visible = not site.is_empty()
	_info_panel.visible = not site.is_empty()
	if site.is_empty():
		return
	var footprint: Vector2 = site["footprint"]
	var center: Vector2 = site["position"]
	(_selection_marker.mesh as BoxMesh).size = Vector3(footprint.x + 1.0, 0.15, footprint.y + 1.0)
	_selection_marker.position = Vector3(center.x, 0.2, center.y)
	_selection_marker.rotation.y = -float(site["rotation"])
	if site["under_construction"]:
		_details_button.visible = false
		_info_title.text = "%s (under construction)" % str(site["label"])
		_info_body.text = "Foundation laid. The building opens once construction finishes."
		return
	if site["dwelling_id"] != HETownLayout.NO_BUSINESS:
		_details_button.visible = false
		_info_title.text = str(site["label"])
		var dwelling: Dictionary = _dwellings.get(int(site["dwelling_id"]), {})
		var shelter := occupants_text(dwelling)
		if not dwelling.get("occupant_household_ids", []).is_empty():
			# The households themselves are buttons under this line.
			var capacity := int(dwelling.get("capacity", 1))
			var count: int = dwelling["occupant_household_ids"].size()
			shelter = "Home of household:" if capacity == 1 else "Home of households (%d of %d):" % [count, capacity]
		if shelter == "":
			shelter = "Shelters one household."
			if site["type_key"] == HETownLayout.DENSE_HOUSE_TYPE_KEY:
				shelter = "Shelters several households."
		var housing_line := housing_text(_housing)
		_info_body.text = shelter if housing_line == "" else "%s\n%s" % [shelter, housing_line]
		return
	var business_id: int = site["business_id"]
	_details_button.visible = business_id != HETownLayout.NO_BUSINESS
	if business_id == HETownLayout.NO_BUSINESS:
		_info_title.text = "%s (vacant)" % str(site["label"]) if site["label"] != "" else "Vacant site"
		_info_body.text = "Empty building. The next new business moves in here."
		return
	var report: Dictionary = _reports.get(business_id, {})
	_info_title.text = str(site["label"])
	_info_body.text = _state_text(report)

## The person window: who the selected villager is, their household, job and
## home, from the villager report (no simulation access here).
func _refresh_villager_info() -> void:
	var household_id := _selected_villager.x
	var member_number := _selected_villager.y
	var report := _villager_layer.household_report(household_id)
	_details_button.visible = false
	_person_button.visible = true
	_household_button.visible = true
	_info_title.text = "Household %d - Member %d" % [household_id, member_number]
	if report.is_empty():
		_info_body.text = ""
		return
	var employer_name := _business_name(int(report["employer_business_id"]))
	var activity := _villager_layer.villager_activity(_selected_villager)
	_shown_activity = activity
	_info_body.text = person_text(report, member_number, employer_name, activity_text(activity, employer_name))
	var dwelling_id := int(report["dwelling_id"])
	_home_button.visible = true
	_home_button.disabled = _layout == null or dwelling_id == -1 or _layout.site_of_dwelling(dwelling_id).is_empty()
	_home_button.text = "Show home" if not _home_button.disabled else "No home"

## Lines of the person window for member `member_number` of a villager report
## (get_villager_reports entry); `employer_name` is "" when unknown.
static func person_text(report: Dictionary, member_number: int, employer_name: String, activity: String = "") -> String:
	var workers: PackedInt32Array = report["worker_ages"]
	var dependents: PackedInt32Array = report["dependent_ages"]
	var index := member_number - 1
	if index < 0 or index >= workers.size() + dependents.size():
		return ""
	var is_worker := index < workers.size()
	var age: int = workers[index] if is_worker else dependents[index - workers.size()]
	var lines: Array[String] = []
	var role := "Worker"
	if not is_worker:
		role = "Child" if age < HEHousehold.AGING_THRESHOLD_DAYS else "Adult living at home"
	lines.append("%s, age %d years %d days" % [role, age / 365, age % 365])
	if is_worker:
		var employer_id := int(report["employer_business_id"])
		if employer_id == -1:
			lines.append("Unemployed")
		else:
			lines.append("Works at %s" % (employer_name if employer_name != "" else "business %d" % employer_id))
	if activity != "":
		lines.append("Now: %s" % activity)
	lines.append("Household: %d worker%s, %d dependent%s" % [workers.size(), "" if workers.size() == 1 else "s", dependents.size(), "" if dependents.size() == 1 else "s"])
	match str(report["housing_status"]):
		"housed":
			lines.append("Lives in house %d" % int(report["dwelling_id"]))
		"homeless":
			lines.append("Homeless: sleeps by the town square")
	return "\n".join(lines)

## What a villager is doing, from HEVillagers.villager_activity() ({"visible",
## "activity", "site_id"}); "" when unknown.
static func activity_text(activity: Dictionary, employer_name: String) -> String:
	if activity.is_empty():
		return ""
	var workplace := employer_name if employer_name != "" else "work"
	match str(activity["activity"]):
		"indoors":
			return "Indoors at home"
		"yard":
			return "Outside the house"
		"walk_work":
			return "Walking to %s" % workplace
		"walk_plaza":
			return "Walking to the town square"
		"walk_home":
			return "Walking home"
		"work":
			return "Working at %s" % workplace
		"work_inside":
			return "Working inside %s" % workplace
		"work_door":
			return "Taking a break outside %s" % workplace
		"plaza":
			return "At the town square"
	return ""

func _business_name(business_id: int) -> String:
	var report: Dictionary = _reports.get(business_id, {})
	return str(report.get("name", ""))

func _on_home_pressed() -> void:
	var report := _villager_layer.household_report(_selected_villager.x)
	if report.is_empty() or _layout == null:
		return
	var site := _layout.site_of_dwelling(int(report["dwelling_id"]))
	if site.is_empty():
		return
	focus_on(site["position"])
	_select_site(site["site_id"])

func _on_view_household_pressed() -> void:
	if _selected_villager.x != -1:
		open_household(_selected_villager.x)

## Household window member link: the person window for that villager.
func _on_member_link_pressed(household_id: int, member_number: int) -> void:
	select_villager(household_id, member_number)
	business_selected.emit(-1)

func _on_person_pressed() -> void:
	if _selected_villager.x != -1:
		person_details_requested.emit(_selected_villager.x, _selected_villager.y)

# ---------------------------------------------------------------------------
# Household window
# ---------------------------------------------------------------------------

## Household ids living in the selected house (empty unless a built house is
## selected).
func _house_occupants() -> Array:
	if _layout == null or _selected_site_id == -1:
		return []
	var site := _layout.get_site(_selected_site_id)
	if site.is_empty() or site["under_construction"] or site["dwelling_id"] == HETownLayout.NO_BUSINESS:
		return []
	return _dwellings.get(int(site["dwelling_id"]), {}).get("occupant_household_ids", [])

## One "Household N" button per occupant under the house text; rebuilt only
## when the occupant list changes so a click is not split across refreshes.
func _set_occupants(ids: Array) -> void:
	if ids == _occupants_shown:
		return
	_occupants_shown = ids.duplicate()
	for child in _occupant_box.get_children():
		_occupant_box.remove_child(child)
		child.queue_free()
	for household_id in ids:
		var button := Button.new()
		button.text = "Household %d" % int(household_id)
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.tooltip_text = "Open household window"
		button.pressed.connect(open_household.bind(int(household_id)))
		_occupant_box.add_child(button)

## Shows the household window (bottom left) for `household_id`.
func open_household(household_id: int) -> void:
	_selected_household = household_id
	_household_signature = ""
	_refresh_info()

func close_household() -> void:
	_selected_household = -1
	_refresh_info()

func selected_household() -> int:
	return _selected_household

func _refresh_household_panel() -> void:
	if _household_panel == null:
		return
	var summary: Dictionary = {}
	if _selected_household != -1 and household_summary_provider.is_valid():
		summary = household_summary_provider.call(_selected_household)
	if summary.is_empty():
		_selected_household = -1
		_household_panel.visible = false
		_household_signature = ""
		return
	_household_panel.visible = true
	_info_panel.visible = false
	_household_title.text = "Household %d" % _selected_household
	var signature := "%d|%d|%s|%s|%s|%.2f|%.2f" % [_selected_household, int(summary["employer_business_id"]),
		str(summary["dwelling_id"]), str(summary["worker_ages"]), str(summary["dependent_ages"]),
		float(summary["health"]), float(summary["morale"])]
	if signature == _household_signature:
		return
	_household_signature = signature
	for child in _household_content.get_children():
		_household_content.remove_child(child)
		child.queue_free()

	var employer_id := int(summary["employer_business_id"])
	var employer_name := _business_name(employer_id)
	var employer_line := Label.new()
	employer_line.text = "Employer: %s" % (employer_name if employer_name != "" else "Unemployed")
	_household_content.add_child(employer_line)
	var housing_line := Label.new()
	match str(summary["housing_status"]):
		"housed":
			housing_line.text = "Lives in house %d" % int(summary["dwelling_id"])
		"homeless":
			housing_line.text = "Homeless"
	if housing_line.text != "":
		_household_content.add_child(housing_line)
	if str(summary["housing_status"]) == "housed" and _layout != null and not _layout.site_of_dwelling(int(summary["dwelling_id"])).is_empty():
		var home_button := Button.new()
		home_button.text = "Show home"
		home_button.pressed.connect(_show_household_home.bind(int(summary["dwelling_id"])))
		_household_content.add_child(home_button)

	_add_household_heading("Members (%d)" % int(summary["headcount"]))
	var member_number := 1
	for age in summary["worker_ages"]:
		_add_household_member(member_number, "Worker", int(age))
		member_number += 1
	for age in summary["dependent_ages"]:
		_add_household_member(member_number, "Dependent", int(age))
		member_number += 1

	_add_household_heading("Health and morale")
	_add_meter_row("Health", float(summary["health"]))
	_add_meter_row("Morale", float(summary["morale"]))

func _add_household_heading(text: String) -> void:
	var heading := Label.new()
	heading.text = text
	heading.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	_household_content.add_child(heading)

## "Member 2: worker, age 31y 40d" link to the dashboard person page plus a
## Locate button that centres the camera on them.
func _add_household_member(member_number: int, role: String, age: int) -> void:
	var row := HBoxContainer.new()
	var link := Button.new()
	link.text = "Member %d: %s, age %dy %dd" % [member_number, role.to_lower(), age / 365, age % 365]
	link.flat = true
	link.alignment = HORIZONTAL_ALIGNMENT_LEFT
	link.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	link.tooltip_text = "Open the person window"
	link.disabled = _villager_layer == null or not _villager_layer.villager_position(Vector2i(_selected_household, member_number)).is_finite()
	link.pressed.connect(_on_member_link_pressed.bind(_selected_household, member_number))
	row.add_child(link)
	var locate := Button.new()
	locate.text = "Locate"
	locate.tooltip_text = "Centre the camera on this person"
	locate.disabled = _villager_layer == null or not _villager_layer.villager_position(Vector2i(_selected_household, member_number)).is_finite()
	locate.pressed.connect(_locate_villager.bind(_selected_household, member_number))
	row.add_child(locate)
	_household_content.add_child(row)

## Rings the villager and centres the camera, keeping the household window open.
func _locate_villager(household_id: int, member_number: int) -> void:
	var key := Vector2i(household_id, member_number)
	var position := _villager_layer.villager_position(key)
	if not position.is_finite():
		return
	_selected_site_id = -1
	_selected_villager = key
	focus_on(Vector2(position.x, position.z))
	_refresh_info()

func _show_household_home(dwelling_id: int) -> void:
	if _layout == null:
		return
	var site := _layout.site_of_dwelling(dwelling_id)
	if site.is_empty():
		return
	focus_on(site["position"])
	var household_id := _selected_household
	_select_site(site["site_id"])
	open_household(household_id)

## "Health  [bar]  72%", colored red/amber/green like the dashboard's meters.
func _add_meter_row(caption: String, value: float) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var name_label := Label.new()
	name_label.text = caption
	name_label.custom_minimum_size = Vector2(60, 0)
	row.add_child(name_label)
	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.value = value
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(150, 16)
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.85, 0.35, 0.3) if value < 0.5 else (Color(0.9, 0.7, 0.3) if value <= 0.8 else Color(0.4, 0.75, 0.45))
	bar.add_theme_stylebox_override("fill", fill)
	row.add_child(bar)
	var value_label := Label.new()
	value_label.text = "%.0f%%" % (value * 100.0)
	row.add_child(value_label)
	_household_content.add_child(row)

func _process(_delta: float) -> void:
	if _selected_villager.x == -1 or _villager_marker == null:
		return
	var drawn := _villager_layer.villager_visible(_selected_villager)
	_villager_marker.visible = drawn
	var position := _villager_layer.villager_position(_selected_villager)
	if drawn and position.is_finite():
		_villager_marker.position = position + Vector3.UP * 0.08
	# The window follows what the villager is doing.
	var activity := _villager_layer.villager_activity(_selected_villager)
	if activity != _shown_activity:
		_refresh_info()

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
	# People stand on top of sites, so they take the click first.
	var villager := _villager_layer.pick(_camera, position) if _camera != null and _camera.is_inside_tree() else Vector2i(-1, -1)
	if villager.x != -1:
		select_villager(villager.x, villager.y)
		business_selected.emit(-1)
		return
	var point: Variant = ground_point(position)
	if point == null:
		return
	var site_id := _site_at(Vector2(point.x, point.z))
	if site_id == -1:
		_selected_household = -1
		_selected_site_id = -1
		_refresh_info()
		business_selected.emit(-1)
		return
	_select_site(site_id)

## Rotates the view by `degrees` about the town centre (same as Q/E).
func rotate_view(degrees: float) -> void:
	_rig.call("rotate_view", degrees)
