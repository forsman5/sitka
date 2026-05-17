class_name Ship
extends Node3D

@export var speed: float = 5.0

var selected: bool = false
var _move_target: Vector3 = Vector3.INF

@onready var _mesh: MeshInstance3D = $MeshInstance3D
var _mat_normal: Material
var _mat_selected: StandardMaterial3D

func _ready() -> void:
	add_to_group("ships")
	_mat_normal = _mesh.get_surface_override_material(0)
	_mat_selected = StandardMaterial3D.new()
	_mat_selected.albedo_color = Color(0.5, 0.85, 1.0, 1)

func set_selected(value: bool) -> void:
	selected = value
	_mesh.set_surface_override_material(0, _mat_selected if selected else _mat_normal)

func set_move_target(pos: Vector3) -> void:
	_move_target = Vector3(pos.x, 0.05, pos.z)

func objective_label() -> String:
	return "sailing" if _move_target != Vector3.INF else "idle"

func _process(delta: float) -> void:
	if _move_target == Vector3.INF:
		return
	var dir := _move_target - global_position
	dir.y = 0.0
	if dir.length() < 0.3:
		_move_target = Vector3.INF
		return
	var terrain = get_tree().get_first_node_in_group("heightmap_terrain")
	var next_pos := global_position + dir.normalized() * speed * GameState.game_speed * delta
	next_pos.y = 0.05
	if terrain == null or terrain.is_ocean_water(next_pos.x, next_pos.z):
		global_position = next_pos
	else:
		_move_target = Vector3.INF
