class_name OnFootPlayer extends CharacterBody3D
## First-person walker: WASD + mouse look, Space to jump, Shift to sprint.
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

var _head: Node3D
var _camera: Camera3D
var _pitch: float = 0.0
var _coyote_left: float = 0.0
var _buffer_left: float = 0.0
var _bob_t: float = 0.0
var _was_on_floor: bool = true
var _land_dip: float = 0.0
var _gravity: float

func _ready() -> void:
	_gravity = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8) * gravity_scale

	var shape := CapsuleShape3D.new()
	shape.radius = 0.35
	shape.height = 1.8
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position.y = 0.9
	add_child(col)

	_head = Node3D.new()
	_head.position.y = eye_height
	add_child(_head)

	_camera = Camera3D.new()
	_camera.fov = 80.0
	_camera.current = true
	_head.add_child(_camera)

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _exit_tree() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		_pitch = clampf(_pitch - event.relative.y * mouse_sensitivity, -PI * 0.495, PI * 0.495)
		_head.rotation.x = _pitch
	elif event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_SPACE:
		_buffer_left = jump_buffer_time

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

func _update_camera(delta: float) -> void:
	var horiz_speed := Vector2(velocity.x, velocity.z).length()
	var bob := 0.0
	if is_on_floor() and horiz_speed > 0.5:
		_bob_t += delta * bob_frequency * horiz_speed
		bob = sin(_bob_t) * bob_amount * clampf(horiz_speed / walk_speed, 0.0, 1.5)
	_land_dip = move_toward(_land_dip, 0.0, delta * 0.6)
	var target_y := eye_height + bob - _land_dip
	_head.position.y = lerpf(_head.position.y, target_y, clampf(delta * 25.0, 0.0, 1.0))
