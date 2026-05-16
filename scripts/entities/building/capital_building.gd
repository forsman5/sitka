extends "res://scripts/entities/building/deposit_building.gd"

@export var bed_count: int = 10

func _ready() -> void:
	super._ready()
	add_to_group("sleep_point")
	add_to_group("capital")

func shows_spawn_button() -> bool: return true
func shows_build_hut_button() -> bool: return true
func get_bed_count() -> int: return bed_count
