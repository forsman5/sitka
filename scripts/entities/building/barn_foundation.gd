extends Node3D

var foundation_name: String = "Barn Foundation"
@export var build_required: int = 12
@export var build_tick_time: float = 2.0
var selected := false
var _progress: int = 0
var _completed := false
var _jm: Node = null
const BuildScene = preload("res://scenes/entities/building/barn.tscn")

@onready var _mesh: MeshInstance3D = $MeshInstance3D
var _mat_normal: Material
var _mat_selected: StandardMaterial3D

func _ready() -> void:
	add_to_group("foundations")
	_mat_normal = _mesh.get_surface_override_material(0)
	_mat_selected = StandardMaterial3D.new()
	_mat_selected.albedo_color = Color(1.0, 0.85, 0.0)
	var n := get_parent()
	while n != null:
		var jm := n.get_node_or_null("JobsManager")
		if jm != null:
			_jm = jm
			_jm.register_foundation(self)
			break
		n = n.get_parent()

func _exit_tree() -> void:
	if _jm != null and is_instance_valid(_jm):
		_jm.unregister_foundation(self)

func set_selected(value: bool) -> void:
	selected = value
	_mesh.set_surface_override_material(0, _mat_selected if selected else _mat_normal)

func get_save_data() -> Dictionary:
	return {
		"scene_key": foundation_name,
		"position": [global_position.x, global_position.y, global_position.z],
		"rotation_y": global_rotation.y,
		"progress": _progress,
	}

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
	var island: Node = null
	var n := get_parent()
	while n != null:
		if n is Island:
			island = n
			break
		n = n.get_parent()
	if island == null:
		queue_free()
		return
	var nav_region := island.get_node("NavigationRegion3D") as NavigationRegion3D
	var built := BuildScene.instantiate() as Node3D
	nav_region.add_child(built)
	built.global_position = global_position
	built.global_rotation = global_rotation
	nav_region.bake_navigation_mesh()
	queue_free()
