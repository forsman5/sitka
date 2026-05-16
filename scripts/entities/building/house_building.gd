extends "res://scripts/entities/building/building.gd"

@export var bed_count: int = 5

func _ready() -> void:
	super._ready()
	town_radius_contribution = 4.5
	add_to_group("sleep_point")

func get_bed_count() -> int:
	return bed_count
