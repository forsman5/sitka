extends SceneTree

## Run with the same --graph=PATH argument as the dashboard (or omit for five).
const Dashboard = preload("res://scripts/sim/dashboard.gd")
var failures: int = 0

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func _run() -> void:
	var dashboard = Dashboard.new()
	root.add_child(dashboard)
	dashboard._speed_multiplier = 0.0
	await process_frame
	await process_frame
	var map = dashboard._route_map
	var sim = dashboard._simulation
	if sim == null:
		quit(1)
		return
	map.fit_graph()
	var ids: Array = sim.get_settlement_ids()
	check(map._positions.size() == ids.size(), "Every settlement must have a position")
	var unique: Dictionary = {}
	for position in map._positions.values():
		unique[position] = true
	check(unique.size() == ids.size(), "Settlement positions must not overlap")
	var before: String = JSON.stringify(sim.get_clock_summary()) + JSON.stringify(sim.get_settlement_summary(ids[0]))
	var last_id: int = ids[-1]
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = map._screen(last_id)
	map._gui_input(click)
	check(dashboard._selected_id == last_id, "Click must select settlement in dashboard")
	check(dashboard._settlement_rows.size() == 1 and dashboard._settlement_rows.has(last_id), "Only selected inspection panel should be built")
	check(dashboard._settlement_picker.get_selected_id() == last_id, "Picker must track map selection")
	var cursor := Vector2(200, 150)
	var anchor: Vector2 = (cursor - map._pan) / map._zoom
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	wheel.position = cursor
	map._gui_input(wheel)
	check(anchor.is_equal_approx((cursor - map._pan) / map._zoom), "Zoom must preserve cursor anchor")
	var pan_before: Vector2 = map._pan
	var middle := InputEventMouseButton.new()
	middle.button_index = MOUSE_BUTTON_MIDDLE
	middle.pressed = true
	map._gui_input(middle)
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(30, -20)
	map._gui_input(motion)
	check(map._pan.is_equal_approx(pan_before + motion.relative), "Drag must pan")
	middle.pressed = false
	map._gui_input(middle)
	map.fit_graph()
	for mode in range(4):
		map.overlay = mode
		map.queue_redraw()
		await process_frame
	check(dashboard._bottom_tabs.get_tab_count() == 2, "Bottom area must have two tabs")
	for tab in range(2):
		dashboard._bottom_tabs.current_tab = tab
		await process_frame
		check(dashboard._bottom_tabs.size.y <= 230, "Bottom tabs must remain compact")
	for commodity in map.Commodity.ALL:
		map.selected_commodity = commodity
		map.refresh_prices()
		var total: float = 0.0
		for sid in ids:
			total += float(sim.get_settlement_prices(sid)[map.Commodity.name_of(commodity)])
		check(is_equal_approx(map.price_mean, total / ids.size()), "Mean must include all nodes equally")
		check(map._get_tooltip(map._screen(last_id)).contains("world mean"), "Price tooltip must show global comparison")
	map.selected_commodity = -1
	map.refresh_prices()
	check(map.price_mean == 0.0 and map._prices.is_empty(), "\"All\" filter must not compute a single-commodity price")
	var mean_color: Color = map.price_color(2.0, 2.0)
	var low_color: Color = map.price_color(1.0, 2.0)
	var high_color: Color = map.price_color(3.0, 2.0)
	check(low_color.g > low_color.r and high_color.r > high_color.g, "Price colors must be green below mean and red above")
	check(mean_color == map.price_color(0.0, 0.0), "Equal and zero means must remain neutral")
	check(before == JSON.stringify(sim.get_clock_summary()) + JSON.stringify(sim.get_settlement_summary(ids[0])), "View actions must not change economics or time")
	sim.advance_ticks(7)
	dashboard._refresh()
	var cargo: Dictionary = {}
	for shipment in sim.get_active_shipments():
		var eid: int = shipment["edge_id"]
		cargo[eid] = float(cargo.get(eid, 0.0)) + float(shipment["quantity"])
	check(cargo == map._traffic, "Traffic overlay must equal in-flight cargo snapshots")
	check(map._shipments == sim.get_active_shipments(), "Markers must reflect authoritative shipment snapshots")
	check(map.size.x > 0 and map.size.y >= 260, "Map needs visible layout space")
	print("Graph view checks: %d settlements, %d failures" % [ids.size(), failures])
	dashboard.queue_free()
	await process_frame
	quit(1 if failures else 0)
