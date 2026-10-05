class_name Sheep
extends CharacterBody3D

# TODO: this is a stub. Sheep currently just idle-wander forever; none of
# cow.gd's grazing/health/barn-sleep/night-safety behavior has been ported
# over yet. Follow-ups before sheep are a "real" entity:
#   - TODO: sleep at night / assign to a barn (cow.gd's _do_sleep + barn bed
#     assignment), currently sheep are awake and wandering 24/7.
#   - TODO: health/food like cow.gd (take_damage, starve if unfed).
#   - TODO: avoid the forest the way cow._pick_wander_target does; sheep
#     steer clear of water (see _pick_wander_target below) but will still
#     happily wander into the forest.
#   - TODO: no "Walk" animation exists on this model (Sheep.fbx only ships
#     "Armature|Idle" and "Armature|Jump") so movement currently just slides
#     the idle pose around instead of playing a walk cycle. Either find/buy
#     a sheep model with a walk clip, or fake one by blending Idle with a
#     bit of procedural bob.

const WANDER_RADIUS_MIN := 3.0
const WANDER_RADIUS_MAX := 12.0
const PAUSE_DURATION_MIN := 2.0
const PAUSE_DURATION_MAX := 6.0

@export var move_speed: float = 1.6

var selected: bool = false
var _terrain: Node = null

@onready var _mesh: MeshInstance3D = $MeshInstance3D
@onready var _nav_agent: NavigationAgent3D = $NavigationAgent3D
@onready var _anim: AnimationPlayer = $Model/AnimationPlayer

var _mat_normal: Material
var _mat_selected: StandardMaterial3D

func _ready() -> void:
	add_to_group("sheep")
	motion_mode = MOTION_MODE_FLOATING
	var p := get_parent()
	while p != null:
		if p is Island:
			_terrain = p.get_node_or_null("NavigationRegion3D/HeightmapTerrain")
			break
		p = p.get_parent()
	if _mesh.visible:
		_mat_normal = _mesh.get_surface_override_material(0)
	_mat_selected = StandardMaterial3D.new()
	_mat_selected.albedo_color = Color(1.0, 0.85, 0.0)
	_nav_agent.velocity_computed.connect(_on_velocity_computed)
	_anim.play("Armature|Idle")
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
	if velocity.length() > 0.05:
		look_at(global_position + velocity.normalized(), Vector3.UP)
	if _terrain != null:
		global_position.y = _terrain.get_height(global_position.x, global_position.z)

func set_selected(v: bool) -> void:
	selected = v
	if _mesh.visible:
		_mesh.set_surface_override_material(0, _mat_selected if v else _mat_normal)

func objective_label() -> String:
	return "wandering"

# TODO: stub loop -- just wander forever. No grazing, no sleep, no barn.
func _run_task_loop() -> void:
	while is_inside_tree():
		await _wander()

func _pick_wander_target() -> Vector3:
	if _terrain == null:
		return global_position
	# `is_water()` only trips below height 0, but the WaterPlane mesh sits
	# exactly at world Y=0 -- a beach point with height 0.0-1.0 reads as
	# "dry" to is_water() while visually sitting right at (or under) the
	# waterline. Require a real height margin above that, not just "not
	# technically water", so sheep don't camp out on that lip.
	const MIN_LAND_HEIGHT := 1.0
	for _i in range(10):
		var angle := randf() * TAU
		var r := randf_range(WANDER_RADIUS_MIN, WANDER_RADIUS_MAX)
		var cx := global_position.x + r * cos(angle)
		var cz := global_position.z + r * sin(angle)
		if _terrain.get_height(cx, cz) < MIN_LAND_HEIGHT:
			continue
		return Vector3(cx, 0.0, cz)
	return global_position.move_toward(Vector3.ZERO, 10.0)

func _wander() -> void:
	var target := _pick_wander_target()
	_nav_agent.target_desired_distance = 1.0
	_nav_agent.set_target_position(target)
	while is_inside_tree() and not _nav_agent.is_navigation_finished():
		await get_tree().process_frame
	if not is_inside_tree():
		return
	await get_tree().create_timer(
		randf_range(PAUSE_DURATION_MIN, PAUSE_DURATION_MAX) / GameState.game_speed
	).timeout
