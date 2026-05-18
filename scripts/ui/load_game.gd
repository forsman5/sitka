extends Control

@onready var _save_list: VBoxContainer = $Panel/VBox/ScrollContainer/SaveList

func _ready() -> void:
	get_tree().paused = false
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
		var btn := Button.new()
		btn.text = "%s  |  Gold: %d  Wood: %d%s" % [
			entry["name"], int(gs.get("gold", 0)), int(gs.get("wood", 0)), date_str
		]
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(_on_save_selected.bind(entry["filename"]))
		_save_list.add_child(btn)

func _on_save_selected(filename: String) -> void:
	var data := SaveLoad.load_game(filename)
	GameState.pending_load = data
	GameState.current_save_name = data.get("name", "")
	get_tree().change_scene_to_file("res://scenes/world/world.tscn")

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")
