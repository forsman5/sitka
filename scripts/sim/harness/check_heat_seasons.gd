extends SceneTree

## Seasonal heat demand check. Run with:
##   godot --headless --path . --script res://scripts/sim/harness/check_heat_seasons.gd
## The heat requirement follows a smooth yearly curve (winter high, summer low)
## that averages 1.0, so a year's total is unchanged; a stone house saves its 25%
## on top of the season.

const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HEHouse = preload("res://scripts/sim/household_economy/records/he_house.gd")
const HEHousehold = preload("res://scripts/sim/household_economy/records/he_household.gd")
const HENeed = preload("res://scripts/sim/household_economy/records/he_need.gd")
const HENeeds = preload("res://scripts/sim/household_economy/data/he_needs.gd")

const SID := HEScenarioSeeds.SETTLEMENT_ID

var _ok := true

func _init() -> void:
	_check_curve()
	_check_households_follow_the_season()
	_check_stone_house_in_winter()
	_check_need_detail()
	print("HEAT SEASONS %s" % ("OK" if _ok else "FAILED"))
	quit(0 if _ok else 1)

func _assert(condition: bool, message: String) -> void:
	if not condition:
		_ok = false
		push_error("FAIL: " + message)

func _check_curve() -> void:
	var heat := HENeeds.get_need(HENeed.Id.HEAT)
	_assert(HENeed.DAYS_PER_SEASON == HESimulation.DAYS_PER_SEASON, "the need and the sim agree on the length of a season")
	var total := 0.0
	var biggest_step := 0.0
	var previous := heat.seasonal_scale(HESimulation.DAYS_PER_YEAR - 1)
	for p_day in HESimulation.DAYS_PER_YEAR:
		var scale := heat.seasonal_scale(p_day)
		total += scale
		biggest_step = maxf(biggest_step, absf(scale - previous))
		previous = scale
	_assert(absf(total / float(HESimulation.DAYS_PER_YEAR) - 1.0) < 0.001, "a year averages exactly 1.0 (%.4f)" % (total / float(HESimulation.DAYS_PER_YEAR)))
	_assert(biggest_step < 0.03, "no step at a season boundary (largest daily change %.3f)" % biggest_step)
	var winter := heat.seasonal_scale(HESimulation.DAYS_PER_SEASON * 3 + 45)
	var summer := heat.seasonal_scale(HESimulation.DAYS_PER_SEASON + 45)
	_assert(winter > 1.6 and summer < 0.45, "winter needs far more than summer (%.2f vs %.2f)" % [winter, summer])
	_assert(heat.seasonal_scale(10) == heat.seasonal_scale(10 + HESimulation.DAYS_PER_YEAR), "the curve repeats every year")
	for need in HENeeds.all():
		if need.id != HENeed.Id.HEAT:
			_assert(need.seasonal_scale(200) == 1.0, "%s has no seasonal curve" % need.label)

## Heat required today as a multiple of the per-person figure. `heads` is the
## household's headcount when the day's consumption ran (before the tick: births
## and ageing happen after it).
func _household_ratio(household: HEHousehold, heads: int) -> float:
	var heat := HENeeds.get_need(HENeed.Id.HEAT)
	return float(household.last_need_required[HENeed.Id.HEAT]) / (float(heads) * heat.per_person_daily)

func _plain_household(sim: HESimulation) -> HEHousehold:
	for household in sim.households.values():
		if (household as HEHousehold).dwelling_id != -1 and (sim.dwellings[(household as HEHousehold).dwelling_id] as HEHouse).is_plain():
			return household
	return null

func _check_households_follow_the_season() -> void:
	var heat := HENeeds.get_need(HENeed.Id.HEAT)
	var sim := HESimulation.new(11, Callable(HEScenarioSeeds, "build_preset").bind("small_village"))
	var summer_ratio := 0.0
	var winter_ratio := 0.0
	var household: HEHousehold = null
	for p_day in HESimulation.DAYS_PER_YEAR:
		household = _plain_household(sim)
		var heads := household.headcount() if household != null else 0
		sim.advance_ticks(1)
		if household == null or not household.last_need_required.has(HENeed.Id.HEAT):
			continue
		var ratio := _household_ratio(household, heads)
		var expected := heat.seasonal_scale(p_day)
		_assert(absf(ratio - expected) < 0.0001, "day %d: heat requirement follows the curve (%.3f vs %.3f)" % [p_day, ratio, expected])
		if p_day == HESimulation.DAYS_PER_SEASON + 45:
			summer_ratio = ratio
		elif p_day == HESimulation.DAYS_PER_SEASON * 3 + 45:
			winter_ratio = ratio
	_assert(winter_ratio > 3.5 * summer_ratio and summer_ratio > 0.0, "midwinter needs about 4.5x midsummer (%.2f vs %.2f)" % [winter_ratio, summer_ratio])

func _check_stone_house_in_winter() -> void:
	var heat := HENeeds.get_need(HENeed.Id.HEAT)
	var sim := HESimulation.new(11, Callable(HEScenarioSeeds, "build_preset").bind("small_village"))
	sim.advance_ticks(HESimulation.DAYS_PER_SEASON * 3 + 44)
	var household := _plain_household(sim)
	_assert(household != null, "a household lives in a plain house")
	(sim.dwellings[household.dwelling_id] as HEHouse).upgrade_to_stone()
	sim._reconcile_housing(SID)
	var winter_day := sim.day
	var heads := household.headcount()
	sim.advance_ticks(1)
	var ratio := _household_ratio(household, heads)
	var expected := heat.seasonal_scale(winter_day) * (1.0 - HEHouse.STONE_HEAT_SAVING)
	_assert(absf(ratio - expected) < 0.0001, "a stone house saves its quarter on top of the winter demand (%.3f vs %.3f)" % [ratio, expected])

func _check_need_detail() -> void:
	var sim := HESimulation.new(11, Callable(HEScenarioSeeds, "build_preset").bind("small_village"))
	sim.advance_ticks(HESimulation.DAYS_PER_SEASON * 3 + 46)
	var detail := sim.get_need_detail(HENeed.Id.HEAT, 5, SID)
	_assert(detail["season_name"] == "Winter" and float(detail["season_scale"]) > 1.6, "the heat detail reports the winter factor (%s x%.2f)" % [detail["season_name"], float(detail["season_scale"])])
	var food := sim.get_need_detail(HENeed.Id.FOOD, 5, SID)
	_assert(is_equal_approx(float(food["season_scale"]), 1.0), "food has no seasonal factor")
