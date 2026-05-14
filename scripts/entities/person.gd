class_name Person
extends CharacterBody3D

const MOVE_SPEED := 5.0
const REACH := 2.0
const DEPOSIT_REACH := 3.5
const ResourceNode = preload("res://scripts/entities/resource_node.gd")
const Building = preload("res://scripts/entities/building.gd")

@export var carry_capacity: float = 10.0

var selected := false
var inventory: Array = []
var _target: Vector3
var _objective_node: Node3D = null
var _move_target: Vector3 = Vector3.INF

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
	_move_target = Vector3.INF

func set_move_objective(pos: Vector3) -> void:
	_move_target = pos
	_objective_node = null

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

func objective_label() -> String:
	if _move_target != Vector3.INF:
		return "moving"
	if _objective_node == null or not is_instance_valid(_objective_node):
		return "idle"
	return "mining " + _objective_node.name

func _is_carry_full() -> bool:
	return current_weight() >= carry_capacity

func _run_task_loop() -> void:
	while true:
		if _move_target != Vector3.INF:
			await _do_move(_move_target)
		elif _is_carry_full():
			await _do_deposit()
		elif _objective_node != null and is_instance_valid(_objective_node):
			await _do_harvest(_objective_node)
		else:
			await get_tree().process_frame

func _do_move(pos: Vector3) -> void:
	move_to(pos)
	while _move_target == pos and global_position.distance_to(pos) > REACH:
		await get_tree().process_frame
	if _move_target == pos:
		_move_target = Vector3.INF

func _do_deposit() -> void:
	var capital: Node = get_tree().get_first_node_in_group("capital")
	if capital == null:
		inventory.clear()
		return
	var capital_3d: Node3D = capital as Node3D
	if capital_3d == null:
		inventory.clear()
		return
	move_to(capital_3d.global_position)
	await _wait_until_near(capital_3d, DEPOSIT_REACH)
	if _move_target != Vector3.INF:
		return
	var building: Building = capital as Building
	if building != null:
		for item in inventory:
			building.deposit(item)
	inventory.clear()

func _do_harvest(node: Node3D) -> void:
	var resource: ResourceNode = node as ResourceNode
	if resource == null:
		_objective_node = null
		return
	while _objective_node == node and is_instance_valid(node) and not _is_carry_full():
		move_to(node.global_position)
		await _wait_until_near(node)
		if _objective_node != node or not is_instance_valid(node) or _move_target != Vector3.INF:
			break
		var items: Array = await resource.mine()
		for item in items:
			inventory.append(item)

func _wait_until_near(node: Node3D, reach: float = REACH) -> void:
	while is_instance_valid(node) and global_position.distance_to(node.global_position) > reach:
		if _move_target != Vector3.INF:
			return
		await get_tree().process_frame
