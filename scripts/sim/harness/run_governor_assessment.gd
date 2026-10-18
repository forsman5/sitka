extends SceneTree

## Prototype AI governor, run from the harness only (no sim changes), to see what a
## governor could rescue. Usage:
##   godot --headless --path . --script res://scripts/sim/harness/run_governor_assessment.gd -- key mode years seed [verbose]
## mode 0 = no governor, 1 = housing, 2 = housing + water/stone upkeep, 3 = 2 + tenements/stone houses

const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")

const GOVERN_EVERY_DAYS := 7

var sim: HESimulation
var sid := HEScenarioSeeds.SETTLEMENT_ID
var built := {"house": 0, "well": 0, "tenement": 0, "stone_house": 0}

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var key := args[0]
	var mode := int(args[1])
	var years := int(args[2])
	var seed_value := int(args[3])
	var verbose := args.size() > 4
	sim = HESimulation.new(seed_value, Callable(HEScenarioSeeds, "build_preset").bind(key), true)
	print("=== %s mode %d seed %d ===" % [key, mode, seed_value])
	print("yr  pop  hh  houses cap homeless  health morale treasury  timber stone  wells(cap) built(h/w/t)")
	_row(0)
	for y in range(1, years + 1):
		var d := 0
		while d < HESimulation.DAYS_PER_YEAR:
			if mode > 0 and d % GOVERN_EVERY_DAYS == 0:
				_govern(mode)
			sim.advance_ticks(1)
			d += 1
		if verbose or y % 5 == 0 or y <= 3:
			_row(y)
	quit(0)

func _stock(commodity: Commodity.Type) -> float:
	for row in sim.get_warehouse_inventory(sid):
		if row["commodity"] == commodity:
			return row["units"]
	return 0.0

func _treasury() -> float:
	return float(sim.get_government_summary(sid).get("treasury", 0.0))

func _pending(type_key: String) -> int:
	var n := 0
	for c in sim.get_construction_reports(sid):
		if c["type_key"] == type_key:
			n += 1
	return n

func _govern(mode: int) -> void:
	var h := sim.get_housing_report(sid)
	var warehouse = sim._government_warehouse(sid)
	if warehouse == null:
		return
	var homeless: int = h["homeless_households"]
	# Housing: build a house whenever a household is unhoused or the town is within one of full.
	var slack: int = int(h["capacity"]) - int(h["households"]) - _pending("house")
	if slack < 1 and _pending("house") == 0:
		var result := sim.request_government_build(sid, "house")
		if result == "built":
			built["house"] += 1
	if mode >= 2:
		var w := sim.get_water_summary(sid)
		var pop: int = w["population"]
		if float(w["capacity"]) < pop * 1.15 and _pending("well") == 0:
			if sim.request_government_build(sid, "well") == "built":
				built["well"] += 1
		# Stand a stone and timber reserve for a year of water servicing + builds.
		var upkeep_stone := maxf(40.0, float(w["sources"]) * 8.0)
		sim.set_warehouse_order(warehouse.id, Commodity.Type.STONE, upkeep_stone, false, 0.0)
		sim.set_warehouse_order(warehouse.id, Commodity.Type.TIMBER, 120.0, false, 0.0)
	if mode >= 3 and homeless == 0:
		# Densify once plain houses are all used and the lot supply (~100 houses) is near.
		if int(h["houses"]) >= 40 and int(h["upgradable_houses"]) > 0 and slack < 1 and _pending("tenement") == 0:
			if sim.request_government_build(sid, "tenement") == "built":
				built["tenement"] += 1

func _row(y: int) -> void:
	var s := sim.get_settlement_summary(sid)
	var h: Dictionary = s["housing"]
	var wb := sim.get_population_wellbeing(sid)
	var w := sim.get_water_summary(sid)
	print("%2d %4d %3d  %4d %4d %5d    %.2f  %.2f  %8.0f %7.0f %5.0f   %d(%d)   %d/%d/%d" % [
		y, s["population"], s["household_count"], h["houses"], h["capacity"], h["homeless_households"],
		wb["avg_health"], wb["avg_morale"], _treasury(), _stock(Commodity.Type.TIMBER), _stock(Commodity.Type.STONE),
		w["sources"], w["capacity"], built["house"], built["well"], built["tenement"]])
	var detail := "     "
	for r in sim.get_business_reports(sid, false):
		if r["type_key"] in ["farm", "woodlot", "cattle_ranch", "sheep_farm", "quarry"]:
			detail += "%s %d/%d  " % [r["type_key"], r["employed_workers"], r["max_capacity"]]
	var grain: Dictionary = (s["market"] as Dictionary).get("Grain", {})
	detail += "grainPx %.2f stock %.0f unemp %d  " % [float(grain.get("price", 0.0)), float(grain.get("stored", 0.0)), s["unemployed_household_count"]]
	for f in (wb["health_factors"] as Array).slice(0, 3):
		detail += "[%s -%.2f] " % [f["label"], f["avg_loss"]]
	print(detail)
