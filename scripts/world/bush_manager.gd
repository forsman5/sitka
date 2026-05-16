extends Node

const BushScene = preload("res://scenes/entities/resource_node_food.tscn")

@export var mean_cluster_time: float = 32.0
@export var min_cluster_size: int = 3
@export var max_cluster_size: int = 5
@export var cluster_spread: float = 3.0
@export var min_bush_spacing: float = 2.5
@export var zone_center: Vector2 = Vector2(-60.0, -3.0)
@export var zone_radius: float = 70.0

func _ready() -> void:
	_spawn_loop()

func _spawn_loop() -> void:
	while is_inside_tree():
		var wait := randf_range(mean_cluster_time * 0.5, mean_cluster_time * 1.5)
		await get_tree().create_timer(wait).timeout
		if not is_inside_tree():
			break
		_attempt_cluster()

func _attempt_cluster() -> void:
	var center := Vector3.ZERO
	var found := false
	for _i in range(15):
		var angle := randf() * TAU
		var r := sqrt(randf()) * zone_radius
		var candidate := Vector3(
			zone_center.x + r * cos(angle),
			0.0,
			zone_center.y + r * sin(angle)
		)
		if absf(candidate.x) > 49.0 or absf(candidate.z) > 49.0:
			continue
		center = candidate
		found = true
		break
	if not found:
		return
	var count := randi_range(min_cluster_size, max_cluster_size)
	for _i in range(count):
		_attempt_bush_near(center)

func _attempt_bush_near(center: Vector3) -> void:
	for _i in range(10):
		var angle := randf() * TAU
		var r := randf() * cluster_spread
		var pos := Vector3(
			center.x + r * cos(angle),
			0.0,
			center.z + r * sin(angle)
		)
		if absf(pos.x) > 49.0 or absf(pos.z) > 49.0:
			continue
		var too_close := false
		for node in get_tree().get_nodes_in_group("resource_nodes"):
			if is_instance_valid(node) and (node as Node3D).global_position.distance_to(pos) < min_bush_spacing:
				too_close = true
				break
		if too_close:
			continue
		for building in get_tree().get_nodes_in_group("buildings"):
			if is_instance_valid(building) and (building as Node3D).global_position.distance_to(pos) < min_bush_spacing:
				too_close = true
				break
		if too_close:
			continue
		var bush: Node3D = BushScene.instantiate() as Node3D
		get_parent().add_child(bush)
		bush.global_position = pos
		return
