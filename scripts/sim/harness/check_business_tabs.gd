extends SceneTree

## Business detail page tabs, against the real household dashboard scene. Run:
##   godot --headless --path . --script res://scripts/sim/harness/check_business_tabs.gd

const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HEFixtures = preload("res://scripts/sim/harness/he_fixtures.gd")

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("FAIL: " + message)

## The label texts in the left column of a facts grid.
func _row_names(grid: GridContainer) -> Array[String]:
	var names: Array[String] = []
	var children := grid.get_children()
	for i in range(0, children.size(), 2):
		if children[i] is Label:
			names.append((children[i] as Label).text)
	return names

## Every tab only refreshes while it is the selected one, so a check that reads
## all four has to visit them.
func _show_all_tabs(dashboard: Control) -> void:
	var tabs: TabContainer = dashboard._business_detail_tabs
	for i in tabs.get_tab_count():
		tabs.current_tab = i
		dashboard._refresh_business_detail()
	tabs.current_tab = 0

func _run() -> void:
	var dashboard_script: GDScript = load("res://scripts/sim/household_economy/he_dashboard.gd")
	dashboard_script.pending_builder = Callable(HEFixtures, "build_three_business_economy")
	var dashboard: Control = (load("res://scenes/sim/he_dashboard.tscn") as PackedScene).instantiate()
	root.add_child(dashboard)
	dashboard._speed_multiplier = 0.0
	await process_frame
	await process_frame
	dashboard._simulation.advance_ticks(5)

	var tabs: TabContainer = dashboard._business_detail_tabs
	check(tabs != null and tabs.get_tab_count() == 4, "Business page should have four tabs")
	var titles: Array[String] = []
	for i in tabs.get_tab_count():
		titles.append(tabs.get_tab_title(i))
	check(titles == ["Cash", "Stocks", "Productivity", "Events"], "Tab order should be Cash, Stocks, Productivity, Events (got %s)" % [titles])

	# A staffed farm: identity above the tabs, money / goods / output drivers split.
	dashboard._on_business_row_selected(HEScenarioSeeds.FARM_BUSINESS_ID)
	_show_all_tabs(dashboard)
	var header := _row_names(dashboard._business_detail_grid)
	check(header.has("Capacity") and header.has("Employed") and not header.has("Cash"), "Header holds identity facts only (got %s)" % [header])
	var cash := _row_names(dashboard._business_detail_cash_grid)
	check(cash.has("Cash") and cash.has("Cash runway") and cash.has("Last wages paid"), "Cash tab holds the money rows (got %s)" % [cash])
	var stocks := _row_names(dashboard._business_detail_stock_grid)
	check(stocks.has("Output inventory"), "Stocks tab holds the output inventory (got %s)" % [stocks])
	var productivity := _row_names(dashboard._business_detail_productivity_grid)
	check(productivity.has("Productivity from morale"), "Productivity tab shows crew morale (got %s)" % [productivity])
	check(productivity.has("Land") and productivity.has("Next harvest"), "Productivity tab shows the farm's land (got %s)" % [productivity])
	check(not cash.has("Output inventory") and not stocks.has("Cash"), "Rows must not leak between tabs")

	# Refreshing keeps the chosen tab and does not duplicate rows.
	tabs.current_tab = 2
	var row_count: int = dashboard._business_detail_cash_grid.get_child_count()
	dashboard._refresh_business_detail()
	check(tabs.current_tab == 2, "A refresh must keep the selected tab")
	check(dashboard._business_detail_cash_grid.get_child_count() == row_count, "A refresh must not duplicate rows")

	# A herd: husbandry controls on Productivity, event log on Events.
	dashboard._on_business_row_selected(HEScenarioSeeds.CATTLE_RANCH_BUSINESS_ID)
	_show_all_tabs(dashboard)
	check(dashboard._business_detail_herd_controls_section.visible and dashboard._business_detail_herd_events_section.visible,
		"A herd business shows its controls and its event log")
	check(dashboard._business_detail_herd_controls_section.get_parent() == tabs.get_child(2),
		"The cull target belongs to the Productivity tab")
	check(dashboard._business_detail_herd_events_section.get_parent() == tabs.get_child(3),
		"Herd events belong to the Events tab")
	var herd_productivity := _row_names(dashboard._business_detail_productivity_grid)
	check(herd_productivity.has("Husbandry") and herd_productivity.has("Herd size"), "Productivity tab shows husbandry (got %s)" % [herd_productivity])

	# A non-herd business hides the herd sections entirely.
	dashboard._on_business_row_selected(HEScenarioSeeds.FARM_BUSINESS_ID)
	_show_all_tabs(dashboard)
	check(not dashboard._business_detail_herd_controls_section.visible, "Herd controls hide for a farm")

	# Government: tax policy sits with the money.
	dashboard._on_business_row_selected(HEScenarioSeeds.GOVERNMENT_BUSINESS_ID)
	_show_all_tabs(dashboard)
	check(dashboard._business_detail_tax_section.visible and dashboard._business_detail_tax_section.get_parent() == tabs.get_child(0),
		"Tax policy belongs to the Cash tab")

	# Hidden tabs cost nothing: with Cash selected, only Cash (and the header)
	# refresh as days pass; switching tabs catches the new one up.
	dashboard._on_business_row_selected(HEScenarioSeeds.FARM_BUSINESS_ID)
	tabs.current_tab = 0
	dashboard._refresh_business_detail()
	dashboard.reset_perf()
	for day in range(5):
		dashboard._simulation.advance_ticks(1)
		dashboard._refresh()
	var perf: Dictionary = dashboard.perf_report()
	check(perf.has("BUSINESS_DETAIL_CASH") and perf["BUSINESS_DETAIL_CASH"]["calls"] == 5, "The selected Cash tab refreshes every day (got %s)" % [perf.get("BUSINESS_DETAIL_CASH")])
	check(perf.has("BUSINESS_DETAIL_HEADER"), "The header above the tabs keeps refreshing")
	for hidden in ["BUSINESS_DETAIL_STOCKS", "BUSINESS_DETAIL_PRODUCTIVITY", "BUSINESS_DETAIL_EVENTS"]:
		check(not perf.has(hidden), "%s must not refresh while hidden (got %s)" % [hidden, perf.get(hidden)])
	dashboard.reset_perf()
	tabs.current_tab = 2
	await process_frame
	await process_frame
	perf = dashboard.perf_report()
	check(perf.has("BUSINESS_DETAIL_PRODUCTIVITY"), "Opening a tab refreshes it on the next frame")
	check(_row_names(dashboard._business_detail_productivity_grid).has("Land"), "The opened tab shows current rows")

	print("business tabs check: %s" % ("PASS" if failures == 0 else "FAIL (%d)" % failures))
	quit(0 if failures == 0 else 1)
