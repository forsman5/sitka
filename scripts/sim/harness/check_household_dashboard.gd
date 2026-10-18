extends SceneTree

## Household table and presenter checks against the real dashboard scene. Run:
##   godot --headless --path . --script res://scripts/sim/harness/check_household_dashboard.gd

const HEFixtures = preload("res://scripts/sim/harness/he_fixtures.gd")
const HEPresenter = preload("res://scripts/sim/household_economy/he_presenter.gd")

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("FAIL: " + message)

func _check_presenter() -> void:
	var p := HEPresenter.new(0.0)
	# Interval 0: due exactly when a new revision exists.
	p.take_dirty()
	check(not p.due(0.016), "Nothing simulated -> not due")
	p.note_simulated(3)
	check(p.due(0.016), "Interval 0 presents immediately after a simulated step")
	check(p.take_dirty().size() == HEPresenter.Group.size(), "A simulated step dirties every group")
	check(p.presented_revision == p.revision, "Presenting records the revision")
	check(not p.due(0.016), "Not due again until something changes")

	var slow := HEPresenter.new(0.1)
	slow.take_dirty()
	slow.note_simulated(1)
	check(not slow.due(0.04), "Inside the interval -> not due")
	slow.note_simulated(5)
	check(not slow.due(0.04), "More revisions do not shorten the interval")
	check(slow.due(0.04), "Interval elapsed -> due")
	slow.take_dirty()
	check(slow.presented_revision == slow.revision, "Skipped revisions are coalesced, not queued")
	check(not slow.due(1.0), "No pending revision -> not due however long it has been")
	slow.request_immediate()
	check(slow.due(0.0), "An explicit request is due regardless of the interval")
	check(slow.take_dirty().size() == HEPresenter.Group.size(), "A request dirties every group")
	check(not slow.due(0.0), "A request is consumed by one presentation")

## Top-bar warehouse stock: most units first, cut off with "..." when narrow;
## plus the town view's own Government build button.
func _check_warehouse_strip(dashboard: Control, sim) -> void:
	const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
	const Commodity = preload("res://scripts/sim/records/commodity.gd")
	var settlement_id: int = dashboard._town_settlement_id()
	check(sim.get_warehouse_inventory(settlement_id).is_empty(), "No warehouse -> empty inventory")
	var warehouse = HEScenarioSeeds.make_warehouse(sim.next_business_id(), settlement_id)
	sim.add_new_business(warehouse)
	warehouse.inventory[Commodity.Type.IRON] = 5.0
	warehouse.inventory[Commodity.Type.TIMBER] = 40.0
	warehouse.inventory[Commodity.Type.TOOLS] = 12.0
	warehouse.inventory[Commodity.Type.WOOL] = 0.0
	var inventory: Array = sim.get_warehouse_inventory(settlement_id)
	check(inventory.size() == 3, "Empty goods are left out of the inventory")
	check(inventory[0]["commodity"] == Commodity.Type.TIMBER and inventory[2]["commodity"] == Commodity.Type.IRON, "Inventory is sorted by units, most first")
	dashboard._refresh_warehouse_strip()
	dashboard._warehouse_strip.size = Vector2(2000, 30)
	dashboard._layout_warehouse_strip()
	var items: Array = dashboard._warehouse_strip_items
	check(items.size() == 3 and items[0].visible and items[2].visible, "A wide strip shows every held good")
	check(not dashboard._warehouse_strip_more.visible, "No ellipsis when everything fits")
	dashboard._warehouse_strip.size = Vector2(items[0].get_combined_minimum_size().x + 60, 30)
	dashboard._layout_warehouse_strip()
	check(items[0].visible and not items[2].visible, "A narrow strip keeps the largest stock and drops the rest")
	check(dashboard._warehouse_strip_more.visible, "Ellipsis shown when goods are cut off")
	check(dashboard._town_gov_build_popup != null and dashboard._town_gov_build_popup.item_count == HEScenarioSeeds.government_buildings().size(), "Town view has a Government build menu")

## The top bar names the current season and follows it across boundaries.
func _check_season_label(dashboard: Control, sim) -> void:
	var names := ["Spring", "Summer", "Autumn", "Winter"]
	var sampled := 0
	var target_day: int = sim.get_clock_summary()["day"] + 4 * 90
	while sim.get_clock_summary()["day"] < target_day:
		sim.advance_ticks(1)
		var clock: Dictionary = sim.get_clock_summary()
		if clock["day_of_season"] == 5:
			dashboard._refresh()
			var expected: String = names[(clock["day"] / 90) % 4]
			sampled += 1
			check(dashboard._day_label.text.begins_with(expected), "Day %d label should start with %s, got '%s'" % [clock["day"], expected, dashboard._day_label.text])
	check(sampled >= 4, "Sampled the label in every season (got %d)" % sampled)

func _run() -> void:
	_check_presenter()
	var dashboard_script: GDScript = load("res://scripts/sim/household_economy/he_dashboard.gd")
	dashboard_script.pending_builder = Callable(HEFixtures, "build_three_business_economy")
	var dashboard: Control = (load("res://scenes/sim/he_dashboard.tscn") as PackedScene).instantiate()
	root.add_child(dashboard)
	dashboard._speed_multiplier = 0.0
	await process_frame
	await process_frame

	var table = dashboard._household_table
	var sim = dashboard._simulation
	check(table != null and table.row_count() == sim.get_household_ids().size(), "Table has one row per household (%d vs %d)" % [table.row_count(), sim.get_household_ids().size()])

	# Values must match what the rich summaries say, across days.
	for day in range(40):
		sim.advance_ticks(1)
		dashboard._refresh()
	var rows: Array = dashboard._simulation.get_household_table_snapshot()
	check(rows.size() == sim.get_household_ids().size(), "Snapshot has one row per household")
	for row in rows:
		var h: Dictionary = sim.get_household_summary(row["id"])
		check(row["employer_business_id"] == h["employer_business_id"], "employer parity for %d" % row["id"])
		check(row["workers"] == h["worker_ages"].size(), "workers parity for %d" % row["id"])
		check(is_equal_approx(row["balance"], h["balance"]), "balance parity for %d" % row["id"])

	# Rebuild only when the household set changes.
	var rebuilds: int = table.rebuild_count
	dashboard._refresh()
	check(table.rebuild_count == rebuilds, "Unchanged household set must not rebuild rows")
	var shown: Array = []
	for row in table._rows.values():
		shown.append((row["id"] as Button).text)
	check(shown.size() == rows.size(), "Every bound row shows its ID")

	# Clicks route through the signals to the dashboard.
	var first_id: int = rows[0]["id"]
	table._on_id_pressed(first_id)
	check(dashboard._selected_household_id == first_id and dashboard._household_detail_panel.visible, "ID press opens that household's detail")
	var employed_row: Dictionary = {}
	for row in rows:
		if row["employer_business_id"] != -1 and dashboard._business_names.has(row["employer_business_id"]):
			employed_row = row
			break
	if not employed_row.is_empty():
		table._on_employer_pressed(employed_row["id"])
		check(dashboard._selected_business_id == employed_row["employer_business_id"], "Employer press opens that business")
	var unemployed_before: int = dashboard._selected_business_id
	table._on_employer_pressed(-12345) # unknown household: no employer, no navigation
	check(dashboard._selected_business_id == unemployed_before, "Unknown employer press does nothing")

	# Hidden views cost nothing: the Town tab and Jobs list are showing, so the
	# Goods/Needs/Businesses/Housing pages and the Households table are idle.
	dashboard.reset_perf()
	for day in range(5):
		sim.advance_ticks(1)
		dashboard._refresh()
	var perf: Dictionary = dashboard.perf_report()
	for visible_group in ["HEADER", "TOWN_STATS", "JOBS"]:
		check(perf.has(visible_group) and perf[visible_group]["calls"] == 5, "%s refreshes every day while visible (got %s)" % [visible_group, perf.get(visible_group)])
	for hidden in ["MARKET", "NEEDS", "BUSINESS_ROWS", "HOUSEHOLDS"]:
		check(not perf.has(hidden), "%s must not refresh while hidden (got %s)" % [hidden, perf.get(hidden)])
	# Opening a hidden tab catches it up on the next frame.
	dashboard._households_page.get_parent().current_tab = dashboard._households_page.get_index()
	await process_frame
	await process_frame
	check(dashboard.perf_report().has("HOUSEHOLDS"), "Opening the Households tab refreshes it")
	var expected_ids: Array = sim.get_household_ids()
	check(table.row_count() == expected_ids.size(), "Households table is current after opening (%d vs %d)" % [table.row_count(), expected_ids.size()])
	_check_warehouse_strip(dashboard, sim)
	_check_season_label(dashboard, sim)

	print("Household dashboard check: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	quit(0 if failures == 0 else 1)
