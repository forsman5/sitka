extends Node3D

const ARRIVE_REACH := 7.0
const SHORE_REACH := 14.0

@export var speed: float = 4.0

var _dock: Node3D = null
var _cow_scene: PackedScene = null
var _return_pos: Vector3 = Vector3.INF

enum State { TO_DOCK, TO_TRADE_POINT }
var _state := State.TO_DOCK

func setup(dock: Node3D, cow_scene: PackedScene, return_pos: Vector3) -> void:
	_dock = dock
	_cow_scene = cow_scene
	_return_pos = Vector3(return_pos.x, 0.05, return_pos.z)

func _process(delta: float) -> void:
	var target: Vector3
	if _state == State.TO_DOCK:
		if not is_instance_valid(_dock):
			queue_free()
			return
		target = Vector3(_dock.global_position.x, 0.05, _dock.global_position.z)
	else:
		target = _return_pos

	var dir := target - global_position
	dir.y = 0.0
	if dir.length() < ARRIVE_REACH:
		_on_arrived()
		return

	var next := global_position + dir.normalized() * speed * GameState.game_speed * delta
	next.y = 0.05
	var terrain := _get_terrain()
	if terrain == null or terrain.is_ocean_water(next.x, next.z):
		global_position = next
	elif _state == State.TO_DOCK and dir.length() < SHORE_REACH:
		_on_arrived()

func _on_arrived() -> void:
	if _state == State.TO_DOCK:
		_deliver_cow()
		_state = State.TO_TRADE_POINT
	else:
		queue_free()

func _deliver_cow() -> void:
	if _cow_scene == null:
		return
	var island := _find_island()
	if island == null:
		return
	var cow := _cow_scene.instantiate()
	cow.name = "Cow%d" % (get_tree().get_nodes_in_group("cows").size() + 1)
	island.add_child(cow)
	var spawn_pos := Vector3.ZERO
	if is_instance_valid(_dock):
		spawn_pos = _dock.global_position + Vector3(randf_range(-2.0, 2.0), 0.0, randf_range(-2.0, 2.0))
		_dock.delivery_in_progress = false
	cow.global_position = spawn_pos

func _find_island() -> Node:
	var n := get_parent()
	while n != null:
		if n is Island:
			return n
		n = n.get_parent()
	return null

func _get_terrain() -> Node:
	var island := _find_island()
	if island == null:
		return null
	return island.get_node_or_null("NavigationRegion3D/HeightmapTerrain")
