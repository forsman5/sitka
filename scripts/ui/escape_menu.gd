extends CanvasLayer

@onready var _overlay: Control = $Overlay

func show_toggle() -> void:
	_overlay.visible = not _overlay.visible

func _on_resume_pressed() -> void:
	_overlay.visible = false

func _on_main_menu_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")
