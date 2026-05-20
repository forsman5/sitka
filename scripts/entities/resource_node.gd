class_name ResourceNode
extends StaticBody3D

const InventoryItem = preload("res://scripts/inventory/inventory_item.gd")

enum Type { WOOD, STONE, FOOD, GOLD }

signal depleted

@export var resource_type: Type = Type.WOOD
@export var amount: int = 100
@export var max_amount: int = 100
@export var wait_time: float = 2.0
@export var obstacle_radius: float = 0.8

var selected: bool = false
var _jm: Node = null

@onready var _mesh: MeshInstance3D = $MeshInstance3D

var _mat_normal: Material
var _mat_selected: StandardMaterial3D

func _ready() -> void:
	add_to_group("resource_nodes")
	depleted.connect(queue_free)
	var n := get_parent()
	while n != null:
		var jm := n.get_node_or_null("JobsManager")
		if jm != null:
			_jm = jm
			_jm.register_resource(self)
			break
		n = n.get_parent()
	if _mesh.visible:
		_mat_normal = _mesh.get_surface_override_material(0)
	_mat_selected = StandardMaterial3D.new()
	_mat_selected.albedo_color = Color(1.0, 1.0, 0.5, 1)
	var obstacle := NavigationObstacle3D.new()
	obstacle.avoidance_enabled = true
	obstacle.radius = obstacle_radius
	add_child(obstacle)
	var terrain: Node = null
	var p := get_parent()
	while p != null:
		if p is Island:
			terrain = p.get_node_or_null("NavigationRegion3D/HeightmapTerrain")
			break
		p = p.get_parent()
	if terrain != null:
		global_position.y = terrain.get_height(global_position.x, global_position.z)

func _exit_tree() -> void:
	if _jm != null and is_instance_valid(_jm):
		_jm.unregister_resource(self)

func get_save_data() -> Dictionary:
	return {
		"resource_type": resource_type,
		"position": [global_position.x, global_position.y, global_position.z],
		"amount": amount,
	}

func set_selected(value: bool) -> void:
	selected = value
	if _mesh.visible:
		_mesh.set_surface_override_material(0, _mat_selected if selected else _mat_normal)

func mine_sync() -> Array:
	if amount <= 0:
		return []
	var item: InventoryItem
	match resource_type:
		Type.WOOD:  item = InventoryItem.new("Wood",  1.0)
		Type.STONE: item = InventoryItem.new("Stone", 2.0)
		Type.FOOD:  item = InventoryItem.new("Food",  0.5)
		Type.GOLD:  item = InventoryItem.new("Gold",  1.0)
	if item == null:
		return []
	amount -= 1
	if amount <= 0:
		depleted.emit()
	return [item]

func harvest(quantity: int) -> int:
	var taken := mini(quantity, amount)
	amount -= taken
	if amount <= 0:
		depleted.emit()
	return taken
