extends CanvasLayer

const Person = preload("res://scripts/entities/person.gd")
const Building = preload("res://scripts/entities/building.gd")

@onready var _wood_label: Label = $Root/WoodLabel
@onready var _gold_label: Label = $Root/GoldLabel
@onready var _selection_panel: Panel = $Root/SelectionPanel
@onready var _header_row: HBoxContainer = $Root/SelectionPanel/VBoxContainer/HeaderRow
@onready var _separator: HSeparator = $Root/SelectionPanel/VBoxContainer/HSeparator
@onready var _rows: GridContainer = $Root/SelectionPanel/VBoxContainer/Rows
@onready var _building_view: VBoxContainer = $Root/SelectionPanel/VBoxContainer/BuildingView
@onready var _building_name: Label = $Root/SelectionPanel/VBoxContainer/BuildingView/BuildingName
@onready var _building_type: Label = $Root/SelectionPanel/VBoxContainer/BuildingView/BuildingType

func _ready() -> void:
	GameState.gold_changed.connect(_on_gold_changed)
	GameState.wood_changed.connect(_on_wood_changed)
	_gold_label.text = "Gold: %d" % GameState.player_gold
	_wood_label.text = "Wood: %d" % GameState.player_wood

func _process(_delta: float) -> void:
	_refresh_panel()

func _on_gold_changed(amount: int) -> void:
	_gold_label.text = "Gold: %d" % amount

func _on_wood_changed(amount: int) -> void:
	_wood_label.text = "Wood: %d" % amount

func _refresh_panel() -> void:
	var persons: Array[Node] = []
	var buildings: Array[Node] = []
	for p in get_tree().get_nodes_in_group("persons"):
		if p.get("selected") == true:
			persons.append(p)
	for b in get_tree().get_nodes_in_group("buildings"):
		if b.get("selected") == true:
			buildings.append(b)

	var has_persons := not persons.is_empty()
	var has_buildings := not buildings.is_empty()
	_selection_panel.visible = has_persons or has_buildings

	_header_row.visible = has_persons
	_separator.visible = has_persons
	_rows.visible = has_persons
	_building_view.visible = has_buildings

	if has_persons:
		for child in _rows.get_children():
			_rows.remove_child(child)
			child.queue_free()
		for node in persons:
			var person: Person = node as Person
			if person != null:
				_add_row(person.name, person.objective_label(),
					"%.1f / %.1f" % [person.current_weight(), person.carry_capacity])

	if has_buildings:
		var building: Building = buildings[0] as Building
		if building != null:
			_building_name.text = building.building_name
			_building_type.text = "Capital"

func _add_row(unit: String, objective: String, carry: String) -> void:
	var name_lbl := Label.new()
	name_lbl.text = unit
	name_lbl.custom_minimum_size = Vector2(110, 0)
	var obj_lbl := Label.new()
	obj_lbl.text = objective
	obj_lbl.custom_minimum_size = Vector2(170, 0)
	var carry_lbl := Label.new()
	carry_lbl.text = carry
	carry_lbl.custom_minimum_size = Vector2(80, 0)
	_rows.add_child(name_lbl)
	_rows.add_child(obj_lbl)
	_rows.add_child(carry_lbl)
