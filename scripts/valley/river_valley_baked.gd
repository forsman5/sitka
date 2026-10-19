extends "res://scripts/valley/river_valley.gd"

## Game-view adapter for the approved frozen terrain bake. The parent keeps
## owning the household economies, selection panel, clock, and dashboard link;
## this script replaces only the terrain/map presentation.

const Bake = preload("res://scripts/valley/valley_bake_data.gd")
const BakeScene = preload("res://scripts/valley/baked_valley_renderer.gd")

const BAKE_DIR := "res://data/valley_bakes/river_valley_1"
const ROLE_TO_SETTLEMENT_ID := {
	"town": ValleySeed.ALDFORD,
	"pasture": ValleySeed.HIGH_FELL,
	"woodland": ValleySeed.OAKMERE,
	"ore": ValleySeed.IRONBANK,
	"port": ValleySeed.STAITHE,
}

var _bake: Dictionary = {}
var _baked_world: Node3D

func _ready() -> void:
	set_process(false)
	set_process_unhandled_input(false)
	_bake = Bake.load_dir(BAKE_DIR)
	if _bake.is_empty():
		push_error("Could not load the approved valley bake at %s" % BAKE_DIR)
		set_process(false)
		return
	var builder := BakeScene.new()
	_baked_world = await builder.build(_bake, get_tree(), Callable())
	if _baked_world == null:
		push_error("Could not build the approved valley bake scene")
		set_process(false)
		return
	# The bake preview uses generator names. The live simulation owns the visible
	# settlement names, so replace those labels when the parent builds its UI.
	for label in _baked_world.find_children("*", "Label3D", true, false):
		label.free()
	map_definition = _map_for_economy(_bake["map"])
	super._ready()
	set_process(true)
	set_process_unhandled_input(true)


func _map_for_economy(source: Resource):
	var source_map := source as MapDefinition
	var result = source_map.duplicate(true)
	var id_map := {}
	var settlements := {}
	for source_id in source_map.settlements:
		var record: Dictionary = source_map.settlements[source_id]
		var role: String = str(record.get("kind", ""))
		if not ROLE_TO_SETTLEMENT_ID.has(role):
			push_error("The baked valley has no economy mapping for settlement role '%s'" % role)
			continue
		var target_id: int = ROLE_TO_SETTLEMENT_ID[role]
		id_map[int(source_id)] = target_id
		settlements[target_id] = record.duplicate(true)
	result.settlements = settlements
	for collection in [result.rivers, result.roads, result.water_routes]:
		for record in collection.values():
			for point in record.get("points", []):
				_remap_anchor(point, id_map)
	for record in result.vegetation.values():
		_remap_anchor(record.get("center"), id_map)
	return result

func _remap_anchor(point: Variant, id_map: Dictionary) -> void:
	if not point is Dictionary:
		return
	for key in ["settlement", "waterfront"]:
		if point.has(key) and id_map.has(int(point[key])):
			point[key] = id_map[int(point[key])]

func _configure_camera() -> void:
	_camera = $RTSCamera/Camera3D
	var rig: Node3D = $RTSCamera
	var size: Vector2 = _bake["size"]
	rig.pan_limit = size * 0.5
	rig.max_ground_height = float(_bake["height_max"])
	# Keep the full valley comfortably in frame without letting the camera pull
	# so far back that trees and route overlays become disconnected-looking
	# specks against the background. The heightfield is 960x720 world units.
	rig.zoom_min = 180.0
	rig.zoom_max = 900.0
	rig.zoom_step = 40.0
	rig.pivot_height = 520.0
	_camera.far = 6000.0
	_camera.size = 560.0
	rig._current_tilt = 65.0
	rig._apply_tilt()
	rig.center_on(Vector3.ZERO)

func _build_landscape() -> void:
	add_child(_baked_world)
	for river_id in map_definition.rivers:
		var river: Dictionary = map_definition.rivers[river_id]
		var outline := TerrainRibbonBuilder.footprint(map_definition.river_path(river_id), float(river["width"]))
		_river_outlines[river_id] = outline
		_transport_clearance.append(TerrainRibbonBuilder.footprint(map_definition.river_path(river_id), float(river["width"]) + 4.0))
	for road_id in map_definition.roads:
		var road: Dictionary = map_definition.roads[road_id]
		_transport_clearance.append(TerrainRibbonBuilder.footprint(map_definition.road_path(road_id), float(road["width"]) + 4.5))
	for crossing_id in map_definition.crossings:
		var crossing: Dictionary = map_definition.crossings[crossing_id]
		var river_id: String = crossing["river"]
		var river: Dictionary = map_definition.rivers[river_id]
		var water := _baked_world.get_node_or_null("River_%s" % river_id) as MeshInstance3D
		if water != null:
			_build_channel_ford(crossing, _river_outlines[river_id], water, map_definition.road_path(crossing["road"]))

func _build_settlements() -> void:
	for settlement_id in map_definition.settlements:
		var spec: Dictionary = map_definition.settlements[settlement_id]
		var center: Vector3 = spec["site"]
		center.y = get_valley_ground_height(Vector2(center.x, center.z))
		settlement_cluster_positions[settlement_id] = Vector2(center.x, center.z)
		var marker := _add_cylinder("SettlementMarker%d" % settlement_id, center + Vector3(0.0, 0.22, 0.0), 3.2, 0.22, spec["accent"])
		marker.set_meta("settlement_id", settlement_id)
		_settlement_markers[settlement_id] = marker
		_add_label(settlement_id, center + Vector3(0.0, 18.0, 0.0))

func get_valley_ground_height(point: Vector2) -> float:
	return Bake.height_at(_bake, point) if not _bake.is_empty() else 0.0

func _ground_point(screen_position: Vector2) -> Vector3:
	var origin := _camera.project_ray_origin(screen_position)
	var direction := _camera.project_ray_normal(screen_position)
	if absf(direction.y) < 0.001:
		return Vector3.INF
	var previous_distance := 0.0
	var previous_delta := origin.y - get_valley_ground_height(Vector2(origin.x, origin.z))
	for sample in range(1, 801):
		var distance := float(sample) * 8.0
		var point := origin + direction * distance
		var delta := point.y - get_valley_ground_height(Vector2(point.x, point.z))
		if previous_delta >= 0.0 and delta <= 0.0:
			var low := previous_distance
			var high := distance
			for _iteration in 12:
				var middle := (low + high) * 0.5
				var probe := origin + direction * middle
				if probe.y > get_valley_ground_height(Vector2(probe.x, probe.z)):
					low = middle
				else:
					high = middle
			var hit := origin + direction * ((low + high) * 0.5)
			return Vector3(hit.x, get_valley_ground_height(Vector2(hit.x, hit.z)), hit.z)
		previous_distance = distance
		previous_delta = delta
	return Vector3.INF
