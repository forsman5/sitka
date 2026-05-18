extends Node3D

@export var pan_speed: float = 15.0
@export var zoom_min: float = 5.0
@export var zoom_max: float = 40.0
@export var tilt_sensitivity: float = 0.3  # degrees per pixel of vertical mouse movement
@export var tilt_min: float = 20.0         # most angled allowed (degrees above horizon)

@onready var _camera: Camera3D = $Camera3D

var _dragging := false
var _drag_last := Vector2.ZERO
var _current_tilt: float = 90.0  # 90 = top-down, tilt_min = most angled

func _ready() -> void:
	add_to_group("rts_camera")
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = 20.0
	_current_tilt = 90.0
	_apply_tilt()
	_camera.make_current()

func center_on(world_pos: Vector3) -> void:
	position.x = world_pos.x
	position.z = world_pos.z

func _process(delta: float) -> void:
	_pan_keyboard(delta)

# Pivots camera around the rig's ground point so the view centre stays anchored.
func _apply_tilt() -> void:
	var rad := deg_to_rad(_current_tilt)
	_camera.position = Vector3(0, 20.0, 20.0 * cos(rad) / sin(rad))
	_camera.rotation_degrees = Vector3(-_current_tilt, 0, 0)

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
	elif event is InputEventMouseMotion:
		if Input.is_key_pressed(KEY_ALT):
			# mouse up (relative.y < 0) → more top-down; mouse down → more angled
			_current_tilt = clampf(_current_tilt - event.relative.y * tilt_sensitivity, tilt_min, 90.0)
			_apply_tilt()
			_drag_last = event.position  # keep fresh so pan doesn't jump on Alt release
		elif _dragging:
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
