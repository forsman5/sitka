extends SceneTree

## Headless check of when a grown dependent leaves home (HEHousehold.evaluate_aging):
##   godot --headless --path . --script res://scripts/sim/harness/check_household_split.gd
## Adults stay home unless the household is over HOME_HEADCOUNT_CAP or a house is
## free; free houses are spent one per leaver; the founding workers never leave.

const HEHousehold = preload("res://scripts/sim/household_economy/records/he_household.gd")
const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")

const MONTHS := 600

var _ok := true

func _init() -> void:
	_check_stays_home_without_a_free_house()
	_check_free_house_lets_one_leave()
	_check_free_houses_are_spent()
	_check_over_cap_pushes_out_down_to_cap()
	_check_workers_never_leave()
	_check_leaver_keeps_age()
	_check_heirs_replace_dead_workers()
	_check_hiring_prefers_family()
	_check_sim_town_without_housing_splits_nothing()
	print("HOUSEHOLD SPLIT %s" % ("OK" if _ok else "FAILED"))
	quit(0 if _ok else 1)

func _assert(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		_ok = false

## A household of `workers` heads plus adult dependents of the given ages.
func _household(workers: int, adult_ages: Array[int]) -> HEHousehold:
	var h := HEHousehold.new(1, workers, adult_ages.size(), 0.0)
	h.seed_dependent_ages(adult_ages)
	return h

func _leavers_over_time(h: HEHousehold, free_housing: int, rng: RandomNumberGenerator) -> int:
	var total := 0
	var houses_left := free_housing
	for month in MONTHS:
		var left := h.evaluate_aging(rng, houses_left)
		total += left
		# The sim spends a free house per leaver, as _evaluate_life_cycle does.
		if houses_left < HEHousehold.FREE_HOUSING_UNLIMITED:
			houses_left = maxi(houses_left - left, 0)
	return total

func _check_stays_home_without_a_free_house() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	# 2 workers + 1 adult child = 3 people, under the cap of 4.
	var h := _household(2, [600] as Array[int])
	_assert(_leavers_over_time(h, 0, rng) == 0, "An adult in an uncrowded household with no free house stays home")
	_assert(h.headcount() == 3, "Headcount unchanged when nobody leaves")

func _check_free_house_lets_one_leave() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 2
	var h := _household(2, [600] as Array[int])
	var left := h.evaluate_aging(rng, 1)
	for month in MONTHS:
		if left > 0:
			break
		left = h.evaluate_aging(rng, 1)
	_assert(left == 1, "With a free house the adult child eventually leaves")
	_assert(h.worker_capacity() == 2, "The leaver is a dependent, not a head")

func _check_free_houses_are_spent() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	# 1 worker + 2 adult children = 3 people, under the cap, so only the free house lets anyone go.
	var h := _household(1, [600, 560] as Array[int])
	var left := _leavers_over_time(h, 1, rng)
	_assert(left == 1, "One free house is spent on one leaver (got %d); the other stays home" % left)
	_assert(h.headcount() == 2, "One adult is left at home with the head")

func _check_over_cap_pushes_out_down_to_cap() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4
	# 2 workers + 3 adult children = 5 people: one over the cap of 4, no free houses.
	var h := _household(2, [650, 600, 560] as Array[int])
	_assert(h.headcount() == 5, "Setup: five people")
	var left := _leavers_over_time(h, 0, rng)
	_assert(left == 1, "Only the person over the cap is pushed out (got %d)" % left)
	_assert(h.headcount() == HEHousehold.HOME_HEADCOUNT_CAP, "Pushing out stops at the cap")

func _check_workers_never_leave() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	# 4 workers: the first two are the heads, the other two took jobs at home.
	var h := _household(4, [600, 600, 600] as Array[int])
	_leavers_over_time(h, HEHousehold.FREE_HOUSING_UNLIMITED, rng)
	_assert(h.worker_capacity() == HEHousehold.HEAD_COUNT, "The head and spouse never leave; working children can (capacity %d)" % h.worker_capacity())
	_assert(h.dependent_ages().is_empty(), "With unlimited housing every grown child eventually leaves")
	h = _household(2, [] as Array[int])
	_leavers_over_time(h, HEHousehold.FREE_HOUSING_UNLIMITED, rng)
	_assert(h.worker_capacity() == 2, "A household of just its heads keeps them")

## A leaving worker takes their real age with them.
func _check_leaver_keeps_age() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 6
	var h := HEHousehold.new(1, 3, 0, 0.0)
	h.seed_worker_ages([2000, 1900, 800] as Array[int])
	var left := 0
	for month in MONTHS:
		left = h.evaluate_aging(rng, 1)
		if left > 0:
			break
	_assert(left == 1 and h.last_promoted_ages == ([800] as Array[int]), "The working child leaves, aged 800 (got %s)" % str(h.last_promoted_ages))
	_assert(h.last_promoted_member_numbers == ([3] as Array[int]), "Member number is the third worker")

## When a worker dies an adult child at home takes the place; a child still
## under age does not, and no more step up than died.
func _check_heirs_replace_dead_workers() -> void:
	var h := HEHousehold.new(1, 2, 3, 0.0)
	h.seed_dependent_ages([700, 400, 100] as Array[int])
	_assert(h.promote_adults(0) == 0, "Nobody steps up when nobody died")
	_assert(h.promote_adults(2) == 2, "Both adult children can step up, the child cannot")
	_assert(h.worker_capacity() == 4 and h.dependent_ages() == ([100] as Array[int]), "Two adults became workers, the child is still a dependent")
	_assert(h.worker_ages().has(700) and h.worker_ages().has(400), "Heirs keep their own age")
	_assert(h.promote_adults(1) == 0, "A child under the aging threshold never steps up")

## An employer with an opening hires its own employees' grown children before
## anyone from the unemployed pool.
func _check_hiring_prefers_family() -> void:
	var sim := HESimulation.new(12345, Callable(HEScenarioSeeds, "build_preset").bind("small_village"), true)
	var sid := HEScenarioSeeds.SETTLEMENT_ID
	var farm_id := -1
	for business_id in sim.businesses:
		if sim.businesses[business_id].type_key == "farm":
			farm_id = business_id
	var farm = sim.businesses[farm_id]
	sim._reconcile_employment() # settle government staffing first
	var members: Array = sim._employment_index().get(farm_id, [])
	_assert(not members.is_empty(), "Setup: the farm has employees")
	var family: HEHousehold = sim.households[members[0]]
	family.add_dependent(500)
	family.add_dependent(520)
	var before: int = sim._business_employed_worker_count(farm_id)
	farm.capacity = before + 1
	sim._reconcile_employment()
	_assert(sim._business_employed_worker_count(farm_id) == before + 1, "The farm filled its one opening")
	_assert(family.adult_dependent_count() == 1, "From its employee's family (one adult child left at home)")
	# The unemployed pool is untouched while the family can supply.
	var other_before: int = sim.get_unemployment_summary(sid).get("unemployed_households", 0)
	farm.capacity = before + 2
	sim._reconcile_employment()
	_assert(family.adult_dependent_count() == 0, "The second opening takes the other child")
	_assert(int(sim.get_unemployment_summary(sid).get("unemployed_households", 0)) <= other_before, "No unemployed household was hired while family could fill it")

## A seeded town with every house taken: grown children stay home instead of
## founding homeless one-person households.
func _check_sim_town_without_housing_splits_nothing() -> void:
	var spec := {
		"format": 1, "key": "tight", "label": "Tight", "blurb": "", "settlement_name": "Tight",
		"households": 20, "crews": {"trader": 6}, "farm_share": 0.55,
		"housing": {"houses": 20, "tenements": 0}, "treasury_bonus": 250.0,
		"warehouse": {"stock": {"timber": 150, "stone": 100}},
	}
	var sim := HESimulation.new(12345, Callable(HEScenarioSeeds, "build_spec").bind(spec), true)
	var sid := HEScenarioSeeds.SETTLEMENT_ID
	var peak_homeless := 0
	for month in 36:
		sim.advance_ticks(30)
		peak_homeless = maxi(peak_homeless, int(sim.get_housing_report(sid)["homeless_households"]))
	print("  full town, 3 years: peak homeless households %d, households %d" % [peak_homeless, sim.get_household_ids().size()])
	_assert(peak_homeless <= 8,"A full town does not flood with homeless households (peak %d)" % peak_homeless)
