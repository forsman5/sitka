class_name RiverValleyLayout
extends RefCounted

## The visual map owns these coordinates. Simulation records deliberately do
## not know about Godot positions, which keeps the simulation headless and
## lets later milestones replace this presentation without changing its data.

const SETTLEMENTS := {
	1: {
		"position": Vector3(0.0, 0.0, -5.0),
		"role": "Ford, mixed farms, and the clan hall",
		"accent": Color("d6b45c"),
		"district": "fields",
	},
	2: {
		"position": Vector3(-118.0, 0.0, 72.0),
		"role": "Upland pasture for sheep, cattle, and wool",
		"accent": Color("a7c884"),
		"district": "pasture",
	},
	3: {
		"position": Vector3(-128.0, 0.0, -78.0),
		"role": "Tributary woodland for timber and charcoal",
		"accent": Color("547a45"),
		"district": "woodland",
	},
	4: {
		"position": Vector3(110.0, 0.0, -70.0),
		"role": "Ore bank and small bloomery",
		"accent": Color("a66a4a"),
		"district": "ore",
	},
	5: {
		"position": Vector3(92.0, 0.0, 94.0),
		"role": "Downstream port, milling, and outside trade",
		"accent": Color("739fc1"),
		"district": "port",
	},
}

## These match ValleySeed._build_transport_edges(). Routes are drawn from
## their endpoint positions; the type only controls presentation in Milestone
## 2, not simulation behavior.
const EDGES := {
	1: {"kind": "track"},
	2: {"kind": "track"},
	3: {"kind": "track"},
	4: {"kind": "river"},
	5: {"kind": "river"},
	6: {"kind": "river"},
}

static func settlement_position(settlement_id: int) -> Vector3:
	return SETTLEMENTS[settlement_id]["position"]

static func role_for(settlement_id: int) -> String:
	return SETTLEMENTS[settlement_id]["role"]

static func main_river() -> PackedVector3Array:
	return PackedVector3Array([
		Vector3(-22.0, 0.0, -120.0), Vector3(-13.0, 0.0, -90.0),
		Vector3(-5.0, 0.0, -55.0), Vector3(0.0, 0.0, -5.0),
		Vector3(25.0, 0.0, 25.0), Vector3(55.0, 0.0, 55.0),
		Vector3(92.0, 0.0, 94.0), Vector3(130.0, 0.0, 120.0),
	])

static func tributary() -> PackedVector3Array:
	return PackedVector3Array([
		Vector3(-158.0, 0.0, -112.0), Vector3(-145.0, 0.0, -95.0),
		Vector3(-128.0, 0.0, -78.0), Vector3(-80.0, 0.0, -50.0),
		Vector3(-35.0, 0.0, -27.0), Vector3(0.0, 0.0, -5.0),
	])

static func track_path(edge_id: int, from_pos: Vector3, to_pos: Vector3) -> PackedVector3Array:
	# The Oakmere road deliberately follows the tributary bank instead of
	# occupying the water centerline. Both Aldford approaches bend into the
	# settlement so the landing/ford reads as a connected place, not a hub of
	# ruler-straight ribbons.
	match edge_id:
		1:
			return PackedVector3Array([
				from_pos, Vector3(-84.0, 0.0, 55.0), Vector3(-48.0, 0.0, 29.0),
				Vector3(-18.0, 0.0, 7.0), Vector3(-5.5, 0.0, -2.0),
			])
		2:
			return PackedVector3Array([
				from_pos, Vector3(-102.0, 0.0, -65.0), Vector3(-69.0, 0.0, -47.0),
				Vector3(-37.0, 0.0, -30.0), Vector3(-8.0, 0.0, -11.0),
			])
		_:
			return PackedVector3Array([from_pos, to_pos])
