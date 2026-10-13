class_name OnFootCompanion extends CharacterBody3D
## The character you are not playing as. A STAND companion (the human) just
## idles in place; a HEEL companion (the dog) trots after the player and keeps
## to their left rear.

enum Mode { STAND, HEEL }

const HUMAN := {
	"model": preload("res://assets/models/people/Casual_Male.fbx"),
	"model_scale": 0.54,
	"capsule_radius": 0.35,
	"capsule_height": 1.8,
	"anim": {"idle": "CharacterArmature|Idle", "walk": "CharacterArmature|Walk", "run": "CharacterArmature|Run"},
}
const DOG := {
	"model": preload("res://assets/models/animals/Husky.fbx"),
	"model_scale": 0.25,
	"capsule_radius": 0.3,
	"capsule_height": 0.8,
	"anim": {"idle": "AnimalArmature|Idle", "walk": "AnimalArmature|Walk", "run": "AnimalArmature|Gallop"},
}

## Heel spot in the player's local space (-X left, +Z behind).
const HEEL_OFFSET := Vector3(-1.1, 0.0, 1.0)
const HEEL_MAX_SPEED := 9.0
const RUN_SPEED := 4.5
## If the player gets this far away (e.g. fell out of the world and respawned), snap back.
const TELEPORT_DISTANCE := 25.0

var mode: int = Mode.STAND
var _data: Dictionary
var _model: Node3D
var _anim: AnimationPlayer
var _player: Node3D
var _gravity: float

func setup(as_human: bool, companion_mode: int) -> void:
	_data = HUMAN if as_human else DOG
	mode = companion_mode

func _ready() -> void:
	add_to_group("on_foot_companion")
	# The island terrain lives on layer 2.
	collision_mask = 1 | 2
	floor_snap_length = 0.5
	_gravity = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8) * 2.2

	var shape := CapsuleShape3D.new()
	shape.radius = _data["capsule_radius"]
	shape.height = _data["capsule_height"]
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position.y = shape.height * 0.5
	add_child(col)

	# Models face +Z at identity; turn them to face -Z like the player.
	_model = (_data["model"] as PackedScene).instantiate()
	_model.rotation_degrees = Vector3(0, 180, 0)
	_model.scale = Vector3.ONE * float(_data["model_scale"])
	add_child(_model)
	if _data == HUMAN:
		SkinTones.apply_random(_model)
	_anim = _model.get_node_or_null("AnimationPlayer") as AnimationPlayer
	_play("idle")

func _physics_process(delta: float) -> void:
	velocity.y = 0.0 if is_on_floor() else velocity.y - _gravity * delta
	if mode == Mode.HEEL:
		_heel(delta)
	else:
		velocity.x = 0.0
		velocity.z = 0.0
	move_and_slide()

func _heel(delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("on_foot_player") as Node3D
		if _player == null:
			return
	var spot := _player.global_transform * HEEL_OFFSET
	var to_spot := spot - global_position
	to_spot.y = 0.0
	var dist := to_spot.length()
	if dist > TELEPORT_DISTANCE:
		global_position = spot + Vector3(0, 0.5, 0)
		velocity = Vector3.ZERO
		return

	# Speed scales with the gap so the dog eases in at heel and sprints to catch up.
	var speed := clampf(dist * 3.0, 0.0, HEEL_MAX_SPEED) if dist > 0.2 else 0.0
	var target := to_spot.normalized() * speed
	var horiz := Vector3(velocity.x, 0.0, velocity.z).move_toward(target, 30.0 * delta)
	velocity.x = horiz.x
	velocity.z = horiz.z

	var moving := horiz.length() > 0.5
	# Face travel while moving; at heel, face the same way as the player.
	var yaw := atan2(-horiz.x, -horiz.z) if moving else _player.global_rotation.y
	rotation.y = lerp_angle(rotation.y, yaw, clampf(delta * 8.0, 0.0, 1.0))
	if horiz.length() > RUN_SPEED:
		_play("run")
	elif moving:
		_play("walk")
	else:
		_play("idle")

func _play(key: String) -> void:
	if _anim == null:
		return
	var clip: String = _data["anim"][key]
	if _anim.current_animation != clip:
		_anim.play(clip, 0.15)
