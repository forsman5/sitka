extends "res://scripts/entities/resource_node.gd"

const _TREE_A := preload("res://assets/models/nature/tree_single_A.gltf")
const _TREE_B := preload("res://assets/models/nature/tree_single_B.gltf")

func _ready() -> void:
	super._ready()
	_mesh.visible = false
	var tree: Node3D = ([_TREE_A, _TREE_B] as Array[PackedScene]).pick_random().instantiate()
	tree.scale = Vector3(2, 2, 2)
	add_child(tree)
