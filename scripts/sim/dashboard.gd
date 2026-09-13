extends Control

## Milestone 0.5: a live, speed-controllable read-out of the simulation.
## This is a view only -- it holds one Simulation instance, advances it by
## calling advance_ticks(), and re-renders from Simulation's read-only query
## methods (get_settlement_ids/get_clock_summary/get_settlement_summary/
## get_workplace_ids/get_workplace_status). It never reaches into
## Simulation's internal Dictionaries directly. No game logic lives here.

const Simulation = preload("res://scripts/sim/simulation.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")

const SEED := 12345
const SECONDS_PER_DAY_AT_1X := 1.0

var _simulation: Simulation
var _speed_multiplier: float = 1.0
var _day_accumulator: float = 0.0

var _time_label: Label
# settlement_id -> {"header": Label, "stock"/"today"/"rolling": {commodity_name: Label}, "workplaces": {workplace_id: Label}}
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

	for settlement_id in _simulation.get_settlement_ids():
		_settlement_rows[settlement_id] = _build_settlement_panel(settlement_list, settlement_id)

func _make_speed_button(label: String, speed: float) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.pressed.connect(func() -> void: _speed_multiplier = speed)
	return btn

func _build_settlement_panel(parent: VBoxContainer, settlement_id: int) -> Dictionary:
	var panel := PanelContainer.new()
	parent.add_child(panel)

	var inner := VBoxContainer.new()
	panel.add_child(inner)

	var header := Label.new()
	header.add_theme_font_size_override("font_size", 18)
	inner.add_child(header)

	var grid := GridContainer.new()
	grid.columns = 4
	inner.add_child(grid)
	for col_label in ["Commodity", "Stock", "Unmet (today)", "Unmet (30d)"]:
		var col_header := Label.new()
		col_header.text = col_label
		col_header.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
		grid.add_child(col_header)

	var stock_labels := {}
	var today_labels := {}
	var rolling_labels := {}
	for c in Commodity.ALL:
		var name_label := Label.new()
		name_label.text = Commodity.name_of(c)
		name_label.custom_minimum_size = Vector2(90, 0)
		grid.add_child(name_label)

		var stock_label := Label.new()
		stock_label.custom_minimum_size = Vector2(90, 0)
		grid.add_child(stock_label)
		stock_labels[Commodity.name_of(c)] = stock_label

		var today_label := Label.new()
		today_label.custom_minimum_size = Vector2(100, 0)
		today_label.add_theme_color_override("font_color", Color(0.9, 0.4, 0.4))
		grid.add_child(today_label)
		today_labels[Commodity.name_of(c)] = today_label

		var rolling_label := Label.new()
		rolling_label.custom_minimum_size = Vector2(100, 0)
		rolling_label.add_theme_color_override("font_color", Color(0.8, 0.6, 0.4))
		grid.add_child(rolling_label)
		rolling_labels[Commodity.name_of(c)] = rolling_label

	var workplace_labels := {}
	var workplace_ids := _simulation.get_workplace_ids(settlement_id)
	if not workplace_ids.is_empty():
		var wp_header := Label.new()
		wp_header.text = "Workplaces"
		wp_header.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
		inner.add_child(wp_header)
		for workplace_id in workplace_ids:
			var wp_label := Label.new()
			inner.add_child(wp_label)
			workplace_labels[workplace_id] = wp_label

	return {
		"header": header,
		"stock": stock_labels,
		"today": today_labels,
		"rolling": rolling_labels,
		"workplaces": workplace_labels,
	}

func _refresh() -> void:
	var clock := _simulation.get_clock_summary()
	_time_label.text = "Day %d  |  Year %d, %s" % [clock["day"], clock["year"], clock["season_name"]]

	for settlement_id in _simulation.get_settlement_ids():
		var summary: Dictionary = _simulation.get_settlement_summary(settlement_id)
		var row: Dictionary = _settlement_rows[settlement_id]
		(row["header"] as Label).text = "%s (population %d)" % [summary["name"], summary["population"]]

		var stock_labels: Dictionary = row["stock"]
		var today_labels: Dictionary = row["today"]
		var rolling_labels: Dictionary = row["rolling"]
		for commodity_name in summary["inventory"].keys():
			var stock: float = summary["inventory"][commodity_name]
			var today: float = summary["unmet_today"][commodity_name]
			var rolling: float = summary["unmet_rolling_30d"][commodity_name]
			(stock_labels[commodity_name] as Label).text = "%.1f" % stock
			(today_labels[commodity_name] as Label).text = ("%.1f" % today) if today > 0.01 else ""
			(rolling_labels[commodity_name] as Label).text = ("%.1f" % rolling) if rolling > 0.01 else ""

		var workplace_labels: Dictionary = row["workplaces"]
		for workplace_id in workplace_labels.keys():
			var status := _simulation.get_workplace_status(workplace_id)
			var label := workplace_labels[workplace_id] as Label
			var planned: float = status["planned_units"]
			var actual: float = status["actual_units"]
			var limiting = status["limiting_input"]
			if limiting != null:
				label.text = "  %s: %.1f / %.1f units -- limited by %s" % [status["recipe_id"], actual, planned, Commodity.name_of(limiting)]
				label.add_theme_color_override("font_color", Color(0.9, 0.4, 0.4))
			else:
				label.text = "  %s: %.1f / %.1f units" % [status["recipe_id"], actual, planned]
				label.add_theme_color_override("font_color", Color(0.7, 0.85, 0.7))
