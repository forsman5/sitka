extends Node3D

@export var pan_speed: float = 15.0
@export var zoom_min: float = 5.0
@export var zoom_max: float = 40.0

@onready var _camera: Camera3D = $Camera3D

var _dragging := false
var _drag_last := Vector2.ZERO

func _ready() -> void:
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = 20.0
	_camera.position = Vector3(0, 20, 0)
	_camera.rotation_degrees = Vector3(-90, 0, 0)
	_camera.make_current()

func _process(delta: float) -> void:
	_pan_keyboard(delta)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_camera.size = clampf(_camera.size - 2.0, zoom_min, zoom_max)
			MOUSE_BUTTON_WHEEL_DOWN:
				_camera.size = clampf(_camera.size + 2.0, zoom_min, zoom_max)
			MOUSE_BUTTON_MIDDLE:
				_dragging = event.pressed
				_drag_last = event.position
	elif event is InputEventMouseMotion and _dragging:
		# scale mouse delta to world units based on orthographic size
		var world_per_px := _camera.size / get_viewport().get_visible_rect().size.y
		var delta: Vector2 = event.position - _drag_last
		_drag_last = event.position
		position.x -= delta.x * world_per_px
		position.z -= delta.y * world_per_px

func _pan_keyboard(delta: float) -> void:
	var dir := Vector3.ZERO
	if Input.is_action_pressed("ui_right") or Input.is_key_pressed(KEY_D): dir.x += 1.0
	if Input.is_action_pressed("ui_left")  or Input.is_key_pressed(KEY_A): dir.x -= 1.0
	if Input.is_action_pressed("ui_down")  or Input.is_key_pressed(KEY_S): dir.z += 1.0
	if Input.is_action_pressed("ui_up")    or Input.is_key_pressed(KEY_W): dir.z -= 1.0
	if dir == Vector3.ZERO:
		return
	var speed := pan_speed * (_camera.size / 20.0)
	position += dir.normalized() * speed * delta
