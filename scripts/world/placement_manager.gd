extends Node

const BuildingScene = preload("res://scenes/entities/building/capital.tscn")
const PersonScene = preload("res://scenes/entities/person.tscn")
const CowScene = preload("res://scenes/entities/cow.tscn")

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
		var island := get_parent()
		for i in 3:
			var person: Node3D = PersonScene.instantiate()
			person.name = "Person%d" % (i + 1)
			island.add_child(person)
			var angle := (i * TAU / 3.0) + randf_range(-0.3, 0.3)
			person.global_position = pos + Vector3(cos(angle) * 4.0, 0.0, sin(angle) * 4.0)
		for i in 2:
			var cow: Node3D = CowScene.instantiate()
			cow.name = "Cow%d" % (i + 1)
			island.add_child(cow)
			var angle := i * PI + randf_range(-0.5, 0.5)
			cow.global_position = pos + Vector3(cos(angle) * 8.0, 0.0, sin(angle) * 8.0)
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
