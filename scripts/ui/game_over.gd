extends CanvasLayer

func _on_return_pressed() -> void:
	GameState.reset()
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")
