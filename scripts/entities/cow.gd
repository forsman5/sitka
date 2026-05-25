class_name Cow
extends CharacterBody3D

const WANDER_RADIUS_MIN := 5.0
const WANDER_RADIUS_MAX := 30.0
const GRAZE_DURATION_MIN := 3.0
const GRAZE_DURATION_MAX := 8.0
const GRAZE_RATE := 12.0

@export var move_speed: float = 2.5
@export var max_food: float = 100.0
var food: float = 50.0
var selected: bool = false
var _grazing: bool = false

@onready var _mesh: MeshInstance3D = $MeshInstance3D
@onready var _nav_agent: NavigationAgent3D = $NavigationAgent3D
var _terrain: Node = null
var _mat_normal: Material
var _mat_selected: StandardMaterial3D

func _ready() -> void:
	add_to_group("cows")
	motion_mode = MOTION_MODE_FLOATING
	var p := get_parent()
	while p != null:
		if p is Island:
			_terrain = p.get_node_or_null("NavigationRegion3D/HeightmapTerrain")
			break
		p = p.get_parent()
	_mat_normal = _mesh.get_surface_override_material(0)
	_mat_selected = StandardMaterial3D.new()
	_mat_selected.albedo_color = Color(1.0, 0.85, 0.0)
	_nav_agent.velocity_computed.connect(_on_velocity_computed)
	_run_task_loop()

func _physics_process(_delta: float) -> void:
	if _nav_agent.is_navigation_finished():
		velocity = Vector3.ZERO
		move_and_slide()
		if _terrain != null:
			global_position.y = _terrain.get_height(global_position.x, global_position.z)
		return
	var next := _nav_agent.get_next_path_position()
	var dir := next - global_position
	dir.y = 0.0
	var speed := move_speed * GameState.game_speed
	_nav_agent.max_speed = speed
	_nav_agent.set_velocity(dir.normalized() * speed if dir.length() > 0.01 else Vector3.ZERO)

func _on_velocity_computed(safe_vel: Vector3) -> void:
	velocity = safe_vel
	velocity.y = 0.0
	move_and_slide()
	if _terrain != null:
		global_position.y = _terrain.get_height(global_position.x, global_position.z)

func _process(delta: float) -> void:
	if _grazing:
		food = minf(food + GRAZE_RATE * GameState.game_speed * delta, max_food)

func set_selected(v: bool) -> void:
	selected = v
	_mesh.set_surface_override_material(0, _mat_selected if v else _mat_normal)

func objective_label() -> String:
	return "grazing" if _grazing else "wandering"

func _is_in_forest() -> bool:
	if _terrain == null:
		return false
	var cfg: MapConfig = _terrain.map_config
	return Vector2(global_position.x, global_position.z).distance_to(cfg.forest_center) < cfg.forest_radius

func _pick_wander_target() -> Vector3:
	if _terrain == null:
		return global_position
	var cfg: MapConfig = _terrain.map_config
	var half := cfg.world_size * 0.5
	for _i in range(10):
		var angle := randf() * TAU
		var r := randf_range(WANDER_RADIUS_MIN, WANDER_RADIUS_MAX)
		var cx := clampf(global_position.x + r * cos(angle), -half + 5.0, half - 5.0)
		var cz := clampf(global_position.z + r * sin(angle), -half + 5.0, half - 5.0)
		if Vector2(cx, cz).distance_to(cfg.forest_center) < cfg.forest_radius:
			continue
		if _terrain.is_ocean_water(cx, cz):
			continue
		return Vector3(cx, 0.0, cz)
	return global_position.move_toward(Vector3.ZERO, 15.0)

func _run_task_loop() -> void:
	while is_inside_tree():
		if _is_in_forest():
			await _flee_forest()
		else:
			await _wander_then_graze()

func _wander_then_graze() -> void:
	var target := _pick_wander_target()
	_nav_agent.target_desired_distance = 1.0
	_nav_agent.set_target_position(target)
	while is_inside_tree() and not _is_in_forest():
		if _nav_agent.is_navigation_finished():
			break
		await get_tree().process_frame
	if not is_inside_tree() or _is_in_forest():
		return
	_grazing = true
	await get_tree().create_timer(
		randf_range(GRAZE_DURATION_MIN, GRAZE_DURATION_MAX) / GameState.game_speed
	).timeout
	_grazing = false

func _flee_forest() -> void:
	if _terrain == null:
		await get_tree().process_frame
		return
	var cfg: MapConfig = _terrain.map_config
	var dir := Vector2(global_position.x, global_position.z) - cfg.forest_center
	if dir.length() < 0.01:
		dir = Vector2(1.0, 0.0)
	dir = dir.normalized()
	var exit := cfg.forest_center + dir * (cfg.forest_radius + 10.0)
	_nav_agent.set_target_position(Vector3(exit.x, 0.0, exit.y))
	while is_inside_tree() and _is_in_forest():
		if _nav_agent.is_navigation_finished():
			break
		await get_tree().process_frame
