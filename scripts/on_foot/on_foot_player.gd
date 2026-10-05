class_name OnFootPlayer extends CharacterBody3D
## Walker: WASD + mouse look, Space to jump, Shift to sprint, F5 cycles the
## camera (first person -> third person behind -> third person in front).
## Keys are read by physical keycode so no InputMap entries are needed.

@export var walk_speed: float = 5.0
@export var sprint_speed: float = 8.5
@export var ground_accel: float = 60.0
@export var ground_friction: float = 50.0
@export var air_accel: float = 12.0
@export var jump_height: float = 1.2
@export var gravity_scale: float = 2.2
@export var fall_gravity_mult: float = 1.35
@export var coyote_time: float = 0.1
@export var jump_buffer_time: float = 0.1
@export var mouse_sensitivity: float = 0.0022
@export var eye_height: float = 1.65
@export var bob_amount: float = 0.04
@export var bob_frequency: float = 2.2
@export var third_person_distance: float = 3.2

enum CameraMode { FIRST_PERSON, THIRD_BACK, THIRD_FRONT }

## Which character the next OnFootPlayer spawns as (set by the chooser scene).
static var selected_character: String = "person"

## Per-character body, camera and animation settings. Models face +Z at identity,
## so they are rotated half a turn to face the -Z movement direction.
const CHARACTERS := {
	"person": {
		"model": preload("res://assets/models/people/Casual_Male.fbx"),
		"model_scale": 0.54,
		"capsule_radius": 0.35,
		"capsule_height": 1.8,
		"eye_height": 1.65,
		"third_person_distance": 3.2,
		"walk_speed": 5.0,
		"sprint_speed": 8.5,
		"jump_height": 1.2,
		"anim": {
			"idle": "CharacterArmature|Idle",
			"walk": "CharacterArmature|Walk",
			"run": "CharacterArmature|Run",
			"jump": "CharacterArmature|Jump",
		},
	},
	"dog": {
		"model": preload("res://assets/models/animals/Husky.fbx"),
		"model_scale": 0.25,
		"capsule_radius": 0.3,
		"capsule_height": 0.8,
		"eye_height": 0.6,
		"third_person_distance": 2.2,
		"walk_speed": 3.5,
		"sprint_speed": 8.0,
		"jump_height": 0.9,
		"anim": {
			"idle": "AnimalArmature|Idle",
			"walk": "AnimalArmature|Walk",
			"run": "AnimalArmature|Gallop",
			"jump": "AnimalArmature|Gallop_Jump",
		},
	},
}

var _head: Node3D
var _arm: SpringArm3D
var _camera: Camera3D
var _model: Node3D
var _anim: AnimationPlayer
var _camera_mode: int = CameraMode.FIRST_PERSON
var _pitch: float = 0.0
var _coyote_left: float = 0.0
var _buffer_left: float = 0.0
var _bob_t: float = 0.0
var _was_on_floor: bool = true
var _land_dip: float = 0.0
var _gravity: float
var _character: Dictionary

func _ready() -> void:
	_character = CHARACTERS[selected_character]
	walk_speed = _character["walk_speed"]
	sprint_speed = _character["sprint_speed"]
	jump_height = _character["jump_height"]
	eye_height = _character["eye_height"]
	third_person_distance = _character["third_person_distance"]
	_gravity = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8) * gravity_scale

	var shape := CapsuleShape3D.new()
	shape.radius = _character["capsule_radius"]
	shape.height = _character["capsule_height"]
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position.y = shape.height * 0.5
	add_child(col)

	_head = Node3D.new()
	_head.position.y = eye_height
	add_child(_head)

	# SpringArm pulls the camera in when something is between it and the head.
	_arm = SpringArm3D.new()
	_arm.shape = SphereShape3D.new()
	(_arm.shape as SphereShape3D).radius = 0.2
	_arm.margin = 0.1
	_arm.add_excluded_object(get_rid())
	_head.add_child(_arm)

	_camera = Camera3D.new()
	_camera.fov = 80.0
	_camera.current = true
	_arm.add_child(_camera)

	_model = (_character["model"] as PackedScene).instantiate()
	_model.rotation_degrees = Vector3(0, 180, 0)
	_model.scale = Vector3.ONE * float(_character["model_scale"])
	add_child(_model)
	_anim = _model.get_node_or_null("AnimationPlayer") as AnimationPlayer

	_set_camera_mode(CameraMode.FIRST_PERSON)

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _exit_tree() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		_pitch = clampf(_pitch - event.relative.y * mouse_sensitivity, -PI * 0.495, PI * 0.495)
		_head.rotation.x = _pitch
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_SPACE:
			_buffer_left = jump_buffer_time
		elif event.physical_keycode == KEY_F5:
			_set_camera_mode((_camera_mode + 1) % CameraMode.size())

func _set_camera_mode(mode: int) -> void:
	_camera_mode = mode
	_model.visible = mode != CameraMode.FIRST_PERSON
	_arm.spring_length = 0.0 if mode == CameraMode.FIRST_PERSON else third_person_distance
	# Rotating the arm half a turn puts the camera in front, looking back at us.
	_arm.rotation.y = PI if mode == CameraMode.THIRD_FRONT else 0.0

func _physics_process(delta: float) -> void:
	var on_floor := is_on_floor()

	# Landing dip, scaled by impact speed.
	if on_floor and not _was_on_floor:
		_land_dip = clampf(-velocity.y * 0.012, 0.0, 0.12)
	_was_on_floor = on_floor

	if on_floor:
		_coyote_left = coyote_time
	else:
		_coyote_left = maxf(_coyote_left - delta, 0.0)
	_buffer_left = maxf(_buffer_left - delta, 0.0)

	# Gravity (heavier on the way down for a snappier arc).
	if not on_floor:
		var g := _gravity * (fall_gravity_mult if velocity.y < 0.0 else 1.0)
		velocity.y -= g * delta

	# Jump: buffered press + coyote window. Holding Space re-jumps on landing.
	if _buffer_left > 0.0 and _coyote_left > 0.0:
		velocity.y = sqrt(2.0 * _gravity * jump_height)
		_buffer_left = 0.0
		_coyote_left = 0.0
	elif on_floor and Input.is_physical_key_pressed(KEY_SPACE) and _buffer_left <= 0.0:
		_buffer_left = jump_buffer_time

	# Horizontal movement.
	var input := Vector2.ZERO
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		input.x = int(Input.is_physical_key_pressed(KEY_D)) - int(Input.is_physical_key_pressed(KEY_A))
		input.y = int(Input.is_physical_key_pressed(KEY_S)) - int(Input.is_physical_key_pressed(KEY_W))
	input = input.limit_length(1.0)
	var wish := (transform.basis * Vector3(input.x, 0.0, input.y)).normalized() * input.length()
	var speed := sprint_speed if Input.is_physical_key_pressed(KEY_SHIFT) else walk_speed
	var target := Vector3(wish.x, 0.0, wish.z) * speed
	var horiz := Vector3(velocity.x, 0.0, velocity.z)

	if input != Vector2.ZERO:
		horiz = horiz.move_toward(target, (ground_accel if on_floor else air_accel) * delta)
	elif on_floor:
		horiz = horiz.move_toward(Vector3.ZERO, ground_friction * delta)
	velocity.x = horiz.x
	velocity.z = horiz.z

	move_and_slide()
	_update_camera(delta)
	_update_animation()

func _update_camera(delta: float) -> void:
	var horiz_speed := Vector2(velocity.x, velocity.z).length()
	var bob := 0.0
	if _camera_mode == CameraMode.FIRST_PERSON and is_on_floor() and horiz_speed > 0.5:
		_bob_t += delta * bob_frequency * horiz_speed
		bob = sin(_bob_t) * bob_amount * clampf(horiz_speed / walk_speed, 0.0, 1.5)
	_land_dip = move_toward(_land_dip, 0.0, delta * 0.6)
	var target_y := eye_height + bob - _land_dip
	_head.position.y = lerpf(_head.position.y, target_y, clampf(delta * 25.0, 0.0, 1.0))

func _update_animation() -> void:
	if _anim == null or not _model.visible:
		return
	var horiz_speed := Vector2(velocity.x, velocity.z).length()
	var anims: Dictionary = _character["anim"]
	var clip: String = anims["idle"]
	if not is_on_floor():
		clip = anims["jump"]
	elif horiz_speed > walk_speed + 0.5:
		clip = anims["run"]
	elif horiz_speed > 0.5:
		clip = anims["walk"]
	if _anim.current_animation != clip:
		_anim.play(clip, 0.15)
