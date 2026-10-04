extends Control

## Setup page shown before the household economy sim starts: pick a preset
## from the dropdown, or tick the businesses to include by hand, then Start.
## Ticking a box by hand flips the dropdown to "Custom". Presets keep their
## own authored staffing; Custom uses HEScenarioSeeds.build_custom.

const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HEDashboard = preload("res://scripts/sim/household_economy/he_dashboard.gd")
const EscapeMenu = preload("res://scripts/ui/escape_menu.gd")

const BUSINESSES := [
	{"id": HEScenarioSeeds.FARM_BUSINESS_ID, "label": "Farm", "hint": "Grows grain."},
	{"id": HEScenarioSeeds.WOODLOT_BUSINESS_ID, "label": "Woodlot", "hint": "Grows timber."},
	{"id": HEScenarioSeeds.TRADER_BUSINESS_ID, "label": "Trader", "hint": "Imports and exports surplus."},
	{"id": HEScenarioSeeds.CATTLE_RANCH_BUSINESS_ID, "label": "Cattle Ranch", "hint": "Herd; starts with no staff."},
	{"id": HEScenarioSeeds.SHEEP_FARM_BUSINESS_ID, "label": "Sheep Farm", "hint": "Herd and wool; starts with no staff."},
	{"id": HEScenarioSeeds.BLOOMERY_BUSINESS_ID, "label": "Bloomery", "hint": "Smelts iron from timber and ore."},
	{"id": HEScenarioSeeds.IRON_MINE_BUSINESS_ID, "label": "Iron Mine", "hint": "Digs ore for the Bloomery."},
]

## "include" mirrors which businesses each builder in HEScenarioSeeds creates,
## so choosing a preset ticks the matching boxes.
const PRESETS := [
	{"label": "Five businesses, evenly staffed", "builder": "build_three_business_economy", "include": [1, 2, 3, 6, 7]},
	{"label": "Five businesses, lopsided start", "builder": "build_lopsided_start", "include": [1, 2, 3, 6, 7]},
	{"label": "Six businesses, with Bloomery", "builder": "build_three_business_economy_with_bloomery", "include": [1, 2, 3, 4, 6, 7]},
	{"label": "Seven businesses, with Bloomery and Iron Mine", "builder": "build_economy_with_bloomery_and_iron_mine", "include": [1, 2, 3, 4, 5, 6, 7]},
]

var _preset_picker: OptionButton
var _checks: Dictionary = {} # business_id -> CheckBox
var _start_button: Button
var _warning_label: Label

func _ready() -> void:
	EscapeMenu.attach_to(self)
	_build_ui()
	_apply_preset(0)

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
	preset_label.text = "Preset"
	vbox.add_child(preset_label)
	_preset_picker = OptionButton.new()
	for preset in PRESETS:
		_preset_picker.add_item(preset["label"])
	_preset_picker.add_item("Custom")
	_preset_picker.item_selected.connect(_on_preset_selected)
	vbox.add_child(_preset_picker)

	var businesses_label := Label.new()
	businesses_label.text = "Businesses to include"
	vbox.add_child(businesses_label)
	for business in BUSINESSES:
		var check := CheckBox.new()
		check.text = business["label"]
		check.tooltip_text = business["hint"]
		check.toggled.connect(_on_check_toggled)
		vbox.add_child(check)
		_checks[business["id"]] = check

	_warning_label = Label.new()
	_warning_label.text = "Include at least a Farm or a Woodlot -- nothing else produces food or fuel."
	_warning_label.add_theme_color_override("font_color", Color(0.95, 0.6, 0.3))
	_warning_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_warning_label)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	vbox.add_child(buttons)
	var back := Button.new()
	back.text = "Back"
	back.pressed.connect(func() -> void: get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn"))
	buttons.add_child(back)
	_start_button = Button.new()
	_start_button.text = "Start"
	_start_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_start_button.pressed.connect(_on_start_pressed)
	buttons.add_child(_start_button)

func _apply_preset(index: int) -> void:
	_preset_picker.select(index)
	var include: Array = PRESETS[index]["include"]
	for id in _checks:
		(_checks[id] as CheckBox).set_pressed_no_signal(include.has(id))
	_update_start_state()

func _on_preset_selected(index: int) -> void:
	if index < PRESETS.size():
		_apply_preset(index)
	else:
		_update_start_state()

func _on_check_toggled(_pressed: bool) -> void:
	_preset_picker.select(PRESETS.size())
	_update_start_state()

func _included_ids() -> Array:
	var ids: Array = []
	for business in BUSINESSES:
		if (_checks[business["id"]] as CheckBox).button_pressed:
			ids.append(business["id"])
	return ids

func _update_start_state() -> void:
	var ids := _included_ids()
	var valid := ids.has(HEScenarioSeeds.FARM_BUSINESS_ID) or ids.has(HEScenarioSeeds.WOODLOT_BUSINESS_ID)
	_start_button.disabled = not valid
	_warning_label.visible = not valid

func _on_start_pressed() -> void:
	var index := _preset_picker.selected
	if index < PRESETS.size():
		HEDashboard.pending_builder = Callable(HEScenarioSeeds, PRESETS[index]["builder"])
	else:
		HEDashboard.pending_builder = Callable(HEScenarioSeeds, "build_custom").bind(_included_ids())
	get_tree().change_scene_to_file("res://scenes/sim/he_dashboard.tscn")
