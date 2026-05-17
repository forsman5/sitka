extends "res://scripts/entities/building/building.gd"

func _ready() -> void:
	super._ready()
	building_name = "Dock"
	building_type = "Fishing Dock"

func shows_spawn_ship_button() -> bool: return true
