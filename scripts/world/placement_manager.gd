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
	var building: Node3D = BuildingScene.instantiate() as Node3D
	get_parent().add_child(building)
	building.global_position = pos
	_update_town_biome(pos)
	for p in get_tree().get_nodes_in_group("persons"):
		(p as Node3D).show()
	queue_free()

func _update_town_biome(pos: Vector3) -> void:
	var mesh := get_parent().get_node("NavigationRegion3D/Terrain/MeshInstance3D") as MeshInstance3D
	if mesh == null:
		return
	var mat := mesh.get_surface_override_material(0) as ShaderMaterial
	if mat == null:
		return
	mat.set_shader_parameter("capital_pos", Vector2(pos.x, pos.z))

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
