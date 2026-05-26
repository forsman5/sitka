class_name Cow
extends CharacterBody3D

const WANDER_RADIUS_MIN := 5.0
const WANDER_RADIUS_MAX := 30.0
const GRAZE_DURATION_MIN := 3.0
const GRAZE_DURATION_MAX := 8.0
const GRAZE_RATE := 12.0
const SLEEP_TIME := 21.0 / 24.0
const WAKE_TIME := 5.5 / 24.0
const SLEEP_REACH := 3.5
const BARN_RANGE := 20.0

@export var move_speed: float = 2.5
@export var max_food: float = 100.0
@export var max_health: int = 5
var food: float = 50.0
var health: int = 5
var selected: bool = false
var _grazing: bool = false
var _sleeping: bool = false
var _assigned_sleep_point: Node3D = null
static var _night_assigned: bool = false

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

func take_damage(amount: int) -> void:
	health = maxi(health - amount, 0)
	if health <= 0:
		queue_free()

func set_selected(v: bool) -> void:
	selected = v
	_mesh.set_surface_override_material(0, _mat_selected if v else _mat_normal)

func objective_label() -> String:
	if _sleeping:
		return "sleeping"
	return "grazing" if _grazing else "wandering"

func _is_night_time() -> bool:
	return GameState.time_of_day >= SLEEP_TIME or GameState.time_of_day < WAKE_TIME

func _is_in_forest() -> bool:
	if _terrain == null:
		return false
	var cfg: MapConfig = _terrain.map_config
	return Vector2(global_position.x, global_position.z).distance_to(cfg.forest_center) < cfg.forest_radius

func _is_in_water() -> bool:
	if _terrain == null:
		return false
	return _terrain.is_water(global_position.x, global_position.z)

static func _assign_cow_beds() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var capacity: Dictionary = {}
	for node in tree.get_nodes_in_group("cow_sleep_point"):
		var cap: int = node.get_cow_bed_count() if node.has_method("get_cow_bed_count") else 0
		if cap > 0:
			capacity[node] = cap
	var cows: Array = []
	for node in tree.get_nodes_in_group("cows"):
		var c := node as Cow
		if c != null:
			c._assigned_sleep_point = null
			cows.append(c)
	var pairs: Array = []
	for cow in cows:
		for sp in capacity:
			pairs.append({"cow": cow, "sp": sp,
				"dist": cow.global_position.distance_to((sp as Node3D).global_position)})
	pairs.sort_custom(func(a, b): return a["dist"] < b["dist"])
	var assigned: Dictionary = {}
	for pair in pairs:
		var c: Cow = pair["cow"]
		var sp = pair["sp"]
		if assigned.has(c) or not capacity.has(sp) or pair["dist"] > BARN_RANGE:
			continue
		c._assigned_sleep_point = sp
		assigned[c] = true
		capacity[sp] -= 1
		if capacity[sp] <= 0:
			capacity.erase(sp)

func _do_sleep() -> void:
	if not Cow._night_assigned:
		Cow._assign_cow_beds()
		Cow._night_assigned = true
	_sleeping = true
	var sheltered := false
	if _assigned_sleep_point != null and is_instance_valid(_assigned_sleep_point):
		_nav_agent.target_desired_distance = SLEEP_REACH
		_nav_agent.set_target_position(_assigned_sleep_point.global_position)
		await get_tree().process_frame
		while is_inside_tree() and _is_night_time() and is_instance_valid(_assigned_sleep_point):
			var dist := global_position.distance_to(_assigned_sleep_point.global_position)
			if dist <= SLEEP_REACH:
				break
			if _nav_agent.is_navigation_finished() and dist <= SLEEP_REACH * 2.0:
				break
			await get_tree().process_frame
		visible = false
		while is_inside_tree() and _is_night_time():
			await get_tree().process_frame
		visible = true
		sheltered = true
	else:
		while is_inside_tree() and _is_night_time():
			await get_tree().process_frame
	if not sheltered:
		take_damage(1)
	if is_inside_tree() and food < 20.0:
		take_damage(1)
	if is_inside_tree() and sheltered:
		health = mini(health + 1, max_health)
	_sleeping = false
	_assigned_sleep_point = null
	Cow._night_assigned = false

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
		const WATER_MARGIN := 5.0
		if _terrain.is_water(cx, cz) \
				or _terrain.is_water(cx + WATER_MARGIN, cz) \
				or _terrain.is_water(cx - WATER_MARGIN, cz) \
				or _terrain.is_water(cx, cz + WATER_MARGIN) \
				or _terrain.is_water(cx, cz - WATER_MARGIN):
			continue
		return Vector3(cx, 0.0, cz)
	return global_position.move_toward(Vector3.ZERO, 15.0)

func _run_task_loop() -> void:
	while is_inside_tree():
		if _is_night_time():
			await _do_sleep()
		elif _is_in_water():
			await _flee_water()
		elif _is_in_forest():
			await _flee_forest()
		else:
			await _wander_then_graze()

func _wander_then_graze() -> void:
	var target := _pick_wander_target()
	_nav_agent.target_desired_distance = 1.0
	_nav_agent.set_target_position(target)
	while is_inside_tree() and not _is_in_forest() and not _is_in_water() and not _is_night_time():
		if _nav_agent.is_navigation_finished():
			break
		await get_tree().process_frame
	if not is_inside_tree() or _is_in_forest() or _is_in_water() or _is_night_time():
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
	while is_inside_tree() and _is_in_forest() and not _is_night_time():
		if _nav_agent.is_navigation_finished():
			break
		await get_tree().process_frame

func _flee_water() -> void:
	_nav_agent.set_target_position(Vector3.ZERO)
	while is_inside_tree() and _is_in_water() and not _is_night_time():
		if _nav_agent.is_navigation_finished():
			break
		await get_tree().process_frame
