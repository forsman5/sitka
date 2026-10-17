extends Control

## Setup page shown before the household economy sim starts: pick a starting
## town (HEPresets: small / mining / large village) or "Custom", then Start.
## Each preset is a spec dictionary -- see data/he_presets.gd -- built by
## HEScenarioSeeds.build_preset. Custom shows a household count and one
## checkbox per business; ticking a box while a preset is selected flips the
## picker to Custom, seeded from that preset's household count and trades.

const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HEPresets = preload("res://scripts/sim/household_economy/data/he_presets.gd")
const HEDashboard = preload("res://scripts/sim/household_economy/he_dashboard.gd")
const HEHouse = preload("res://scripts/sim/household_economy/records/he_house.gd")
const EscapeMenu = preload("res://scripts/ui/escape_menu.gd")

var _preset_picker: OptionButton
var _blurb_label: Label
var _detail_label: Label
var _custom_box: VBoxContainer
var _household_spin: SpinBox
var _gold_spin: SpinBox
var _houses_spin: SpinBox
var _tenements_spin: SpinBox
var _farm_share_spin: SpinBox
var _checks: Dictionary = {} # business type_key -> CheckBox
var _warning_label: Label
var _start_button: Button

func _ready() -> void:
	EscapeMenu.attach_to(self)
	_build_ui()
	_apply_preset(HEPresets.keys().find(HEPresets.DEFAULT_KEY))

func _add_spin_row(caption: String, min_value: float, max_value: float, step: float, value: float) -> SpinBox:
	var row := HBoxContainer.new()
	_custom_box.add_child(row)
	var label := Label.new()
	label.text = caption
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var spin := SpinBox.new()
	spin.min_value = min_value
	spin.max_value = max_value
	spin.step = step
	spin.value = value
	spin.value_changed.connect(func(_v: float) -> void: _on_custom_edited())
	row.add_child(spin)
	return spin

func _custom_index() -> int:
	return HEPresets.keys().size()

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
	_preset_picker.add_item("Custom")
	_preset_picker.item_selected.connect(_apply_preset)
	vbox.add_child(_preset_picker)

	_blurb_label = Label.new()
	_blurb_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_blurb_label)
	_detail_label = Label.new()
	_detail_label.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	_detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_detail_label)

	_custom_box = VBoxContainer.new()
	_custom_box.add_theme_constant_override("separation", 6)
	vbox.add_child(_custom_box)
	_household_spin = _add_spin_row("Households", HEPresets.CUSTOM_MIN_HOUSEHOLDS, HEPresets.CUSTOM_MAX_HOUSEHOLDS, 1, 30)
	_gold_spin = _add_spin_row("Starting gold (treasury)", 0, HEPresets.CUSTOM_MAX_GOLD, 25, 150)
	_houses_spin = _add_spin_row("Houses (1 household each)", 0, HEPresets.CUSTOM_MAX_HOUSES, 1, 36)
	_tenements_spin = _add_spin_row("Tenements (%d households each)" % HEHouse.DENSE_CAPACITY, 0, HEPresets.CUSTOM_MAX_HOUSES, 1, 0)
	_farm_share_spin = _add_spin_row("Farm share of field workers (%)", 0, 100, 5, 50)
	var businesses_label := Label.new()
	businesses_label.text = "Businesses to include"
	_custom_box.add_child(businesses_label)
	for business in HEScenarioSeeds.business_types():
		var check := CheckBox.new()
		check.text = business["label"]
		check.tooltip_text = business["hint"]
		check.toggled.connect(func(_pressed: bool) -> void: _on_custom_edited())
		_custom_box.add_child(check)
		_checks[business["type_key"]] = check

	_warning_label = Label.new()
	_warning_label.text = "Include a Farm or a Woodlot -- nothing else produces food or fuel."
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

## Seeds the Custom controls from a preset (or the small-village default).
func _load_custom_controls(spec: Dictionary) -> void:
	var trades := HEPresets.included_trades(spec)
	for type_key in _checks:
		(_checks[type_key] as CheckBox).set_pressed_no_signal(trades.has(type_key))
	_household_spin.set_value_no_signal(int(spec["households"]))
	var housing: Dictionary = spec.get("housing", {})
	var tenements := int(housing.get("tenements", 0))
	_tenements_spin.set_value_no_signal(tenements)
	_houses_spin.set_value_no_signal(int(housing.get("houses", ceili(int(spec["households"]) * 1.2))) - tenements)
	_gold_spin.set_value_no_signal(float(spec.get("treasury_bonus", 0.0)))
	_farm_share_spin.set_value_no_signal(roundi(float(spec.get("farm_share", 0.5)) * 100.0))

func _apply_preset(index: int) -> void:
	_preset_picker.select(index)
	var is_custom := index == _custom_index()
	_custom_box.visible = is_custom
	if is_custom:
		_blurb_label.text = "A hand-picked roster of businesses and starting population."
	else:
		var spec := HEPresets.spec(HEPresets.keys()[index])
		_load_custom_controls(spec)
		_blurb_label.text = str(spec["blurb"])
		var housing: Dictionary = spec.get("housing", {})
		var trades: Array[String] = ["Farm", "Woodlot"]
		for crew_key in spec.get("crews", {}):
			trades.append(str(crew_key).capitalize())
		var wells := int(spec.get("water", {}).get("wells", 0))
		_detail_label.text = "%d households, %d houses%s. Trades: %s." % [int(spec["households"]), int(housing.get("houses", 0)), ", %d wells" % wells if wells > 0 else "", ", ".join(trades)]
	_detail_label.visible = not is_custom
	_update_start_state()

## A box or the household count changed: whatever was selected becomes Custom.
## The controls already hold the values, so nothing is reloaded.
func _on_custom_edited() -> void:
	if _preset_picker.selected != _custom_index():
		_preset_picker.select(_custom_index())
		_custom_box.visible = true
		_detail_label.visible = false
		_blurb_label.text = "A hand-picked roster of businesses and starting population."
	_update_start_state()

func _included() -> Array:
	var included: Array = []
	for type_key in _checks:
		if (_checks[type_key] as CheckBox).button_pressed:
			included.append(type_key)
	return included

func _update_start_state() -> void:
	var valid := _preset_picker.selected != _custom_index() or HEPresets.custom_roster_valid(_included())
	_start_button.disabled = not valid
	_warning_label.visible = not valid

func _on_start_pressed() -> void:
	if _preset_picker.selected == _custom_index():
		var spec := HEPresets.custom_spec(_included(), int(_household_spin.value), {
			"houses": int(_houses_spin.value),
			"tenements": int(_tenements_spin.value),
			"treasury_bonus": _gold_spin.value,
			"farm_share": _farm_share_spin.value / 100.0,
		})
		HEDashboard.pending_builder = Callable(HEScenarioSeeds, "build_spec").bind(spec)
	else:
		var key: String = HEPresets.keys()[_preset_picker.selected]
		HEDashboard.pending_builder = Callable(HEScenarioSeeds, "build_preset").bind(key)
	get_tree().change_scene_to_file("res://scenes/sim/he_dashboard.tscn")
