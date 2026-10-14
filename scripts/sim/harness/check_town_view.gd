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
	check(view._housing_label.text.begins_with("Housing: %d houses" % (house_count + 1)), "Town view should show the housing report (got '%s')" % view._housing_label.text)
	check(dashboard._housing_label.text.begins_with("%d houses" % (house_count + 1)), "Dashboard Town tab should show housing (got '%s')" % dashboard._housing_label.text)

	# A failed business leaves its building, vacant, for the next business.
	var after_count: int = view.site_node_count()
	var ranch_site := layout.site_of_business(HEScenarioSeeds.CATTLE_RANCH_BUSINESS_ID)
	dashboard._simulation.businesses.erase(HEScenarioSeeds.CATTLE_RANCH_BUSINESS_ID)
	dashboard._refresh()
	var vacated := layout.get_site(ranch_site["site_id"])
	check(vacated["business_id"] == HETownLayout.NO_BUSINESS and vacated["built"], "A failed ranch should leave a vacant building")
	check(view.site_node_count() == after_count, "The vacant building stays drawn")
	print("TOWN VIEW %s" % ("OK" if failures == 0 else "FAILED (%d)" % failures))
	quit(0 if failures == 0 else 1)

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
