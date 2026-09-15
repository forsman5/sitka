extends Node3D

## A static presentation of the five-settlement authored valley. This scene
## consumes snapshots from Simulation but never advances or mutates it.

const Simulation = preload("res://scripts/sim/simulation.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")
const ValleySeed = preload("res://scripts/sim/data/valley_seed.gd")
const Layout = preload("res://scripts/valley/river_valley_layout.gd")
const AuthoredValleyTerrain = preload("res://scripts/valley/authored_valley_terrain.gd")
const TerrainRibbonBuilder = preload("res://scripts/valley/terrain_ribbon_builder.gd")

const GROUND_COLOR := Color("6e8d52")
const ROAD_COLOR := Color("8c7657")
const RIVER_COLOR := Color("356f9b")
const TRACK_WIDTH := 2.1
const RIVER_BANK_COLOR := Color("5f6244")
const ROAD_SHOULDER_COLOR := Color("76684e")

var _simulation: Simulation
var _camera: Camera3D
var _selection_panel: PanelContainer
var _selection_title: Label
var _selection_role: Label
var _selection_stats: Label
var _selection_inventory: Label
var _selection_workplaces: Label
var _hint_label: Label
var _selected_settlement_id := -1
var _settlement_markers: Dictionary = {}
var _terrain: AuthoredValleyTerrain

## settlement_id -> ground-plane (x,z) of its (possibly CLUSTER_OFFSETS-shifted)
## building cluster, populated by _build_settlements(). ValleyVegetation reads
## this so scattered scenery avoids the actual house positions, not just the
## district's authored anchor point (which for Aldford/Oakmere/Staithe is the
## riverbank, not where their houses ended up).
var settlement_cluster_positions: Dictionary = {}

func _ready() -> void:
	_simulation = Simulation.new(12345)
	_camera = $RTSCamera/Camera3D
	call_deferred("_configure_camera")
	_build_landscape()
	_build_settlements()
	_build_interface()

func _configure_camera() -> void:
	_camera.size = 350.0
	# The playable detail occupies WORLD_SIZE, while the visual landscape now
	# continues through SURROUND_SIZE.  Use that wider extent for panning so an
	# overview camera can travel through the surrounding countryside instead of
	# being snapped back to the valley's centre.
	$RTSCamera.pan_limit = AuthoredValleyTerrain.SURROUND_SIZE * 0.5
	$RTSCamera.max_ground_height = AuthoredValleyTerrain.HEIGHT_MAX
	$RTSCamera.center_on(Vector3(0.0, 0.0, 0.0))

func _process(_delta: float) -> void:
	# At valley scale labels and route geometry dominate. At settlement scale
	# the physical clusters are still present and become the visual focus.
	var valley_lens := _camera.size >= 78.0
	for marker in _settlement_markers.values():
		(marker as MeshInstance3D).visible = valley_lens or marker.get_meta("settlement_id") == _selected_settlement_id

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var point := _ground_point(event.position)
		if point == Vector3.INF:
			return
		var nearest_id := -1
		var nearest_distance := 8.0
		for settlement_id in Layout.SETTLEMENTS:
			var visual_position: Vector2 = settlement_cluster_positions.get(
				settlement_id,
				Vector2(Layout.settlement_position(settlement_id).x, Layout.settlement_position(settlement_id).z),
			)
			var distance := Vector2(point.x, point.z).distance_to(visual_position)
			if distance < nearest_distance:
				nearest_distance = distance
				nearest_id = settlement_id
		if nearest_id != -1:
			_select_settlement(nearest_id)

func _ground_point(screen_position: Vector2) -> Vector3:
	var origin := _camera.project_ray_origin(screen_position)
	var direction := _camera.project_ray_normal(screen_position)
	if absf(direction.y) < 0.001:
		return Vector3.INF
	var distance := -origin.y / direction.y
	return origin + direction * distance if distance >= 0.0 else Vector3.INF

func _build_landscape() -> void:
	_terrain = AuthoredValleyTerrain.new()
	add_child(_terrain)
	_terrain.build()

	_add_watercourse("MainRiver", Layout.main_river(), 18.0, RIVER_COLOR)
	_add_watercourse("Tributary", Layout.tributary(), 10.0, Color("477fa8"))
	var confluence := TerrainRibbonBuilder.build_disc("AldfordConfluence", Vector2(0.0, -5.0), 10.5, Callable(self, "get_valley_ground_height"), 0.30, _water_material(RIVER_COLOR), 48)
	add_child(confluence)

	# Existing seed edges are the source of truth for the static route drawing.
	for edge_id in Layout.EDGES:
		var edge := _simulation.get_transport_edge_summary(edge_id)
		var from_pos := Layout.settlement_position(edge["settlement_a_id"])
		var to_pos := Layout.settlement_position(edge["settlement_b_id"])
		if Layout.EDGES[edge_id]["kind"] == "track":
			_add_route(edge_id, Layout.track_path(edge_id, from_pos, to_pos), TRACK_WIDTH, ROAD_COLOR)

	# The ford is intentionally weak and legible: a narrow pale crossing at
	# Aldford, reserved for replacement by a bridge in Milestone 3.
	_add_ribbon("AldfordFord", PackedVector3Array([Vector3(-8.0, 0.0, -5.0), Vector3(1.0, 0.0, -5.0), Vector3(12.0, 0.0, -5.0)]), 3.2, 0.72, _ground_material(Color("c9b58a")), 1.0, 0.12, 41, true)

## The first valley remains deliberately simple, but this shared ground query
## keeps decorative vegetation and future building placement aligned with its
## existing hill geometry instead of floating on the base plane.
func get_valley_ground_height(point: Vector2) -> float:
	return _terrain.get_height(point.x, point.y) if _terrain != null else 0.0

## Aldford, Oakmere, and Staithe's authored positions double as vertices of
## the main river or tributary polyline (the river network was authored
## against the settlement layout, e.g. so Aldford sits at the ford), so their
## houses and fields need to sit off to the side of the water instead of
## literally on top of it. High Fell and Ironbank aren't on the river network
## at all and need no offset. Each offset was picked by measuring clearance
## against the actual river/tributary segments meeting at that settlement,
## not eyeballed.
const CLUSTER_OFFSETS := {
	ValleySeed.ALDFORD: Vector3(-16.0, 0.0, 12.0), # off the ford confluence
	ValleySeed.OAKMERE: Vector3(-9.0, 0.0, 14.0),  # off the tributary bend
	ValleySeed.STAITHE: Vector3(-11.0, 0.0, 14.0), # off the river bend
}

func _build_settlements() -> void:
	for settlement_id in _simulation.get_settlement_ids():
		var spec: Dictionary = Layout.SETTLEMENTS[settlement_id]
		var center: Vector3 = spec["position"]
		center.y = get_valley_ground_height(Vector2(center.x, center.z))
		var cluster_center: Vector3 = center + CLUSTER_OFFSETS.get(settlement_id, Vector3.ZERO)
		cluster_center.y = get_valley_ground_height(Vector2(cluster_center.x, cluster_center.z))
		settlement_cluster_positions[settlement_id] = Vector2(cluster_center.x, cluster_center.z)
		_add_resource_region(cluster_center, spec["district"], spec["accent"])
		_add_settlement_cluster(settlement_id, cluster_center, spec["accent"])
		_add_label(settlement_id, cluster_center + Vector3(0.0, 5.2, 0.0))

## The settlement's authored (unoffset) position, ground-projected -- for the
## small riverside structures that belong at the water regardless of where
## CLUSTER_OFFSETS moved the settlement's houses.
func _river_edge_anchor(settlement_id: int) -> Vector3:
	var anchor := Layout.settlement_position(settlement_id)
	anchor.y = get_valley_ground_height(Vector2(anchor.x, anchor.z))
	return anchor

func _add_settlement_cluster(settlement_id: int, center: Vector3, accent: Color) -> void:
	var marker := _add_cylinder("SettlementMarker%d" % settlement_id, center + Vector3(0.0, 0.2, 0.0), 2.3, 0.20, accent.lightened(0.15))
	marker.set_meta("settlement_id", settlement_id)
	_settlement_markers[settlement_id] = marker

	var offsets := [Vector2(-4, -2), Vector2(4, -1), Vector2(-2, 4), Vector2(4, 4)]
	for i in offsets.size():
		var offset: Vector2 = offsets[i]
		var size := Vector3(2.7 + (i % 2), 1.6 + (i % 2) * 0.4, 2.5)
		_add_house(center + Vector3(offset.x, 0.8, offset.y), size, accent.darkened(0.28))
	_add_house(center + Vector3(0.0, 1.35, 0.0), Vector3(4.6, 2.7, 3.8), accent.darkened(0.38))

	if settlement_id == ValleySeed.ALDFORD:
		# Anchored to the actual ford/riverbank, not `center` -- these
		# settlements' houses are offset away from the water (see
		# CLUSTER_OFFSETS), but a landing or quay still needs to sit at the
		# river itself.
		var river_edge := _river_edge_anchor(ValleySeed.ALDFORD)
		var landing_point := Vector2(river_edge.x + 8.5, river_edge.z - 5.0)
		var landing_height := get_valley_ground_height(landing_point)
		_add_box("AldfordLanding", Vector3(landing_point.x, landing_height + 0.28, landing_point.y), Vector3(3.5, 0.35, 7.0), Color("7d6044"))
	elif settlement_id == ValleySeed.STAITHE:
		var river_edge := _river_edge_anchor(ValleySeed.STAITHE)
		_add_box("StaitheQuay", river_edge + Vector3(-4.0, 0.32, 5.0), Vector3(4.0, 0.42, 13.0), Color("76573e"))
		# On the bank near the quay's landward end, not out past it into the
		# 18-unit-wide channel -- a physical mill building can't float on the
		# water the way the quay's jetty is meant to.
		_add_box("StaitheMill", river_edge + Vector3(-7.0, 1.4, 10.0), Vector3(3.0, 2.8, 3.0), Color("c5b27d"))

func _add_resource_region(center: Vector3, district: String, accent: Color) -> void:
	match district:
		"pasture":
			for x in [-15.0, -8.0, 8.0, 16.0]:
				_add_cylinder("PastureMarker", center + Vector3(x, 0.15, 9.0), 1.0, 0.25, accent)
		"woodland":
			pass # Detailed woodland is instantiated by ValleyVegetation.
		"ore":
			for offset in [Vector2(-12, 6), Vector2(-8, 10), Vector2(-5, 6), Vector2(-10, 2)]:
				_add_cylinder("OreDeposit", center + Vector3(offset.x, 0.35, offset.y), 1.8, 0.7, accent)
		"fields":
			for offset in [Vector2(-13, 10), Vector2(-6, 12), Vector2(8, 10), Vector2(14, 13)]:
				_add_box("Field", center + Vector3(offset.x, 0.08, offset.y), Vector3(5.5, 0.12, 4.5), Color("b8ad58"))
		"port":
			# Offset away from the river (Staithe's `center` here is already
			# CLUSTER_OFFSETS-shifted off the water) so an 11x8 plaza doesn't
			# reach back into it.
			_add_box("MarketGround", center + Vector3(7.0, 0.10, 7.0), Vector3(11.0, 0.12, 8.0), Color("b69762"))

func _add_label(settlement_id: int, position: Vector3) -> void:
	var label := Label3D.new()
	var summary := _simulation.get_settlement_summary(settlement_id)
	label.text = "%s\n%s" % [summary["name"], Layout.SETTLEMENTS[settlement_id]["role"].split(",")[0]]
	label.name = "Label%d" % settlement_id
	label.position = position
	label.font_size = 52
	label.outline_size = 8
	label.modulate = Color.WHITE
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(label)

func _build_interface() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	_hint_label = Label.new()
	_hint_label.text = "River Valley — mouse wheel: zoom   |   middle drag / WASD: pan   |   Alt + drag: tilt   |   click a settlement"
	_hint_label.position = Vector2(18, 16)
	_hint_label.add_theme_font_size_override("font_size", 15)
	canvas.add_child(_hint_label)

	_selection_panel = PanelContainer.new()
	_selection_panel.position = Vector2(18, 54)
	_selection_panel.size = Vector2(325, 350)
	_selection_panel.visible = false
	canvas.add_child(_selection_panel)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 8)
	_selection_panel.add_child(content)
	_selection_title = Label.new()
	_selection_title.add_theme_font_size_override("font_size", 23)
	content.add_child(_selection_title)
	_selection_role = Label.new()
	_selection_role.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_selection_role)
	_selection_stats = Label.new()
	content.add_child(_selection_stats)
	_selection_inventory = Label.new()
	_selection_inventory.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_selection_inventory)
	_selection_workplaces = Label.new()
	_selection_workplaces.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_selection_workplaces)

func _select_settlement(settlement_id: int) -> void:
	_selected_settlement_id = settlement_id
	_selection_panel.visible = true
	var summary := _simulation.get_settlement_summary(settlement_id)
	_selection_title.text = "%s%s" % [summary["name"], "  •  Clan holding" if summary["is_player_holding"] else ""]
	_selection_role.text = Layout.role_for(settlement_id)
	_selection_stats.text = "Population: %d   Households: %d\nWorkers: %d available   Status: %s" % [summary["population"], summary["household_count"], summary["available_workers"], summary["status"]]
	var stock_parts: Array[String] = []
	for commodity in Commodity.ALL:
		var name := Commodity.name_of(commodity)
		stock_parts.append("%s %.0f" % [name, summary["inventory"][name]])
	_selection_inventory.text = "Seeded inventory\n" + ", ".join(stock_parts)
	var report_parts: Array[String] = []
	for report in _simulation.get_workplace_reports(settlement_id):
		report_parts.append(str(report["recipe_id"]).capitalize())
	_selection_workplaces.text = "Workplaces: " + ", ".join(report_parts)

func _add_route(edge_id: int, points: PackedVector3Array, width: float, color: Color) -> void:
	# A darker, wider shoulder settles the path into the grass. The narrower
	# worn strip has low-amplitude deterministic width changes rather than a
	# perfectly constant silhouette.
	_add_ribbon("RouteShoulder%d" % edge_id, points, width + 1.45, 0.10, _ground_material(ROAD_SHOULDER_COLOR), 2.8, 0.20, edge_id * 17)
	_add_ribbon("Route%d" % edge_id, points, width, 0.14, _ground_material(color), 2.8, 0.28, edge_id * 17 + 5)

func _add_watercourse(prefix: String, points: PackedVector3Array, width: float, color: Color) -> void:
	# Banks are one continuous terrain-following strip beneath a separate calm
	# water surface. Each water cross-section shares one sampled center height,
	# avoiding the pitched/floating joins produced by horizontal boxes.
	_add_ribbon("%sBank" % prefix, points, width + 3.6, 0.12, _ground_material(RIVER_BANK_COLOR), 2.4)
	_add_ribbon(prefix, points, width, 0.22, _water_material(color), 2.4, 0.0, 0, true)

func _add_ribbon(node_name: String, points: PackedVector3Array, width: float, y_offset: float, material: Material, sample_spacing: float, width_variation: float = 0.0, variation_seed: int = 0, flat_cross_section: bool = false) -> MeshInstance3D:
	var ribbon := TerrainRibbonBuilder.build(node_name, points, Callable(self, "get_valley_ground_height"), width, y_offset, material, sample_spacing, width_variation, variation_seed, flat_cross_section)
	add_child(ribbon)
	return ribbon

func _add_house(position: Vector3, size: Vector3, color: Color) -> void:
	_add_box("House", position, size, color)
	var roof := PrismMesh.new()
	roof.left_to_right = 0.5
	roof.size = Vector3(size.x + 0.35, size.z + 0.25, size.y * 0.72)
	var instance := MeshInstance3D.new()
	instance.name = "ThatchRoof"
	instance.mesh = roof
	instance.material_override = _material(Color("5d4735"))
	instance.position = position + Vector3(0.0, size.y * 0.62, 0.0)
	instance.rotation_degrees = Vector3(0.0, 90.0, 0.0)
	add_child(instance)

func _add_tree(position: Vector3) -> void:
	_add_cylinder("TreeTrunk", position + Vector3(0.0, 1.1, 0.0), 0.27, 2.2, Color("5b4431"))
	var crown := SphereMesh.new()
	crown.radius = 1.55
	crown.height = 3.0
	var instance := MeshInstance3D.new()
	instance.name = "TreeCrown"
	instance.mesh = crown
	instance.material_override = _material(Color("315c36"))
	instance.position = position + Vector3(0.0, 3.0, 0.0)
	add_child(instance)

func _add_hill(position: Vector3, size: Vector3, color: Color) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = 1.0
	mesh.height = 2.0
	var instance := MeshInstance3D.new()
	instance.name = "Hill"
	instance.mesh = mesh
	instance.material_override = _material(color)
	instance.position = position
	instance.scale = size
	add_child(instance)

func _add_box(node_name: String, position: Vector3, size: Vector3, color: Color) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = _material(color)
	instance.position = position
	add_child(instance)
	return instance

func _add_cylinder(node_name: String, position: Vector3, radius: float, height: float, color: Color) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = _material(color)
	instance.position = position
	add_child(instance)
	return instance

func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.92
	return material

func _ground_material(color: Color) -> StandardMaterial3D:
	var material := _material(color)
	material.roughness = 1.0
	return material

func _water_material(color: Color) -> StandardMaterial3D:
	var material := _material(color)
	material.roughness = 0.30
	material.metallic = 0.08
	return material
