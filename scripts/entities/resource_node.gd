class_name ResourceNode
extends StaticBody3D

const InventoryItem = preload("res://scripts/inventory/inventory_item.gd")

enum Type { WOOD, STONE, FOOD, GOLD }

signal depleted

@export var resource_type: Type = Type.WOOD
@export var amount: int = 100
@export var max_amount: int = 100
@export var wait_time: float = 2.0

var selected: bool = false

@onready var _mesh: MeshInstance3D = $MeshInstance3D

var _mat_normal: Material
var _mat_selected: StandardMaterial3D

func _ready() -> void:
	add_to_group("resource_nodes")
	depleted.connect(queue_free)
	_mat_normal = _mesh.get_surface_override_material(0)
	_mat_selected = StandardMaterial3D.new()
	_mat_selected.albedo_color = Color(1.0, 1.0, 0.5, 1)
	var obstacle := NavigationObstacle3D.new()
	obstacle.avoidance_enabled = true
	obstacle.radius = 0.8
	add_child(obstacle)

func set_selected(value: bool) -> void:
	selected = value
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
