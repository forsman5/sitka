class_name RiverValleyLayout
extends RefCounted

## The visual map owns these coordinates. Simulation records deliberately do
## not know about Godot positions, which keeps the simulation headless and
## lets later milestones replace this presentation without changing its data.

const SETTLEMENTS := {
	1: {
		"position": Vector3(0.0, 0.0, 6.0),
		"role": "Ford, mixed farms, and the clan hall",
		"accent": Color("d6b45c"),
		"district": "fields",
	},
	2: {
		"position": Vector3(-70.0, 7.0, -42.0),
		"role": "Upland pasture for sheep, cattle, and wool",
		"accent": Color("a7c884"),
		"district": "pasture",
	},
	3: {
		"position": Vector3(-48.0, 1.0, 48.0),
		"role": "Tributary woodland for timber and charcoal",
		"accent": Color("547a45"),
		"district": "woodland",
	},
	4: {
		"position": Vector3(48.0, 1.0, 42.0),
		"role": "Ore bank and small bloomery",
		"accent": Color("a66a4a"),
		"district": "ore",
	},
	5: {
		"position": Vector3(76.0, 0.0, -46.0),
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
		Vector3(-12.0, 0.08, 105.0), Vector3(-8.0, 0.08, 72.0),
		Vector3(-2.0, 0.08, 37.0), Vector3(0.0, 0.08, 6.0),
		Vector3(19.0, 0.08, -18.0), Vector3(48.0, 0.08, -32.0),
		Vector3(76.0, 0.08, -46.0), Vector3(108.0, 0.08, -72.0),
	])

static func tributary() -> PackedVector3Array:
	return PackedVector3Array([
		Vector3(-70.0, 0.12, 72.0), Vector3(-54.0, 0.12, 56.0),
		Vector3(-35.0, 0.12, 42.0), Vector3(-18.0, 0.12, 24.0),
		Vector3(0.0, 0.12, 6.0),
	])
