extends SceneTree

## The Butcher buys livestock only as far as it expects to sell the meat.
## Over four years of the small village: it is still trading at the end (it used
## to run out of cash selling an unsold glut), its finished meat never runs far
## past the cover it is allowed, and it still produces some meat.
## Run: Godot --headless --path . --script res://scripts/sim/harness/check_butcher_demand.gd

const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")
const HEBusiness = preload("res://scripts/sim/household_economy/records/he_business.gd")

const SEED := 7
const DAYS := 1440

var _ok := true

func _init() -> void:
	var sim := HESimulation.new(SEED, Callable(HEScenarioSeeds, "build_preset").bind("small_village"))
	var worst_overshoot := -INF
	var meat_made := 0.0
	for d in DAYS:
		sim.advance_ticks(1)
		meat_made += float((sim._history.back().get("produced", {}) as Dictionary).get("Meat", 0.0))
		for b in sim.businesses.values():
			if not b.processes_livestock:
				continue
			var sold: float = sim._routine_local_use(b, Commodity.Type.MEAT)
			var allowed: float = maxf(HESimulation.BUTCHERY_MIN_FINISHED_MEAT, sold * HESimulation.BUTCHERY_FINISHED_COVER_DAYS)
			# Two lots of slack: a purchase is sized in whole head, and the allowed
			# cover shrinks when sales slow while meat already made cannot be unmade.
			worst_overshoot = maxf(worst_overshoot, b.stock(Commodity.Type.MEAT) - allowed - 2.0 * HESimulation.BUTCHERY_MEAT_PER_HEAD[HEBusiness.Species.CATTLE])
	var butcher: Variant = null
	for b in sim.businesses.values():
		if b.processes_livestock:
			butcher = b
	_assert(butcher != null, "the Butcher is still trading after %d days" % DAYS)
	_assert(worst_overshoot <= 0.0, "finished meat stayed within its cover (worst overshoot %.0f)" % worst_overshoot)
	_assert(meat_made > 100.0, "the Butcher still produced meat (%.0f)" % meat_made)
	print("meat made %.0f, worst overshoot of cover %.0f" % [meat_made, worst_overshoot])
	print("BUTCHER DEMAND %s" % ("OK" if _ok else "FAILED"))
	quit(0 if _ok else 1)

func _assert(condition: bool, message: String) -> void:
	if not condition:
		_ok = false
		push_error("FAIL: " + message)
