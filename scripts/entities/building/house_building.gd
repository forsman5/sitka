extends "res://scripts/entities/building/building.gd"

const _HOME_A := preload("res://assets/models/buildings/building_home_A_blue.gltf")
const _HOME_B := preload("res://assets/models/buildings/building_home_B_blue.gltf")

@export var bed_count: int = 5

func _ready() -> void:
	super._ready()
	town_radius_contribution = 4.5
	add_to_group("sleep_point")
	var mesh: Node3D = ([_HOME_A, _HOME_B] as Array[PackedScene]).pick_random().instantiate()
	mesh.scale = Vector3(2, 2, 2)
	add_child(mesh)

func get_bed_count() -> int:
	return bed_count
