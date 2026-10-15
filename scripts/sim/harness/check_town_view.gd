extends SceneTree

## Town view check against the real household dashboard scene. Run with:
##   godot --headless --path . --script res://scripts/sim/harness/check_town_view.gd

const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HEFixtures = preload("res://scripts/sim/harness/he_fixtures.gd")
const HETownLayout = preload("res://scripts/sim/household_economy/he_town_layout.gd")

var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("FAIL: " + message)

func _positions(layout: HETownLayout) -> Dictionary:
	var out := {}
	for site in layout.get_sites():
		out[site["site_id"]] = site["position"]
	return out

func _run() -> void:
	# Loaded at runtime: the dashboard script needs the GameState autoload, which
	# is not registered yet while this script itself is being compiled.
	var dashboard_script: GDScript = load("res://scripts/sim/household_economy/he_dashboard.gd")
	dashboard_script.pending_builder = Callable(HEFixtures, "build_three_business_economy")
	var dashboard: Control = (load("res://scenes/sim/he_dashboard.tscn") as PackedScene).instantiate()
	root.add_child(dashboard)
	dashboard._speed_multiplier = 0.0
	await process_frame
	await process_frame
	var view = dashboard._town_view
	var layout: HETownLayout = dashboard._town_layout
	check(view != null and not view.visible, "Town view exists and starts hidden")
	var business_count: int = dashboard._simulation.get_business_reports().size()
	var house_count: int = dashboard._simulation.get_dwelling_reports().size()
	check(house_count > 0, "The seeded town should have houses")
	check(view.site_node_count() == business_count + house_count, "Every business and house is drawn (%d sites, %d businesses, %d houses)" % [view.site_node_count(), business_count, house_count])
	for key in ["government", "farm", "cattle_ranch", "sheep_farm"]:
		var found := false
		for site in layout.get_sites():
			found = found or site["type_key"] == key
		check(found, "Default scenario should place a %s" % key)

	# House panel names who lives there (HESimulation house assignment).
	var first_household: int = dashboard._simulation.get_household_ids()[0]
	var home_id: int = dashboard._simulation.get_household_summary(first_household)["dwelling_id"]
	var home_site := layout.site_of_dwelling(home_id)
	check(not home_site.is_empty(), "The first household's house has a site")
	if not home_site.is_empty():
		view._select_site(home_site["site_id"])
		check(view._info_body.text.contains("Home of household") and view._info_body.text.contains(str(first_household)), "House panel names its household (got '%s')" % view._info_body.text)
		view.clear_selection()
	check(view.occupants_text({"occupant_household_ids": [3, 7], "capacity": 4}) == "Home of households 3, 7 (2 of 4)", "Tenement panel names its households and room")
	check(view.occupants_text({"occupant_household_ids": [], "capacity": 1}) == "Empty (room for 1 household)", "Empty house says so")

	var before := _positions(layout)
	dashboard._set_town_mode(true)
	await process_frame
	await process_frame
	check(view.visible and not dashboard._dashboard_body[0].visible, "Town mode hides the dashboard body")
	check(view.size.y > 300.0, "Town view should get real space (height %.0f)" % view.size.y)

	# Click the farm's site and read back the selection.
	var farm_site := layout.site_of_business(HEScenarioSeeds.FARM_BUSINESS_ID)
	check(not farm_site.is_empty(), "Farm should have a site")
	var screen: Vector2 = _screen_of(view, farm_site["position"])
	_click(view, screen)
	check(view.selected_business_id() == HEScenarioSeeds.FARM_BUSINESS_ID, "Clicking the farm should select it (got %d)" % view.selected_business_id())
	var requested := []
	view.details_requested.connect(func(id: int) -> void: requested.append(id))
	view._on_details_pressed()
	check(requested == [HEScenarioSeeds.FARM_BUSINESS_ID], "Details button should request the farm's detail panel")
	check(not view.visible and dashboard._selected_business_id == HEScenarioSeeds.FARM_BUSINESS_ID, "Details should return to the dashboard with the farm open")
	dashboard._set_town_mode(true)

	# The shared RTS rig: rotating the view must not break click selection.
	view.rotate_view(90.0)
	await process_frame
	view.clear_selection()
	_click(view, _screen_of(view, farm_site["position"]))
	check(view.selected_business_id() == HEScenarioSeeds.FARM_BUSINESS_ID, "Selection should still work after rotating the camera")

	await _check_villagers(dashboard, view, layout)

	# Wheel zoom goes through the shared RTS rig.
	var size_before: float = view.camera().size
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	wheel.position = view.size * 0.5
	view._gui_input(wheel)
	check(view.camera().size < size_before, "Wheel up should zoom in")

	# Town time: one sim day per visual day, ticked at dawn, never scaled by
	# the dashboard's speed buttons. (Direct assignment, not the setter, so the
	# check does not rewrite the user's settings file.)
	var game_state: Node = root.get_node("GameState")
	var saved_day_seconds: float = game_state.town_day_seconds
	game_state.town_day_seconds = 60.0
	dashboard._speed_multiplier = 1.0
	dashboard._town_phase = dashboard.TOWN_TICK_PHASE
	var day_before: int = dashboard._simulation.day
	for i in 250: # a little over one 60 s day of 0.25 s frames
		dashboard._advance_town_time(0.25)
	check(dashboard._simulation.day == day_before + 1, "One 60 s town day should tick the sim exactly once (day %d -> %d)" % [day_before, dashboard._simulation.day])
	check(absf(view.time_of_day() - dashboard._town_phase) < 0.0001, "The view clock should follow the town phase")
	dashboard._speed_multiplier = 0.0
	var paused_day: int = dashboard._simulation.day
	for i in 400:
		dashboard._process(0.25)
	check(dashboard._simulation.day == paused_day, "Paused town time must not tick the sim")
	check(not dashboard._speed_buttons[2].visible and dashboard._speed_buttons[1].text == "Play", "Town mode shows Pause/Play only")
	dashboard._set_town_mode(false)
	check(dashboard._speed_buttons[2].visible and dashboard._speed_buttons[1].text == "1x", "Dashboard mode restores the speed buttons")
	dashboard._set_town_mode(true)
	game_state.town_day_seconds = saved_day_seconds

	# The shared day/night function the RTS also uses.
	var sun := DirectionalLight3D.new()
	var env := Environment.new()
	var day_night: GDScript = load("res://scripts/world/day_night_cycle.gd")
	day_night.apply_time(0.5, sun, env, 0.15)
	check(is_equal_approx(sun.light_energy, 1.2), "Noon light energy should be 1.2 (got %f)" % sun.light_energy)
	day_night.apply_time(0.0, sun, env, 0.15)
	check(is_equal_approx(sun.light_energy, 0.0) and is_equal_approx(env.ambient_light_energy, 0.15), "Midnight is dark but keeps the minimum ambient")
	sun.free()

	# Advancing days and a new business must not move existing sites.
	dashboard._simulation.advance_ticks(30)
	dashboard._refresh()
	check(_positions(layout) == before, "Advancing days moved a site")
	var woodlot_option: Dictionary = {}
	for option in HEScenarioSeeds.business_types():
		if option["type_key"] == "woodlot":
			woodlot_option = option
	# The default preset has no woodlot only if the roster says so; otherwise
	# any unbuilt type will do.
	for option in HEScenarioSeeds.business_types():
		if not dashboard._simulation.has_business_of_type(dashboard._town_settlement_id(), option["type_key"]):
			woodlot_option = option
			break
	if not woodlot_option.is_empty():
		var index := HEScenarioSeeds.business_types().find(woodlot_option)
		dashboard._on_create_business_pressed(index)
		var after := _positions(layout)
		for site_id in before:
			check(after[site_id] == before[site_id], "Creating a business moved site %d" % site_id)
		check(after.size() == before.size() + 1, "A new business should add exactly one site")
		check(view.site_node_count() == after.size() - (1 if not layout.get_site(0)["built"] else 0), "View should draw every built site")

	# A house built mid-run (the Government build menu's "house") gets a plot
	# and the housing readout follows the housing report.
	var drawn_before: int = view.site_node_count()
	var house_script: GDScript = load("res://scripts/sim/household_economy/records/he_house.gd")
	dashboard._simulation.add_dwelling(house_script.new(dashboard._simulation.next_dwelling_id(), dashboard._town_settlement_id()))
	dashboard._refresh()
	check(view.site_node_count() == drawn_before + 1, "A new house should add exactly one drawn site")
	check(view._housing_label.text.begins_with("Housing: %d homes" % (house_count + 1)), "Town view should show the housing report (got '%s')" % view._housing_label.text)
	# The Town tab's housing line only refreshes while the dashboard is shown.
	var was_town_mode: bool = view.visible
	dashboard._set_town_mode(false)
	await process_frame
	await process_frame
	check(dashboard._housing_label.text.begins_with("%d homes" % (house_count + 1)), "Dashboard Town tab should show housing (got '%s')" % dashboard._housing_label.text)
	dashboard._set_town_mode(was_town_mode)

	# A failed business leaves its building, vacant, for the next business.
	var after_count: int = view.site_node_count()
	var ranch_site := layout.site_of_business(HEScenarioSeeds.CATTLE_RANCH_BUSINESS_ID)
	dashboard._simulation.businesses.erase(HEScenarioSeeds.CATTLE_RANCH_BUSINESS_ID)
	dashboard._refresh()
	var vacated := layout.get_site(ranch_site["site_id"])
	check(vacated["business_id"] == HETownLayout.NO_BUSINESS and vacated["built"], "A failed ranch should leave a vacant building")
	check(view.site_node_count() == after_count, "The vacant building stays drawn")

	# A Government-built house stands as a foundation first, then the house.
	var sim = dashboard._simulation
	var settlement_id: int = dashboard._town_settlement_id()
	var warehouse = HEScenarioSeeds.make_warehouse(sim.next_business_id(), settlement_id)
	sim.add_business(warehouse)
	warehouse.inventory[preload("res://scripts/sim/records/commodity.gd").Type.TIMBER] = 500.0
	sim.businesses[HEScenarioSeeds.GOVERNMENT_BUSINESS_ID].balance = 5000.0
	var house_index := -1
	for i in HEScenarioSeeds.government_buildings().size():
		if HEScenarioSeeds.government_buildings()[i]["type_key"] == "house":
			house_index = i
	dashboard._on_build_government_pressed(house_index)
	var construction: Array = sim.get_construction_reports(settlement_id)
	check(construction.size() == 1, "Pressing build house starts one construction")
	if construction.size() == 1:
		var lot := layout.site_of_dwelling(int(construction[0]["dwelling_id"]))
		check(not lot.is_empty() and lot["under_construction"], "The house's foundation has a lot")
		var lot_label: Label3D = view._site_nodes[lot["site_id"]]["label"]
		check(lot_label.text.ends_with("(under construction)"), "The foundation is labelled under construction (got '%s')" % lot_label.text)
		sim.advance_ticks(sim.construction_days)
		dashboard._refresh()
		check(not layout.get_site(lot["site_id"])["under_construction"], "The house replaces its foundation")
		lot_label = view._site_nodes[lot["site_id"]]["label"]
		check(not lot_label.text.contains("under construction"), "The finished house drops the construction label")
	print("TOWN VIEW %s" % ("OK" if failures == 0 else "FAILED (%d)" % failures))
	quit(0 if failures == 0 else 1)

## Villagers: one model per household member, milling in front of their own
## house (homeless at the plaza); clicking one opens the person window, whose
## buttons jump to the home and to the dashboard's person detail.
func _check_villagers(dashboard, view, layout: HETownLayout) -> void:
	var sim = dashboard._simulation
	var reports: Array = sim.get_villager_reports(dashboard._town_settlement_id())
	var population := 0
	for report in reports:
		population += (report["worker_ages"] as PackedInt32Array).size() + (report["dependent_ages"] as PackedInt32Array).size()
	check(population > 0 and view.villager_count() == population, "One villager per person (%d drawn, %d people)" % [view.villager_count(), population])
	var females := 0
	for key in view.villagers().villager_keys():
		if view.villagers()._villagers[key]["female"]:
			females += 1
	check(females > population / 5 and females < population * 4 / 5, "Both body models are in use (%d of %d female)" % [females, population])

	# Shadows follow the GameState setting (off by default). Set directly and
	# signalled by hand, so the check does not rewrite the user's settings file.
	var game_state: Node = root.get_node("GameState")
	var saved_shadows: bool = game_state.villager_shadows
	var shadow_mesh := view.villagers().find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	game_state.villager_shadows = false
	game_state.settings_changed.emit()
	check(shadow_mesh.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "Villager shadows off when the setting is off")
	game_state.villager_shadows = true
	game_state.settings_changed.emit()
	check(shadow_mesh.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON, "Villager shadows follow the setting when turned on")
	game_state.villager_shadows = saved_shadows
	game_state.settings_changed.emit()

	# Schedule: at midnight nobody housed is drawn, at noon workers are at work.
	# Everything after this runs at an at-home hour (see below).
	_check_day_cycle(view, layout, reports)

	# Each housed villager stands in its own yard (evening, before bedtime).
	view.set_time_of_day(20.2 / 24.0)
	var housed_key := Vector2i(-1, -1)
	var far := 0
	for report in reports:
		if int(report["dwelling_id"]) == -1:
			continue
		var site := layout.site_of_dwelling(int(report["dwelling_id"]))
		var position: Vector3 = view.villagers().villager_position(Vector2i(int(report["household_id"]), 1))
		if site.is_empty() or not position.is_finite():
			continue
		if Vector2(position.x, position.z).distance_to(site["position"]) > 9.0:
			far += 1
		if housed_key.x == -1:
			housed_key = Vector2i(int(report["household_id"]), 1)
	check(housed_key.x != -1, "Some villager has a house")
	check(far == 0, "Villagers mill in front of their own house (%d too far)" % far)

	# Milling: they move while the town clock runs and freeze while paused.
	var start: Vector3 = view.villagers().villager_position(housed_key)
	view.set_villagers_paused(false)
	for i in 120:
		view.set_time_of_day((20.2 + 0.004 * i) / 24.0)
		view.villagers()._process(0.1)
	var moved := false
	for key in view.villagers().villager_keys():
		moved = moved or view.villagers().villager_position(key) != start
	check(moved, "Villagers mill about while the town runs")
	view.set_villagers_paused(true)
	var frozen: Vector3 = view.villagers().villager_position(housed_key)
	view.villagers()._process(1.0)
	check(view.villagers().villager_position(housed_key) == frozen, "Paused villagers stand still")

	# Click a villager: the person window names them and their household.
	view.clear_selection()
	var position: Vector3 = view.villagers().villager_position(housed_key)
	var chest := position + Vector3.UP * 1.0
	_click(view, view.camera().unproject_position(chest))
	var picked: Vector2i = view.selected_villager()
	check(picked.x != -1, "Clicking a villager selects them")
	if picked.x == -1:
		view.select_villager(housed_key.x, housed_key.y)
		picked = housed_key
	check(view._info_panel.visible and view._info_title.text == "Household %d - Member %d" % [picked.x, picked.y], "Person window title (got '%s')" % view._info_title.text)
	check(view._info_body.text.contains("Household:") and view._home_button.visible and view._person_button.visible, "Person window shows the household and both buttons")

	# Show home: selects the household's house and centres the camera on it.
	var home_dwelling := int(view.villagers().household_report(picked.x)["dwelling_id"])
	view._on_home_pressed()
	var home_site := layout.site_of_dwelling(home_dwelling)
	check(view._selected_site_id == int(home_site["site_id"]) and view.selected_villager().x == -1, "Show home selects the villager's house")
	var rig: Node3D = view._rig
	check(Vector2(rig.position.x, rig.position.z).distance_to(home_site["position"]) < 0.5, "Show home centres the camera on the house")
	check(view._info_body.text.begins_with("Home of household") and view._info_body.text.contains(str(picked.x)), "The house panel lists the villager's household (got '%s')" % view._info_body.text)

	# Person details: back to the dashboard with that person open.
	view.select_villager(picked.x, picked.y)
	view._on_person_pressed()
	check(not view.visible and dashboard._selected_person_household_id == picked.x and dashboard._selected_person_number == picked.y, "Person details opens the dashboard person page")
	dashboard._set_town_mode(true)
	await process_frame

## Night and day: housed villagers are all indoors (hidden) at midnight, and
## employed workers are at their job at noon. Leaves the view at noon.
func _check_day_cycle(view, layout: HETownLayout, reports: Array) -> void:
	var layer = view.villagers()
	view.set_time_of_day(0.0)
	var visible_housed := 0
	var homeless_visible := 0
	var homeless := 0
	for report in reports:
		var housed := int(report["dwelling_id"]) != -1
		var count: int = (report["worker_ages"] as PackedInt32Array).size() + (report["dependent_ages"] as PackedInt32Array).size()
		for n in range(1, count + 1):
			var drawn: bool = layer.villager_visible(Vector2i(int(report["household_id"]), n))
			if housed and drawn:
				visible_housed += 1
			if not housed:
				homeless += 1
				homeless_visible += 1 if drawn else 0
	check(visible_housed == 0, "Nobody housed is visible at midnight (%d are)" % visible_housed)
	check(homeless_visible == homeless, "Homeless villagers stay visible at midnight")
	view.set_time_of_day(0.5)
	var at_work := 0
	var workers := 0
	for report in reports:
		var employer := int(report["employer_business_id"])
		var work := layout.site_of_business(employer) if employer != -1 else {}
		if work.is_empty():
			continue
		var worker_count: int = (report["worker_ages"] as PackedInt32Array).size()
		for n in range(1, worker_count + 1):
			var key := Vector2i(int(report["household_id"]), n)
			workers += 1
			var position: Vector3 = layer.villager_position(key)
			var near := layout.site_contains(work, Vector2(position.x, position.z)) or Vector2(position.x, position.z).distance_to(work["position"]) < 4.0 + maxf((work["footprint"] as Vector2).x, (work["footprint"] as Vector2).y)
			if near:
				at_work += 1
	check(workers > 0, "The seeded town has employed workers")
	check(at_work == workers, "Workers are at work at noon (%d of %d)" % [at_work, workers])
	# A hidden selected villager keeps the person window open, with the ring hidden.
	var hidden_key := Vector2i(-1, -1)
	for report in reports:
		if int(report["dwelling_id"]) != -1:
			hidden_key = Vector2i(int(report["household_id"]), 1)
			break
	if hidden_key.x != -1:
		view.set_time_of_day(0.0)
		view.select_villager(hidden_key.x, hidden_key.y)
		check(view.selected_villager() == hidden_key and view._info_panel.visible, "A hidden villager can still be selected from the dashboard")
		check(view._info_body.text.contains("Indoors"), "The person window says they are indoors (got '%s')" % view._info_body.text)
		check(not view._villager_marker.visible, "The selection ring hides while the villager is indoors")
		check(layer.pick(view.camera(), view.camera().unproject_position(layer.villager_position(hidden_key) + Vector3.UP)) != hidden_key, "Hidden villagers cannot be picked")
		view.clear_selection()

## Screen position (view-local) of a town-coordinate point, via the camera.
func _screen_of(view, town_point: Vector2) -> Vector2:
	return view.camera().unproject_position(Vector3(town_point.x, 0.0, town_point.y))

func _click(view, position: Vector2) -> void:
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = position
	view._gui_input(down)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = position
	view._gui_input(up)
