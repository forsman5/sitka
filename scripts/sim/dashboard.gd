extends Control

## Milestone 0.75/0.76/1/1.1: a live, speed-controllable read-out of the
## simulation. This is a view only -- it holds one Simulation instance,
## advances it by calling advance_ticks(), and re-renders from Simulation's
## read-only query methods (get_settlement_ids/get_clock_summary/
## get_settlement_summary/get_workplace_reports/get_settlement_prices/
## get_active_shipments/get_transport_edge_ids/get_game_over_info). It never
## reaches into Simulation's internal Dictionaries directly. No game logic
## lives here. The schematic route map (route_map.gd) is a sibling view of
## the same Simulation instance, not a separate authority.

const Simulation = preload("res://scripts/sim/simulation.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")
const MultiValleySeed = preload("res://scripts/sim/data/multivalley_seed.gd")
const RouteMap = preload("res://scripts/sim/route_map.gd")

const SEED := 12345
const SECONDS_PER_DAY_AT_1X := 1.0

## Set by main_menu.gd immediately before change_scene_to_file, as an
## alternative to the --graph= command line arg for launches that have no
## command line to read from (the in-editor "Large Valleys" button). Consumed
## and cleared on the next _ready(); the headless/CLI --graph= path above is
## unaffected.
static var pending_graph_path: String = ""

var _builder: MultiValleySeed
var _graph: Dictionary = {}
var _selected_id: int = -1
var _settlement_list: VBoxContainer
var _settlement_picker: OptionButton
var _simulation: Simulation
var _speed_multiplier: float = 1.0
var _day_accumulator: float = 0.0
var _game_over_shown := false

var _bottom_tabs: TabContainer
var _commodity_picker: OptionButton
var _map_legend: Label
var _time_label: Label
var _game_over_label: Label
var _route_map: RouteMap
var _shipments_box: VBoxContainer
# settlement_id -> {"header", "status", "population", "workers", "stress", "grid": {commodity_name: {"stock","today","rolling"}}, "workplaces_box"}
var _settlement_rows: Dictionary = {}

func _ready() -> void:
	var graph_path := pending_graph_path
	pending_graph_path = ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--graph="):
			graph_path = arg.trim_prefix("--graph=")
	if not graph_path.is_empty():
		_builder = MultiValleySeed.new()
		var error: String = _builder.load_graph(graph_path)
		if not error.is_empty():
			var message := Label.new()
			message.text = error
			message.position = Vector2(24, 24)
			add_child(message)
			push_error(error)
			set_process(false)
			return
		_graph = _builder.graph
	if _graph.is_empty():
		_simulation = Simulation.new(SEED)
	else:
		_simulation = Simulation.new(int(_graph["seed"]), Callable(_builder, "build"))
		_speed_multiplier = 0.0
	_build_ui()
	_refresh()

func _process(delta: float) -> void:
	if _simulation == null or _speed_multiplier <= 0.0:
		return
	_day_accumulator += minf(delta, 0.25) * _speed_multiplier / SECONDS_PER_DAY_AT_1X
	# Bound interactive work; large worlds slow down rather than freezing the UI.
	_day_accumulator = minf(_day_accumulator, 8.0)
	_route_map.tick_fraction = fmod(_day_accumulator, 1.0)
	_route_map.queue_redraw()
	var days_to_advance := mini(int(_day_accumulator), 4)
	if days_to_advance <= 0:
		return
	var started_usec: int = Time.get_ticks_usec()
	for i in range(days_to_advance):
		_simulation.advance_ticks(1)
		_day_accumulator -= 1.0
		if Time.get_ticks_usec() - started_usec >= 12000:
			break
	_refresh()

	if not _simulation.get_game_over_info().is_empty() and not _game_over_shown:
		_game_over_shown = true
		_speed_multiplier = 0.0

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

	_game_over_label = Label.new()
	_game_over_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
	_game_over_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_game_over_label.visible = false
	vbox.add_child(_game_over_label)

	var map_tools := HBoxContainer.new()
	vbox.add_child(map_tools)
	var fit := Button.new()
	fit.text = "Fit graph (F)"
	fit.pressed.connect(func() -> void: _route_map.fit_graph())
	map_tools.add_child(fit)
	var overlay := OptionButton.new()
	for title in ["Routes", "Weekly capacity", "Cargo in transit", "Commodity prices"]:
		overlay.add_item(title)
	overlay.item_selected.connect(func(index: int) -> void:
		_route_map.overlay = index
		_update_map_legend()
		_route_map.queue_redraw())
	map_tools.add_child(overlay)
	# One persistent commodity filter shared by every overlay that cares about
	# a specific commodity, rather than a separate picker per mode: it narrows
	# "cargo in transit" to just that commodity's shipments, and picks which
	# commodity's price colors "commodity prices". "All" (the default) means
	# no filter for cargo, and for prices there's no single sensible color
	# for every commodity at once, so it falls back to the normal population/
	# status coloring instead -- see route_map.gd's selected_commodity.
	_commodity_picker = OptionButton.new()
	_commodity_picker.add_item("All", -1)
	for c in Commodity.ALL:
		_commodity_picker.add_item(Commodity.name_of(c), c)
	_commodity_picker.item_selected.connect(func(index: int) -> void:
		_route_map.selected_commodity = _commodity_picker.get_item_id(index)
		_route_map.refresh_snapshot()
		_update_map_legend())
	map_tools.add_child(_commodity_picker)
	_settlement_picker = OptionButton.new()
	_settlement_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for sid in _simulation.get_settlement_ids():
		_settlement_picker.add_item(_simulation.get_settlement_summary(sid)["name"], sid)
	_settlement_picker.item_selected.connect(func(index: int) -> void:
		_select_settlement(_settlement_picker.get_item_id(index)))
	map_tools.add_child(_settlement_picker)
	var help := Label.new()
	help.text = "Wheel: zoom · Drag background: pan · Click node: inspect | Blue: river · Brown: road"
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(help)
	_map_legend = Label.new()
	_map_legend.text = "Width shows selected overlay. Cargo in transit is not weekly utilization. Hover routes for quantities and directional travel times."
	_map_legend.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_map_legend)

	_route_map = RouteMap.new()
	_route_map.simulation = _simulation
	_route_map.graph = _graph
	_route_map.settlement_selected.connect(_select_settlement)
	_route_map.custom_minimum_size = Vector2(0, 260)
	_route_map.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_route_map.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_route_map)

	_bottom_tabs = TabContainer.new()
	_bottom_tabs.custom_minimum_size = Vector2(0, 220)
	_bottom_tabs.size_flags_vertical = Control.SIZE_FILL
	vbox.add_child(_bottom_tabs)
	var scroll := ScrollContainer.new()
	scroll.name = "Valley"
	_bottom_tabs.add_child(scroll)

	_settlement_list = VBoxContainer.new()
	_settlement_list.add_theme_constant_override("separation", 16)
	_settlement_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_settlement_list)

	_selected_id = _simulation.get_settlement_ids()[0]
	_settlement_rows[_selected_id] = _build_settlement_panel(_settlement_list, _selected_id)
	_route_map.selected_id = _selected_id

	var shipments_scroll := ScrollContainer.new()
	shipments_scroll.name = "Transactions"
	_bottom_tabs.add_child(shipments_scroll)
	shipments_scroll.tooltip_text = "Active shipments for the selected settlement"

	_shipments_box = VBoxContainer.new()
	_shipments_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	shipments_scroll.add_child(_shipments_box)

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

	var stats_label := Label.new()
	stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stats_label.add_theme_color_override("font_color", Color(0.75, 0.75, 0.8))
	inner.add_child(stats_label)

	var grid := GridContainer.new()
	grid.columns = 4
	inner.add_child(grid)
	for col_label in ["Commodity", "Stock", "Price", "Unmet (today)"]:
		var col_header := Label.new()
		col_header.text = col_label
		col_header.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
		grid.add_child(col_header)

	var stock_labels := {}
	var price_labels := {}
	var today_labels := {}
	for c in Commodity.ALL:
		var name_label := Label.new()
		name_label.text = Commodity.name_of(c)
		name_label.custom_minimum_size = Vector2(90, 0)
		grid.add_child(name_label)

		var stock_label := Label.new()
		stock_label.custom_minimum_size = Vector2(90, 0)
		grid.add_child(stock_label)
		stock_labels[Commodity.name_of(c)] = stock_label

		var price_label := Label.new()
		price_label.custom_minimum_size = Vector2(70, 0)
		price_label.add_theme_color_override("font_color", Color(0.6, 0.75, 0.9))
		grid.add_child(price_label)
		price_labels[Commodity.name_of(c)] = price_label

		var today_label := Label.new()
		today_label.custom_minimum_size = Vector2(100, 0)
		today_label.add_theme_color_override("font_color", Color(0.9, 0.4, 0.4))
		grid.add_child(today_label)
		today_labels[Commodity.name_of(c)] = today_label

	var workplaces_box := VBoxContainer.new()
	inner.add_child(workplaces_box)

	var connections_label := Label.new()
	connections_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	connections_label.add_theme_color_override("font_color", Color(0.75, 0.75, 0.8))
	inner.add_child(connections_label)

	return {
		"header": header,
		"stats": stats_label,
		"stock": stock_labels,
		"price": price_labels,
		"today": today_labels,
		"workplaces_box": workplaces_box,
		"workplace_labels": {},
		"connections": connections_label,
	}

func _refresh() -> void:
	var clock := _simulation.get_clock_summary()
	_time_label.text = "Day %d  |  Year %d, %s" % [clock["day"], clock["year"], clock["season_name"]]

	var game_over := _simulation.get_game_over_info()
	_game_over_label.visible = not game_over.is_empty()
	if not game_over.is_empty():
		_game_over_label.text = "GAME OVER -- " + str(game_over["summary"])

	for settlement_id in _settlement_rows.keys():
		var summary: Dictionary = _simulation.get_settlement_summary(settlement_id)
		var row: Dictionary = _settlement_rows[settlement_id]

		(row["header"] as Label).text = "%s (population %d, %s)%s" % [
			summary["name"], summary["population"], summary["status"],
			" [player holding]" if summary["is_player_holding"] else ""]

		(row["stats"] as Label).text = "households=%d  workers=%d/%d  avg stress=%.2f  migration pressure=%d  relocated: %d out / %d in  starved=%d (%d lifetime)  grain fulfillment: today=%.0f%% 30d=%.0f%%" % [
			summary["household_count"], summary["assigned_workers"], summary["available_workers"],
			summary["avg_food_stress"], summary["migration_pressure_count"],
			summary["relocations_out_total"], summary["relocations_in_total"],
			summary["starvation_deaths_recent"], summary["starvation_deaths_total"],
			summary["grain_fulfillment_today"] * 100.0, summary["grain_fulfillment_rolling_30d"] * 100.0]

		var stock_labels: Dictionary = row["stock"]
		var price_labels: Dictionary = row["price"]
		var today_labels: Dictionary = row["today"]
		var unmet_today: Dictionary = summary["unmet_household_demand_today"]
		var prices: Dictionary = _simulation.get_settlement_prices(settlement_id)
		for commodity_name in summary["inventory"].keys():
			var stock: float = summary["inventory"][commodity_name]
			var today: float = unmet_today.get(commodity_name, 0.0)
			(stock_labels[commodity_name] as Label).text = "%.1f" % stock
			(price_labels[commodity_name] as Label).text = "%.2f" % (prices[commodity_name] as float)
			(today_labels[commodity_name] as Label).text = ("%.1f" % today) if today > 0.01 else ""

		_refresh_workplace_rows(row, settlement_id)
		(row["connections"] as Label).text = "Connected to: " + _connected_settlement_names(settlement_id)

	_refresh_shipments()
	_route_map.refresh_snapshot()
	_update_map_legend()

func _refresh_workplace_rows(row: Dictionary, settlement_id: int) -> void:
	var workplaces_box: VBoxContainer = row["workplaces_box"]
	var workplace_labels: Dictionary = row["workplace_labels"]
	var reports := _simulation.get_workplace_reports(settlement_id)

	if workplace_labels.is_empty() and not reports.is_empty():
		var header := Label.new()
		header.text = "Workplaces"
		header.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
		workplaces_box.add_child(header)
		for report in reports:
			var label := Label.new()
			workplaces_box.add_child(label)
			workplace_labels[report["workplace_id"]] = label

	for report in reports:
		var label := workplace_labels[report["workplace_id"]] as Label
		if report["kind"] == "trade_center":
			var staffed: float = report["actual_labor"]
			var target: float = report["target_labor"]
			label.text = "  trade center #%d: %.1f / %.1f labor%s" % [
				report["workplace_id"], staffed, target,
				" (understaffed)" if staffed < target - 0.01 else "",
			]
			label.add_theme_color_override("font_color", Color(0.85, 0.75, 0.4) if staffed < target - 0.01 else Color(0.7, 0.85, 0.7))
			continue
		var actual: float = report["actual_units"]
		var planned: float = report["planned_units"]
		var limiting = report["limiting_input"]
		var labor_note := "" if report["actual_labor"] >= report["target_labor"] - 0.01 else " (understaffed: %.0f/%.0f labor)" % [report["actual_labor"], report["target_labor"]]
		if limiting != null:
			label.text = "  %s: %.1f / %.1f units -- limited by %s%s" % [report["recipe_id"], actual, planned, Commodity.name_of(limiting), labor_note]
			label.add_theme_color_override("font_color", Color(0.9, 0.4, 0.4))
		elif labor_note != "":
			label.text = "  %s: %.1f / %.1f units%s" % [report["recipe_id"], actual, planned, labor_note]
			label.add_theme_color_override("font_color", Color(0.85, 0.75, 0.4))
		else:
			label.text = "  %s: %.1f / %.1f units" % [report["recipe_id"], actual, planned]
			label.add_theme_color_override("font_color", Color(0.7, 0.85, 0.7))

## Names of settlements this one has a transport edge to, comma-separated.
## Detail about each connection (mode, capacity, travel time, etc.) will be
## added later -- this is just the list.
func _connected_settlement_names(settlement_id: int) -> String:
	var names: Array[String] = []
	for edge_id in _simulation.get_transport_edge_ids():
		var edge := _simulation.get_transport_edge_summary(edge_id)
		if edge["settlement_a_id"] == settlement_id:
			names.append(edge["settlement_b_name"])
		elif edge["settlement_b_id"] == settlement_id:
			names.append(edge["settlement_a_name"])
	if names.is_empty():
		return "(none)"
	return ", ".join(names)

func _refresh_shipments() -> void:
	for child in _shipments_box.get_children():
		child.queue_free()

	var shipments: Array = _simulation.get_active_shipments().filter(func(s: Dictionary) -> bool:
		return s["origin_settlement_id"] == _selected_id or s["destination_settlement_id"] == _selected_id)
	if shipments.is_empty():
		var label := Label.new()
		label.text = "(none)"
		label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
		_shipments_box.add_child(label)
		return

	for shipment in shipments:
		var label := Label.new()
		var days_remaining: int = shipment["days_remaining"]
		label.text = "  Center #%d: %.1f %s, %s -> %s (arrives in %d day%s)" % [
			shipment["origin_trade_center_workplace_id"],
			shipment["quantity"], Commodity.name_of(shipment["commodity"]),
			shipment["origin_name"], shipment["destination_name"],
			days_remaining, "" if days_remaining == 1 else "s"]
		_shipments_box.add_child(label)


func _select_settlement(settlement_id: int) -> void:
	_selected_id = settlement_id
	_route_map.selected_id = settlement_id
	_settlement_picker.select(_settlement_picker.get_item_index(settlement_id))
	for child in _settlement_list.get_children():
		_settlement_list.remove_child(child)
		child.queue_free()
	_settlement_rows.clear()
	_settlement_rows[settlement_id] = _build_settlement_panel(_settlement_list, settlement_id)
	_refresh()

func _update_map_legend() -> void:
	var filter_note := "" if _route_map.selected_commodity == -1 else " · Trade filter: %s only" % Commodity.name_of(_route_map.selected_commodity)
	if _route_map.overlay == 3 and _route_map.selected_commodity != -1:
		_map_legend.text = "%s prices · World mean %.2f (each settlement equally weighted) · Green: below mean · Neutral: mean · Red: above mean" % [Commodity.name_of(_route_map.selected_commodity), _route_map.price_mean]
	elif _route_map.overlay == 3:
		_map_legend.text = "Commodity prices: pick a commodity in the filter to color by its price. Showing population/status coloring until then. Nodes: green stable, yellow shortage, orange shrinking, red collapsed."
	else:
		_map_legend.text = "Nodes: green stable, yellow shortage, orange shrinking, red collapsed. Width: selected overlay; cargo in transit is not weekly utilization." + filter_note
