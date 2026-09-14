extends SceneTree

## Opt-in headless scale probe. Uses the production Simulation unchanged.
const Sim = preload("res://scripts/sim/simulation.gd")
const Seed = preload("res://scripts/sim/data/valley_seed.gd")
const SettlementRecord = preload("res://scripts/sim/records/settlement.gd")
const HouseholdRecord = preload("res://scripts/sim/records/household.gd")
const WorkplaceRecord = preload("res://scripts/sim/records/workplace.gd")
const EdgeRecord = preload("res://scripts/sim/records/transport_edge.gd")
const Goods = preload("res://scripts/sim/records/commodity.gd")

var graph: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var options: Dictionary = {"days": "360", "out": "user://multivalley.jsonl"}
	for arg in OS.get_cmdline_user_args():
		var parts: PackedStringArray = arg.trim_prefix("--").split("=", true, 1)
		if parts.size() != 2 or parts[0] not in ["graph", "days", "out"]:
			_fail("Use --graph=PATH --days=360 --out=PATH after Godot's -- separator")
			return
		options[parts[0]] = parts[1]
	var day_text: String = options["days"]
	if not options.has("graph") or not day_text.is_valid_int() or int(day_text) < 1:
		_fail("A graph path and positive integer days are required")
		return
	var input: FileAccess = FileAccess.open(options["graph"], FileAccess.READ)
	if input == null:
		_fail("Cannot open graph: %s" % options["graph"])
		return
	var parser := JSON.new()
	if parser.parse(input.get_as_text()) != OK or not parser.data is Dictionary:
		_fail("Invalid graph JSON")
		return
	input.close()
	graph = parser.data
	if graph.get("schema_version", 0) != 1 or not graph.has("settlements") or not graph.has("edges"):
		_fail("Expected schema v1 from tools/generate_multivalley.py")
		return
	var output: FileAccess = FileAccess.open(options["out"], FileAccess.WRITE)
	if output == null:
		_fail("Cannot write output (create its parent directory first)")
		return
	var sim = Sim.new(int(graph["seed"]), Callable(self, "_build"))
	output.store_line(JSON.stringify({"type": "configuration", "graph": graph,
		"days": int(day_text), "godot": Engine.get_version_info()}))
	var simulation_usec: int = 0
	var report_usec: int = 0
	for index in range(int(day_text)):
		var start: int = Time.get_ticks_usec()
		sim.advance_ticks(1)
		simulation_usec += Time.get_ticks_usec() - start
		# Every month plus the final day; history stays bounded in Simulation.
		if (index + 1) % 30 == 0 or index + 1 == int(day_text):
			start = Time.get_ticks_usec()
			var summaries: Array = []
			var population: int = 0
			var deaths: int = 0
			var collapsed: int = 0
			var delivered: int = 0
			for sid in sim.get_settlement_ids():
				var summary: Dictionary = sim.get_settlement_summary(sid)
				for quantity in summary["inventory"].values():
					if not is_finite(float(quantity)) or float(quantity) < -0.000001:
						_fail("Invalid inventory at settlement %s" % sid)
						return
				population += int(summary["population"])
				deaths += int(summary["starvation_deaths_total"])
				delivered += int(summary["shipments_received_total"])
				if summary["status"] == "collapsed":
					collapsed += 1
				summaries.append(summary)
			var economic: Dictionary = {"clock": sim.get_clock_summary(),
				"settlements": summaries, "shipments": sim.get_active_shipments()}
			var fingerprint: String = JSON.stringify(economic).sha256_text()
			output.store_line(JSON.stringify({"type": "sample", "state": economic,
				"fingerprint": fingerprint, "population": population,
				"starvation_deaths": deaths, "collapsed": collapsed,
				"shipments_delivered": delivered}))
			output.flush()
			report_usec += Time.get_ticks_usec() - start
			print("day=%d population=%d collapsed=%d delivered=%d sim_ms=%.1f" % [
				index + 1, population, collapsed, delivered, simulation_usec / 1000.0])
	output.store_line(JSON.stringify({"type": "timing", "simulation_usec": simulation_usec,
		"report_usec": report_usec, "mean_tick_ms": simulation_usec / (1000.0 * int(day_text))}))
	output.close()
	quit(0)

func _build(rng: RandomNumberGenerator) -> Dictionary:
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

func _fail(message: String) -> void:
	push_error(message)
	quit(1)
