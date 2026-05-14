class_name Person
extends CharacterBody3D

const MOVE_SPEED := 5.0
const REACH := 2.0
const ResourceNode = preload("res://scripts/entities/resource_node.gd")

@export var carry_capacity: float = 10.0

var selected := false
var inventory: Array = []
var _target: Vector3
var _objective_node: Node3D = null

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
	_run_task_loop()

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

func set_objective(node: Node3D) -> void:
	_objective_node = node

func current_weight() -> float:
	var total := 0.0
	for item in inventory:
		total += item.weight
	return total

func can_carry(items: Array) -> bool:
	var added := 0.0
	for item in items:
		added += item.weight
	return current_weight() + added <= carry_capacity

func _is_carry_full() -> bool:
	return current_weight() >= carry_capacity

func objective_label() -> String:
	if _objective_node == null or not is_instance_valid(_objective_node):
		return "idle"
	return "mining " + _objective_node.name

func _run_task_loop() -> void:
	while true:
		var node: Node3D = _objective_node
		if node != null and is_instance_valid(node) and not _is_carry_full():
			await _do_harvest(node)
		else:
			await get_tree().process_frame

func _do_harvest(node: Node3D) -> void:
	var resource: ResourceNode = node as ResourceNode
	if resource == null:
		_objective_node = null
		return
	while _objective_node == node and is_instance_valid(node) and not _is_carry_full():
		move_to(node.global_position)
		await _wait_until_near(node)
		if _objective_node != node or not is_instance_valid(node):
			break
		var items: Array = await resource.mine()
		for item in items:
			inventory.append(item)

func _wait_until_near(node: Node3D) -> void:
	while is_instance_valid(node) and global_position.distance_to(node.global_position) > REACH:
		await get_tree().process_frame
