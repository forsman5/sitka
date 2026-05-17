extends Node

var _armed: bool = false
var _scene: PackedScene = null
var _wood_cost: int = 0
var _coast_mode: bool = false
var _last_coast_snap: Dictionary = {}
var _preview_node: MeshInstance3D = null
var _preview_mat: StandardMaterial3D = null

@onready var _hint_label: Label = $HintUI/HintLabel

func _ready() -> void:
	add_to_group("building_placement")

func arm(scene: PackedScene, wood_cost: int, coast_mode: bool = false) -> void:
	_scene = scene
	_wood_cost = wood_cost
	_armed = true
	_coast_mode = coast_mode
	_hint_label.visible = true
	if coast_mode:
		_ensure_preview()
		_preview_node.visible = true

func _disarm() -> void:
	_armed = false
	_coast_mode = false
	_hint_label.visible = false
	if _preview_node != null and is_instance_valid(_preview_node):
		_preview_node.visible = false

func _process(_delta: float) -> void:
	if not (_armed and _coast_mode):
		return
	var world_pos := _raycast_y0(get_viewport().get_mouse_position())
	if world_pos == Vector3.INF:
		_last_coast_snap = {}
		return
	_last_coast_snap = _compute_coast_snap(world_pos)
	var valid: bool = _last_coast_snap.get("valid", false)
	_preview_node.visible = true
	_preview_mat.albedo_color = Color(0.3, 0.9, 0.3, 0.5) if valid else Color(0.9, 0.3, 0.3, 0.5)
	if valid:
		_preview_node.global_position = _last_coast_snap["position"]
		_preview_node.rotation.y = _last_coast_snap["rotation_y"]

func _input(event: InputEvent) -> void:
	if not _armed:
		return
	if event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed and not event.is_echo():
		_disarm()
		get_viewport().set_input_as_handled()
		return
	if _coast_mode:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT \
				and event.pressed:
			if _last_coast_snap.get("valid", false):
				_place_coast()
			get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		var pos := _raycast_y0(event.position)
		if pos != Vector3.INF:
			_place(pos)
			get_viewport().set_input_as_handled()

func _place(pos: Vector3) -> void:
	if GameState.player_wood < _wood_cost:
		_disarm()
		return
	GameState.player_wood -= _wood_cost
	var instance: Node3D = _scene.instantiate() as Node3D
	if instance.has_method("build_sync"):
		get_tree().current_scene.add_child(instance)
		instance.global_position = pos
	else:
		var nav_region := get_tree().current_scene.get_node("NavigationRegion3D") as Node
		var terrain = get_tree().get_first_node_in_group("heightmap_terrain")
		if terrain != null:
			terrain.prepare_for_bake()
		nav_region.add_child(instance)
		instance.global_position = pos
		nav_region.bake_finished.connect(func():
			if terrain != null and is_instance_valid(terrain):
				terrain.restore_visual()
		, CONNECT_ONE_SHOT)
		nav_region.bake_navigation_mesh()
	get_tree().current_scene.update_town_shader()
	_disarm()

func _place_coast() -> void:
	if GameState.player_wood < _wood_cost:
		_disarm()
		return
	GameState.player_wood -= _wood_cost
	var instance: Node3D = _scene.instantiate() as Node3D
	get_tree().current_scene.add_child(instance)
	instance.global_position = _last_coast_snap["position"]
	instance.rotation.y = _last_coast_snap["rotation_y"]
	get_tree().current_scene.update_town_shader()
	_disarm()

func _raycast_y0(screen_pos: Vector2) -> Vector3:
	var camera := get_viewport().get_camera_3d()
	var space := camera.get_world_3d().direct_space_state
	var from := camera.project_ray_origin(screen_pos)
	var to := from + camera.project_ray_normal(screen_pos) * 1000.0
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 2
	query.collide_with_bodies = true
	query.collide_with_areas = false
	var result := space.intersect_ray(query)
	return result.get("position", Vector3.INF)

func _ensure_preview() -> void:
	if _preview_node != null and is_instance_valid(_preview_node):
		return
	_preview_node = MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(3.0, 0.3, 8.0)
	_preview_node.mesh = mesh
	_preview_mat = StandardMaterial3D.new()
	_preview_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_preview_mat.albedo_color = Color(0.3, 0.9, 0.3, 0.5)
	_preview_node.material_override = _preview_mat
	_preview_node.visible = false
	get_tree().current_scene.add_child(_preview_node)

func _compute_coast_snap(world_pos: Vector3) -> Dictionary:
	var terrain = get_tree().get_first_node_in_group("heightmap_terrain")
	if terrain == null:
		return {"valid": false}
	var cx := world_pos.x
	var cz := world_pos.z
	var step := 3.0
	var grad: Vector2 = Vector2(
		terrain.get_height(cx + step, cz) - terrain.get_height(cx - step, cz),
		terrain.get_height(cx, cz + step) - terrain.get_height(cx, cz - step)
	)
	if grad.length() < 0.05:
		return {"valid": false}
	grad = grad.normalized()
	var cross: Dictionary = _find_coast_crossing(terrain, Vector2(cx, cz), grad)
	if not cross["valid"]:
		return {"valid": false}
	var pt: Vector2 = cross["pt"]
	var h_land: float = terrain.get_height(pt.x + grad.x * 4.0, pt.y + grad.y * 4.0)
	var h_water: float = terrain.get_height(pt.x - grad.x * 4.0, pt.y - grad.y * 4.0)
	if h_land <= 0.0:
		return {"valid": false}
	if h_water >= 0.0:
		return {"valid": false}
	return {
		"valid": true,
		"position": Vector3(pt.x, maxf(terrain.get_height(pt.x, pt.y), 0.0), pt.y),
		"rotation_y": atan2(-grad.x, -grad.y)
	}

func _find_coast_crossing(terrain, origin: Vector2, inland_dir: Vector2) -> Dictionary:
	var h0: float = terrain.get_height(origin.x, origin.y)
	if absf(h0) < 0.15:
		return {"valid": true, "pt": origin}
	var scan_dir: Vector2 = -inland_dir if h0 > 0.0 else inland_dir
	var prev_pt: Vector2 = origin
	var prev_h: float = h0
	var pt: Vector2
	var h: float
	for i in range(1, 25):
		pt = origin + scan_dir * (i * 0.5)
		h = terrain.get_height(pt.x, pt.y)
		if (prev_h > 0.0 and h <= 0.0) or (prev_h <= 0.0 and h > 0.0):
			var t: float = prev_h / (prev_h - h)
			return {"valid": true, "pt": prev_pt.lerp(pt, t)}
		prev_pt = pt
		prev_h = h
	return {"valid": false}
