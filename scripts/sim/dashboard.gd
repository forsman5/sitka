extends Control

## Milestone 0.5: a live, speed-controllable read-out of the simulation.
## This is a view only -- it holds one Simulation instance, advances it by
## calling advance_ticks() (never touches its internals directly), and
## re-renders from get_settlement_summary() snapshots. No game logic lives
## here.

const Simulation = preload("res://scripts/sim/simulation.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")

const SEED := 12345
const SECONDS_PER_DAY_AT_1X := 1.0
const SEASON_NAMES := ["Spring", "Summer", "Autumn", "Winter"]

var _simulation: Simulation
var _speed_multiplier: float = 1.0
var _day_accumulator: float = 0.0

var _time_label: Label
# settlement_id -> {"header": Label, "stock": {commodity_name: Label}, "unmet": {commodity_name: Label}}
var _settlement_rows: Dictionary = {}

func _ready() -> void:
	_simulation = Simulation.new(SEED)
	_build_ui()
	_refresh()

func _process(delta: float) -> void:
	if _speed_multiplier <= 0.0:
		return
	_day_accumulator += delta * _speed_multiplier / SECONDS_PER_DAY_AT_1X
	var days_to_advance := int(_day_accumulator)
	if days_to_advance <= 0:
		return
	_simulation.advance_ticks(days_to_advance)
	_day_accumulator -= days_to_advance
	_refresh()

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, 16)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	margin.add_child(vbox)

	var top_bar := HBoxContainer.new()
	top_bar.add_theme_constant_override("separation", 8)
	vbox.add_child(top_bar)

	_time_label = Label.new()
	_time_label.add_theme_font_size_override("font_size", 22)
	top_bar.add_child(_time_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_bar.add_child(spacer)

	top_bar.add_child(_make_speed_button("Pause", 0.0))
	top_bar.add_child(_make_speed_button("1x", 1.0))
	top_bar.add_child(_make_speed_button("10x", 10.0))
	top_bar.add_child(_make_speed_button("100x", 100.0))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	var settlement_list := VBoxContainer.new()
	settlement_list.add_theme_constant_override("separation", 16)
	settlement_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(settlement_list)

	for settlement_id in _simulation.settlements.keys():
		_settlement_rows[settlement_id] = _build_settlement_panel(settlement_list)

func _make_speed_button(label: String, speed: float) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.pressed.connect(func() -> void: _speed_multiplier = speed)
	return btn

func _build_settlement_panel(parent: VBoxContainer) -> Dictionary:
	var panel := PanelContainer.new()
	parent.add_child(panel)

	var inner := VBoxContainer.new()
	panel.add_child(inner)

	var header := Label.new()
	header.add_theme_font_size_override("font_size", 18)
	inner.add_child(header)

	var grid := GridContainer.new()
	grid.columns = 3
	inner.add_child(grid)

	var stock_labels := {}
	var unmet_labels := {}
	for c in Commodity.ALL:
		var name_label := Label.new()
		name_label.text = Commodity.name_of(c)
		name_label.custom_minimum_size = Vector2(90, 0)
		grid.add_child(name_label)

		var stock_label := Label.new()
		stock_label.custom_minimum_size = Vector2(90, 0)
		grid.add_child(stock_label)
		stock_labels[Commodity.name_of(c)] = stock_label

		var unmet_label := Label.new()
		unmet_label.custom_minimum_size = Vector2(120, 0)
		unmet_label.add_theme_color_override("font_color", Color(0.9, 0.4, 0.4))
		grid.add_child(unmet_label)
		unmet_labels[Commodity.name_of(c)] = unmet_label

	return {"header": header, "stock": stock_labels, "unmet": unmet_labels}

func _refresh() -> void:
	var s := _simulation.season()
	_time_label.text = "Day %d  |  Year %d, %s" % [_simulation.day, _simulation.year, SEASON_NAMES[s]]

	for settlement_id in _simulation.settlements.keys():
		var summary: Dictionary = _simulation.get_settlement_summary(settlement_id)
		var row: Dictionary = _settlement_rows[settlement_id]
		(row["header"] as Label).text = "%s (population %d)" % [summary["name"], summary["population"]]

		var stock_labels: Dictionary = row["stock"]
		var unmet_labels: Dictionary = row["unmet"]
		for commodity_name in summary["inventory"].keys():
			var stock: float = summary["inventory"][commodity_name]
			var unmet: float = summary["unmet_demand"][commodity_name]
			(stock_labels[commodity_name] as Label).text = "%.1f" % stock
			(unmet_labels[commodity_name] as Label).text = ("unmet %.1f" % unmet) if unmet > 0.01 else ""
