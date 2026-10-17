class_name OnFootHorse extends CharacterBody3D
## Controllable horse body. The visual scene owns the model, gait clips, and rider anchor.

const HORSE_VISUAL := preload("res://scenes/on_foot/riding_horse.tscn")

@export var walk_speed := 3.5
@export var gallop_speed := 9.0
@export var acceleration := 12.0
@export var friction := 14.0
@export var turn_speed := 6.0
@export var jump_height := 1.4

var rider: OnFootPlayer
var visual: Node3D
var _gravity: float


func _ready() -> void:
	name = "RidingHorse"
	add_to_group("on_foot_horse")
	collision_mask = 1 | 2
	floor_snap_length = 0.5
	_gravity = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
	var shape := CapsuleShape3D.new()
	shape.radius = 0.6
	shape.height = 1.8
	var collision := CollisionShape3D.new()
	collision.name = "CollisionShape3D"
	collision.shape = shape
	collision.position.y = shape.height * 0.5
	add_child(collision)
	visual = HORSE_VISUAL.instantiate()
	visual.name = "Visual"
	add_child(visual)
	visual.call("set_gait", "Idle")


func ride_step(delta: float, direction: Vector3, gallop: bool, jump: bool = false) -> void:
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	var on_floor := is_on_floor()
	var target := direction * (gallop_speed if gallop else walk_speed)
	var accel := (acceleration if direction.length_squared() > 0.01 else friction) * (1.0 if on_floor else 0.25)
	horizontal = horizontal.move_toward(target, accel * delta)
	velocity.x = horizontal.x
	velocity.z = horizontal.z
	if jump and on_floor:
		velocity.y = sqrt(2.0 * _gravity * jump_height)
	elif not on_floor:
		velocity.y -= _gravity * delta
	else:
		velocity.y = 0.0
	move_and_slide()
	if horizontal.length() > 0.2:
		var heading := atan2(-horizontal.x, -horizontal.z)
		rotation.y = lerp_angle(rotation.y, heading, clampf(turn_speed * delta, 0.0, 1.0))
	var speed := Vector2(velocity.x, velocity.z).length()
	if not is_on_floor():
		visual.call("set_gait", "Jump")
	else:
		visual.call("set_gait", "Gallop" if speed > walk_speed + 0.8 else ("Walk" if speed > 0.2 else "Idle"))


func stop() -> void:
	velocity = Vector3.ZERO
	visual.call("set_gait", "Idle")
