extends Control

## Cached, interactive graph view over public Simulation snapshots.
## Layout, selection, pan/zoom and overlays never change simulation state.
signal settlement_selected(settlement_id: int)

const Simulation = preload("res://scripts/sim/simulation.gd")
const TransportEdge = preload("res://scripts/sim/records/transport_edge.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")
const AUTHORED_POSITIONS := {
	1: Vector2(405, 330), 2: Vector2(108, 90), 3: Vector2(675, 72),
	4: Vector2(792, 330), 5: Vector2(558, 528),
}
const STATUS_COLORS := {
	"stable": Color("64bd83"), "food_insecure": Color("e0c45b"),
	"contracting": Color("db904f"), "collapsed": Color("a85159"),
}

var simulation: Simulation
var graph: Dictionary = {}
var overlay: int = 0 # 0 routes, 1 weekly capacity, 2 cargo currently in transit
var selected_id: int = -1
var tick_fraction: float = 0.0
var _positions: Dictionary = {}
var _groups: Array = []
var _summaries: Dictionary = {}
var _edges: Array = []
var _shipments: Array = []
var _traffic: Dictionary = {}
var _bounds := Rect2()
var _zoom: float = 1.0
var _pan := Vector2.ZERO
var _dragging: bool = false
var _fitted: bool = false

func _ready() -> void:
	clip_contents = true
	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	resized.connect(func() -> void:
		if not _fitted and size.x > 0 and size.y > 0:
			fit_graph()
		queue_redraw())
	refresh_snapshot()
	call_deferred("fit_graph")

func refresh_snapshot() -> void:
	if simulation == null:
		return
	_summaries.clear()
	for sid in simulation.get_settlement_ids():
		_summaries[sid] = simulation.get_settlement_summary(sid)
	_edges.clear()
	for eid in simulation.get_transport_edge_ids():
		_edges.append(simulation.get_transport_edge_summary(eid))
	_shipments = simulation.get_active_shipments()
	_traffic.clear()
	for shipment in _shipments:
		var eid: int = shipment["edge_id"]
		_traffic[eid] = float(_traffic.get(eid, 0.0)) + float(shipment["quantity"])
	if _positions.is_empty():
		_build_layout()
	queue_redraw()

func _build_layout() -> void:
	_positions.clear()
	_groups.clear()
	if graph.is_empty() and _summaries.size() == 5:
		_positions = AUTHORED_POSITIONS.duplicate()
		_bounds = Rect2(40, 30, 820, 570)
		return
	var members: Dictionary = {}
	for node in graph.get("settlements", []):
		var valley: int = int(node["valley"])
		if not members.has(valley):
			members[valley] = []
		members[valley].append(int(node["id"]))
	if members.is_empty():
		members[1] = _summaries.keys()
	var valleys: Array = members.keys()
	valleys.sort()
	var largest: int = 1
	for ids in members.values():
		largest = maxi(largest, ids.size())
	var local_columns: int = ceili(sqrt(float(largest)))
	var local_rows: int = ceili(float(largest) / local_columns)
	var group_size := Vector2(local_columns * 150.0 + 60, local_rows * 100.0 + 70)
	var columns: int = ceili(sqrt(float(valleys.size())))
	for index in range(valleys.size()):
		var valley: int = valleys[index]
		var ids: Array = members[valley]
		ids.sort()
		var row: int = floori(float(index) / columns)
		var col: int = index % columns
		if row % 2 == 1:
			col = columns - 1 - col
		var origin := Vector2(col, row) * (group_size + Vector2(60, 60))
		_groups.append({"rect": Rect2(origin, group_size), "label": "Valley %d" % valley})
		for i in range(ids.size()):
			_positions[ids[i]] = origin + Vector2(100 + (i % local_columns) * 150, 90 + floori(float(i) / local_columns) * 100)
	_bounds = Rect2(Vector2.ZERO, Vector2(columns, ceili(float(valleys.size()) / columns)) * (group_size + Vector2(60, 60)))

func fit_graph() -> void:
	if _bounds.size.x <= 0 or size.x <= 0 or size.y <= 0:
		return
	_zoom = clampf(minf((size.x - 40) / _bounds.size.x, (size.y - 40) / _bounds.size.y), 0.02, 4.0)
	_pan = size * 0.5 - _bounds.get_center() * _zoom
	_fitted = true
	queue_redraw()

func _screen(sid: int) -> Vector2:
	return (_positions.get(sid, Vector2.ZERO) as Vector2) * _zoom + _pan

func _hit_node(point: Vector2) -> int:
	var closest: int = -1
	var distance: float = 16.0
	for sid in _positions:
		var d: float = point.distance_to(_screen(sid))
		if d < distance:
			closest = sid
			distance = d
	return closest

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mouse: InputEventMouseButton = event
		if mouse.pressed and mouse.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var world: Vector2 = (mouse.position - _pan) / _zoom
			_zoom = clampf(_zoom * (1.2 if mouse.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.2), 0.02, 4.0)
			_pan = mouse.position - world * _zoom
			accept_event()
		elif mouse.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT]:
			grab_focus()
			_dragging = mouse.pressed
			if mouse.pressed and mouse.button_index == MOUSE_BUTTON_LEFT:
				var sid: int = _hit_node(mouse.position)
				if sid >= 0:
					selected_id = sid
					_dragging = false
					settlement_selected.emit(sid)
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		_pan += (event as InputEventMouseMotion).relative
		accept_event()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_F:
		fit_graph()
		accept_event()
	queue_redraw()

func _get_tooltip(at_position: Vector2) -> String:
	var sid: int = _hit_node(at_position)
	if sid >= 0 and _summaries.has(sid):
		var s: Dictionary = _summaries[sid]
		return "%s\nPopulation %d | %s\n30-day food fulfillment %.0f%%\nClick to inspect" % [s["name"], s["population"], s["status"], s["grain_fulfillment_rolling_30d"] * 100]
	for edge in _edges:
		var a: Vector2 = _screen(edge["settlement_a_id"])
		var b: Vector2 = _screen(edge["settlement_b_id"])
		if at_position.distance_to(Geometry2D.get_closest_point_to_segment(at_position, a, b)) <= 6:
			return "%s ↔ %s\nCapacity %.1f units/week (shared both directions)\nCargo in transit %.1f units\nTravel %.1f / %.1f days\nToll/risk are routing signals" % [edge["settlement_a_name"], edge["settlement_b_name"], edge["capacity"], _traffic.get(edge["id"], 0.0), edge["travel_time_days_a_to_b"], edge["travel_time_days_b_to_a"]]
	return "Wheel: zoom | Drag background / middle / right: pan | F: fit"

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("121d29"))
	if simulation == null:
		return
	var font: Font = ThemeDB.fallback_font
	for group in _groups:
		var rect: Rect2 = group["rect"]
		var screen_rect := Rect2(rect.position * _zoom + _pan, rect.size * _zoom)
		draw_rect(screen_rect, Color("1b2c3b"))
		draw_rect(screen_rect, Color("344c60"), false, 1)
		draw_string(font, screen_rect.position + Vector2(8, 20), group["label"], HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("a6bed2"))
	for edge in _edges:
		var color := Color("498db3") if edge["mode"] == TransportEdge.Mode.RIVER_BARGE else Color("8a7863")
		var width: float = 1.5
		if overlay == 1:
			width = clampf(sqrt(float(edge["capacity"])) * 0.3, 1.0, 9.0)
		elif overlay == 2:
			var cargo: float = _traffic.get(edge["id"], 0.0)
			color = Color("ffd17a") if cargo > 0 else Color("344453")
			width = clampf(sqrt(cargo) * 0.3, 1.0, 9.0)
		draw_line(_screen(edge["settlement_a_id"]), _screen(edge["settlement_b_id"]), color, width, true)
	for sid in _positions:
		var pos: Vector2 = _screen(sid)
		if not Rect2(Vector2.ZERO, size).grow(80).has_point(pos):
			continue
		var summary: Dictionary = _summaries[sid]
		var radius: float = clampf(13 * _zoom, 5, 15)
		if sid == selected_id:
			draw_circle(pos, radius + 4, Color("ffffff"), false, 2, true)
		draw_circle(pos, radius, STATUS_COLORS.get(summary["status"], Color.GRAY))
		if _zoom >= 0.55 or sid == selected_id:
			var label: String = summary["name"] if graph.is_empty() else "#%d" % sid
			draw_string(font, pos + Vector2(12, 5), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("edf3f8"))
	for shipment in _shipments:
		var duration: float = maxf(1.0, float(shipment["arrival_day"] - shipment["departure_day"]))
		var progress: float = clampf(float(shipment["progress_fraction"]) + tick_fraction / duration, 0, 1)
		var a: Vector2 = _screen(shipment["origin_settlement_id"])
		var b: Vector2 = _screen(shipment["destination_settlement_id"])
		var pos: Vector2 = a.lerp(b, progress)
		var direction: Vector2 = (b - a).normalized()
		var normal := Vector2(-direction.y, direction.x)
		# Offset opposing traffic so both directions remain distinguishable.
		pos += normal * 4
		draw_colored_polygon(PackedVector2Array([pos + direction * 6, pos - direction * 4 + normal * 3, pos - direction * 4 - normal * 3]), Color("fff5d6"))
