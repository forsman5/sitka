extends Node3D

@onready var _terrain: StaticBody3D = $Terrain

func _ready() -> void:
	_terrain.world_clicked.connect(_on_world_clicked)

func _on_world_clicked(world_pos: Vector3) -> void:
	for person in get_tree().get_nodes_in_group("persons"):
		if person.selected:
			person.move_to(world_pos)
