extends SceneTree

const VALLEY_SCENE := preload("res://scenes/valley/river_valley.tscn")
const RIBBON_CROSS_VERTICES := 5

var _failures: Array[String] = []

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var valley := VALLEY_SCENE.instantiate()
	root.add_child(valley)
	await process_frame
	await process_frame

	for node_name in ["MainRiverBank", "MainRiver", "TributaryBank", "Tributary", "AldfordConfluence", "RouteShoulder1", "Route1", "AldfordFord"]:
		_check_ribbon(valley, node_name)

	_check_water_cross_sections(valley.get_node("MainRiver") as MeshInstance3D)
	_check_water_cross_sections(valley.get_node("Tributary") as MeshInstance3D)
	_check_grounded_route(valley, valley.get_node("Route1") as MeshInstance3D, 0.14)
	_check_confluence(valley.get_node("MainRiver") as MeshInstance3D, valley.get_node("Tributary") as MeshInstance3D)

	if _failures.is_empty():
		print("PASS: landscape ribbons are continuous, grounded, and share the Aldford confluence")
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)

func _check_ribbon(valley: Node, node_name: String) -> void:
	var instance := valley.get_node_or_null(node_name) as MeshInstance3D
	_require(instance != null, "%s is missing" % node_name)
	if instance == null:
		return
	_require(instance.mesh is ArrayMesh, "%s must use continuous ArrayMesh geometry" % node_name)
	if instance.mesh is ArrayMesh:
		var vertices: PackedVector3Array = (instance.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		_require(vertices.size() >= 6, "%s has too few sampled vertices" % node_name)

func _check_water_cross_sections(instance: MeshInstance3D) -> void:
	var vertices: PackedVector3Array = (instance.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	for index in range(0, vertices.size(), RIBBON_CROSS_VERTICES):
		for cross_index in range(1, RIBBON_CROSS_VERTICES):
			if not is_equal_approx(vertices[index].y, vertices[index + cross_index].y):
				_failures.append("%s has a pitched water cross-section at sample %d" % [instance.name, index / RIBBON_CROSS_VERTICES])
				return

func _check_grounded_route(valley: Node, instance: MeshInstance3D, expected_offset: float) -> void:
	var vertices: PackedVector3Array = (instance.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	for vertex in vertices:
		var ground_height := float(valley.call("get_valley_ground_height", Vector2(vertex.x, vertex.z)))
		if absf(vertex.y - ground_height - expected_offset) > 0.015:
			_failures.append("%s leaves the terrain near (%0.1f, %0.1f)" % [instance.name, vertex.x, vertex.z])
			return

func _check_confluence(main_river: MeshInstance3D, tributary: MeshInstance3D) -> void:
	var main_center := _nearest_center_sample(main_river, Vector2(0.0, -5.0))
	var tributary_center := _nearest_center_sample(tributary, Vector2(0.0, -5.0))
	_require(Vector2(main_center.x, main_center.z).distance_to(Vector2(0.0, -5.0)) < 0.1, "main river misses the Aldford confluence")
	_require(Vector2(tributary_center.x, tributary_center.z).distance_to(Vector2(0.0, -5.0)) < 0.1, "tributary misses the Aldford confluence")
	_require(absf(main_center.y - tributary_center.y) < 0.015, "water surfaces disagree in height at the Aldford confluence")

func _nearest_center_sample(instance: MeshInstance3D, target: Vector2) -> Vector3:
	var vertices: PackedVector3Array = (instance.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var nearest := Vector3.INF
	var nearest_distance := INF
	for index in range(0, vertices.size(), RIBBON_CROSS_VERTICES):
		var center := vertices[index + int(RIBBON_CROSS_VERTICES / 2)]
		var distance := Vector2(center.x, center.z).distance_to(target)
		if distance < nearest_distance:
			nearest = center
			nearest_distance = distance
	return nearest

func _require(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
