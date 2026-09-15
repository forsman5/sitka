extends Node3D

@export var pan_speed: float = 15.0
@export var zoom_min: float = 5.0
@export var zoom_max: float = 40.0
@export var tilt_sensitivity: float = 0.3  # degrees per pixel of vertical mouse movement
@export var tilt_min: float = 20.0         # most angled allowed (degrees above horizon)
@export var pivot_height: float = 20.0     # camera altitude above the rig's ground anchor;
                                            # must clear the tallest terrain in the scene or
                                            # the camera ends up inside/under the mesh
## Half-extent (x, z) of the world's ground, in world units. Panning is
## clamped so the visible area never crosses outside this rectangle -- unset
## (INF) leaves panning unrestricted, which is what world.tscn's open-ended
## procedural map wants. Scenes with a fixed-size ground plane (the river
## valley) should set this after building their terrain.
@export var pan_limit: Vector2 = Vector2.INF
## Tallest terrain above the pan_limit ground plane, in world units. The
## clamp math below is exact for a flat Y=0 plane; real elevation pushes the
## actual visible ground point further along the tilt direction than that
## flat-plane math predicts, by roughly height / tan(tilt) at a grazing
## angle (over the valley's ~38-unit hills at a 38-degree tilt, that's a
## ~50-unit error -- not a rounding issue). 0 keeps the exact flat-plane math
## for scenes whose ground is actually flat at y=0.
@export var max_ground_height: float = 0.0

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
	_clamp_to_pan_limit()

func _process(delta: float) -> void:
	_pan_keyboard(delta)

# Pivots camera around the rig's ground point so the view centre stays anchored.
func _apply_tilt() -> void:
	var rad := deg_to_rad(_current_tilt)
	_camera.position = Vector3(0, pivot_height, pivot_height * cos(rad) / sin(rad))
	_camera.rotation_degrees = Vector3(-_current_tilt, 0, 0)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_camera.size = clampf(_camera.size - 2.0, zoom_min, zoom_max)
				_clamp_to_pan_limit()
			MOUSE_BUTTON_WHEEL_DOWN:
				_camera.size = clampf(_camera.size + 2.0, zoom_min, zoom_max)
				_clamp_to_pan_limit()
			MOUSE_BUTTON_MIDDLE:
				_dragging = event.pressed
				_drag_last = event.position
	elif event is InputEventMouseMotion:
		if Input.is_key_pressed(KEY_ALT):
			# mouse up (relative.y < 0) → more top-down; mouse down → more angled
			_current_tilt = clampf(_current_tilt - event.relative.y * tilt_sensitivity, tilt_min, 90.0)
			_apply_tilt()
			_clamp_to_pan_limit()
			_drag_last = event.position  # keep fresh so pan doesn't jump on Alt release
		elif _dragging:
			var world_per_px := _camera.size / get_viewport().get_visible_rect().size.y
			var delta: Vector2 = event.position - _drag_last
			_drag_last = event.position
			position.x -= delta.x * world_per_px
			position.z -= delta.y * world_per_px
			_clamp_to_pan_limit()

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
	_clamp_to_pan_limit()

## Keeps the visible ground rectangle inside pan_limit -- otherwise panning
## (or zooming/tilting out further than the ground extends) reveals empty
## background past the terrain's edge. Orthographic + tilt keeps the ground
## footprint's edges parallel (no perspective trapezoid), so scaling the
## top-down half-extent by 1/sin(tilt) is exact for the near/far reach, not
## just an approximation.
func _clamp_to_pan_limit() -> void:
	if not (is_finite(pan_limit.x) and is_finite(pan_limit.y)):
		return
	var half := _visible_half_extent()
	position.x = 0.0 if half.x >= pan_limit.x else clampf(position.x, -pan_limit.x + half.x, pan_limit.x - half.x)
	position.z = 0.0 if half.y >= pan_limit.y else clampf(position.z, -pan_limit.y + half.y, pan_limit.y - half.y)

## Half-extent, in world units, of what the camera can currently see on the
## ground plane. camera.size is calibrated to the viewport's vertical extent
## (see the drag-pan handler's own world_per_px), so horizontal follows from
## the viewport aspect ratio. Tilting away from top-down stretches the
## vertical (world Z) reach since the ground plane is seen at a grazing angle.
func _visible_half_extent() -> Vector2:
	var viewport_size := get_viewport().get_visible_rect().size
	var aspect := viewport_size.x / maxf(viewport_size.y, 1.0)
	var tilt_rad := deg_to_rad(clampf(_current_tilt, 1.0, 90.0))
	var tilt_stretch := 1.0 / sin(tilt_rad)
	var elevation_reach := max_ground_height / tan(tilt_rad)
	return Vector2(_camera.size * 0.5 * aspect, _camera.size * 0.5 * tilt_stretch + elevation_reach)
