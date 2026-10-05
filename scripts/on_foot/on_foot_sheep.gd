class_name OnFootSheep extends CharacterBody3D
## Flock sheep for the On Foot plane. Grazes in place, drifts back toward the
## flock, and bolts away from the player once they come within the player's
## scare radius (larger for the dog). Standalone: no navmesh or terrain needed.

const MODEL_SCENE := preload("res://assets/models/animals/Sheep.fbx")

@export var wander_speed: float = 1.2
@export var flee_speed: float = 5.5
@export var turn_rate: float = 6.0
@export var accel: float = 14.0
@export var arena_half_size: float = 90.0

var _model: Node3D
var _anim: AnimationPlayer
var _player: Node3D
var _gravity: float
var _wander_dir := Vector3.ZERO
var _state_left: float = 0.0
var _grazing: bool = true
var _fleeing: bool = false
var _bob_t: float = randf() * TAU

func _ready() -> void:
	add_to_group("on_foot_sheep")
	_gravity = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)

	var shape := CapsuleShape3D.new()
	shape.radius = 0.32
	shape.height = 0.9
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position.y = shape.height * 0.5
	add_child(col)

	# Same placement as sheep.tscn: rotated so the model faces -Z.
	_model = MODEL_SCENE.instantiate()
	_model.rotation_degrees = Vector3(0, 180, 0)
	_model.scale = Vector3.ONE * 0.117
	add_child(_model)
	_anim = _model.get_node_or_null("AnimationPlayer") as AnimationPlayer
	if _anim != null:
		_anim.play("Armature|Idle")

	_state_left = randf_range(0.5, 4.0)

func _physics_process(delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("on_foot_player") as Node3D

	var desired := Vector3.ZERO
	var speed := wander_speed
	_fleeing = false

	var flee_dir := _flee_direction()
	if flee_dir != Vector3.ZERO:
		_fleeing = true
		desired = flee_dir
		speed = flee_speed
	else:
		_state_left -= delta
		if _state_left <= 0.0:
			_grazing = not _grazing
			_state_left = randf_range(2.0, 5.0) if _grazing else randf_range(1.5, 3.5)
			_wander_dir = _pick_wander_dir()
		if not _grazing:
			desired = _wander_dir
		else:
			speed = 0.0

	var target := desired * speed
	var horiz := Vector3(velocity.x, 0.0, velocity.z).move_toward(target, accel * delta)
	velocity.x = horiz.x
	velocity.z = horiz.z
	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y -= _gravity * delta

	move_and_slide()
	_face_and_animate(delta, horiz)

## Direction away from the player (blended away from the arena edge), or zero if
## the player is far enough away that this sheep is calm.
func _flee_direction() -> Vector3:
	if _player == null:
		return Vector3.ZERO
	var scare := 8.0
	if _player.has_method("scare_radius"):
		scare = _player.call("scare_radius")
	var away := global_position - _player.global_position
	away.y = 0.0
	var dist := away.length()
	# Hysteresis: once running, keep going a little past the trigger distance.
	var trigger := scare * (1.2 if _fleeing else 1.0)
	if dist > trigger:
		return Vector3.ZERO
	away = away.normalized() if dist > 0.01 else Vector3.FORWARD
	return (away + _edge_push() + _separation()).normalized()

## Gentle wander that keeps drifting back toward the rest of the flock.
func _pick_wander_dir() -> Vector3:
	var dir := Vector3.FORWARD.rotated(Vector3.UP, randf() * TAU)
	var mates := get_tree().get_nodes_in_group("on_foot_sheep")
	var center := Vector3.ZERO
	var n := 0
	for m in mates:
		if m != self:
			center += (m as Node3D).global_position
			n += 1
	if n > 0:
		var to_flock := center / n - global_position
		to_flock.y = 0.0
		if to_flock.length() > 5.0:
			dir = (dir + to_flock.normalized() * 1.5).normalized()
	return (dir + _edge_push() * 2.0).normalized()

func _edge_push() -> Vector3:
	var push := Vector3.ZERO
	var margin := 12.0
	var p := global_position
	if absf(p.x) > arena_half_size - margin:
		push.x = -signf(p.x)
	if absf(p.z) > arena_half_size - margin:
		push.z = -signf(p.z)
	return push

func _separation() -> Vector3:
	var push := Vector3.ZERO
	for m in get_tree().get_nodes_in_group("on_foot_sheep"):
		if m == self:
			continue
		var off: Vector3 = global_position - (m as Node3D).global_position
		off.y = 0.0
		var d := off.length()
		if d > 0.01 and d < 1.5:
			push += off / d * (1.5 - d)
	return push

func _face_and_animate(delta: float, horiz: Vector3) -> void:
	var speed := horiz.length()
	if speed > 0.2:
		var target_yaw := atan2(-horiz.x, -horiz.z)
		rotation.y = lerp_angle(rotation.y, target_yaw, clampf(delta * turn_rate, 0.0, 1.0))
	# The model only ships Idle and Jump clips, so fake a trot with a bob and sway.
	if speed > 0.2:
		_bob_t += delta * speed * (4.0 if _fleeing else 6.0)
		_model.position.y = absf(sin(_bob_t)) * (0.12 if _fleeing else 0.05)
		_model.rotation.z = sin(_bob_t) * 0.06
	else:
		_model.position.y = move_toward(_model.position.y, 0.0, delta)
		_model.rotation.z = move_toward(_model.rotation.z, 0.0, delta)
