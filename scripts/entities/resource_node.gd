class_name ResourceNode
extends StaticBody3D

const InventoryItem = preload("res://scripts/inventory/inventory_item.gd")

enum Type { WOOD, STONE, FOOD, GOLD }

signal depleted

@export var resource_type: Type = Type.WOOD
@export var amount: int = 100
@export var max_amount: int = 100
@export var wait_time: float = 2.0

func _ready() -> void:
	add_to_group("resource_nodes")

func mine() -> Array:
	await get_tree().create_timer(wait_time / GameState.gather_speed).timeout
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
