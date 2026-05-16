class_name Person
extends CharacterBody3D

@export var move_speed: float = 5.0
const REACH := 2.0
const DEPOSIT_REACH := 3.5
const SLEEP_TIME := 21.0 / 24.0
const WAKE_TIME := 5.5 / 24.0
const ResourceNode = preload("res://scripts/entities/resource_node.gd")
const Building = preload("res://scripts/entities/building/building.gd")

@export var carry_capacity: float = 10.0
@export var max_health: int = 10
var health: int = 10

var selected := false
var inventory: Array = []
var _objective_node: Node3D = null
var _last_resource_type: int = -1
var _move_target: Vector3 = Vector3.INF
var _deposit_queued: bool = false
var _sleeping: bool = false
var _camping: bool = false
var _assigned_sleep_point: Node3D = null

static var _night_assigned: bool = false

@onready var _mesh: MeshInstance3D = $MeshInstance3D
@onready var _nav_agent: NavigationAgent3D = $NavigationAgent3D

var _mat_normal: Material
var _mat_selected: StandardMaterial3D

func _ready() -> void:
	add_to_group("persons")
	motion_mode = MOTION_MODE_FLOATING
	_mat_normal = _mesh.get_surface_override_material(0)
	_mat_selected = StandardMaterial3D.new()
	_mat_selected.albedo_color = Color(1.0, 0.85, 0.0)
	_nav_agent.target_desired_distance = 1.0
	_nav_agent.velocity_computed.connect(_on_velocity_computed)
	_run_task_loop()

func _physics_process(_delta: float) -> void:
	if _nav_agent.is_navigation_finished():
		velocity = Vector3.ZERO
		move_and_slide()
		global_position.y = 0.0
		return
	var next_pos := _nav_agent.get_next_path_position()
	var dir := next_pos - global_position
	dir.y = 0.0
	var speed := move_speed * GameState.game_speed
	_nav_agent.max_speed = speed
	var desired := dir.normalized() * speed if dir.length() > 0.01 else Vector3.ZERO
	_nav_agent.set_velocity(desired)

func _on_velocity_computed(safe_velocity: Vector3) -> void:
	velocity = safe_velocity
	velocity.y = 0.0
	move_and_slide()
	global_position.y = 0.0

func move_to(world_pos: Vector3) -> void:
	_nav_agent.set_target_position(world_pos)

func set_selected(value: bool) -> void:
	selected = value
	_mesh.set_surface_override_material(0, _mat_selected if selected else _mat_normal)

func set_objective(node: Node3D) -> void:
	_objective_node = node
	_move_target = Vector3.INF
	var r := node as ResourceNode
	if r != null:
		_last_resource_type = r.resource_type

func set_move_objective(pos: Vector3) -> void:
	_move_target = pos
	_objective_node = null
	_deposit_queued = false

func set_deposit_objective() -> void:
	_deposit_queued = true
	_objective_node = null
	_move_target = Vector3.INF

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
	if _camping:
		return "camping"
	if _sleeping:
		return "sleeping"
	if _move_target != Vector3.INF:
		return "moving"
	if _deposit_queued:
		return "depositing"
	if _objective_node == null or not is_instance_valid(_objective_node):
		return "idle"
	var resource: ResourceNode = _objective_node as ResourceNode
	if resource == null:
		return "mining " + _objective_node.name
	match resource.resource_type:
		ResourceNode.Type.WOOD:  return "mine Wood"
		ResourceNode.Type.STONE: return "mine Stone"
		ResourceNode.Type.FOOD:  return "mine Food"
		ResourceNode.Type.GOLD:  return "mine Gold"
	return "mining"

func take_damage(amount: int) -> void:
	health = maxi(health - amount, 0)

func _is_carry_full() -> bool:
	return current_weight() >= carry_capacity

func _is_night_time() -> bool:
	return GameState.time_of_day >= SLEEP_TIME or GameState.time_of_day < WAKE_TIME

func _run_task_loop() -> void:
	while is_inside_tree():
		if _move_target != Vector3.INF:
			await _do_move(_move_target)
		elif _is_night_time():
			await _do_sleep()
		elif _deposit_queued or _is_carry_full():
			_deposit_queued = false
			await _do_deposit()
		elif _objective_node != null and is_instance_valid(_objective_node):
			await _do_harvest(_objective_node)
		elif _last_resource_type >= 0 and (_objective_node == null or not is_instance_valid(_objective_node)):
			_objective_node = _find_nearest_of_type(_last_resource_type as ResourceNode.Type)
			await get_tree().process_frame
		else:
			await get_tree().process_frame

func _do_move(pos: Vector3) -> void:
	_nav_agent.target_desired_distance = REACH
	move_to(pos)
	while _move_target == pos and global_position.distance_to(pos) > REACH and is_inside_tree():
		await get_tree().process_frame
	if _move_target == pos:
		_move_target = Vector3.INF

func _nearest_deposit_point() -> Node3D:
	var nearest: Node3D = null
	var nearest_dist := INF
	for node in get_tree().get_nodes_in_group("deposit_point"):
		var d := global_position.distance_to((node as Node3D).global_position)
		if d < nearest_dist:
			nearest_dist = d
			nearest = node as Node3D
	return nearest


func _do_deposit() -> void:
	var nearest := _nearest_deposit_point()
	if nearest == null:
		inventory.clear()
		return
	_nav_agent.target_desired_distance = DEPOSIT_REACH
	move_to(nearest.global_position)
	await _wait_until_near(nearest, DEPOSIT_REACH)
	if _move_target != Vector3.INF:
		return
	var building: Building = nearest as Building
	if building != null:
		for item in inventory:
			building.deposit(item)
	inventory.clear()
	_objective_node = null

static func _assign_beds() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var capacity: Dictionary = {}
	for node in tree.get_nodes_in_group("sleep_point"):
		var b := node as Building
		if b != null:
			var cap := b.get_bed_count()
			if cap > 0:
				capacity[b] = cap
	var persons: Array = []
	for node in tree.get_nodes_in_group("persons"):
		var p := node as Person
		if p != null:
			p._assigned_sleep_point = null
			persons.append(p)
	var pairs: Array = []
	for person in persons:
		for sp in capacity:
			var d: float = person.global_position.distance_to((sp as Node3D).global_position)
			pairs.append({"person": person, "sp": sp, "dist": d})
	pairs.sort_custom(func(a, b): return a["dist"] < b["dist"])
	var assigned: Dictionary = {}
	for pair in pairs:
		var p: Person = pair["person"]
		var sp = pair["sp"]
		if assigned.has(p) or not capacity.has(sp):
			continue
		p._assigned_sleep_point = sp
		assigned[p] = true
		capacity[sp] -= 1
		if capacity[sp] <= 0:
			capacity.erase(sp)

func _do_sleep() -> void:
	if not Person._night_assigned:
		Person._assign_beds()
		Person._night_assigned = true
	_sleeping = true
	if _assigned_sleep_point != null:
		_nav_agent.target_desired_distance = DEPOSIT_REACH
		move_to(_assigned_sleep_point.global_position)
		await _wait_until_near(_assigned_sleep_point, DEPOSIT_REACH)
		var building: Building = _assigned_sleep_point as Building
		if building != null:
			for item in inventory:
				building.deposit(item)
		inventory.clear()
		visible = false
		while is_inside_tree() and _is_night_time():
			await get_tree().process_frame
		visible = true
	else:
		_camping = true
		take_damage(2)
		while is_inside_tree() and _is_night_time():
			await get_tree().process_frame
		_camping = false
	_sleeping = false
	_assigned_sleep_point = null
	Person._night_assigned = false

func _do_harvest(node: Node3D) -> void:
	var resource: ResourceNode = node as ResourceNode
	if resource == null:
		_objective_node = null
		return
	var res_type := resource.resource_type
	_nav_agent.target_desired_distance = 1.0
	while _objective_node == node and is_instance_valid(node) and not _is_carry_full() and not _is_night_time():
		move_to(node.global_position)
		await _wait_until_near(node)
		if _objective_node != node or not is_instance_valid(node) or _move_target != Vector3.INF or _is_night_time():
			break
		await get_tree().create_timer(resource.wait_time / (GameState.gather_speed * GameState.game_speed)).timeout
		if not is_instance_valid(node) or _objective_node != node or _move_target != Vector3.INF or _is_night_time():
			break
		var items := resource.mine_sync()
		for item in items:
			inventory.append(item)
	if not is_instance_valid(node) and not _is_carry_full() and not is_instance_valid(_objective_node):
		_objective_node = _find_nearest_of_type(res_type)

func _find_nearest_of_type(type: ResourceNode.Type) -> Node3D:
	var nearest: Node3D = null
	var nearest_dist := INF
	for n in get_tree().get_nodes_in_group("resource_nodes"):
		if not is_instance_valid(n):
			continue
		var r: ResourceNode = n as ResourceNode
		if r == null or r.resource_type != type:
			continue
		var d := global_position.distance_to(r.global_position)
		if d < nearest_dist:
			nearest_dist = d
			nearest = n as Node3D
	return nearest

func _wait_until_near(node: Node3D, reach: float = REACH) -> void:
	if not is_inside_tree():
		return
	await get_tree().process_frame
	while is_instance_valid(node) and is_inside_tree():
		var dist := global_position.distance_to(node.global_position)
		if dist <= reach:
			return
		if _move_target != Vector3.INF:
			return
		if _nav_agent.is_navigation_finished() and dist <= reach * 2.0:
			return
		await get_tree().process_frame
