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
	var building: Node3D = _scene.instantiate() as Node3D
	get_tree().current_scene.add_child(building)
	building.global_position = pos
	_disarm()

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
