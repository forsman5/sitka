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
## A bark inside the player's bark radius keeps a sheep running for this long
## (seconds, min..max), even once it is outside the normal scare radius.
@export var startle_time_min: float = 2.0
@export var startle_time_max: float = 2.5
## A bark makes a calm sheep hop straight up before it bolts.
@export var react_time: float = 0.4
@export var react_hop_height: float = 0.6
## Each sheep waits a random beat (seconds, min..max) after a bark before hopping.
@export var react_delay_min: float = 0.0
@export var react_delay_max: float = 0.18
## Chance that a sheep already running still gets spooked into a hop by a bark.
@export_range(0.0, 1.0) var running_react_chance: float = 0.1

## True once the pen has claimed this sheep; it then ignores the player.
var penned: bool = false
var _slot_pos := Vector3.ZERO
var _slot_yaw: float = 0.0
var _pen_walk_left: float = 0.0
var _frozen: bool = false

var _model: Node3D
var _anim: AnimationPlayer
var _player: Node3D
var _terrain: Node = null
var _gravity: float
var _wander_dir := Vector3.ZERO
var _state_left: float = 0.0
var _grazing: bool = true
var _fleeing: bool = false
var _startled_left: float = 0.0
var _react_left: float = 0.0
var _react_delay_left: float = 0.0
var _listening_to: Node = null
var _bob_t: float = randf() * TAU

func _ready() -> void:
	add_to_group("on_foot_sheep")
	collision_mask = 1 | 2  # World objects plus the island terrain (layer 2).
	_terrain = get_tree().get_first_node_in_group("heightmap_terrain")
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

## Called by the pen when this sheep enters: walk to the slot, then stand still.
func pen_in(slot_pos: Vector3, yaw: float) -> void:
	penned = true
	_slot_pos = slot_pos
	_slot_yaw = yaw
	_pen_walk_left = 8.0

func _penned_step(delta: float) -> void:
	if _frozen:
		return
	var to_slot := _slot_pos - global_position
	to_slot.y = 0.0
	_pen_walk_left -= delta
	if to_slot.length() < 0.15 or _pen_walk_left <= 0.0:
		# Arrived (or crowded out for too long): lock in place, stop animating.
		_frozen = true
		velocity = Vector3.ZERO
		global_position = Vector3(_slot_pos.x, global_position.y, _slot_pos.z)
		rotation.y = _slot_yaw
		_model.position.y = 0.0
		_model.rotation.z = 0.0
		if _anim != null:
			_anim.pause()
		return
	var horiz := Vector3(velocity.x, 0.0, velocity.z).move_toward(to_slot.normalized() * wander_speed, accel * delta)
	velocity.x = horiz.x
	velocity.z = horiz.z
	velocity.y = 0.0 if is_on_floor() else velocity.y - _gravity * delta
	move_and_slide()
	_face_and_animate(delta, horiz)

func _physics_process(delta: float) -> void:
	if penned:
		_penned_step(delta)
		return
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("on_foot_player") as Node3D
	if _player != null and _listening_to != _player and _player.has_signal("barked"):
		_player.connect("barked", _on_player_barked)
		_listening_to = _player
	_startled_left = maxf(_startled_left - delta, 0.0)
	if _react_delay_left > 0.0:
		_react_delay_left -= delta
		if _react_delay_left <= 0.0:
			_react_left = react_time
	if _react_delay_left > 0.0 or _react_left > 0.0:
		_react_step(delta)
		return

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

	if desired != Vector3.ZERO:
		desired = _avoid_water(desired)
		if desired == Vector3.ZERO:
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

## Sheep won't walk into the sea or pond: if the way ahead is water, swing
## toward the nearest dry heading (or stop if boxed in).
func _avoid_water(dir: Vector3) -> Vector3:
	if _terrain == null:
		return dir
	const MIN_LAND_HEIGHT := 0.6
	for deg in [0.0, 40.0, -40.0, 80.0, -80.0, 130.0, -130.0]:
		var d := dir.rotated(Vector3.UP, deg_to_rad(deg))
		var ahead := global_position + d * 2.0
		if _terrain.get_height(ahead.x, ahead.z) >= MIN_LAND_HEIGHT:
			return d
	return Vector3.ZERO

## The player barked: sheep within the bark radius bolt for a few seconds.
func _on_player_barked(bark_pos: Vector3) -> void:
	if penned or _player == null or not _player.has_method("bark_radius"):
		return
	var off := global_position - bark_pos
	off.y = 0.0
	if off.length() <= _player.call("bark_radius"):
		var calm := _startled_left <= 0.0 and not _fleeing
		_startled_left = randf_range(startle_time_min, startle_time_max)
		if calm or randf() < running_react_chance:
			_react_delay_left = maxf(randf_range(react_delay_min, react_delay_max), 0.001)

## Startle hop: stand still and jump straight up, then bolt (the bark's startle
## timer is already set, so the flee starts as soon as we land).
func _react_step(delta: float) -> void:
	_react_left = maxf(_react_left - delta, 0.0)
	var t := 1.0 - _react_left / react_time
	_model.position.y = sin(t * PI) * react_hop_height
	_model.rotation.z = 0.0
	var horiz := Vector3(velocity.x, 0.0, velocity.z).move_toward(Vector3.ZERO, accel * delta)
	velocity.x = horiz.x
	velocity.z = horiz.z
	velocity.y = 0.0 if is_on_floor() else velocity.y - _gravity * delta
	move_and_slide()

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
	if dist > trigger and _startled_left <= 0.0:
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
