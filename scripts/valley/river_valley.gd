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
const MapDefinition = preload("res://scripts/valley/valley_map_definition.gd")

@export var map_definition: MapDefinition
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
var _river_outlines: Dictionary = {}
var _transport_clearance: Array[PackedVector2Array] = []

## Rendered settlement sites, shared by selection and vegetation clearance.
var settlement_cluster_positions: Dictionary = {}

func _ready() -> void:
	if map_definition == null:
		map_definition = Layout.create_map()
	var errors := map_definition.validate_geometry()
	if not errors.is_empty():
		push_error("Invalid valley map: %s" % "; ".join(errors))
		set_process(false)
		return
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
		for settlement_id in map_definition.settlements:
			var visual_position: Vector2 = settlement_cluster_positions.get(
				settlement_id,
				Vector2(map_definition.settlements[settlement_id]["site"].x, map_definition.settlements[settlement_id]["site"].z),
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

	for id in map_definition.rivers:
		var river: Dictionary = map_definition.rivers[id]
		var path := map_definition.river_path(id)
		_river_outlines[id] = TerrainRibbonBuilder.footprint(path, river["width"])
		_transport_clearance.append(TerrainRibbonBuilder.footprint(path, river["width"] + 4.0))
	var previous_water: Array = []
	for id in map_definition.rivers:
		var river: Dictionary = map_definition.rivers[id]
		var other_banks: Array = []
		for other_id in _river_outlines:
			if other_id != id:
				other_banks.append(_river_outlines[other_id])
		_add_watercourse(river["node_name"], map_definition.river_path(id), river["width"], other_banks, previous_water)
		previous_water.append(_river_outlines[id])
	for id in map_definition.roads:
		_add_route(id)
	for id in map_definition.crossings:
		var crossing: Dictionary = map_definition.crossings[id]
		var river: Dictionary = map_definition.rivers[crossing["river"]]
		_build_channel_ford(crossing, _river_outlines[crossing["river"]], get_node(river["node_name"]), map_definition.road_path(crossing["road"]))

func _build_channel_ford(spec: Dictionary, outline: PackedVector2Array, water: MeshInstance3D, route: PackedVector3Array) -> void:
	var prefix: String = spec["name"]
	var anchor: Vector3 = spec["position"]
	# Select the bank pair near the explicitly authored crossing.
	var samples := TerrainRibbonBuilder._sample_catmull_rom(route, 0.6)
	var banks: Array[Vector2] = []
	for segment in range(samples.size() - 1):
		var start := Vector2(samples[segment].x, samples[segment].z)
		var finish := Vector2(samples[segment + 1].x, samples[segment + 1].z)
		for i in outline.size():
			var hit: Variant = Geometry2D.segment_intersects_segment(start, finish, outline[i], outline[(i + 1) % outline.size()])
			if hit != null and hit.distance_to(Vector2(anchor.x, anchor.z)) <= spec["radius"] and (banks.is_empty() or banks.back().distance_to(hit) > 0.01):
				banks.append(hit)
	if banks.size() != 2:
		push_error("%s ford requires two riverbank intersections; found %d" % [prefix, banks.size()])
		return
	var center := (banks[0] + banks[1]) * 0.5
	# Sample the rendered water triangles, not the riverbed: upstream water is
	# level across each section and can sit above the underlying heightmap.
	var faces: PackedVector3Array = water.mesh.get_faces()
	var nearby_faces: Array[PackedVector3Array] = []
	var reach := banks[0].distance_to(banks[1]) * 0.5 + 4.0
	for i in range(0, faces.size(), 3):
		var triangle := PackedVector3Array([faces[i], faces[i + 1], faces[i + 2]])
		if minf(triangle[0].z, minf(triangle[1].z, triangle[2].z)) <= center.y + reach and maxf(triangle[0].z, maxf(triangle[1].z, triangle[2].z)) >= center.y - reach:
			nearby_faces.append(triangle)
	var surface_height := Callable(self, "_channel_ford_height").bind(nearby_faces)
	var crossing := PackedVector3Array([Vector3(banks[0].x, 0, banks[0].y), Vector3(center.x, 0, center.y), Vector3(banks[1].x, 0, banks[1].y)])
	var material := ShaderMaterial.new()
	material.shader = preload("res://shaders/ford_shallows.gdshader")
	add_child(TerrainRibbonBuilder.build("%sFordShallows" % prefix, crossing, Callable(self, "get_valley_ground_height"), spec["width"], 0.0, material, 0.35, 0.12, 83, false, PackedVector2Array(), surface_height, 16))
	var rng := RandomNumberGenerator.new()
	rng.seed = spec["seed"]
	var direction := (banks[1] - banks[0]).normalized()
	var side := Vector2(-direction.y, direction.x)
	for i in 28:
		var point := banks[0].lerp(banks[1], (float(i) + 0.5) / 28.0) + side * rng.randf_range(-1.15, 1.15)
		var mesh := SphereMesh.new()
		mesh.radius = rng.randf_range(0.16, 0.32)
		mesh.height = mesh.radius * 0.65
		mesh.radial_segments = 8
		mesh.rings = 4
		var stone := MeshInstance3D.new()
		stone.name = "%sFordStone%d" % [prefix, i]
		stone.mesh = mesh
		stone.material_override = _ground_material(Color("798078"))
		stone.position = Vector3(point.x, surface_height.call(point, 0), point.y)
		add_child(stone)
	for i in 2:
		var point := banks[i] + direction * (-2.0 if i == 0 else 2.0) + side * 2.2
		_add_cylinder("%sFordMarker" % prefix, Vector3(point.x, get_valley_ground_height(point) + 0.7, point.y), 0.14, 1.4, Color("65513b"))

func _channel_ford_height(point: Vector2, _original: float, faces: Array[PackedVector3Array]) -> float:
	for triangle in faces:
		var a := triangle[0]
		var b := triangle[1]
		var c := triangle[2]
		if Geometry2D.is_point_in_polygon(point, PackedVector2Array([Vector2(a.x, a.z), Vector2(b.x, b.z), Vector2(c.x, c.z)])):
			var normal := (b - a).cross(c - a)
			return a.y - (normal.x * (point.x - a.x) + normal.z * (point.y - a.z)) / normal.y + 0.07
	return get_valley_ground_height(point) + 0.28

## The first valley remains deliberately simple, but this shared ground query
## keeps decorative vegetation and future building placement aligned with its
## existing hill geometry instead of floating on the base plane.
func get_valley_ground_height(point: Vector2) -> float:
	return _terrain.get_height(point.x, point.y) if _terrain != null else 0.0

func is_transport_clear(point: Vector2) -> bool:
	for outline in _transport_clearance:
		if Geometry2D.is_point_in_polygon(point, outline):
			return false
	return true

func _build_settlements() -> void:
	for settlement_id in map_definition.settlements:
		var spec: Dictionary = map_definition.settlements[settlement_id]
		var cluster_center: Vector3 = spec["site"]
		cluster_center.y = get_valley_ground_height(Vector2(cluster_center.x, cluster_center.z))
		settlement_cluster_positions[settlement_id] = Vector2(cluster_center.x, cluster_center.z)
		_add_resource_region(cluster_center, spec["district"], spec["accent"])
		_add_settlement_cluster(settlement_id, cluster_center, spec["accent"])
		_add_label(settlement_id, cluster_center + Vector3(0.0, 5.2, 0.0))

## Waterfront anchors are separate from inland settlement sites.
func _river_edge_anchor(settlement_id: int) -> Vector3:
	var anchor := map_definition.resolve_point({"waterfront": settlement_id})
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
		# The landing follows the waterfront anchor independently of the houses.
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
			# Place the market inland of the settlement center.
			_add_box("MarketGround", center + Vector3(7.0, 0.10, 7.0), Vector3(11.0, 0.12, 8.0), Color("b69762"))

func _add_label(settlement_id: int, position: Vector3) -> void:
	var label := Label3D.new()
	var summary := _simulation.get_settlement_summary(settlement_id)
	label.text = "%s\n%s" % [summary["name"], map_definition.settlements[settlement_id]["role"].split(",")[0]]
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
	_selection_role.text = map_definition.settlements[settlement_id]["role"]
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

func _add_route(id: String) -> void:
	var spec: Dictionary = map_definition.roads[id]
	var points := map_definition.road_path(id)
	var width: float = spec["width"]
	var seed_value: int = spec["seed"]
	_transport_clearance.append(TerrainRibbonBuilder.footprint(points, width + 4.5))
	var ground := Callable(self, "get_valley_ground_height")
	add_child(TerrainRibbonBuilder.build("RouteShoulder_" + id, points, ground, width + 1.45, 0.26, _ground_material(ROAD_SHOULDER_COLOR), 0.4, 0.20, seed_value, false, _river_outlines.values(), Callable(), 16))
	add_child(TerrainRibbonBuilder.build("Route_" + id, points, ground, width, 0.30, _ground_material(ROAD_COLOR), 0.4, 0.28, seed_value + 5, false, _river_outlines.values(), Callable(), 16))

func _add_watercourse(prefix: String, points: PackedVector3Array, width: float, bank_cutout: Array, water_cutout: Array) -> void:
	var ground := Callable(self, "get_valley_ground_height")
	add_child(TerrainRibbonBuilder.build("%sBank" % prefix, points, ground, width + 3.6, 0.12, _ground_material(RIVER_BANK_COLOR), 0.6, 0.0, 0, false, bank_cutout, Callable(), 16))
	add_child(TerrainRibbonBuilder.build(prefix, points, ground, width, 0.22, _water_material(RIVER_COLOR), 0.6, 0.0, 0, true, water_cutout, Callable(self, "_confluence_surface_height"), 16))

func _confluence_surface_height(point: Vector2, original_height: float) -> float:
	# Both channels use the same terrain-following surface around the mouth.
	# The smooth outer transition preserves the existing upstream cross-sections.
	var height := original_height
	for junction in map_definition.junctions.values():
		var center: Vector3 = junction["position"]
		var distance := point.distance_to(Vector2(center.x, center.z))
		var blend := 1.0 - smoothstep(junction["inner_radius"], junction["outer_radius"], distance)
		height = lerpf(height, get_valley_ground_height(point) + 0.45, blend)
	return height

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
