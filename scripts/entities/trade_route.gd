extends Node3D

var selected: bool = false

func _ready() -> void:
	add_to_group("trade_routes")
	global_position.y = 0.0

func set_selected(value: bool) -> void:
	selected = value
