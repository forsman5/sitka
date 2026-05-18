extends Control

@onready var _save_list: VBoxContainer = $Panel/VBox/ScrollContainer/SaveList
@onready var _confirm_dialog: Panel = $DeleteConfirmDialog
@onready var _confirm_label: Label = $DeleteConfirmDialog/VBox/ConfirmLabel

var _pending_delete: String = ""

func _ready() -> void:
	get_tree().paused = false
	_populate_list()

func _populate_list() -> void:
	for child in _save_list.get_children():
		child.queue_free()
	var saves := SaveLoad.get_save_list()
	if saves.is_empty():
		var lbl := Label.new()
		lbl.text = "No saves found."
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.modulate = Color(0.65, 0.65, 0.75, 1)
		_save_list.add_child(lbl)
		return
	for entry in saves:
		var gs: Dictionary = entry.get("game_state", {})
		var local: Dictionary = entry.get("saved_local", {})
		var date_str := ""
		if not local.is_empty():
			date_str = "  %d/%d" % [int(local.get("month", 0)), int(local.get("day", 0))]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		var load_btn := Button.new()
		load_btn.text = "%s  |  Gold: %d  Wood: %d%s" % [
			entry["name"], int(gs.get("gold", 0)), int(gs.get("wood", 0)), date_str
		]
		load_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		load_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		load_btn.pressed.connect(_on_save_selected.bind(entry["filename"]))
		var del_btn := Button.new()
		del_btn.text = "X"
		del_btn.custom_minimum_size = Vector2(28, 0)
		del_btn.modulate = Color(1.0, 0.45, 0.45, 1)
		del_btn.pressed.connect(_on_delete_pressed.bind(entry["filename"], entry["name"]))
		row.add_child(load_btn)
		row.add_child(del_btn)
		_save_list.add_child(row)

func _on_save_selected(filename: String) -> void:
	var data := SaveLoad.load_game(filename)
	GameState.pending_load = data
	GameState.current_save_name = data.get("name", "")
	get_tree().change_scene_to_file("res://scenes/world/world.tscn")

func _on_delete_pressed(filename: String, display_name: String) -> void:
	_pending_delete = filename
	_confirm_label.text = "Delete \"%s\"?" % display_name
	_confirm_dialog.visible = true

func _on_delete_confirmed() -> void:
	_confirm_dialog.visible = false
	SaveLoad.delete_save(_pending_delete)
	_pending_delete = ""
	_populate_list()

func _on_delete_cancelled() -> void:
	_confirm_dialog.visible = false
	_pending_delete = ""

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")
