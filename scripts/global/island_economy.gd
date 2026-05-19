class_name IslandEconomy
extends Resource

signal gold_changed(value: int)
signal wood_changed(value: int)
signal food_changed(value: int)

var gold: int = 0:
	set(v): gold = v; gold_changed.emit(v)
var wood: int = 0:
	set(v): wood = v; wood_changed.emit(v)
var food: int = 50:
	set(v): food = v; food_changed.emit(v)

func reset() -> void:
	gold = 0
	wood = 0
	food = 50

func get_save_data() -> Dictionary:
	return {"gold": gold, "wood": wood, "food": food}

func restore_from_save(d: Dictionary) -> void:
	gold = int(d.get("gold", 0))
	wood = int(d.get("wood", 0))
	food = int(d.get("food", 50))
