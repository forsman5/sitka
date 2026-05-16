class_name Building
extends StaticBody3D

const InventoryItem = preload("res://scripts/inventory/inventory_item.gd")

@export var building_name: String = "Building"
@export var building_type: String = "Building"

var selected: bool = false
var upgrades: Dictionary = {}

func has_upgrade(id: String) -> bool:
	return upgrades.get(id, false)

func get_available_upgrades() -> Array:
	return []

func shows_spawn_button() -> bool: return false
func shows_build_hut_button() -> bool: return false

func apply_upgrade(id: String) -> void:
	upgrades[id] = true
	_on_upgrade_applied(id)

func _on_upgrade_applied(_id: String) -> void:
	pass

@onready var _mesh: MeshInstance3D = $MeshInstance3D

var _mat_normal: Material
var _mat_selected: StandardMaterial3D

func _ready() -> void:
	add_to_group("buildings")
	_mat_normal = _mesh.get_surface_override_material(0)
	_mat_selected = StandardMaterial3D.new()
	_mat_selected.albedo_color = Color(0.85, 0.9, 1.0, 1)

func set_selected(value: bool) -> void:
	selected = value
	_mesh.set_surface_override_material(0, _mat_selected if selected else _mat_normal)

func deposit(item: InventoryItem) -> void:
	match item.item_name:
		"Gold": GameState.player_gold += 1
		"Wood": GameState.player_wood += 1
