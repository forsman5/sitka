class_name HEHouseholdTable
extends VBoxContainer

## The Households list tab: a header row plus one row of labels per
## household. A pure view -- it is handed presentation rows and reports clicks
## through signals; it never reads the simulation. he_dashboard.gd builds the
## rows (see its _household_table_rows) and wires the signals.
##
## Row shape passed to set_snapshot (all keys required):
##   id: int, employer_business_id: int, housing_status: String
##   ("housed" | "homeless" | other), workers: int, oldest_worker: int,
##   dependents: int, oldest_dependent: int, stock: Dictionary[commodity ->
##   float] (one entry per HESimulation.SUBSISTENCE_COMMODITIES), balance:
##   float, stress: float, scarcity: float, unaffordable: float.
##
## The table owns its row controls and rebuilds them only when the set of
## household IDs changes, so a dead household's row cannot sit frozen. Each
## control reads the household ID it is bound to when it is pressed (not an ID
## captured at creation) so a future virtualized row pool can reuse them.

const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")

## A household's ID button was pressed.
signal row_selected(household_id: int)
## A household's employer button was pressed; carries the employer business.
signal employer_pressed(business_id: int)

var _rows: Dictionary = {} # household_id -> {row labels...}
var _known_ids: Array[int] = []
var _employer_of: Dictionary = {} # household_id -> employer business id as last shown
var rebuild_count := 0 # for tests and timing

func _init() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL

func row_count() -> int:
	return _rows.size()

## Rows are in the order given. `business_names` maps business_id -> name; an
## employer absent from it (or -1) shows as "Unemployed" and is not clickable.
func set_snapshot(rows: Array, business_names: Dictionary) -> void:
	var ids: Array[int] = []
	for row in rows:
		ids.append(row["id"])
	if ids != _known_ids:
		_rebuild(ids)
	for row in rows:
		_bind(row, business_names)

func _rebuild(ids: Array[int]) -> void:
	rebuild_count += 1
	_known_ids = ids
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_rows.clear()
	_employer_of.clear()

	var grid := GridContainer.new()
	# One stock column per good that satisfies a household need (HENeeds), so a
	# new satisfier gets its column without a dashboard edit.
	var goods_columns: Array[String] = []
	for c in HESimulation.SUBSISTENCE_COMMODITIES:
		goods_columns.append(Commodity.name_of(c))
	var col_labels: Array[String] = ["ID", "Employer", "Housing", "Workers", "Dependents"]
	col_labels.append_array(goods_columns)
	col_labels.append_array(["Balance", "Stress", "Unmet (scarce)", "Unmet (unfunded)"])
	grid.columns = col_labels.size()
	add_child(grid)
	for col_label in col_labels:
		var header := Label.new()
		header.text = col_label
		header.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
		grid.add_child(header)

	for household_id in ids:
		var id_label := Button.new()
		id_label.flat = true
		id_label.alignment = HORIZONTAL_ALIGNMENT_LEFT
		id_label.custom_minimum_size = Vector2(30, 0)
		id_label.tooltip_text = "Open household detail"
		id_label.pressed.connect(_on_id_pressed.bind(household_id))
		grid.add_child(id_label)

		var employer_label := Button.new()
		employer_label.flat = true
		employer_label.alignment = HORIZONTAL_ALIGNMENT_LEFT
		employer_label.custom_minimum_size = Vector2(80, 0)
		employer_label.pressed.connect(_on_employer_pressed.bind(household_id))
		grid.add_child(employer_label)

		var housing_status_label := Label.new()
		housing_status_label.custom_minimum_size = Vector2(70, 0)
		grid.add_child(housing_status_label)

		var workers_label := Label.new()
		workers_label.custom_minimum_size = Vector2(50, 0)
		workers_label.add_theme_color_override("font_color", Color(0.7, 0.8, 0.9))
		grid.add_child(workers_label)

		var dependents_label := Label.new()
		dependents_label.custom_minimum_size = Vector2(90, 0)
		dependents_label.add_theme_color_override("font_color", Color(0.9, 0.85, 0.6))
		dependents_label.tooltip_text = "Age (in days) of each dependent still in this household; the oldest is next to come of age and split off on its own."
		grid.add_child(dependents_label)

		var goods_labels := {}
		for c in HESimulation.SUBSISTENCE_COMMODITIES:
			var goods_label := Label.new()
			goods_label.custom_minimum_size = Vector2(70, 0)
			grid.add_child(goods_label)
			goods_labels[c] = goods_label

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

		_rows[household_id] = {
			"id": id_label, "employer": employer_label, "housing": housing_status_label, "workers": workers_label, "dependents": dependents_label,
			"goods": goods_labels, "balance": balance_label,
			"stress": stress_label, "scarcity": scarcity_label, "unaffordable": unaffordable_label,
		}

func _bind(data: Dictionary, business_names: Dictionary) -> void:
	var household_id: int = data["id"]
	var row: Dictionary = _rows[household_id]
	(row["id"] as Button).text = str(household_id)
	var employer_id: int = data["employer_business_id"]
	_employer_of[household_id] = employer_id
	var employer_button := row["employer"] as Button
	employer_button.text = business_names.get(employer_id, "Unemployed")
	employer_button.disabled = not business_names.has(employer_id)
	employer_button.tooltip_text = "Open employer detail" if not employer_button.disabled else ""
	var housing_status_label := row["housing"] as Label
	match data["housing_status"]:
		"homeless":
			housing_status_label.text = "Homeless"
			housing_status_label.add_theme_color_override("font_color", Color(0.9, 0.4, 0.4))
		"housed":
			housing_status_label.text = "Housed"
			housing_status_label.remove_theme_color_override("font_color")
		_:
			housing_status_label.text = ""
	var workers: int = data["workers"]
	(row["workers"] as Label).text = "0" if workers <= 0 else "%d (oldest: %dd)" % [workers, data["oldest_worker"]]
	var dependents: int = data["dependents"]
	(row["dependents"] as Label).text = "0" if dependents <= 0 else "%d (oldest: %dd)" % [dependents, data["oldest_dependent"]]
	for c in HESimulation.SUBSISTENCE_COMMODITIES:
		(row["goods"][c] as Label).text = "%.1f" % data["stock"][c]
	(row["balance"] as Label).text = "%.1f" % data["balance"]
	(row["stress"] as Label).text = "%.2f" % data["stress"]
	var scarcity: float = data["scarcity"]
	var unaffordable: float = data["unaffordable"]
	(row["scarcity"] as Label).text = ("%.2f" % scarcity) if scarcity > 0.01 else ""
	(row["unaffordable"] as Label).text = ("%.2f" % unaffordable) if unaffordable > 0.01 else ""

func _on_id_pressed(household_id: int) -> void:
	row_selected.emit(household_id)

func _on_employer_pressed(household_id: int) -> void:
	var employer_id: int = _employer_of.get(household_id, -1)
	if employer_id != -1:
		employer_pressed.emit(employer_id)
