extends CharacterBody3D

const MOVE_SPEED := 5.0

var selected := false
var _target: Vector3

@onready var _mesh: MeshInstance3D = $MeshInstance3D

var _mat_normal: Material
var _mat_selected: StandardMaterial3D

func _ready() -> void:
	add_to_group("persons")
	_target = global_position
	motion_mode = MOTION_MODE_FLOATING
	_mat_normal = _mesh.get_surface_override_material(0)
	_mat_selected = StandardMaterial3D.new()
	_mat_selected.albedo_color = Color(1.0, 0.85, 0.0)

func _physics_process(_delta: float) -> void:
	var dir := _target - global_position
	dir.y = 0.0
	if dir.length() > 0.1:
		velocity = dir.normalized() * MOVE_SPEED
	else:
		velocity = Vector3.ZERO
	move_and_slide()
	global_position.y = 0.0

func move_to(world_pos: Vector3) -> void:
	_target = world_pos

func set_selected(value: bool) -> void:
	selected = value
	_mesh.set_surface_override_material(0, _mat_selected if selected else _mat_normal)
