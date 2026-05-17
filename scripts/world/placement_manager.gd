extends Node

const BuildingScene = preload("res://scenes/entities/building/capital.tscn")

var _active: bool = true

func _input(event: InputEvent) -> void:
	if not _active:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		var pos := _raycast_y0(event.position)
		if pos != Vector3.INF:
			_place_capital(pos)
			get_viewport().set_input_as_handled()

func _place_capital(pos: Vector3) -> void:
	_active = false
	var nav_region := get_parent().get_node("NavigationRegion3D") as Node
	var building: Node3D = BuildingScene.instantiate() as Node3D
	nav_region.add_child(building)
	building.global_position = pos
	get_parent().update_town_shader()
	var terrain = get_tree().get_first_node_in_group("heightmap_terrain")
	if terrain != null:
		terrain.prepare_for_bake()
	nav_region.bake_finished.connect(func():
		if terrain != null and is_instance_valid(terrain):
			terrain.restore_visual()
		for p in get_tree().get_nodes_in_group("persons"):
			(p as Node3D).show()
		queue_free()
	, CONNECT_ONE_SHOT)
	nav_region.bake_navigation_mesh()

func _raycast_y0(screen_pos: Vector2) -> Vector3:
	var camera := get_viewport().get_camera_3d()
	var space := camera.get_world_3d().direct_space_state
	var from := camera.project_ray_origin(screen_pos)
	var to := from + camera.project_ray_normal(screen_pos) * 1000.0
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 2
	query.collide_with_bodies = true
	query.collide_with_areas = false
	var result := space.intersect_ray(query)
	return result.get("position", Vector3.INF)
