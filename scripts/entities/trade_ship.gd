extends Node3D

const ARRIVE_REACH := 7.0
const SHORE_REACH := 14.0

@export var speed: float = 4.0

var _dock: Node3D = null
var _item_scene: PackedScene = null
var _item_label: String = "Cow"
var _item_group: String = "cows"
var _return_pos: Vector3 = Vector3.INF

enum State { TO_DOCK, TO_TRADE_POINT }
var _state := State.TO_DOCK

func setup(dock: Node3D, item_scene: PackedScene, return_pos: Vector3, item_label: String = "Cow", item_group: String = "cows") -> void:
	_dock = dock
	_item_scene = item_scene
	_item_label = item_label
	_item_group = item_group
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
		_deliver_item()
		_state = State.TO_TRADE_POINT
	else:
		queue_free()

func _deliver_item() -> void:
	if _item_scene == null:
		return
	var island := _find_island()
	if island == null:
		return
	var item := _item_scene.instantiate()
	item.name = "%s%d" % [_item_label, get_tree().get_nodes_in_group(_item_group).size() + 1]
	island.add_child(item)
	var spawn_pos := Vector3.ZERO
	if is_instance_valid(_dock):
		spawn_pos = _dock.global_position + Vector3(randf_range(-2.0, 2.0), 0.0, randf_range(-2.0, 2.0))
		_dock.delivery_in_progress = false
	item.global_position = spawn_pos

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
