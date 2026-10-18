extends SceneTree

## Prints how the food chain is doing in the Bakery village preset: Mill and
## Bakery crew/cash, bread and flour output and price, and how many households
## ate bread / flour / grain / meat on each sampled day.
##   godot --headless --path . --script res://scripts/sim/harness/measure_bakery.gd
## Optional user args after `--`: days (default 720), preset key, seed.

const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HEPresets = preload("res://scripts/sim/household_economy/data/he_presets.gd")
const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEBusiness = preload("res://scripts/sim/household_economy/records/he_business.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")

var seed_value := 12345
const SAMPLE_EVERY := 60

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var days := int(args[0]) if args.size() > 0 else 720
	var key := args[1] if args.size() > 1 else "bakery_village"
	if args.size() > 2:
		seed_value = int(args[2])
	var spec := HEPresets.spec(key)
	var sim := HESimulation.new(seed_value, Callable(HEScenarioSeeds, "build_spec").bind(spec), true)
	print("day | hh | bakery crew/bal/bread-made | mill crew/bal | bread$ flour$ grain$ | households eating (main food) bread/flour/grain/meat/none | bread share of food points | bread exported")
	var bread_made := 0.0
	var bread_exported := 0.0
	for d in range(1, days + 1):
		sim.advance_ticks(1)
		var rec: Dictionary = sim.get_daily_history(1)[0]
		bread_made += (rec["produced"] as Dictionary).get("Bread", 0.0)
		bread_exported += (rec.get("exported", {}) as Dictionary).get("Bread", 0.0)
		if d % SAMPLE_EVERY != 0:
			continue
		var bakery: HEBusiness = sim.businesses.get(HEScenarioSeeds.BAKERY_BUSINESS_ID)
		var mill: HEBusiness = sim.businesses.get(HEScenarioSeeds.MILL_BUSINESS_ID)
		var eat := {"bread": 0, "flour": 0, "grain": 0, "meat": 0, "none": 0}
		var points := {"bread": 0.0, "other": 0.0}
		for h in sim.households.values():
			var best := "none"
			var best_pts := 0.0
			for c in [Commodity.Type.BREAD, Commodity.Type.FLOUR, Commodity.Type.GRAIN, Commodity.Type.MEAT]:
				var taken: float = h.last_consumed.get(c, 0.0)
				var pts: float = taken * (4.0 if c == Commodity.Type.BREAD else (0.5 if c == Commodity.Type.GRAIN else 1.0))
				points["bread" if c == Commodity.Type.BREAD else "other"] += pts
				if pts > best_pts:
					best_pts = pts
					best = Commodity.name_of(c).to_lower()
			eat[best] += 1
		var market: Dictionary = sim.get_city_summary()["market"]
		var total_pts: float = points["bread"] + points["other"]
		print("%d | %d | %s | %s | %.2f %.2f %.2f | %s | %.0f%% | %.0f" % [
			d, sim.households.size(),
			("%d/%.0f/%.0f" % [bakery.capacity, bakery.balance, bread_made]) if bakery != null else "GONE",
			("%d/%.0f" % [mill.capacity, mill.balance]) if mill != null else "GONE",
			_price(market, "Bread"), _price(market, "Flour"), _price(market, "Grain"),
			str(eat), 100.0 * points["bread"] / maxf(total_pts, 0.0001), bread_exported])
		bread_made = 0.0
		bread_exported = 0.0
	quit(0)

func _price(market: Dictionary, name: String) -> float:
	var row = market.get(name)
	if row == null:
		return 0.0
	return float(row.get("price", 0.0))
