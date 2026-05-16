extends Node

const TreeScene = preload("res://scenes/entities/resource_node_wood.tscn")

@export var mean_spawn_time: float = 3.0
@export var min_tree_spacing: float = 4.0
@export var forest_center: Vector2 = Vector2(-60.0, -3.0)
@export var forest_radius: float = 50.0

func _ready() -> void:
	_spawn_loop()

func _spawn_loop() -> void:
	while is_inside_tree():
		var wait := randf_range(mean_spawn_time * 0.5, mean_spawn_time * 2.0)
		await get_tree().create_timer(wait).timeout
		if not is_inside_tree():
			break
		_attempt_spawn()

func _attempt_spawn() -> void:
	for _i in range(10):
		var angle := randf() * TAU
		var r := sqrt(randf()) * forest_radius
		var pos := Vector3(
			forest_center.x + r * cos(angle),
			0.0,
			forest_center.y + r * sin(angle)
		)
		if absf(pos.x) > 49.0 or absf(pos.z) > 49.0:
			continue
		var too_close := false
		for node in get_tree().get_nodes_in_group("resource_nodes"):
			if is_instance_valid(node) and (node as Node3D).global_position.distance_to(pos) < min_tree_spacing:
				too_close = true
				break
		if too_close:
			continue
		for building in get_tree().get_nodes_in_group("buildings"):
			if is_instance_valid(building) and (building as Node3D).global_position.distance_to(pos) < min_tree_spacing:
				too_close = true
				break
		if too_close:
			continue
		var tree: Node3D = TreeScene.instantiate() as Node3D
		get_parent().add_child(tree)
		tree.global_position = pos
		return
