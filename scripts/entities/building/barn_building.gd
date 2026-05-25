extends "res://scripts/entities/building/building.gd"

@export var cow_bed_count: int = 4

func _ready() -> void:
	super._ready()
	building_name = "Barn"
	building_type = "Barn"
	town_radius_contribution = 3.0
	add_to_group("cow_sleep_point")

func get_cow_bed_count() -> int:
	return cow_bed_count
