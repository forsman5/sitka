extends Control

## Setup page shown before the household economy sim starts: pick a starting
## town (HEPresets: small / mining / large village), then Start. Each preset is
## a spec dictionary -- see data/he_presets.gd -- built by
## HEScenarioSeeds.build_preset.

const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HEPresets = preload("res://scripts/sim/household_economy/data/he_presets.gd")
const HEDashboard = preload("res://scripts/sim/household_economy/he_dashboard.gd")
const EscapeMenu = preload("res://scripts/ui/escape_menu.gd")

var _preset_picker: OptionButton
var _blurb_label: Label
var _detail_label: Label

func _ready() -> void:
	EscapeMenu.attach_to(self)
	_build_ui()
	_apply_preset(HEPresets.keys().find(HEPresets.DEFAULT_KEY))

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(480, 0)
	vbox.add_theme_constant_override("separation", 12)
	center.add_child(vbox)

	var title := Label.new()
	title.text = "Household economy setup"
	title.add_theme_font_size_override("font_size", 28)
	vbox.add_child(title)

	var preset_label := Label.new()
	preset_label.text = "Starting town"
	vbox.add_child(preset_label)
	_preset_picker = OptionButton.new()
	for key in HEPresets.keys():
		_preset_picker.add_item(str(HEPresets.spec(key)["label"]))
	_preset_picker.item_selected.connect(_apply_preset)
	vbox.add_child(_preset_picker)

	_blurb_label = Label.new()
	_blurb_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_blurb_label)
	_detail_label = Label.new()
	_detail_label.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	_detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_detail_label)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	vbox.add_child(buttons)
	var back := Button.new()
	back.text = "Back"
	back.pressed.connect(func() -> void: get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn"))
	buttons.add_child(back)
	var start_button := Button.new()
	start_button.text = "Start"
	start_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	start_button.pressed.connect(_on_start_pressed)
	buttons.add_child(start_button)

func _apply_preset(index: int) -> void:
	_preset_picker.select(index)
	var spec := HEPresets.spec(HEPresets.keys()[index])
	_blurb_label.text = str(spec["blurb"])
	var housing: Dictionary = spec.get("housing", {})
	var crews: Dictionary = spec.get("crews", {})
	var trades: Array[String] = ["Farm", "Woodlot"]
	for crew_key in crews:
		trades.append(str(crew_key).capitalize())
	_detail_label.text = "%d households, %d houses. Trades: %s." % [int(spec["households"]), int(housing.get("houses", 0)), ", ".join(trades)]

func _on_start_pressed() -> void:
	var key: String = HEPresets.keys()[_preset_picker.selected]
	HEDashboard.pending_builder = Callable(HEScenarioSeeds, "build_preset").bind(key)
	get_tree().change_scene_to_file("res://scenes/sim/he_dashboard.tscn")
