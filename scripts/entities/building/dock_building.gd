extends "res://scripts/entities/building/building.gd"

var delivery_in_progress: bool = false

func _ready() -> void:
	super._ready()
	building_name = "Dock"
	building_type = "Fishing Dock"

func shows_spawn_ship_button() -> bool: return true
func shows_buy_cow_button() -> bool: return true
