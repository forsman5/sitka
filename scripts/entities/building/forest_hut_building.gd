extends "res://scripts/entities/building/deposit_building.gd"

const _TENT   := preload("res://assets/models/buildings/tent.gltf")
const _TAVERN := preload("res://assets/models/buildings/building_tavern_blue.gltf")
const BUNK_BEDS_COST := 50

@export var bed_count: int = 4

var _visual: Node3D

func _ready() -> void:
	super._ready()
	_visual = _TENT.instantiate()
	_visual.scale = Vector3(3, 5, 3)
	add_child(_visual)

func get_available_upgrades() -> Array:
	if has_upgrade("bunk_beds"):
		return []
	return [{"id": "bunk_beds", "label": "Bunk Beds (%dw)" % BUNK_BEDS_COST, "cost_wood": BUNK_BEDS_COST}]

func get_bed_count() -> int:
	return bed_count if has_upgrade("bunk_beds") else 0

func _on_upgrade_applied(id: String) -> void:
	if id == "bunk_beds":
		add_to_group("sleep_point")
		_visual.queue_free()
		_visual = _TAVERN.instantiate()
		_visual.scale = Vector3(2, 2, 2)
		add_child(_visual)
