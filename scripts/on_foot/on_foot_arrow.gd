class_name OnFootArrow extends Node3D
## A thrown-arc arrow: flies under gravity, sticks into whatever it hits, then
## fades away. Terrain/world collide on layers 1 and 2.

const SPEED := 32.0
const GRAVITY := 14.0
const LIFETIME := 6.0
const STUCK_LIFETIME := 4.0

var velocity: Vector3 = Vector3.ZERO
var _stuck: bool = false
var _age: float = 0.0

func _ready() -> void:
	# The model's tip is at +Z, but look_at() aims -Z, so flip it around.
	var model := OnFootWeapons.ARROW_SCENE.instantiate() as Node3D
	model.rotation_degrees.y = 180.0
	add_child(model)

func _physics_process(delta: float) -> void:
	_age += delta
	if _stuck:
		if _age > STUCK_LIFETIME:
			queue_free()
		return
	if _age > LIFETIME:
		queue_free()
		return
	var from := global_position
	velocity.y -= GRAVITY * delta
	var to := from + velocity * delta
	var query := PhysicsRayQueryParameters3D.create(from, to, 1 | 2)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		global_position = hit["position"]
		_stuck = true
		_age = 0.0
		return
	global_position = to
	# The model's length runs along local Z; point it down the flight path.
	look_at(to + velocity, Vector3.UP)
