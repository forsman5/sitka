extends CanvasLayer

@onready var _load_btn: Button = $Panel/VBox/LoadButton

func _ready() -> void:
	_load_btn.disabled = not SaveLoad.has_save()

func _on_return_pressed() -> void:
	GameState.reset()
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")

func _on_load_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/ui/load_game.tscn")
