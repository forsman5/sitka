class_name Building
extends StaticBody3D

const InventoryItem = preload("res://scripts/inventory/inventory_item.gd")

@export var building_name: String = "Building"

func _ready() -> void:
	add_to_group("capital")

func deposit(item: InventoryItem) -> void:
	match item.item_name:
		"Gold": GameState.player_gold += 1
		"Wood": GameState.player_wood += 1
