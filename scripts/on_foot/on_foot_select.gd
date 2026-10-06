extends Control
## Character chooser shown between the main menu's On Foot button and the walk scene.

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.08, 0.12, 1)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(260, 0)
	box.add_theme_constant_override("separation", 14)
	center.add_child(box)

	var title := Label.new()
	title.text = "Walk as..."
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	box.add_child(title)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	box.add_child(row)
	for entry in [["Person", "person"], ["Dog", "dog"]]:
		var b := Button.new()
		b.text = entry[0]
		b.custom_minimum_size = Vector2(123, 48)
		b.pressed.connect(_start.bind(entry[1]))
		row.add_child(b)

	var back := Button.new()
	back.text = "Back"
	back.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn"))
	box.add_child(back)

func _start(character: String) -> void:
	OnFootPlayer.selected_character = character
	get_tree().change_scene_to_file("res://scenes/on_foot/on_foot.tscn")
