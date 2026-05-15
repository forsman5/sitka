extends CanvasLayer

@onready var _overlay: Control = $Overlay

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed and not event.is_echo():
		show_toggle()
		get_viewport().set_input_as_handled()

func show_toggle() -> void:
	_overlay.visible = not _overlay.visible
	if GameState.pause_on_escape:
		get_tree().paused = _overlay.visible

func _on_resume_pressed() -> void:
	_overlay.visible = false
	get_tree().paused = false

func _on_main_menu_pressed() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")
