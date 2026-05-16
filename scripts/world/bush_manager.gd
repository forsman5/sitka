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
	var town_radius := _get_town_radius()
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
		var in_town := false
		for capital in get_tree().get_nodes_in_group("capital"):
			if is_instance_valid(capital) and (capital as Node3D).global_position.distance_to(candidate) < town_radius:
				in_town = true
				break
		if in_town:
			continue
		center = candidate
		found = true
		break
	if not found:
		return
	var count := randi_range(min_cluster_size, max_cluster_size)
	for _i in range(count):
		_attempt_bush_near(center, town_radius)

func _attempt_bush_near(center: Vector3, town_radius: float) -> void:
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
		for capital in get_tree().get_nodes_in_group("capital"):
			if is_instance_valid(capital) and (capital as Node3D).global_position.distance_to(pos) < town_radius:
				too_close = true
				break
		if too_close:
			continue
		var bush: Node3D = BushScene.instantiate() as Node3D
		get_parent().add_child(bush)
		bush.global_position = pos
		return

func _get_town_radius() -> float:
	var mesh := get_tree().current_scene.get_node_or_null(
		"NavigationRegion3D/Terrain/MeshInstance3D") as MeshInstance3D
	if mesh == null:
		return 0.0
	var mat := mesh.get_surface_override_material(0) as ShaderMaterial
	if mat == null:
		return 0.0
	return mat.get_shader_parameter("town_radius")
