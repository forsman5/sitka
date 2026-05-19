extends CanvasLayer

const Person = preload("res://scripts/entities/person.gd")
const Building = preload("res://scripts/entities/building/building.gd")
const PersonScene = preload("res://scenes/entities/person.tscn")
const ForestHutFoundationScene = preload("res://scenes/entities/building/forest_hut_foundation.tscn")
const HouseFoundationScene = preload("res://scenes/entities/building/house_foundation.tscn")
const DockFoundationScene = preload("res://scenes/entities/building/dock_foundation.tscn")
const ShipScene = preload("res://scenes/entities/ship.tscn")
const ResourceNode = preload("res://scripts/entities/resource_node.gd")

@onready var _day_label: Label = $Root/DayLabel
@onready var _time_label: Label = $Root/TimeLabel
@onready var _wood_label: Label = $Root/WoodLabel
@onready var _gold_label: Label = $Root/GoldLabel
@onready var _food_label: Label = $Root/FoodLabel
@onready var _people_label: Label = $Root/PeopleLabel
@onready var _selection_panel: Panel = $Root/SelectionPanel
@onready var _header_row: HBoxContainer = $Root/SelectionPanel/VBoxContainer/HeaderRow
@onready var _separator: HSeparator = $Root/SelectionPanel/VBoxContainer/HSeparator
@onready var _rows: GridContainer = $Root/SelectionPanel/VBoxContainer/Rows
@onready var _resource_view: VBoxContainer = $Root/SelectionPanel/VBoxContainer/ResourceView
@onready var _resource_name: Label = $Root/SelectionPanel/VBoxContainer/ResourceView/ResourceName
@onready var _resource_amount: Label = $Root/SelectionPanel/VBoxContainer/ResourceView/AmountLabel
@onready var _foundation_view: VBoxContainer = $Root/SelectionPanel/VBoxContainer/FoundationView
@onready var _foundation_name: Label = $Root/SelectionPanel/VBoxContainer/FoundationView/FoundationName
@onready var _foundation_progress: Label = $Root/SelectionPanel/VBoxContainer/FoundationView/ProgressLabel
@onready var _building_view: VBoxContainer = $Root/SelectionPanel/VBoxContainer/BuildingView
@onready var _building_name: Label = $Root/SelectionPanel/VBoxContainer/BuildingView/BuildingName
@onready var _building_type: Label = $Root/SelectionPanel/VBoxContainer/BuildingView/BuildingType
@onready var _spawn_btn: Button = $Root/SelectionPanel/VBoxContainer/BuildingView/SpawnButton
@onready var _spawn_ship_btn: Button = $Root/SelectionPanel/VBoxContainer/BuildingView/SpawnShipButton
@onready var _build_btn: Button = $Root/BuildButton
@onready var _build_menu: Panel = $Root/BuildMenu
@onready var _jobs_btn: Button = $Root/JobsButton
@onready var _jobs_panel: Panel = $Root/JobsPanel
@onready var _build_hut_btn: Button = $Root/BuildMenu/VBox/BuildHutButton
@onready var _build_house_btn: Button = $Root/BuildMenu/VBox/BuildHouseButton
@onready var _build_dock_btn: Button = $Root/BuildMenu/VBox/BuildDockButton
@onready var _upgrades_container: VBoxContainer = $Root/SelectionPanel/VBoxContainer/BuildingView/UpgradesContainer
@onready var _selection_bar: HBoxContainer = $Root/SelectionBar
@onready var _btn_all_persons: Button = $Root/SelectionBar/AllPersonsButton
@onready var _btn_all_ships: Button = $Root/SelectionBar/AllShipsButton
@onready var _btn_next_person: Button = $Root/SelectionBar/NextPersonButton
@onready var _speed_bar: HBoxContainer = $Root/SpeedBar
@onready var _btn_pause: Button = $Root/SpeedBar/PauseButton
@onready var _btn_1x: Button = $Root/SpeedBar/Speed1xButton
@onready var _btn_2x: Button = $Root/SpeedBar/Speed2xButton
@onready var _btn_5x: Button = $Root/SpeedBar/Speed5xButton

var _last_selected_building: Building = null
var _paused: bool = false
var _person_cycle_idx: int = 0
var _game_over_triggered := false
var _style_active: StyleBoxFlat
var _style_inactive: StyleBoxFlat

func _ready() -> void:
	GameState.gold_changed.connect(_on_gold_changed)
	GameState.wood_changed.connect(_on_wood_changed)
	GameState.food_changed.connect(_on_food_changed)
	_gold_label.text = "Gold: %d" % GameState.player_gold
	_wood_label.text = "Wood: %d" % GameState.player_wood
	_food_label.text = "Food: %d" % GameState.player_food
	_style_active = StyleBoxFlat.new()
	_style_active.bg_color = Color(1.0, 1.0, 0.5, 1.0)
	_style_active.set_corner_radius_all(3)
	_style_inactive = StyleBoxFlat.new()
	_style_inactive.bg_color = Color(0.12, 0.12, 0.18, 0.9)
	_style_inactive.set_corner_radius_all(3)
	_update_speed_highlight()

func _process(_delta: float) -> void:
	var capital_placed := not get_tree().get_nodes_in_group("capital").is_empty()
	_speed_bar.visible = capital_placed
	_build_btn.visible = capital_placed
	_jobs_btn.visible = capital_placed
	_selection_bar.visible = capital_placed
	_btn_all_ships.disabled = get_tree().get_nodes_in_group("ships").is_empty()
	var _persons_empty := get_tree().get_nodes_in_group("persons").is_empty()
	_btn_all_persons.disabled = _persons_empty
	_btn_next_person.disabled = _persons_empty
	_build_hut_btn.disabled = GameState.player_wood < GameState.forest_hut_cost
	_build_house_btn.disabled = GameState.player_wood < GameState.house_cost
	_build_dock_btn.disabled = GameState.player_wood < GameState.dock_cost
	_refresh_panel()
	_refresh_people()
	var total_hours := GameState.time_of_day * 24.0
	var h := int(total_hours) % 24
	var m := int((total_hours - int(total_hours)) * 60.0)
	_time_label.text = "%02d:%02d" % [h, m]
	_day_label.visible = GameState.show_day_counter
	if GameState.show_day_counter:
		_day_label.text = "Day %d" % GameState.day_count
	if not _game_over_triggered:
		_check_game_over()

func _check_game_over() -> void:
	if get_tree().get_nodes_in_group("capital").is_empty():
		return
	if get_tree().get_nodes_in_group("persons").is_empty() \
			and GameState.player_gold < GameState.settler_cost:
		_game_over_triggered = true
		get_tree().paused = false
		get_tree().change_scene_to_file("res://scenes/ui/game_over.tscn")

func _on_gold_changed(amount: int) -> void:
	_gold_label.text = "Gold: %d" % amount

func _on_wood_changed(amount: int) -> void:
	_wood_label.text = "Wood: %d" % amount

func _on_food_changed(amount: int) -> void:
	_food_label.text = "Food: %d" % amount

func _refresh_people() -> void:
	var persons := get_tree().get_nodes_in_group("persons")
	var total := persons.size()
	var jm: Node = IslandsManager.get_jobs_manager()
	var idle: int = jm.get_idle_count() if jm else 0
	var beds := 0
	for sp in get_tree().get_nodes_in_group("sleep_point"):
		var b := sp as Building
		if b != null:
			beds += b.get_bed_count()
	_people_label.text = "%d people  %d idle  %d beds" % [total, idle, beds]

func _refresh_panel() -> void:
	var persons: Array[Node] = []
	var ships: Array[Node] = []
	var buildings: Array[Node] = []
	var resources: Array[Node] = []
	var foundations: Array[Node] = []
	for p in get_tree().get_nodes_in_group("persons"):
		if p.get("selected") == true:
			persons.append(p)
	for s in get_tree().get_nodes_in_group("ships"):
		if s.get("selected") == true:
			ships.append(s)
	for b in get_tree().get_nodes_in_group("buildings"):
		if b.get("selected") == true:
			buildings.append(b)
	for r in get_tree().get_nodes_in_group("resource_nodes"):
		if is_instance_valid(r) and r.get("selected") == true:
			resources.append(r)
	for f in get_tree().get_nodes_in_group("foundations"):
		if is_instance_valid(f) and f.get("selected") == true:
			foundations.append(f)

	var has_persons := not persons.is_empty()
	var has_ships := not ships.is_empty()
	var has_units := has_persons or has_ships
	var has_buildings := not buildings.is_empty()
	var has_resources := not resources.is_empty()
	var has_foundations := not foundations.is_empty()
	_selection_panel.visible = has_units or has_buildings or has_resources or has_foundations

	_header_row.visible = has_units
	_separator.visible = has_units
	_rows.visible = has_units
	_building_view.visible = has_buildings
	_resource_view.visible = has_resources
	_foundation_view.visible = has_foundations

	if has_units:
		for child in _rows.get_children():
			_rows.remove_child(child)
			child.queue_free()
		for node in persons:
			var person: Person = node as Person
			if person != null:
				_add_row(person.name, person.objective_label(),
					"%.1f / %.1f" % [person.current_weight(), person.carry_capacity],
					"%d / %d" % [person.health, person.max_health])
		for node in ships:
			var ship: Ship = node as Ship
			if ship != null:
				_add_row(ship.name, ship.objective_label(), "-", "-")

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

	if has_foundations:
		var f = foundations[0]
		if is_instance_valid(f):
			_foundation_name.text = f.get("foundation_name") if f.get("foundation_name") != null else "Foundation"
			_foundation_progress.text = "%d / %d" % [f.get("_progress"), f.get("build_required")]

	if has_buildings:
		var building: Building = buildings[0] as Building
		if building != null:
			_building_name.text = building.building_name
			_building_type.text = building.building_type
		_spawn_btn.visible = building != null and building.shows_spawn_button()
		_spawn_btn.disabled = GameState.player_gold < GameState.settler_cost
		_spawn_ship_btn.visible = building != null and building.shows_spawn_ship_button()
		_spawn_ship_btn.disabled = GameState.player_wood < GameState.ship_cost
		if building != _last_selected_building:
			_last_selected_building = building
			for child in _upgrades_container.get_children():
				child.queue_free()
			if building != null:
				for upgrade in building.get_available_upgrades():
					var btn := Button.new()
					btn.text = upgrade["label"]
					btn.set_meta("upgrade_cost_wood", upgrade.get("cost_wood", 0))
					btn.pressed.connect(_apply_upgrade.bind(building, upgrade))
					_upgrades_container.add_child(btn)
		for btn in _upgrades_container.get_children():
			(btn as Button).disabled = GameState.player_wood < (btn as Button).get_meta("upgrade_cost_wood", 0)

func _apply_upgrade(building: Building, upgrade: Dictionary) -> void:
	var wood_cost: int = upgrade.get("cost_wood", 0)
	if GameState.player_wood < wood_cost:
		return
	GameState.player_wood -= wood_cost
	building.apply_upgrade(upgrade["id"])
	_last_selected_building = null

func _on_build_btn_pressed() -> void:
	_build_menu.visible = not _build_menu.visible
	_jobs_panel.visible = false

func _on_jobs_btn_pressed() -> void:
	_jobs_panel.visible = not _jobs_panel.visible
	_build_menu.visible = false

func _on_build_hut_pressed() -> void:
	_build_menu.visible = false
	if GameState.player_wood < GameState.forest_hut_cost:
		return
	var placement = get_tree().get_first_node_in_group("building_placement")
	if placement:
		placement.arm(ForestHutFoundationScene, GameState.forest_hut_cost)

func _on_build_house_pressed() -> void:
	_build_menu.visible = false
	if GameState.player_wood < GameState.house_cost:
		return
	var placement = get_tree().get_first_node_in_group("building_placement")
	if placement:
		placement.arm(HouseFoundationScene, GameState.house_cost)

func _on_build_dock_pressed() -> void:
	_build_menu.visible = false
	if GameState.player_wood < GameState.dock_cost:
		return
	var placement = get_tree().get_first_node_in_group("building_placement")
	if placement:
		placement.arm(DockFoundationScene, GameState.dock_cost, true)

func _on_spawn_ship_pressed() -> void:
	if GameState.player_wood < GameState.ship_cost:
		return
	var building: Building = _last_selected_building
	if building == null or not building.shows_spawn_ship_button():
		return
	GameState.player_wood -= GameState.ship_cost
	var ship: Node3D = ShipScene.instantiate() as Node3D
	var idx := get_tree().get_nodes_in_group("ships").size() + 1
	ship.name = "Ship%d" % idx
	get_tree().current_scene.add_child(ship)
	var water_dir := building.global_transform.basis.z
	ship.global_position = building.global_position + water_dir * 5.0
	ship.global_position.y = 0.05

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

func _on_all_persons_pressed() -> void:
	for s in get_tree().get_nodes_in_group("ships"):
		s.set_selected(false)
	for b in get_tree().get_nodes_in_group("buildings"):
		b.set_selected(false)
	for r in get_tree().get_nodes_in_group("resource_nodes"):
		r.set_selected(false)
	for f in get_tree().get_nodes_in_group("foundations"):
		f.set_selected(false)
	for p in get_tree().get_nodes_in_group("persons"):
		p.set_selected(true)

func _on_all_ships_pressed() -> void:
	for p in get_tree().get_nodes_in_group("persons"):
		p.set_selected(false)
	for b in get_tree().get_nodes_in_group("buildings"):
		b.set_selected(false)
	for r in get_tree().get_nodes_in_group("resource_nodes"):
		r.set_selected(false)
	for f in get_tree().get_nodes_in_group("foundations"):
		f.set_selected(false)
	for s in get_tree().get_nodes_in_group("ships"):
		s.set_selected(true)

func _on_next_person_pressed() -> void:
	var persons := get_tree().get_nodes_in_group("persons")
	if persons.is_empty():
		return
	_person_cycle_idx = _person_cycle_idx % persons.size()
	var person: Node3D = persons[_person_cycle_idx] as Node3D
	for p in get_tree().get_nodes_in_group("persons"):
		p.set_selected(false)
	for s in get_tree().get_nodes_in_group("ships"):
		s.set_selected(false)
	for b in get_tree().get_nodes_in_group("buildings"):
		b.set_selected(false)
	person.set_selected(true)
	_person_cycle_idx = (_person_cycle_idx + 1) % persons.size()
	var cam = get_tree().get_first_node_in_group("rts_camera")
	if cam != null:
		cam.center_on(person.global_position)

func _on_pause_pressed() -> void:
	_paused = true
	get_tree().paused = true
	_update_speed_highlight()

func _on_1x_pressed() -> void:
	_paused = false
	get_tree().paused = false
	GameState.game_speed = 1.0
	_update_speed_highlight()

func _on_2x_pressed() -> void:
	_paused = false
	get_tree().paused = false
	GameState.game_speed = 2.0
	_update_speed_highlight()

func _on_5x_pressed() -> void:
	_paused = false
	get_tree().paused = false
	GameState.game_speed = 5.0
	_update_speed_highlight()

func _update_speed_highlight() -> void:
	_btn_pause.add_theme_stylebox_override("normal", _style_active if _paused else _style_inactive)
	_btn_1x.add_theme_stylebox_override("normal", _style_active if not _paused and GameState.game_speed == 1.0 else _style_inactive)
	_btn_2x.add_theme_stylebox_override("normal", _style_active if not _paused and GameState.game_speed == 2.0 else _style_inactive)
	_btn_5x.add_theme_stylebox_override("normal", _style_active if not _paused and GameState.game_speed == 5.0 else _style_inactive)

func _add_row(unit: String, objective: String, carry: String, hp: String) -> void:
	var name_lbl := Label.new()
	name_lbl.text = unit
	name_lbl.custom_minimum_size = Vector2(110, 0)
	var obj_lbl := Label.new()
	obj_lbl.text = objective
	obj_lbl.custom_minimum_size = Vector2(170, 0)
	var carry_lbl := Label.new()
	carry_lbl.text = carry
	carry_lbl.custom_minimum_size = Vector2(80, 0)
	var hp_lbl := Label.new()
	hp_lbl.text = hp
	hp_lbl.custom_minimum_size = Vector2(70, 0)
	_rows.add_child(name_lbl)
	_rows.add_child(obj_lbl)
	_rows.add_child(carry_lbl)
	_rows.add_child(hp_lbl)
