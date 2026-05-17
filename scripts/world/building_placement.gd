extends Node

var _armed: bool = false
var _scene: PackedScene = null
var _wood_cost: int = 0

@onready var _hint_label: Label = $HintUI/HintLabel

func _ready() -> void:
	add_to_group("building_placement")

func arm(scene: PackedScene, wood_cost: int) -> void:
	_scene = scene
	_wood_cost = wood_cost
	_armed = true
	_hint_label.visible = true

func _disarm() -> void:
	_armed = false
	_hint_label.visible = false

func _input(event: InputEvent) -> void:
	if not _armed:
		return
	if event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed and not event.is_echo():
		_disarm()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		var pos := _raycast_y0(event.position)
		if pos != Vector3.INF:
			_place(pos)
			get_viewport().set_input_as_handled()

func _place(pos: Vector3) -> void:
	if GameState.player_wood < _wood_cost:
		_disarm()
		return
	GameState.player_wood -= _wood_cost
	var instance: Node3D = _scene.instantiate() as Node3D
	if instance.has_method("build_sync"):
		get_tree().current_scene.add_child(instance)
		instance.global_position = pos
	else:
		var nav_region := get_tree().current_scene.get_node("NavigationRegion3D") as Node
		var terrain = get_tree().get_first_node_in_group("heightmap_terrain")
		if terrain != null:
			terrain.prepare_for_bake()
		nav_region.add_child(instance)
		instance.global_position = pos
		nav_region.bake_finished.connect(func():
			if terrain != null and is_instance_valid(terrain):
				terrain.restore_visual()
		, CONNECT_ONE_SHOT)
		nav_region.bake_navigation_mesh()
	get_tree().current_scene.update_town_shader()
	_disarm()

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
