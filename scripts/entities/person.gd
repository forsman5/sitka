extends Node3D

const MOVE_SPEED := 5.0

var selected := false
var _target: Vector3

@onready var _mesh: MeshInstance3D = $MeshInstance3D
@onready var _area: Area3D = $Area3D

var _mat_normal: Material
var _mat_selected: StandardMaterial3D

func _ready() -> void:
	add_to_group("persons")
	_target = global_position
	_mat_normal = _mesh.get_surface_override_material(0)
	_mat_selected = StandardMaterial3D.new()
	_mat_selected.albedo_color = Color(1.0, 0.85, 0.0)
	_area.input_event.connect(_on_area_input)

func _process(delta: float) -> void:
	var flat_target := Vector3(_target.x, global_position.y, _target.z)
	if global_position.distance_to(flat_target) > 0.05:
		global_position = global_position.move_toward(flat_target, MOVE_SPEED * delta)

func move_to(world_pos: Vector3) -> void:
	_target = world_pos

func _on_area_input(_camera: Node, event: InputEvent, _pos: Vector3, _normal: Vector3, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		selected = !selected
		_mesh.set_surface_override_material(0, _mat_selected if selected else _mat_normal)
		get_viewport().set_input_as_handled()
