extends "res://scripts/entities/building/deposit_building.gd"

func _ready() -> void:
	super._ready()
	add_to_group("sleep_point")

func shows_spawn_button() -> bool: return true
func shows_build_hut_button() -> bool: return true
