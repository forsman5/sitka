class_name HEScenarioSeeds
extends RefCounted

## Authored H1 test worlds. Builders return settlement-indexed world data so
## the same HESimulation construction path supports both the original
## one-city scenarios and multi-settlement locality checks.

const Commodity = preload("res://scripts/sim/records/commodity.gd")
const Recipe = preload("res://scripts/sim/records/recipe.gd")
const HEHousehold = preload("res://scripts/sim/household_economy/records/he_household.gd")
const HEBusiness = preload("res://scripts/sim/household_economy/records/he_business.gd")
const HEField = preload("res://scripts/sim/household_economy/records/he_field.gd")
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

## Farm: 4 fields of 10 acres, planted ~22 days apart on a 90-day growth
## cycle, so there's a harvest roughly every 22 days rather than one big one
## every 90. labor_per_area_per_day is chosen so a FULLY staffed farm (every
## field getting all the labor it can use) works out to exactly the same
## max_capacity the old flat-rate model used (40 * 1.25 = 50), and
## yield_per_area is chosen so a fully-staffed field's harvest matches what
## the old 1.6 grain/worker/day rate would have produced over one growth
## cycle (12.5 workers/field * 90 days * 1.6 = 1800 grain per 10-acre field
## = 180 grain/acre) -- so the farm grows about the same total grain as
## before at full staffing, and the rest of the economy stays in balance.
const FARM_LAND_AREA_ACRES := 40.0
const FARM_FIELD_COUNT := 4
const FARM_GROWTH_DAYS := 90
const FARM_LABOR_PER_AREA_PER_DAY := 1.25
const FARM_YIELD_PER_AREA := 180.0
const FARM_FIELD_START_DAYS: Array[int] = [0, 22, 45, 67]

## Woodlot: same field/harvest model, its own (longer, coppice-like) cycle.
## Same derivation as the farm above: labor_per_area_per_day keeps
## max_capacity at the old flat 50 (50 * 1.0), and yield_per_area matches
## the old 1.0 timber/worker/day rate over one 180-day cycle (12.5
## workers/stand * 180 days * 1.0 = 2250 timber per 12.5-acre stand = 180
## timber/acre).
const WOODLOT_LAND_AREA_ACRES := 50.0
const WOODLOT_FIELD_COUNT := 4
const WOODLOT_GROWTH_DAYS := 180
const WOODLOT_LABOR_PER_AREA_PER_DAY := 1.0
const WOODLOT_YIELD_PER_AREA := 180.0
const WOODLOT_FIELD_START_DAYS: Array[int] = [0, 45, 90, 135]

## Smaller ceiling than the production businesses -- the Trader is meant to
## stay a release valve for surplus, not grow into the settlement's
## dominant employer. Not land-based, so it keeps a flat authored ceiling.
const TRADER_MAX_CAPACITY := 20

## Starting herd sizes -- deliberately well under either species' cull
## target (HESimulation.HERD_CULL_TARGET) so growth and the first cull are
## both visible within a normal scenario run, not just an instant no-op.
const CATTLE_STARTING_HERD := 30.0
const SHEEP_STARTING_HERD := 60.0

## Ranches aren't land-based the way Farm/Woodlot are (they share
## HESimulation.SETTLEMENT_GRAZING_LAND, a different resource entirely --
## see he_business.gd's Kind.HERD doc comment), so they keep a flat
## authored ceiling like the Trader rather than one derived from acreage.
## Smaller than Farm/Woodlot -- tending a herd that mostly grows/thins on
## its own needs fewer hands than working a field every day.
const CATTLE_RANCH_MAX_CAPACITY := 6
const SHEEP_FARM_MAX_CAPACITY := 10

const STARTING_BALANCE := 20.0
## A short cushion, not a permanent living -- these scenarios exist to
## exercise the wage-driven labor market and starvation, not to prove a
## household can coast on savings indefinitely (that's the earlier
## owner-operator cut's story).
const STARTING_BUFFER_DAYS := 10.0

## Every business starts with roughly this many days of its own current
## wage bill already in the bank -- a cash cushion to draw on before its
## first harvest/trade income actually lands, not a permanent subsidy (see
## he_simulation.gd's WAGE_NEGATIVE_BALANCE_FLOOR_DAYS for what happens once
## it's gone).
const STARTING_CASH_RESERVE_DAYS := 30.0

## A field business also starts with enough of its own product already in
## stock to cover local demand until ITS OWN first harvest lands (see
## _build_world's use of days-until-first-harvest below), with headroom so
## the daily sell-pace mechanic (HESimulation.SELL_PACE_HEADROOM) doesn't
## run it dry a little early.
const STARTING_STOCK_HEADROOM := 1.3

static func _farm_recipe() -> Recipe:
	return Recipe.new("farm", {}, {Commodity.Type.GRAIN: 1.6})

static func _woodlot_recipe() -> Recipe:
	return Recipe.new("woodlot", {}, {Commodity.Type.TIMBER: 1.0})

## A field's labor_applied is seeded as if it had been fully staffed for
## every day it's already grown before day 0 -- otherwise a field seeded
## partway through its cycle (see FARM_FIELD_START_DAYS/WOODLOT_FIELD_
## START_DAYS) would harvest at an artificially low efficiency on its very
## first cycle, since none of the labor from "before the simulation began"
## would ever have been recorded.
static func _make_fields(field_count: int, land_area_acres: float, start_days: Array[int], labor_per_area_per_day: float) -> Array[HEField]:
	var area_each: float = land_area_acres / field_count
	var fields: Array[HEField] = []
	for i in field_count:
		var days_growing: int = start_days[i]
		var labor_applied: float = area_each * labor_per_area_per_day * days_growing
		fields.append(HEField.new(area_each, days_growing, labor_applied))
	return fields

## The going reference wage a business would face on day 0, before any real
## price/wage history exists -- BASE_PRICE stands in for the not-yet-formed
## market price, same dependency-ratio shape as HESimulation._reference_
## wage_per_worker. Used only to size each business's STARTING_CASH_RESERVE_
## DAYS cushion (see _build_world) -- once the simulation is running,
## the real _reference_wage_per_worker takes over.
static func _estimated_starting_reference_wage() -> float:
	var dependency_ratio: float = float(HOUSEHOLD_SIZE) / float(WORKER_CAPACITY)
	var per_person_cost: float = HESimulation.BASE_PRICE[Commodity.Type.GRAIN] * HESimulation.GRAIN_PER_PERSON_PER_DAY \
		+ HESimulation.BASE_PRICE[Commodity.Type.TIMBER] * HESimulation.FUEL_TIMBER_PER_PERSON_PER_DAY
	return dependency_ratio * per_person_cost

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

	var farm := HEBusiness.new(FARM_BUSINESS_ID, "Farm", _farm_recipe(), 0, farm_capacity, HEBusiness.Kind.PRODUCTION, SETTLEMENT_ID)
	farm.configure_land(FARM_LAND_AREA_ACRES, _make_fields(FARM_FIELD_COUNT, FARM_LAND_AREA_ACRES, FARM_FIELD_START_DAYS, FARM_LABOR_PER_AREA_PER_DAY), FARM_GROWTH_DAYS, FARM_YIELD_PER_AREA, FARM_LABOR_PER_AREA_PER_DAY)

	var woodlot := HEBusiness.new(WOODLOT_BUSINESS_ID, "Woodlot", _woodlot_recipe(), 0, woodlot_capacity, HEBusiness.Kind.PRODUCTION, SETTLEMENT_ID)
	woodlot.configure_land(WOODLOT_LAND_AREA_ACRES, _make_fields(WOODLOT_FIELD_COUNT, WOODLOT_LAND_AREA_ACRES, WOODLOT_FIELD_START_DAYS, WOODLOT_LABOR_PER_AREA_PER_DAY), WOODLOT_GROWTH_DAYS, WOODLOT_YIELD_PER_AREA, WOODLOT_LABOR_PER_AREA_PER_DAY)

	var trader := HEBusiness.new(TRADER_BUSINESS_ID, "Trader", null, TRADER_MAX_CAPACITY, trader_capacity, HEBusiness.Kind.TRADER, SETTLEMENT_ID)

	# Ranches aren't seeded with any day-one employees (unlike Farm/Woodlot/
	# Trader above) -- they self-bootstrap through the same zero-capacity
	# trial-hire path HESimulation._evaluate_business_capacity already gives
	# every business, protected until their first herd cycle actually lands
	# (see HEBusiness.has_long_cycle()/growth_days, set below to match
	# HESimulation.HERD_EVAL_INTERVAL_DAYS so ranches get that same
	# cycle-aware protection/eval-cadence treatment Farm/Woodlot's fields do).
	var cattle_ranch := HEBusiness.new(CATTLE_RANCH_BUSINESS_ID, "Cattle Ranch", null, CATTLE_RANCH_MAX_CAPACITY, 0, HEBusiness.Kind.HERD, SETTLEMENT_ID, HEBusiness.Species.CATTLE, CATTLE_STARTING_HERD)
	cattle_ranch.growth_days = HESimulation.HERD_EVAL_INTERVAL_DAYS
	var sheep_farm := HEBusiness.new(SHEEP_FARM_BUSINESS_ID, "Sheep Farm", null, SHEEP_FARM_MAX_CAPACITY, 0, HEBusiness.Kind.HERD, SETTLEMENT_ID, HEBusiness.Species.SHEEP, SHEEP_STARTING_HERD)
	sheep_farm.growth_days = HESimulation.HERD_EVAL_INTERVAL_DAYS

	var estimated_wage := _estimated_starting_reference_wage()
	farm.balance = STARTING_CASH_RESERVE_DAYS * estimated_wage * farm_capacity
	woodlot.balance = STARTING_CASH_RESERVE_DAYS * estimated_wage * woodlot_capacity
	trader.balance = STARTING_CASH_RESERVE_DAYS * estimated_wage * trader_capacity

	var farm_days_to_first_harvest: int = FARM_GROWTH_DAYS - FARM_FIELD_START_DAYS.max()
	farm.add_stock(Commodity.Type.GRAIN, HOUSEHOLD_COUNT * HOUSEHOLD_SIZE * HESimulation.GRAIN_PER_PERSON_PER_DAY * farm_days_to_first_harvest * STARTING_STOCK_HEADROOM)
	var woodlot_days_to_first_harvest: int = WOODLOT_GROWTH_DAYS - WOODLOT_FIELD_START_DAYS.max()
	woodlot.add_stock(Commodity.Type.TIMBER, HOUSEHOLD_COUNT * HOUSEHOLD_SIZE * HESimulation.FUEL_TIMBER_PER_PERSON_PER_DAY * woodlot_days_to_first_harvest * STARTING_STOCK_HEADROOM)

	var businesses: Dictionary[int, HEBusiness] = {
		FARM_BUSINESS_ID: farm,
		WOODLOT_BUSINESS_ID: woodlot,
		TRADER_BUSINESS_ID: trader,
		CATTLE_RANCH_BUSINESS_ID: cattle_ranch,
		SHEEP_FARM_BUSINESS_ID: sheep_farm,
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
