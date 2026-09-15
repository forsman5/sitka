extends Control

## H1 equivalent of scripts/sim/dashboard.gd: a live, speed-controllable
## read-out of HESimulation. This is a view only -- it holds one
## HESimulation instance, advances it by calling advance_ticks(), and
## re-renders from HESimulation's read-only query methods. It never reaches
## into HESimulation's internal Dictionaries directly, and holds no
## economic rules of its own.

const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")

const SEED := 4242
const SECONDS_PER_DAY_AT_1X := 1.0
const WAGE_TOOLTIP := "A business paying above the reference wage grows (green); one paying below shrinks (red)."
## Blotter shows a scrollable scan of recent history, not the full
## HESimulation.EVENT_LOG_MAX -- older entries just aren't rendered.
const BLOTTER_DISPLAY_LIMIT := 40

const SCENARIOS := [
	{"label": "Two businesses, evenly staffed", "builder": "build_two_business_economy"},
	{"label": "Two businesses, lopsided start", "builder": "build_lopsided_start"},
]

var _simulation: HESimulation
var _speed_multiplier: float = 1.0
var _day_accumulator: float = 0.0

var _day_label: Label
var _city_stats_label: Label
var _market_labels: Dictionary = {} # commodity_name -> {"price","offered","funded","traded"}
var _business_list: VBoxContainer
var _business_rows: Dictionary = {} # business_id -> {row labels...}
var _household_list: VBoxContainer
var _household_rows: Dictionary = {} # household_id -> {row labels...}
var _known_household_ids: Array[int] = [] # rebuild trigger -- see _refresh()
var _business_names: Dictionary = {} # business_id -> name, for the household table's Employer column
var _blotter_display: RichTextLabel

func _ready() -> void:
	_configure_tooltip_theme()
	_load_scenario(0)
	_build_ui()
	_refresh()

func _configure_tooltip_theme() -> void:
	var tooltip_theme := Theme.new()
	var tooltip_panel := StyleBoxFlat.new()
	tooltip_panel.bg_color = Color(0.025, 0.025, 0.04, 0.98)
	tooltip_panel.border_width_left = 1
	tooltip_panel.border_width_top = 1
	tooltip_panel.border_width_right = 1
	tooltip_panel.border_width_bottom = 1
	tooltip_panel.border_color = Color(0.32, 0.32, 0.42, 1.0)
	tooltip_panel.corner_radius_top_left = 4
	tooltip_panel.corner_radius_top_right = 4
	tooltip_panel.corner_radius_bottom_left = 4
	tooltip_panel.corner_radius_bottom_right = 4
	tooltip_panel.content_margin_left = 10.0
	tooltip_panel.content_margin_top = 7.0
	tooltip_panel.content_margin_right = 10.0
	tooltip_panel.content_margin_bottom = 7.0
	tooltip_theme.set_stylebox("panel", "TooltipPanel", tooltip_panel)
	tooltip_theme.set_color("font_color", "TooltipLabel", Color(0.92, 0.92, 0.96))
	theme = tooltip_theme

func _process(delta: float) -> void:
	if _simulation == null or _speed_multiplier <= 0.0:
		return
	_day_accumulator += minf(delta, 0.25) * _speed_multiplier / SECONDS_PER_DAY_AT_1X
	_day_accumulator = minf(_day_accumulator, 8.0) # bound interactive work, same as dashboard.gd
	var days_to_advance := mini(int(_day_accumulator), 4)
	if days_to_advance <= 0:
		return
	for i in range(days_to_advance):
		_simulation.advance_ticks(1)
		_day_accumulator -= 1.0
	_refresh()

func _load_scenario(index: int) -> void:
	var scenario: Dictionary = SCENARIOS[index]
	_simulation = HESimulation.new(SEED, Callable(HEScenarioSeeds, scenario["builder"]))
	_business_names.clear()
	for report in _simulation.get_business_reports():
		_business_names[report["business_id"]] = report["name"]
	_day_accumulator = 0.0

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

	_day_label = Label.new()
	_day_label.add_theme_font_size_override("font_size", 22)
	top_bar.add_child(_day_label)

	var scenario_picker := OptionButton.new()
	for scenario in SCENARIOS:
		scenario_picker.add_item(scenario["label"])
	scenario_picker.item_selected.connect(func(index: int) -> void:
		_load_scenario(index)
		_rebuild_business_rows()
		_rebuild_household_rows()
		_refresh())
	top_bar.add_child(scenario_picker)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_bar.add_child(spacer)

	top_bar.add_child(_make_speed_button("Pause", 0.0))
	top_bar.add_child(_make_speed_button("1x", 1.0))
	top_bar.add_child(_make_speed_button("10x", 10.0))
	top_bar.add_child(_make_speed_button("100x", 100.0))

	_city_stats_label = Label.new()
	_city_stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_city_stats_label.add_theme_color_override("font_color", Color(0.75, 0.75, 0.8))
	vbox.add_child(_city_stats_label)

	vbox.add_child(_build_market_grid())

	var business_header := Label.new()
	business_header.text = "Businesses"
	business_header.add_theme_font_size_override("font_size", 16)
	vbox.add_child(business_header)
	_business_list = VBoxContainer.new()
	vbox.add_child(_business_list)

	var lower_row := HBoxContainer.new()
	lower_row.add_theme_constant_override("separation", 16)
	lower_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(lower_row)

	var household_column := VBoxContainer.new()
	household_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	household_column.size_flags_stretch_ratio = 2.0
	lower_row.add_child(household_column)

	var household_header := Label.new()
	household_header.text = "Households"
	household_header.add_theme_font_size_override("font_size", 16)
	household_column.add_child(household_header)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	household_column.add_child(scroll)

	_household_list = VBoxContainer.new()
	_household_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_household_list)

	var blotter_column := VBoxContainer.new()
	blotter_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	blotter_column.size_flags_stretch_ratio = 1.0
	lower_row.add_child(blotter_column)

	var blotter_header := Label.new()
	blotter_header.text = "Blotter"
	blotter_header.add_theme_font_size_override("font_size", 16)
	blotter_column.add_child(blotter_header)

	_blotter_display = RichTextLabel.new()
	_blotter_display.bbcode_enabled = true
	_blotter_display.scroll_following = false
	_blotter_display.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_blotter_display.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	blotter_column.add_child(_blotter_display)

	_rebuild_business_rows()
	_rebuild_household_rows()

func _make_speed_button(label: String, speed: float) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.pressed.connect(func() -> void: _speed_multiplier = speed)
	return btn

func _build_market_grid() -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = 5
	for col_label in ["Good", "Price", "Offered", "Funded request", "Traded"]:
		var header := Label.new()
		header.text = col_label
		header.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
		grid.add_child(header)

	for c in HESimulation.SUBSISTENCE_COMMODITIES:
		var name := Commodity.name_of(c)
		var name_label := Label.new()
		name_label.text = name
		name_label.custom_minimum_size = Vector2(70, 0)
		grid.add_child(name_label)

		var labels := {}
		for key in ["price", "offered", "funded", "traded"]:
			var value_label := Label.new()
			value_label.custom_minimum_size = Vector2(110, 0)
			value_label.add_theme_color_override("font_color", Color(0.6, 0.75, 0.9))
			grid.add_child(value_label)
			labels[key] = value_label
		_market_labels[name] = labels
	return grid

func _rebuild_business_rows() -> void:
	for child in _business_list.get_children():
		_business_list.remove_child(child)
		child.queue_free()
	_business_rows.clear()

	var grid := GridContainer.new()
	grid.columns = 8
	_business_list.add_child(grid)
	for col_label in ["Name", "Capacity", "Max", "Employed", "Output", "Wage (7d avg)", "Reference wage", "Stock"]:
		var header := Label.new()
		header.text = col_label
		if col_label == "Wage (7d avg)":
			header.mouse_filter = Control.MOUSE_FILTER_STOP
			header.mouse_default_cursor_shape = Control.CURSOR_HELP
			header.tooltip_text = WAGE_TOOLTIP
		header.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
		grid.add_child(header)

	for report in _simulation.get_business_reports():
		var business_id: int = report["business_id"]
		var labels := {}
		for key in ["name", "capacity", "max_capacity", "employed", "output", "wage", "reference", "stock"]:
			var label := Label.new()
			label.custom_minimum_size = Vector2(90, 0)
			if key == "wage":
				label.mouse_filter = Control.MOUSE_FILTER_STOP
				label.mouse_default_cursor_shape = Control.CURSOR_HELP
				label.tooltip_text = WAGE_TOOLTIP
			grid.add_child(label)
			labels[key] = label
		_business_rows[business_id] = labels

func _rebuild_household_rows() -> void:
	_known_household_ids = _simulation.get_household_ids()
	for child in _household_list.get_children():
		_household_list.remove_child(child)
		child.queue_free()
	_household_rows.clear()

	var grid := GridContainer.new()
	grid.columns = 10
	_household_list.add_child(grid)
	for col_label in ["ID", "Employer", "Workers", "Dependents", "Grain", "Timber", "Balance", "Stress", "Unmet (scarce)", "Unmet (unfunded)"]:
		var header := Label.new()
		header.text = col_label
		header.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
		grid.add_child(header)

	for household_id in _simulation.get_household_ids():
		var id_label := Label.new()
		id_label.custom_minimum_size = Vector2(30, 0)
		grid.add_child(id_label)

		var employer_label := Label.new()
		employer_label.custom_minimum_size = Vector2(80, 0)
		grid.add_child(employer_label)

		var workers_label := Label.new()
		workers_label.custom_minimum_size = Vector2(50, 0)
		workers_label.add_theme_color_override("font_color", Color(0.7, 0.8, 0.9))
		grid.add_child(workers_label)

		var dependents_label := Label.new()
		dependents_label.custom_minimum_size = Vector2(90, 0)
		dependents_label.add_theme_color_override("font_color", Color(0.9, 0.85, 0.6))
		dependents_label.tooltip_text = "Age (in days) of each dependent still in this household; the oldest is next to come of age and split off on its own."
		grid.add_child(dependents_label)

		var grain_label := Label.new()
		grain_label.custom_minimum_size = Vector2(70, 0)
		grid.add_child(grain_label)

		var timber_label := Label.new()
		timber_label.custom_minimum_size = Vector2(70, 0)
		grid.add_child(timber_label)

		var balance_label := Label.new()
		balance_label.custom_minimum_size = Vector2(70, 0)
		grid.add_child(balance_label)

		var stress_label := Label.new()
		stress_label.custom_minimum_size = Vector2(60, 0)
		grid.add_child(stress_label)

		var scarcity_label := Label.new()
		scarcity_label.custom_minimum_size = Vector2(90, 0)
		scarcity_label.add_theme_color_override("font_color", Color(0.9, 0.4, 0.4))
		grid.add_child(scarcity_label)

		var unaffordable_label := Label.new()
		unaffordable_label.custom_minimum_size = Vector2(90, 0)
		unaffordable_label.add_theme_color_override("font_color", Color(0.85, 0.75, 0.4))
		grid.add_child(unaffordable_label)

		_household_rows[household_id] = {
			"id": id_label, "employer": employer_label, "workers": workers_label, "dependents": dependents_label,
			"grain": grain_label, "timber": timber_label, "balance": balance_label,
			"stress": stress_label, "scarcity": scarcity_label, "unaffordable": unaffordable_label,
		}

func _refresh() -> void:
	var clock := _simulation.get_clock_summary()
	_day_label.text = "Day %d" % clock["day"]

	var city := _simulation.get_city_summary()
	_city_stats_label.text = "households=%d  population=%d  unemployed households=%d  avg stress=%.2f  short of goods=%d  short of funds=%d  total money=%.1f  emigrations (lifetime)=%d  births (lifetime)=%d  worker promotions (lifetime)=%d  money written off=%.1f" % [
		city["household_count"], city["population"], city["unemployed_household_count"], city["avg_food_stress"],
		city["households_short_of_goods"], city["households_short_of_funds"], city["total_money"],
		city["emigrations_total"], city["births_total"], city["worker_promotions_total"], city["money_written_off_total"]]

	var market := _simulation.get_market_summary()
	for commodity_name in _market_labels.keys():
		var labels: Dictionary = _market_labels[commodity_name]
		var entry: Dictionary = market[commodity_name]
		var clearing: Dictionary = entry["last_clearing"]
		(labels["price"] as Label).text = "%.2f" % entry["price"]
		(labels["offered"] as Label).text = "%.1f" % clearing.get("total_offered", 0.0)
		(labels["funded"] as Label).text = "%.1f" % clearing.get("total_requested_funded", 0.0)
		(labels["traded"] as Label).text = "%.1f" % clearing.get("quantity_traded", 0.0)

	for report in _simulation.get_business_reports():
		var row: Dictionary = _business_rows.get(report["business_id"], {})
		if row.is_empty():
			continue
		(row["name"] as Label).text = report["name"]
		(row["capacity"] as Label).text = str(report["capacity"])
		(row["max_capacity"] as Label).text = str(report["max_capacity"])
		(row["employed"] as Label).text = "%d workers / %d hh" % [report["employed_workers"], report["employed_household_count"]]
		(row["output"] as Label).text = "%.1f %s/day" % [report["last_actual_units"], report["output_commodity"]]
		var wage: float = report["rolling_average_wage"]
		var reference: float = report["reference_wage_per_worker"]
		var wage_label := row["wage"] as Label
		wage_label.text = "%.3f" % wage
		wage_label.add_theme_color_override("font_color", Color(0.6, 0.85, 0.6) if wage > reference else Color(0.9, 0.5, 0.5))
		(row["reference"] as Label).text = "%.3f" % reference
		(row["stock"] as Label).text = "%.1f" % report["stock"]

	var current_ids := _simulation.get_household_ids()
	if current_ids != _known_household_ids:
		# A household died (or, later, split) since the rows were built --
		# rebuild the table to match exactly who's actually still alive,
		# rather than leaving a dead household's row frozen forever on
		# whatever it last displayed (which is how this previously made a
		# starved-out city look like it still had all its original
		# households, just stuck at 1/1).
		_known_household_ids = current_ids
		_rebuild_household_rows()

	var grain_name := Commodity.name_of(Commodity.Type.GRAIN)
	var timber_name := Commodity.name_of(Commodity.Type.TIMBER)
	for household_id in _household_rows.keys():
		var h := _simulation.get_household_summary(household_id)
		var row: Dictionary = _household_rows[household_id]
		(row["id"] as Label).text = str(household_id)
		(row["employer"] as Label).text = _business_names.get(h["employer_business_id"], "Unemployed")
		(row["workers"] as Label).text = str(h["worker_capacity"])

		var dependent_ages: Array = h["dependent_ages"]
		var dependents_label := row["dependents"] as Label
		if dependent_ages.is_empty():
			dependents_label.text = "0"
		else:
			var oldest: int = dependent_ages.max()
			dependents_label.text = "%d (oldest: %dd)" % [dependent_ages.size(), oldest]
		(row["grain"] as Label).text = "%.1f" % h["inventory"][grain_name]
		(row["timber"] as Label).text = "%.1f" % h["inventory"][timber_name]
		(row["balance"] as Label).text = "%.1f" % h["balance"]
		(row["stress"] as Label).text = "%.2f" % h["food_stress"]

		var scarcity_total := 0.0
		for v in h["unmet_scarcity_today"].values():
			scarcity_total += v
		var unaffordable_total := 0.0
		for v in h["unmet_unaffordable_today"].values():
			unaffordable_total += v
		(row["scarcity"] as Label).text = ("%.2f" % scarcity_total) if scarcity_total > 0.01 else ""
		(row["unaffordable"] as Label).text = ("%.2f" % unaffordable_total) if unaffordable_total > 0.01 else ""

	_refresh_blotter()

## Newest event first, since that's what a player checking in on the city
## cares about seeing without scrolling.
func _refresh_blotter() -> void:
	var events := _simulation.get_event_log(BLOTTER_DISPLAY_LIMIT)
	if events.is_empty():
		_blotter_display.text = "[i]No events yet.[/i]"
		return
	var lines: Array[String] = []
	for i in range(events.size() - 1, -1, -1):
		lines.append(_format_event(events[i]))
	_blotter_display.text = "\n".join(lines)

func _format_event(event: Dictionary) -> String:
	var day: int = event["day"]
	match event["type"]:
		"birth":
			return "[color=#8fd98f]Day %d - Household %d: birth[/color]" % [day, event["household_id"]]
		"emigrate":
			var suffix := " - household ended" if event["household_ended"] else ""
			return "[color=#e08d8d]Day %d - Household %d: %s emigrated (starvation)%s[/color]" % [day, event["household_id"], event["member_type"], suffix]
		"split":
			return "[color=#8db4e0]Day %d - Household %d split: Household %d founded[/color]" % [day, event["parent_household_id"], event["new_household_id"]]
		"coming_of_age":
			return "[color=#d9c98f]Day %d - Household %d: member came of age[/color]" % [day, event["household_id"]]
		"job":
			var employer: String = _business_names.get(event["business_id"], "Business #%d" % event["business_id"])
			return "[color=#8fd9d0]Day %d - Household %d: hired by %s[/color]" % [day, event["household_id"], employer]
		_:
			return "Day %d - %s" % [day, event["type"]]
