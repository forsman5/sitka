extends SceneTree

## Household spending: comfort goods go to affluent households. At posted
## prices where meat costs several times grain per food-unit, households near
## subsistence still pick grain while affluent ones pick meat, and meat earns
## the food-comfort morale bonus in proportion to how much of the food it is.
## Run: Godot --headless --path . --script res://scripts/sim/harness/check_household_spending.gd

const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HEHousehold = preload("res://scripts/sim/household_economy/records/he_household.gd")
const HENeeds = preload("res://scripts/sim/household_economy/data/he_needs.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")

const SEED := 7
const PRESET := "large_village"
const WARMUP_DAYS := 150

var _ok := true

func _init() -> void:
	var sim := HESimulation.new(SEED, Callable(HEScenarioSeeds, "build_preset").bind(PRESET))
	sim.advance_ticks(WARMUP_DAYS)
	var sid := HEScenarioSeeds.SETTLEMENT_ID
	var food := HENeeds.get_need(0)
	var butcher: Variant = null
	for b in sim.businesses.values():
		if b.type_key == "butcher":
			butcher = b
	_assert(butcher != null, "the town has a Butcher")
	# Put meat on the shelf and hold the posted prices where they usually sit:
	# grain at its floor, meat at base (3.2x grain per food-unit).
	butcher.add_stock(Commodity.Type.MEAT, 500.0)
	var market = sim.markets[sid]
	market.price[Commodity.Type.GRAIN] = 0.25
	market.price[Commodity.Type.MEAT] = 1.6
	var cascade: Array[Commodity.Type] = sim._household_cascade(sid, food)
	_assert(cascade.has(Commodity.Type.MEAT) and cascade[0] == Commodity.Type.MEAT, "meat is on offer and cleared first (comfort first): %s" % str(cascade))

	var rich := 0
	var rich_meat := 0
	var poor := 0
	var poor_meat := 0
	for h in sim.households.values():
		var affluence: float = sim._household_affluence(h)
		var favourite: int = sim._household_favourite(h, food, cascade)
		if affluence > 0.9:
			rich += 1
			rich_meat += 1 if favourite == Commodity.Type.MEAT else 0
		elif affluence < 0.1:
			poor += 1
			poor_meat += 1 if favourite == Commodity.Type.MEAT else 0
	print("favour meat: %d / %d affluent, %d / %d near subsistence" % [rich_meat, rich, poor_meat, poor])
	_assert(rich > 0 and poor > 0, "both affluent and near-subsistence households exist (%d / %d)" % [rich, poor])
	_assert(rich_meat >= rich * 0.6, "most affluent households favour meat (%d of %d)" % [rich_meat, rich])
	_assert(poor_meat == 0, "no household near subsistence favours meat (%d of %d)" % [poor_meat, poor])

	# Morale: a household eating only meat gets the full food comfort bonus;
	# half meat, half of it; no meat, none.
	var h: HEHousehold = sim.households.values()[0]
	var need_units: float = float(h.headcount()) * food.per_person_daily
	h.last_need_required[food.id] = need_units
	h.last_consumed[Commodity.Type.MEAT] = need_units / food.value_of(Commodity.Type.MEAT)
	h.last_consumed[Commodity.Type.GRAIN] = 0.0
	_assert(_comfort_bonus(h) > HENeeds.FOOD_MEAT_MORALE - 0.001, "all-meat food earns the full comfort bonus (%.3f)" % _comfort_bonus(h))
	h.last_consumed[Commodity.Type.MEAT] *= 0.5
	_assert(absf(_comfort_bonus(h) - HENeeds.FOOD_MEAT_MORALE * 0.5) < 0.001, "half-meat food earns half (%.3f)" % _comfort_bonus(h))
	h.last_consumed[Commodity.Type.MEAT] = 0.0
	_assert(_comfort_bonus(h) == 0.0, "no meat, no comfort bonus")
	print("HOUSEHOLD SPENDING %s" % ("OK" if _ok else "FAILED"))
	quit(0 if _ok else 1)

func _comfort_bonus(h: HEHousehold) -> float:
	var total := 0.0
	for bonus in h.morale_bonuses():
		if str(bonus["label"]) == "Food: Meat":
			total += bonus["bonus"]
	return total

func _assert(condition: bool, message: String) -> void:
	if not condition:
		_ok = false
		push_error("FAIL: " + message)
