extends Control
## Weapon chooser shown between the main menu's On Foot Combat button and the
## walk scene. The person spawns holding the chosen weapon.

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
	box.custom_minimum_size = Vector2(360, 0)
	box.add_theme_constant_override("separation", 14)
	center.add_child(box)

	var title := Label.new()
	title.text = "Choose your weapon"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	box.add_child(title)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	box.add_child(row)
	for weapon in OnFootWeapons.DEFS:
		var b := Button.new()
		b.text = OnFootWeapons.DEFS[weapon]["label"]
		b.custom_minimum_size = Vector2(173, 48)
		b.pressed.connect(_start.bind(weapon))
		row.add_child(b)

	var hint := Label.new()
	hint.text = "Left click to swing or shoot"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.modulate = Color(0.65, 0.65, 0.75, 1)
	box.add_child(hint)

	var back := Button.new()
	back.text = "Back"
	back.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn"))
	box.add_child(back)

func _start(weapon: String) -> void:
	OnFootPlayer.selected_character = "person"
	OnFootPlayer.selected_weapon = weapon
	get_tree().change_scene_to_file("res://scenes/on_foot/on_foot.tscn")
