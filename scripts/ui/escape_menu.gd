extends CanvasLayer

@onready var _overlay: Control = $Overlay
@onready var _saved_label: Label = $Overlay/Panel/VBox/SavedLabel
@onready var _name_dialog: Panel = $Overlay/NameDialog
@onready var _name_input: LineEdit = $Overlay/NameDialog/VBox/NameInput
@onready var _confirm_dialog: Panel = $Overlay/ConfirmDialog
@onready var _confirm_label: Label = $Overlay/ConfirmDialog/VBox/ConfirmLabel

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed and not event.is_echo():
		if _confirm_dialog.visible:
			_on_confirm_no_pressed()
		elif _name_dialog.visible:
			_on_save_cancel_pressed()
		else:
			show_toggle()
		get_viewport().set_input_as_handled()

func show_toggle() -> void:
	_overlay.visible = not _overlay.visible
	if GameState.pause_on_escape:
		get_tree().paused = _overlay.visible

func _on_resume_pressed() -> void:
	_overlay.visible = false
	get_tree().paused = false

func _on_save_pressed() -> void:
	_name_input.text = GameState.current_save_name
	_name_dialog.visible = true
	_name_input.grab_focus()
	_name_input.select_all()

func _on_save_ok_pressed() -> void:
	var save_name := _name_input.text.strip_edges()
	if save_name.is_empty():
		return
	if SaveLoad.save_exists(save_name):
		_confirm_label.text = "Overwrite \"%s\"?" % save_name
		_name_dialog.visible = false
		_confirm_dialog.visible = true
	else:
		_name_dialog.visible = false
		_do_save(save_name)

func _on_confirm_yes_pressed() -> void:
	_confirm_dialog.visible = false
	_do_save(_name_input.text.strip_edges())

func _on_confirm_no_pressed() -> void:
	_confirm_dialog.visible = false
	_name_dialog.visible = true

func _on_save_cancel_pressed() -> void:
	_name_dialog.visible = false

func _on_name_submitted(_text: String) -> void:
	_on_save_ok_pressed()

func _do_save(save_name: String) -> void:
	GameState.current_save_name = save_name
	SaveLoad.save_game(get_tree().current_scene, save_name)
	_saved_label.modulate.a = 1.0
	var tween := create_tween()
	tween.tween_property(_saved_label, "modulate:a", 0.0, 1.5).set_delay(0.5)

func _on_main_menu_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")
