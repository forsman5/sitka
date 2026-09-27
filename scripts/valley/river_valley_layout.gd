class_name RiverValleyLayout
extends RefCounted

const MapDefinition = preload("res://scripts/valley/valley_map_definition.gd")

## The single authored map. Simulation IDs link records, but simulation code
## never depends on visual positions. Waterfront anchors stay fixed when a
## settlement site moves; road endpoints and woodland centers follow its site.
static func create_map() -> MapDefinition:
	var map := MapDefinition.new()
	map.settlements = {
		1: {"site": Vector3(-16, 0, 7), "waterfront": {"junction": "aldford"}, "role": "Ford, mixed farms, and the clan hall", "accent": Color("d6b45c"), "district": "fields"},
		2: {"site": Vector3(-118, 0, 72), "role": "Upland pasture for sheep, cattle, and wool", "accent": Color("a7c884"), "district": "pasture"},
		3: {"site": Vector3(-137, 0, -64), "role": "Tributary woodland for timber and charcoal", "accent": Color("547a45"), "district": "woodland"},
		4: {"site": Vector3(110, 0, -70), "role": "Ore bank and small bloomery", "accent": Color("a66a4a"), "district": "ore"},
		5: {"site": Vector3(81, 0, 108), "waterfront": Vector3(92, 0, 94), "role": "Downstream port, milling, and outside trade", "accent": Color("739fc1"), "district": "port"},
	}
	map.junctions = {
		"aldford": {"position": Vector3(0, 0, -5), "inner_radius": 18.0, "outer_radius": 38.0},
	}
	map.rivers = {
		"main": {"node_name": "MainRiver", "width": 18.0, "points": [Vector3(-22, 0, -120), Vector3(-13, 0, -90), Vector3(-5, 0, -55), {"junction": "aldford"}, Vector3(25, 0, 25), Vector3(55, 0, 55), {"waterfront": 5}, Vector3(130, 0, 120)]},
		"tributary": {"node_name": "Tributary", "width": 10.0, "points": [Vector3(-158, 0, -112), Vector3(-145, 0, -95), Vector3(-128, 0, -78), Vector3(-80, 0, -50), Vector3(-35, 0, -27), {"junction": "aldford"}]},
	}
	map.crossings = {
		"aldford": {"kind": "ford", "name": "Aldford", "road": "aldford_approach", "river": "main", "position": Vector3(0, 0, -1), "radius": 20.0, "width": 4.2, "seed": 4107},
		"upstream": {"kind": "ford", "name": "Upstream", "road": "oakmere_ironbank", "river": "main", "position": Vector3(-9, 0, -74), "radius": 20.0, "width": 3.8, "seed": 8307},
		"oakmere": {"kind": "ford", "name": "Oakmere", "road": "oakmere_ironbank", "river": "tributary", "position": Vector3(-126, 0, -78), "radius": 16.0, "width": 3.8, "seed": 8407},
	}
	map.roads = {
		"high_fell_aldford": {"simulation_edge": 1, "width": 2.1, "seed": 17, "points": [{"settlement": 2}, Vector3(-84, 0, 55), Vector3(-48, 0, 29), {"settlement": 1, "offset": Vector3(-2, 0, 0)}, {"settlement": 1}]},
		"oakmere_aldford": {"simulation_edge": 2, "width": 2.1, "seed": 34, "points": [{"settlement": 3}, Vector3(-116, 0, -56), Vector3(-94, 0, -43), Vector3(-72, 0, -33), Vector3(-50, 0, -22), Vector3(-29, 0, -9), {"settlement": 1}]},
		"oakmere_ironbank": {"simulation_edge": 3, "width": 2.1, "seed": 51, "points": [{"settlement": 3}, {"crossing": "oakmere", "offset": Vector3(-8, 0, 10)}, {"crossing": "oakmere"}, {"crossing": "oakmere", "offset": Vector3(8, 0, -10)}, Vector3(-110, 0, -90), Vector3(-80, 0, -76.3866), Vector3(-40, 0, -75.042), {"crossing": "upstream"}, Vector3(0, 0, -73.6975), {"settlement": 4}]},
		"aldford_approach": {"simulation_edge": 0, "width": 2.4, "seed": 41, "points": [{"settlement": 1, "offset": Vector3(-2, 0, 0)}, {"crossing": "aldford", "offset": Vector3(-13, 0, 3)}, {"crossing": "aldford"}, {"crossing": "aldford", "offset": Vector3(14, 0, -3)}, Vector3(22, 0, -8), Vector3(28, 0, -15)]},
	}
	map.vegetation = {
		"oakmere_woodland": {"center": {"settlement": 3, "offset": Vector3(9, 0, -14)}, "radii": Vector2(46, 34), "count": 210, "seed": 5103, "clearance": 14.0},
		"aldford_riverbank": {"center": {"settlement": 1, "offset": Vector3(1, 0, 10)}, "radii": Vector2(24, 13), "count": 26, "seed": 5104, "clearance": 7.0},
		"staithe_riverbank": {"center": {"settlement": 5, "offset": Vector3(-4, 0, -29)}, "radii": Vector2(27, 16), "count": 32, "seed": 5105, "clearance": 8.0},
		"high_fell_fringe": {"center": {"settlement": 2}, "radii": Vector2(31, 18), "count": 16, "seed": 5106, "clearance": 10.0},
	}
	return map
