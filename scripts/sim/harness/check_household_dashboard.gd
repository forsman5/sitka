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
	var rows: Array = dashboard._household_table_rows()
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

	print("Household dashboard check: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	quit(0 if failures == 0 else 1)
