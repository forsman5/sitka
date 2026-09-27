class_name HEScenarioSeeds
extends RefCounted

## Authored H1 test worlds. Builders return settlement-indexed world data so
## the same HESimulation construction path supports both the original
## one-city scenarios and multi-settlement locality checks.

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
const TRADER_BUSINESS_ID := 3
const CATTLE_RANCH_BUSINESS_ID := 4
const SHEEP_FARM_BUSINESS_ID := 5

const HOUSEHOLD_COUNT := 30
const FARM_MAX_CAPACITY := 50
const WOODLOT_MAX_CAPACITY := 50
## Smaller ceiling than the production businesses -- the Trader is meant to
## stay a release valve for surplus, not grow into the settlement's
## dominant employer.
const TRADER_MAX_CAPACITY := 20

## Starting herd sizes -- deliberately well under either species' cull
## target (HESimulation.HERD_CULL_TARGET) so growth and the first cull are
## both visible within a normal scenario run, not just an instant no-op.
const CATTLE_STARTING_HERD := 30.0
const SHEEP_STARTING_HERD := 60.0

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

## Deterministic but spread-out starting ages (in days) for each household's
## DEPENDENTS seeded dependents, so the whole population doesn't age into
## workers in one synchronized pulse AGING_THRESHOLD_DAYS from now. Not
## meant to represent real household composition, just to avoid a seeding
## artifact.
static func _staggered_starting_ages(household_id: int) -> Array[int]:
	var ages: Array[int] = []
	for slot in DEPENDENTS:
		var age := (household_id * 53 + slot * 137) % HEHousehold.AGING_THRESHOLD_DAYS
		ages.append(age)
	return ages

## Same staggering idea as _staggered_starting_ages, but for WORKERS: spread
## across a worker's whole working lifespan (AGING_THRESHOLD_DAYS..
## LIFESPAN_DAYS) instead of every seeded worker starting freshly of age --
## a settled starting population should already have members at every stage
## of life, old-age death included, not just brand-new adults who all die
## in a synchronized pulse LIFESPAN_DAYS from world-seed time.
static func _staggered_starting_worker_ages(household_id: int) -> Array[int]:
	var span := HEHousehold.LIFESPAN_DAYS - HEHousehold.AGING_THRESHOLD_DAYS
	var ages: Array[int] = []
	for slot in WORKER_CAPACITY:
		var age := HEHousehold.AGING_THRESHOLD_DAYS + (household_id * 89 + slot * 211) % span
		ages.append(age)
	return ages

## `farm_capacity`/`woodlot_capacity`/`trader_capacity` are each business's
## STARTING capacity and how many workers are actually assigned there on
## day one (they should sum to HOUSEHOLD_COUNT * WORKER_CAPACITY so nobody
## starts unemployed by construction, unless a scenario deliberately wants
## that).
static func _build_world(farm_capacity: int, woodlot_capacity: int, trader_capacity: int) -> Dictionary:
	var settlement := HESettlement.new(SETTLEMENT_ID, "Testholm")
	var businesses: Dictionary[int, HEBusiness] = {
		FARM_BUSINESS_ID: HEBusiness.new(FARM_BUSINESS_ID, "Farm", _farm_recipe(), FARM_MAX_CAPACITY, farm_capacity, HEBusiness.Kind.PRODUCTION, SETTLEMENT_ID),
		WOODLOT_BUSINESS_ID: HEBusiness.new(WOODLOT_BUSINESS_ID, "Woodlot", _woodlot_recipe(), WOODLOT_MAX_CAPACITY, woodlot_capacity, HEBusiness.Kind.PRODUCTION, SETTLEMENT_ID),
		TRADER_BUSINESS_ID: HEBusiness.new(TRADER_BUSINESS_ID, "Trader", null, TRADER_MAX_CAPACITY, trader_capacity, HEBusiness.Kind.TRADER, SETTLEMENT_ID),
		CATTLE_RANCH_BUSINESS_ID: HEBusiness.new(CATTLE_RANCH_BUSINESS_ID, "Cattle Ranch", null, 0, 0, HEBusiness.Kind.HERD, SETTLEMENT_ID, HEBusiness.Species.CATTLE, CATTLE_STARTING_HERD),
		SHEEP_FARM_BUSINESS_ID: HEBusiness.new(SHEEP_FARM_BUSINESS_ID, "Sheep Farm", null, 0, 0, HEBusiness.Kind.HERD, SETTLEMENT_ID, HEBusiness.Species.SHEEP, SHEEP_STARTING_HERD),
	}
	settlement.business_ids.append(FARM_BUSINESS_ID)
	settlement.business_ids.append(WOODLOT_BUSINESS_ID)
	settlement.business_ids.append(TRADER_BUSINESS_ID)
	settlement.business_ids.append(CATTLE_RANCH_BUSINESS_ID)
	settlement.business_ids.append(SHEEP_FARM_BUSINESS_ID)

	var grain_buffer := HOUSEHOLD_SIZE * HESimulation.GRAIN_PER_PERSON_PER_DAY * STARTING_BUFFER_DAYS
	var timber_buffer := HOUSEHOLD_SIZE * HESimulation.FUEL_TIMBER_PER_PERSON_PER_DAY * STARTING_BUFFER_DAYS
	var wool_buffer := HOUSEHOLD_SIZE * HESimulation.WOOL_PER_PERSON_PER_DAY * STARTING_BUFFER_DAYS

	var households: Dictionary[int, HEHousehold] = {}
	var farm_workers_assigned := 0
	var woodlot_workers_assigned := 0
	var trader_workers_assigned := 0
	for i in HOUSEHOLD_COUNT:
		var household_id := i + 1
		var household := HEHousehold.new(household_id, WORKER_CAPACITY, DEPENDENTS, STARTING_BALANCE, SETTLEMENT_ID)
		household.add_stock(Commodity.Type.GRAIN, grain_buffer)
		household.add_stock(Commodity.Type.TIMBER, timber_buffer)
		household.add_stock(Commodity.Type.WOOL, wool_buffer)
		household.seed_dependent_ages(_staggered_starting_ages(household_id))
		household.seed_worker_ages(_staggered_starting_worker_ages(household_id))

		if farm_workers_assigned < farm_capacity:
			household.employer_business_id = FARM_BUSINESS_ID
			farm_workers_assigned += WORKER_CAPACITY
		elif woodlot_workers_assigned < woodlot_capacity:
			household.employer_business_id = WOODLOT_BUSINESS_ID
			woodlot_workers_assigned += WORKER_CAPACITY
		elif trader_workers_assigned < trader_capacity:
			household.employer_business_id = TRADER_BUSINESS_ID
			trader_workers_assigned += WORKER_CAPACITY
		# else: stays unemployed (-1) -- only happens if the three capacities
		# don't cover the whole population, which a scenario may want.

		households[household_id] = household
		settlement.household_ids.append(household_id)

	return {"settlements": {SETTLEMENT_ID: settlement}, "households": households, "businesses": businesses}

## Evenly staffed on day one -- HOUSEHOLD_COUNT*WORKER_CAPACITY workers split
## with a small slice going to the Trader and the rest split 50/50 between
## Farm and Woodlot. With the recipe rates above, Woodlot's output is
## structurally oversupplied relative to Farm-household fuel demand, so its
## wage should fall below the reference wage and its capacity should
## contract over time, while Farm's grows -- the "let it tune itself"
## scenario, rather than hand-balancing the recipe rates. The Trader takes
## some of the edge off that divergence (it exports Woodlot's surplus
## timber for a bit of extra revenue) without erasing it, since it only
## ever touches stock above a comfortable reserve.
static func build_three_business_economy(_rng: RandomNumberGenerator) -> Dictionary:
	var trader := 8
	var remainder := HOUSEHOLD_COUNT * WORKER_CAPACITY - trader
	var half := (remainder / WORKER_CAPACITY / 2) * WORKER_CAPACITY
	return _build_world(half, remainder - half, trader)

## Deliberately mis-staffed the OTHER way on day one -- Woodlot overstaffed,
## Farm understaffed -- to make the self-correction visible fast rather
## than waiting for the balanced scenario's slower drift. The Trader starts
## with a smaller slice still, since it's a release valve, not a primary
## employer.
static func build_lopsided_start(_rng: RandomNumberGenerator) -> Dictionary:
	var trader := 6
	var remainder := HOUSEHOLD_COUNT * WORKER_CAPACITY - trader
	var farm := int(remainder * 0.2)
	return _build_world(farm, remainder - farm, trader)

## Small disconnected pair used to prove that settlement-local markets,
## employment pools, and summaries do not leak into one another.
static func build_two_settlement_economy(_rng: RandomNumberGenerator) -> Dictionary:
	var north := HESettlement.new(1, "Northbank")
	var south := HESettlement.new(2, "Southbank")
	var north_farm := HEBusiness.new(101, "North Farm", Recipe.new("north_farm", {}, {Commodity.Type.GRAIN: 4.0}), 8, 2, HEBusiness.Kind.PRODUCTION, 1)
	var south_farm := HEBusiness.new(201, "South Farm", Recipe.new("south_farm", {}, {Commodity.Type.GRAIN: 0.1}), 8, 2, HEBusiness.Kind.PRODUCTION, 2)
	var businesses: Dictionary[int, HEBusiness] = {101: north_farm, 201: south_farm}
	var households: Dictionary[int, HEHousehold] = {}
	var north_household := HEHousehold.new(1001, 2, 2, 20.0, 1)
	var south_household := HEHousehold.new(2001, 2, 2, 20.0, 2)
	north_household.employer_business_id = 101
	south_household.employer_business_id = 201
	for h in [north_household, south_household]:
		h.add_stock(Commodity.Type.GRAIN, 1.0)
		h.add_stock(Commodity.Type.TIMBER, 10.0)
		households[h.id] = h
	north.household_ids.append(1001)
	north.business_ids.append(101)
	south.household_ids.append(2001)
	south.business_ids.append(201)
	return {
		"settlements": {1: north, 2: south},
		"households": households,
		"businesses": businesses,
	}
