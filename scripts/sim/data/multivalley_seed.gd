extends RefCounted

## Shared seed adapter for the headless probe and interactive dashboard.
const Sim = preload("res://scripts/sim/simulation.gd")
const Seed = preload("res://scripts/sim/data/valley_seed.gd")
const SettlementRecord = preload("res://scripts/sim/records/settlement.gd")
const HouseholdRecord = preload("res://scripts/sim/records/household.gd")
const WorkplaceRecord = preload("res://scripts/sim/records/workplace.gd")
const EdgeRecord = preload("res://scripts/sim/records/transport_edge.gd")
const Goods = preload("res://scripts/sim/records/commodity.gd")

var graph: Dictionary = {}

func load_graph(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return "Cannot open graph: %s" % path
	var parser := JSON.new()
	var error := parser.parse(file.get_as_text())
	file.close()
	if error != OK or not parser.data is Dictionary:
		return "Invalid graph JSON: %s" % path
	var candidate: Dictionary = parser.data
	if candidate.get("schema_version", 0) != 1 or not _integer(candidate.get("seed")):
		return "Expected schema v1 and integer seed from generate_multivalley.py"
	if not candidate.get("settlements") is Array or not candidate.get("edges") is Array:
		return "Graph requires settlement and edge arrays"
	if candidate["settlements"].is_empty():
		return "Graph has no settlements"
	var ids: Dictionary = {}
	for node in candidate["settlements"]:
		if not node is Dictionary:
			return "Invalid settlement record"
		for field in ["id", "valley", "households", "archetype"]:
			if not _integer(node.get(field)) or int(node[field]) < 1:
				return "Settlement %s must be a positive integer" % field
		if ids.has(int(node["id"])) or int(node["archetype"]) > 5 or not node.get("name") is String:
			return "Duplicate settlement ID, invalid archetype, or missing name"
		ids[int(node["id"])] = true
	var edge_ids: Dictionary = {}
	var pairs: Dictionary = {}
	for edge in candidate["edges"]:
		if not edge is Dictionary:
			return "Invalid edge record"
		for field in ["id", "a", "b"]:
			if not _integer(edge.get(field)) or int(edge[field]) < 1:
				return "Edge %s must be a positive integer" % field
		var a: int = int(edge["a"])
		var b: int = int(edge["b"])
		var pair := "%d:%d" % [mini(a, b), maxi(a, b)]
		if a == b or not ids.has(a) or not ids.has(b) or edge_ids.has(int(edge["id"])) or pairs.has(pair):
			return "Invalid edge endpoints or duplicate edge"
		for field in ["capacity", "days_ab", "days_ba", "toll", "risk"]:
			if not _number(edge.get(field)) or float(edge[field]) < 0.0:
				return "Edge %s must be finite and nonnegative" % field
		if float(edge["days_ab"]) <= 0.0 or float(edge["days_ba"]) <= 0.0:
			return "Edge travel times must be positive"
		if edge.get("kind") not in ["river", "feeder", "track", "pass"]:
			return "Unknown edge kind"
		edge_ids[int(edge["id"])] = true
		pairs[pair] = true
	graph = candidate
	return ""

func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))

func _integer(value: Variant) -> bool:
	return _number(value) and float(value) == floor(float(value))

func build(rng: RandomNumberGenerator) -> Dictionary:
	# Borrow current authored recipes/roles, not a second economic model.
	var template: Dictionary = Seed.build_default_valley(rng)
	var settlements: Dictionary[int, SettlementRecord] = {}
	var households: Dictionary[int, HouseholdRecord] = {}
	var workplaces: Dictionary[int, WorkplaceRecord] = {}
	var edges: Dictionary[int, EdgeRecord] = {}
	for node in graph["settlements"]:
		var sid: int = int(node["id"])
		var role: int = int(node["archetype"])
		var count: int = int(node["households"])
		var source = template["settlements"][role]
		var settlement = SettlementRecord.new(sid, str(node["name"]))
		# No player holding: one failed town must not stop the whole benchmark.
		settlements[sid] = settlement
		var scale: float = float(count) / source.household_ids.size()
		for c in Goods.ALL:
			settlement.add_stock(c, source.stock(c) * scale)
		for i in range(count):
			var hid: int = households.size() + 1
			var household = HouseholdRecord.new(hid, sid, rng.randi_range(1, 3), rng.randi_range(0, 4))
			households[hid] = household
			settlement.household_ids.append(hid)
		# Finite 90-day household food buffer, never replenished by the harness.
		var population: int = 0
		for hid in settlement.household_ids:
			population += households[hid].headcount()
		settlement.add_stock(Goods.Type.GRAIN, population * Sim.GRAIN_PER_PERSON_PER_DAY * 90.0)
		for wid in source.workplace_ids:
			var original = template["workplaces"][wid]
			var new_id: int = workplaces.size() + 1
			var target: float = original.target_labor * scale
			if original.kind == WorkplaceRecord.Kind.TRADE_CENTER:
				target = original.target_labor
			var workplace = WorkplaceRecord.new(new_id, sid, original.recipe, target, original.kind)
			workplaces[new_id] = workplace
			settlement.workplace_ids.append(new_id)
	for item in graph["edges"]:
		var eid: int = int(item["id"])
		var mode = EdgeRecord.Mode.RIVER_BARGE if item["kind"] == "river" else EdgeRecord.Mode.CART
		edges[eid] = EdgeRecord.new(eid, int(item["a"]), int(item["b"]), mode,
			float(item["capacity"]), float(item["days_ab"]), float(item["days_ba"]),
			float(item["toll"]), float(item["risk"]))
	return {"settlements": settlements, "households": households,
		"workplaces": workplaces, "transport_edges": edges}
