extends Node3D

var foundation_name: String = "House Foundation"
var town_radius_contribution: float = 2.0
@export var build_required: int = 15
@export var build_tick_time: float = 2.0
var selected := false
var _progress: int = 0
var _completed := false
const BuildScene = preload("res://scenes/entities/building/house.tscn")

@onready var _mesh: MeshInstance3D = $MeshInstance3D
var _mat_normal: Material
var _mat_selected: StandardMaterial3D

func _ready() -> void:
	add_to_group("foundations")
	_mat_normal = _mesh.get_surface_override_material(0)
	_mat_selected = StandardMaterial3D.new()
	_mat_selected.albedo_color = Color(1.0, 0.85, 0.0)

func set_selected(value: bool) -> void:
	selected = value
	_mesh.set_surface_override_material(0, _mat_selected if selected else _mat_normal)

func build_sync() -> bool:
	if _completed:
		return true
	_progress += 1
	if _progress >= build_required:
		_completed = true
		_complete()
		return true
	return false

func progress_ratio() -> float:
	return float(_progress) / float(build_required)

func _complete() -> void:
	var nav_region := get_tree().current_scene.get_node("NavigationRegion3D") as NavigationRegion3D
	var built := BuildScene.instantiate() as Node3D
	nav_region.add_child(built)
	built.global_position = global_position
	built.global_rotation = global_rotation
	nav_region.bake_navigation_mesh()
	get_tree().current_scene.update_town_shader()
	queue_free()
