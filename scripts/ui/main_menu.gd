extends Control

@onready var _load_btn: Button = $Panel/VBox/LoadButton

func _ready() -> void:
	get_tree().paused = false
	_load_btn.disabled = not SaveLoad.has_save()

func _on_start_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/world/world.tscn")

func _on_load_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/ui/load_game.tscn")
