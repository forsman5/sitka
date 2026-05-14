class_name InventoryItem
extends RefCounted

var item_name: String
var weight: float

func _init(p_name: String, p_weight: float) -> void:
	item_name = p_name
	weight = p_weight
