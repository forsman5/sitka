extends Node3D

const DRAG_THRESHOLD := 6.0

var _drag_start := Vector2.ZERO
var _dragging := false

@onready var _selection_box: Panel = $SelectionUI/SelectionBox
@onready var _nav_region: NavigationRegion3D = $NavigationRegion3D

func _ready() -> void:
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
		if not shift:
			_deselect_all()
		person.set_selected(true)
		return
	var building := _get_building_at(screen_pos)
	if building != null:
		_deselect_all()
		_deselect_all_resources()
		_deselect_all_buildings()
		building.set_selected(true)
		return
	var resource := _get_resource_at(screen_pos)
	if resource != null:
		_deselect_all()
		_deselect_all_buildings()
		_deselect_all_resources()
		resource.set_selected(true)
		return
	if not shift:
		_deselect_all()
		_deselect_all_buildings()
		_deselect_all_resources()

func _finish_box_select(end_pos: Vector2) -> void:
	var shift := Input.is_key_pressed(KEY_SHIFT)
	var rect := Rect2(_drag_start, end_pos - _drag_start).abs()
	_deselect_all_buildings()
	_deselect_all_resources()
	if not shift:
		_deselect_all()
	var camera := get_viewport().get_camera_3d()
	for person: Node3D in get_tree().get_nodes_in_group("persons"):
		var screen_pos := camera.unproject_position(person.global_position + Vector3(0, 0.9, 0))
		if rect.has_point(screen_pos):
			person.set_selected(true)

func _update_selection_box(current_pos: Vector2) -> void:
	_selection_box.visible = true
	var abs_rect := Rect2(_drag_start, current_pos - _drag_start).abs()
	_selection_box.position = abs_rect.position
	_selection_box.size = abs_rect.size

func _deselect_all() -> void:
	for p: Node3D in get_tree().get_nodes_in_group("persons"):
		p.set_selected(false)

func _deselect_all_buildings() -> void:
	for b: Node3D in get_tree().get_nodes_in_group("buildings"):
		b.set_selected(false)

func _deselect_all_resources() -> void:
	for r: Node3D in get_tree().get_nodes_in_group("resource_nodes"):
		r.set_selected(false)

func _any_selected() -> bool:
	for p: Node3D in get_tree().get_nodes_in_group("persons"):
		if p.selected:
			return true
	return false

func _handle_right_click(screen_pos: Vector2) -> void:
	if not _any_selected():
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

func _raycast_y0(screen_pos: Vector2) -> Vector3:
	var camera := get_viewport().get_camera_3d()
	var origin := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	if absf(dir.y) < 0.0001:
		return Vector3.INF
	var t := -origin.y / dir.y
	if t < 0.0:
		return Vector3.INF
	return origin + dir * t
