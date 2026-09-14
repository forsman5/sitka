extends Control

## Milestone 1.1: a graph-theory-textbook-style schematic of the valley's
## settlements, routes, and in-transit shipments -- not a map, not to scale.
## Pure view: reads Simulation's query methods each _draw() call and owns no
## simulation truth itself. Node layout below is display-only data, not
## authoritative geography (that's Milestone 2's real terrain/camera work).

const Simulation = preload("res://scripts/sim/simulation.gd")
const TransportEdge = preload("res://scripts/sim/records/transport_edge.gd")

## Normalized (0..1) positions, scaled to this control's current size each
## draw. Keyed by ValleySeed's settlement ids (Aldford=1 .. Staithe=5).
## Loosely mirrors the valley's described relative geography: Aldford
## central where the overland routes meet the river; High Fell/Oakmere
## upstream; Ironbank just downstream of Oakmere; Staithe further downstream.
const NODE_POSITIONS_NORMALIZED := {
	1: Vector2(0.45, 0.55), # Aldford
	2: Vector2(0.12, 0.15), # High Fell
	3: Vector2(0.75, 0.12), # Oakmere
	4: Vector2(0.88, 0.55), # Ironbank
	5: Vector2(0.62, 0.88), # Staithe
}

const STATUS_COLORS := {
	"stable": Color(0.35, 0.75, 0.4),
	"food_insecure": Color(0.85, 0.75, 0.25),
	"contracting": Color(0.85, 0.5, 0.2),
	"collapsed": Color(0.55, 0.2, 0.2),
}
const DEFAULT_NODE_COLOR := Color(0.6, 0.6, 0.6)

const EDGE_COLORS := {
	TransportEdge.Mode.CART: Color(0.55, 0.45, 0.35, 0.7),
	TransportEdge.Mode.RIVER_BARGE: Color(0.3, 0.55, 0.85, 0.75),
	TransportEdge.Mode.FOOT: Color(0.5, 0.5, 0.5, 0.5),
	TransportEdge.Mode.CATTLE_DRIVE: Color(0.6, 0.4, 0.2, 0.6),
}

const NODE_RADIUS := 16.0
const SHIPMENT_RADIUS := 5.0

var simulation: Simulation

func _node_position(settlement_id: int, ids: Array[int], index: int) -> Vector2:
	if NODE_POSITIONS_NORMALIZED.has(settlement_id):
		return (NODE_POSITIONS_NORMALIZED[settlement_id] as Vector2) * size
	# Fallback for any settlement without an authored position: spread
	# evenly around a circle so the map degrades gracefully instead of
	# stacking everything at the origin.
	var angle := TAU * float(index) / float(max(1, ids.size()))
	var center := size * 0.5
	var radius: float = min(size.x, size.y) * 0.35
	return center + Vector2(cos(angle), sin(angle)) * radius

func _draw() -> void:
	if simulation == null:
		return

	var ids := simulation.get_settlement_ids()
	var positions := {}
	for i in ids.size():
		positions[ids[i]] = _node_position(ids[i], ids, i)

	for edge_id in simulation.get_transport_edge_ids():
		var edge := simulation.get_transport_edge_summary(edge_id)
		var a: Vector2 = positions.get(edge["settlement_a_id"], size * 0.5)
		var b: Vector2 = positions.get(edge["settlement_b_id"], size * 0.5)
		var color: Color = EDGE_COLORS.get(edge["mode"], Color(0.5, 0.5, 0.5, 0.5))
		draw_line(a, b, color, 2.0)

	var font := ThemeDB.fallback_font
	var font_size := ThemeDB.fallback_font_size

	for settlement_id in ids:
		var summary := simulation.get_settlement_summary(settlement_id)
		var pos: Vector2 = positions[settlement_id]
		var color: Color = STATUS_COLORS.get(summary["status"], DEFAULT_NODE_COLOR)
		draw_circle(pos, NODE_RADIUS, color)
		draw_circle(pos, NODE_RADIUS, Color(0, 0, 0, 0.4), false, 1.5)
		draw_string(font, pos + Vector2(-60.0, NODE_RADIUS + 14.0), summary["name"], HORIZONTAL_ALIGNMENT_CENTER, 120.0, font_size)

	for shipment in simulation.get_active_shipments():
		var origin: Vector2 = positions.get(shipment["origin_settlement_id"], size * 0.5)
		var destination: Vector2 = positions.get(shipment["destination_settlement_id"], size * 0.5)
		var pos: Vector2 = origin.lerp(destination, shipment["progress_fraction"])
		draw_circle(pos, SHIPMENT_RADIUS, Color(1.0, 1.0, 1.0, 0.9))
		draw_circle(pos, SHIPMENT_RADIUS, Color(0, 0, 0, 0.6), false, 1.0)
