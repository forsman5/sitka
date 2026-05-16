extends "res://scripts/entities/building/building.gd"

const _HOME_A := preload("res://assets/models/buildings/building_home_A_blue.gltf")
const _HOME_B := preload("res://assets/models/buildings/building_home_B_blue.gltf")

@export var bed_count: int = 5

var _light: OmniLight3D

func _ready() -> void:
	super._ready()
	town_radius_contribution = 4.5
	add_to_group("sleep_point")
	var mesh: Node3D = ([_HOME_A, _HOME_B] as Array[PackedScene]).pick_random().instantiate()
	mesh.scale = Vector3(2, 2, 2)
	add_child(mesh)
	_light = OmniLight3D.new()
	_light.position = Vector3(0.0, 1.5, 0.0)
	_light.light_color = Color(1.0, 0.8, 0.45)
	_light.omni_range = 10.0
	_light.light_energy = 0.0
	add_child(_light)

func _process(_delta: float) -> void:
	var night := pow(absf(GameState.time_of_day - 0.5) * 2.0, 2.0)
	_light.light_energy = night * 2.5

func get_bed_count() -> int:
	return bed_count
