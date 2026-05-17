extends Node3D

const DRAG_THRESHOLD := 6.0

var _drag_start := Vector2.ZERO
var _dragging := false

@onready var _selection_box: Panel = $SelectionUI/SelectionBox
@onready var _nav_region: NavigationRegion3D = $NavigationRegion3D

func _ready() -> void:
	var terrain = get_tree().get_first_node_in_group("heightmap_terrain")
	if terrain != null:
		terrain.prepare_for_bake()
		_nav_region.bake_finished.connect(func():
			if is_instance_valid(terrain):
				terrain.restore_visual()
		, CONNECT_ONE_SHOT)
	_nav_region.bake_navigation_mesh()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_drag_start = event.position
			_dragging = false
		else:
			_finish_input(event.position)
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		_handle_right_click(event.position)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		if event.position.distance_to(_drag_start) > DRAG_THRESHOLD:
			_dragging = true
		if _dragging:
			_update_selection_box(event.position)
			get_viewport().set_input_as_handled()

func _finish_input(screen_pos: Vector2) -> void:
	if _dragging:
		_finish_box_select(screen_pos)
	else:
		_handle_single_click(screen_pos)
	_selection_box.visible = false
	_dragging = false

func _handle_single_click(screen_pos: Vector2) -> void:
	var shift := Input.is_key_pressed(KEY_SHIFT)
	var person := _get_person_at(screen_pos)
	if person != null:
		_deselect_all_buildings()
		_deselect_all_resources()
		_deselect_all_foundations()
		_deselect_all_ships()
		if not shift:
			_deselect_all()
		person.set_selected(true)
		return
	var ship := _get_ship_at(screen_pos)
	if ship != null:
		_deselect_all()
		_deselect_all_buildings()
		_deselect_all_resources()
		_deselect_all_foundations()
		_deselect_all_ships()
		ship.set_selected(true)
		return
	var foundation := _get_foundation_at(screen_pos)
	if foundation != null:
		_deselect_all()
		_deselect_all_buildings()
		_deselect_all_resources()
		_deselect_all_foundations()
		foundation.set_selected(true)
		return
	var building := _get_building_at(screen_pos)
	if building != null:
		_deselect_all()
		_deselect_all_resources()
		_deselect_all_foundations()
		_deselect_all_buildings()
		building.set_selected(true)
		return
	var resource := _get_resource_at(screen_pos)
	if resource != null:
		_deselect_all()
		_deselect_all_buildings()
		_deselect_all_foundations()
		_deselect_all_resources()
		resource.set_selected(true)
		return
	if not shift:
		_deselect_all()
		_deselect_all_buildings()
		_deselect_all_resources()
		_deselect_all_foundations()

func _finish_box_select(end_pos: Vector2) -> void:
	var shift := Input.is_key_pressed(KEY_SHIFT)
	var rect := Rect2(_drag_start, end_pos - _drag_start).abs()
	_deselect_all_buildings()
	_deselect_all_resources()
	_deselect_all_foundations()
	if not shift:
		_deselect_all()
		_deselect_all_ships()
	var camera := get_viewport().get_camera_3d()
	for person: Node3D in get_tree().get_nodes_in_group("persons"):
		var screen_pos := camera.unproject_position(person.global_position + Vector3(0, 0.9, 0))
		if rect.has_point(screen_pos):
			person.set_selected(true)
	for ship: Node3D in get_tree().get_nodes_in_group("ships"):
		var screen_pos := camera.unproject_position(ship.global_position + Vector3(0, 0.5, 0))
		if rect.has_point(screen_pos):
			ship.set_selected(true)

func _update_selection_box(current_pos: Vector2) -> void:
	_selection_box.visible = true
	var abs_rect := Rect2(_drag_start, current_pos - _drag_start).abs()
	_selection_box.position = abs_rect.position
	_selection_box.size = abs_rect.size

func _deselect_all() -> void:
	for p: Node3D in get_tree().get_nodes_in_group("persons"):
		p.set_selected(false)

func _deselect_all_ships() -> void:
	for s: Node3D in get_tree().get_nodes_in_group("ships"):
		s.set_selected(false)

func _deselect_all_buildings() -> void:
	for b: Node3D in get_tree().get_nodes_in_group("buildings"):
		b.set_selected(false)

func _deselect_all_resources() -> void:
	for r: Node3D in get_tree().get_nodes_in_group("resource_nodes"):
		r.set_selected(false)

func _deselect_all_foundations() -> void:
	for f: Node3D in get_tree().get_nodes_in_group("foundations"):
		f.set_selected(false)

func _any_selected() -> bool:
	for p: Node3D in get_tree().get_nodes_in_group("persons"):
		if p.selected:
			return true
	return false

func _any_ship_selected() -> bool:
	for s: Node3D in get_tree().get_nodes_in_group("ships"):
		if s.get("selected") == true:
			return true
	return false

func _handle_right_click(screen_pos: Vector2) -> void:
	if _any_ship_selected():
		var pos := _raycast_y0(screen_pos)
		if pos != Vector3.INF:
			var terrain = get_tree().get_first_node_in_group("heightmap_terrain")
			if terrain != null and terrain.is_ocean_water(pos.x, pos.z):
				for s: Node3D in get_tree().get_nodes_in_group("ships"):
					if s.get("selected") == true:
						s.set_move_target(pos)
		return
	if not _any_selected():
		return
	var foundation := _get_foundation_at(screen_pos)
	if foundation != null:
		for p: Node3D in get_tree().get_nodes_in_group("persons"):
			if p.selected:
				p.set_build_objective(foundation)
		return
	var resource := _get_resource_at(screen_pos)
	if resource != null:
		for p: Node3D in get_tree().get_nodes_in_group("persons"):
			if p.selected:
				p.set_objective(resource)
		return
	var building := _get_building_at(screen_pos)
	if building != null:
		for p: Node3D in get_tree().get_nodes_in_group("persons"):
			if p.selected:
				p.set_deposit_objective()
		return
	var pos := _raycast_y0(screen_pos)
	if pos != Vector3.INF:
		for p: Node3D in get_tree().get_nodes_in_group("persons"):
			if p.selected:
				p.set_move_objective(pos)

func _get_building_at(screen_pos: Vector2) -> Node3D:
	var camera := get_viewport().get_camera_3d()
	var space := get_world_3d().direct_space_state
	var from := camera.project_ray_origin(screen_pos)
	var to := from + camera.project_ray_normal(screen_pos) * 1000.0
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = true
	query.collide_with_bodies = false
	var result := space.intersect_ray(query)
	if result.is_empty():
		return null
	var collider: Object = result.get("collider")
	if collider is Area3D:
		var parent: Node = (collider as Area3D).get_parent()
		if parent.is_in_group("buildings"):
			return parent as Node3D
	return null

func _get_resource_at(screen_pos: Vector2) -> Node3D:
	var camera := get_viewport().get_camera_3d()
	var space := get_world_3d().direct_space_state
	var from := camera.project_ray_origin(screen_pos)
	var to := from + camera.project_ray_normal(screen_pos) * 1000.0
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = true
	query.collide_with_bodies = false
	var result := space.intersect_ray(query)
	if result.is_empty():
		return null
	var collider: Object = result.get("collider")
	if collider is Area3D:
		var parent: Node = (collider as Area3D).get_parent()
		if parent.is_in_group("resource_nodes"):
			return parent as Node3D
	return null

func _get_foundation_at(screen_pos: Vector2) -> Node3D:
	var camera := get_viewport().get_camera_3d()
	var space := get_world_3d().direct_space_state
	var from := camera.project_ray_origin(screen_pos)
	var to := from + camera.project_ray_normal(screen_pos) * 1000.0
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = true
	query.collide_with_bodies = false
	var result := space.intersect_ray(query)
	if result.is_empty():
		return null
	var collider: Object = result.get("collider")
	if collider is Area3D:
		var parent: Node = (collider as Area3D).get_parent()
		if parent.is_in_group("foundations"):
			return parent as Node3D
	return null

func _get_ship_at(screen_pos: Vector2) -> Node3D:
	var camera := get_viewport().get_camera_3d()
	var space := get_world_3d().direct_space_state
	var from := camera.project_ray_origin(screen_pos)
	var to := from + camera.project_ray_normal(screen_pos) * 1000.0
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = true
	query.collide_with_bodies = false
	var result := space.intersect_ray(query)
	if result.is_empty():
		return null
	var collider: Object = result.get("collider")
	if collider is Area3D:
		var parent: Node = (collider as Area3D).get_parent()
		if parent.is_in_group("ships"):
			return parent as Node3D
	return null

func _get_person_at(screen_pos: Vector2) -> Node3D:
	var camera := get_viewport().get_camera_3d()
	var space := get_world_3d().direct_space_state
	var from := camera.project_ray_origin(screen_pos)
	var to := from + camera.project_ray_normal(screen_pos) * 1000.0
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = true
	query.collide_with_bodies = false
	var result := space.intersect_ray(query)
	if result.is_empty():
		return null
	var collider: Object = result.get("collider")
	if collider is Area3D:
		var parent: Node = (collider as Area3D).get_parent()
		if parent.is_in_group("persons"):
			return parent as Node3D
	return null

func update_town_shader() -> void:
	var terrain = get_tree().get_first_node_in_group("heightmap_terrain")
	if terrain == null:
		return
	var mesh := terrain.get_node_or_null("MeshInstance3D") as MeshInstance3D
	if mesh == null:
		return
	var mat := mesh.material_override as ShaderMaterial
	if mat == null:
		return
	var positions := PackedVector2Array()
	var radii := PackedFloat32Array()
	var groups := ["capital", "buildings", "foundations"]
	for group in groups:
		for node in get_tree().get_nodes_in_group(group):
			var n3d := node as Node3D
			if n3d == null:
				continue
			var r = n3d.get("town_radius_contribution")
			if r == null or float(r) <= 0.0:
				continue
			positions.append(Vector2(n3d.global_position.x, n3d.global_position.z))
			radii.append(float(r))
	mat.set_shader_parameter("building_positions", positions)
	mat.set_shader_parameter("building_radii", radii)
	mat.set_shader_parameter("building_count", positions.size())

func _raycast_y0(screen_pos: Vector2) -> Vector3:
	var camera := get_viewport().get_camera_3d()
	var space := get_world_3d().direct_space_state
	var from := camera.project_ray_origin(screen_pos)
	var to := from + camera.project_ray_normal(screen_pos) * 1000.0
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 2
	query.collide_with_bodies = true
	query.collide_with_areas = false
	var result := space.intersect_ray(query)
	return result.get("position", Vector3.INF)
