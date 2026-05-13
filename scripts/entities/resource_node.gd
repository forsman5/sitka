class_name ResourceNode
extends StaticBody3D

enum Type { WOOD, STONE, FOOD }

signal depleted

@export var resource_type: Type = Type.WOOD
@export var amount: int = 100
@export var max_amount: int = 100

func harvest(quantity: int) -> int:
	var taken := mini(quantity, amount)
	amount -= taken
	if amount <= 0:
		depleted.emit()
	return taken
