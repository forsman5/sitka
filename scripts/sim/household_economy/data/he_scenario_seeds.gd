class_name HEScenarioSeeds
extends RefCounted

## Authored H1 test worlds: one settlement, two city-owned businesses
## (Farm, Woodlot), and a population of pure-labor households. Each returns
## {settlement, households, businesses} so HESimulation.new(seed,
## Callable(HEScenarioSeeds, "...")) can run it directly.

const Commodity = preload("res://scripts/sim/records/commodity.gd")
const Recipe = preload("res://scripts/sim/records/recipe.gd")
const HEHousehold = preload("res://scripts/sim/household_economy/records/he_household.gd")
const HEBusiness = preload("res://scripts/sim/household_economy/records/he_business.gd")
const HESettlement = preload("res://scripts/sim/household_economy/records/he_settlement.gd")
const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")

const SETTLEMENT_ID := 1
const WORKER_CAPACITY := 2
const DEPENDENTS := 2
const HOUSEHOLD_SIZE := WORKER_CAPACITY + DEPENDENTS

const FARM_BUSINESS_ID := 1
const WOODLOT_BUSINESS_ID := 2

const HOUSEHOLD_COUNT := 30
const FARM_MAX_CAPACITY := 50
const WOODLOT_MAX_CAPACITY := 50

const STARTING_BALANCE := 20.0
## A short cushion, not a permanent living -- these scenarios exist to
## exercise the wage-driven labor market and starvation, not to prove a
## household can coast on savings indefinitely (that's the earlier
## owner-operator cut's story).
const STARTING_BUFFER_DAYS := 10.0

static func _farm_recipe() -> Recipe:
	return Recipe.new("farm", {}, {Commodity.Type.GRAIN: 1.6})

static func _woodlot_recipe() -> Recipe:
	return Recipe.new("woodlot", {}, {Commodity.Type.TIMBER: 1.0})

## `farm_capacity`/`woodlot_capacity` are both the business's STARTING
## capacity and how many workers are actually assigned there on day one
## (they should sum to HOUSEHOLD_COUNT * WORKER_CAPACITY so nobody starts
## unemployed by construction, unless a scenario deliberately wants that).
static func _build_world(farm_capacity: int, woodlot_capacity: int) -> Dictionary:
	var settlement := HESettlement.new(SETTLEMENT_ID, "Testholm")
	var businesses: Dictionary[int, HEBusiness] = {
		FARM_BUSINESS_ID: HEBusiness.new(FARM_BUSINESS_ID, "Farm", _farm_recipe(), FARM_MAX_CAPACITY, farm_capacity),
		WOODLOT_BUSINESS_ID: HEBusiness.new(WOODLOT_BUSINESS_ID, "Woodlot", _woodlot_recipe(), WOODLOT_MAX_CAPACITY, woodlot_capacity),
	}
	settlement.business_ids.append(FARM_BUSINESS_ID)
	settlement.business_ids.append(WOODLOT_BUSINESS_ID)

	var grain_buffer := HOUSEHOLD_SIZE * HESimulation.GRAIN_PER_PERSON_PER_DAY * STARTING_BUFFER_DAYS
	var timber_buffer := HOUSEHOLD_SIZE * HESimulation.FUEL_TIMBER_PER_PERSON_PER_DAY * STARTING_BUFFER_DAYS

	var households: Dictionary[int, HEHousehold] = {}
	var farm_workers_assigned := 0
	var woodlot_workers_assigned := 0
	for i in HOUSEHOLD_COUNT:
		var household_id := i + 1
		var household := HEHousehold.new(household_id, WORKER_CAPACITY, DEPENDENTS, STARTING_BALANCE)
		household.add_stock(Commodity.Type.GRAIN, grain_buffer)
		household.add_stock(Commodity.Type.TIMBER, timber_buffer)

		if farm_workers_assigned < farm_capacity:
			household.employer_business_id = FARM_BUSINESS_ID
			farm_workers_assigned += WORKER_CAPACITY
		elif woodlot_workers_assigned < woodlot_capacity:
			household.employer_business_id = WOODLOT_BUSINESS_ID
			woodlot_workers_assigned += WORKER_CAPACITY
		# else: stays unemployed (-1) -- only happens if the two capacities
		# don't cover the whole population, which a scenario may want.

		households[household_id] = household
		settlement.household_ids.append(household_id)

	return {"settlement": settlement, "households": households, "businesses": businesses}

## Evenly staffed on day one -- HOUSEHOLD_COUNT*WORKER_CAPACITY workers split
## 50/50 between Farm and Woodlot. With the recipe rates above, Woodlot's
## output is structurally oversupplied relative to Farm-household fuel
## demand, so its wage should fall below the reference wage and its
## capacity should contract over time, while Farm's grows -- the "let it
## tune itself" scenario, rather than hand-balancing the recipe rates.
static func build_two_business_economy(_rng: RandomNumberGenerator) -> Dictionary:
	var half := (HOUSEHOLD_COUNT / 2) * WORKER_CAPACITY
	return _build_world(half, half)

## Deliberately mis-staffed the OTHER way on day one -- Woodlot overstaffed,
## Farm understaffed -- to make the self-correction visible fast rather
## than waiting for the balanced scenario's slower drift.
static func build_lopsided_start(_rng: RandomNumberGenerator) -> Dictionary:
	var total := HOUSEHOLD_COUNT * WORKER_CAPACITY
	return _build_world(int(total * 0.2), int(total * 0.8))
