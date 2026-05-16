extends CanvasLayer

const Person = preload("res://scripts/entities/person.gd")
const Building = preload("res://scripts/entities/building/building.gd")
const PersonScene = preload("res://scenes/entities/person.tscn")
const ForestHutScene = preload("res://scenes/entities/building/forest_hut.tscn")
const ResourceNode = preload("res://scripts/entities/resource_node.gd")

@onready var _time_label: Label = $Root/TimeLabel
@onready var _wood_label: Label = $Root/WoodLabel
@onready var _gold_label: Label = $Root/GoldLabel
@onready var _selection_panel: Panel = $Root/SelectionPanel
@onready var _header_row: HBoxContainer = $Root/SelectionPanel/VBoxContainer/HeaderRow
@onready var _separator: HSeparator = $Root/SelectionPanel/VBoxContainer/HSeparator
@onready var _rows: GridContainer = $Root/SelectionPanel/VBoxContainer/Rows
@onready var _resource_view: VBoxContainer = $Root/SelectionPanel/VBoxContainer/ResourceView
@onready var _resource_name: Label = $Root/SelectionPanel/VBoxContainer/ResourceView/ResourceName
@onready var _resource_amount: Label = $Root/SelectionPanel/VBoxContainer/ResourceView/AmountLabel
@onready var _building_view: VBoxContainer = $Root/SelectionPanel/VBoxContainer/BuildingView
@onready var _building_name: Label = $Root/SelectionPanel/VBoxContainer/BuildingView/BuildingName
@onready var _building_type: Label = $Root/SelectionPanel/VBoxContainer/BuildingView/BuildingType
@onready var _spawn_btn: Button = $Root/SelectionPanel/VBoxContainer/BuildingView/SpawnButton
@onready var _build_hut_btn: Button = $Root/SelectionPanel/VBoxContainer/BuildingView/BuildHutButton

func _ready() -> void:
	GameState.gold_changed.connect(_on_gold_changed)
	GameState.wood_changed.connect(_on_wood_changed)
	_gold_label.text = "Gold: %d" % GameState.player_gold
	_wood_label.text = "Wood: %d" % GameState.player_wood

func _process(_delta: float) -> void:
	_refresh_panel()
	var total_hours := GameState.time_of_day * 24.0
	var h := int(total_hours) % 24
	var m := int((total_hours - int(total_hours)) * 60.0)
	_time_label.text = "%02d:%02d" % [h, m]

func _on_gold_changed(amount: int) -> void:
	_gold_label.text = "Gold: %d" % amount

func _on_wood_changed(amount: int) -> void:
	_wood_label.text = "Wood: %d" % amount

func _refresh_panel() -> void:
	var persons: Array[Node] = []
	var buildings: Array[Node] = []
	var resources: Array[Node] = []
	for p in get_tree().get_nodes_in_group("persons"):
		if p.get("selected") == true:
			persons.append(p)
	for b in get_tree().get_nodes_in_group("buildings"):
		if b.get("selected") == true:
			buildings.append(b)
	for r in get_tree().get_nodes_in_group("resource_nodes"):
		if is_instance_valid(r) and r.get("selected") == true:
			resources.append(r)

	var has_persons := not persons.is_empty()
	var has_buildings := not buildings.is_empty()
	var has_resources := not resources.is_empty()
	_selection_panel.visible = has_persons or has_buildings or has_resources

	_header_row.visible = has_persons
	_separator.visible = has_persons
	_rows.visible = has_persons
	_building_view.visible = has_buildings
	_resource_view.visible = has_resources

	if has_persons:
		for child in _rows.get_children():
			_rows.remove_child(child)
			child.queue_free()
		for node in persons:
			var person: Person = node as Person
			if person != null:
				_add_row(person.name, person.objective_label(),
					"%.1f / %.1f" % [person.current_weight(), person.carry_capacity])

	if has_resources:
		var res: ResourceNode = resources[0] as ResourceNode
		if res != null and is_instance_valid(res):
			var type_name: String
			match res.resource_type:
				ResourceNode.Type.WOOD:  type_name = "Wood"
				ResourceNode.Type.STONE: type_name = "Stone"
				ResourceNode.Type.FOOD:  type_name = "Food"
				ResourceNode.Type.GOLD:  type_name = "Gold"
				_: type_name = "Resource"
			_resource_name.text = type_name
			_resource_amount.text = "%d / %d" % [res.amount, res.max_amount]

	if has_buildings:
		var building: Building = buildings[0] as Building
		if building != null:
			_building_name.text = building.building_name
			_building_type.text = building.building_type
		_spawn_btn.disabled = GameState.player_gold < GameState.settler_cost
		_build_hut_btn.disabled = GameState.player_wood < GameState.forest_hut_cost

func _on_build_hut_pressed() -> void:
	if GameState.player_wood < GameState.forest_hut_cost:
		return
	var placement = get_tree().get_first_node_in_group("building_placement")
	if placement:
		placement.arm(ForestHutScene, GameState.forest_hut_cost)

func _on_spawn_pressed() -> void:
	if GameState.player_gold < GameState.settler_cost:
		return
	var capital: Node3D = get_tree().get_first_node_in_group("capital") as Node3D
	if capital == null:
		return
	GameState.player_gold -= GameState.settler_cost
	var person: Node3D = PersonScene.instantiate() as Node3D
	var idx := get_tree().get_nodes_in_group("persons").size() + 1
	person.name = "Person%d" % idx
	get_tree().current_scene.add_child(person)
	person.global_position = capital.global_position + Vector3(randf_range(-3.0, 3.0), 0.0, randf_range(-3.0, 3.0))

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
