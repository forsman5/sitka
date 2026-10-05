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
const HENeed = preload("res://scripts/sim/household_economy/records/he_need.gd")
const HENeeds = preload("res://scripts/sim/household_economy/data/he_needs.gd")
const HESettlement = preload("res://scripts/sim/household_economy/records/he_settlement.gd")
const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")

const SETTLEMENT_ID := 1
const WORKER_CAPACITY := 2
const DEPENDENTS := 2
const HOUSEHOLD_SIZE := WORKER_CAPACITY + DEPENDENTS

const FARM_BUSINESS_ID := 1
const WOODLOT_BUSINESS_ID := 2
const TRADER_BUSINESS_ID := 3
const BLOOMERY_BUSINESS_ID := 4
const IRON_MINE_BUSINESS_ID := 5
## Shifted to 6/7 to leave room for the opt-in Bloomery (4) and Iron Mine (5)
## -- the opt-in scenarios and the ranches can all be present at once.
const CATTLE_RANCH_BUSINESS_ID := 6
const SHEEP_FARM_BUSINESS_ID := 7
const BUTCHER_BUSINESS_ID := 8
## The town government (Kind.GOVERNMENT): a treasury filled by sales tax that
## pays one permanent administrator household. Present in every _build_world
## town, including build_custom's, which never offers it as a choice.
const GOVERNMENT_BUSINESS_ID := 9
## Days of administrator wages a new government's treasury starts with.
const STARTING_TREASURY_DAYS := 10.0

## The Butcher turns the ranches' culled livestock into meat and leather (see
## HESimulation's BUTCHERY_* constants). It keeps one household on year-round
## -- ranch culls arrive in lumps every HERD_EVAL_INTERVAL_DAYS, and a
## business tuned to zero between them would miss the next one -- and may grow
## to a second when there is enough to process. Like the ranches it has no
## day-one employees: it is hired from the unemployed pool.
const BUTCHER_MIN_CAPACITY := 2
## Crew a ranch is authorized to hire from day one. It starts with no employees
## and fills this from the unemployed pool at the weekly reconcile; there is no
## longer a trial-hire path that bootstraps a business sitting at zero.
const RANCH_STARTING_CAPACITY := 4
const BUTCHER_MAX_CAPACITY := 4

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

## Opt-in only -- see build_three_business_economy_with_bloomery(). Smaller
## than Farm/Woodlot's ceiling, similar in scale to the Trader: a workshop,
## not a whole settlement's dominant employer. Legacy (non-field) business,
## so this IS the hard ceiling, not a land-derived one.
const BLOOMERY_MAX_CAPACITY := 20

## Starting herd sizes -- deliberately well under either species' cull
## target (HESimulation.HERD_CULL_TARGET) so growth and the first cull are
## both visible within a normal scenario run, not just an instant no-op.
## Cattle's target/start ratio (1.5x) matches what it always was, just at
## a bigger absolute scale (see HESimulation.HERD_CULL_TARGET's doc
## comment) -- keeps the ~900-day time-to-first-cull unchanged.
const CATTLE_STARTING_HERD := 100.0
const SHEEP_STARTING_HERD := 100.0

## A ranch's staff ceiling is derived from its herd, the way a field
## business derives its from acreage: the workers a herd at its cull target
## needs for FULL care (HESimulation.HERD_LABOR_PER_HEAD_PER_DAY), rounded up.
## Not a hand-tuned flat number any more -- the old flat ceilings (cattle 1,
## sheep 10) existed to keep a self-tuner from overshooting a herd whose
## labor produced nothing; with husbandry now driving wool, mortality and
## reproduction, the ceiling just states how many hands the herd can use.
static func herd_max_capacity(species: HEBusiness.Species) -> int:
	return ceili(HESimulation.HERD_CULL_TARGET[species] * HESimulation.HERD_LABOR_PER_HEAD_PER_DAY[species])

## Opt-in alongside the Bloomery. Like the workshop, this is a compact,
## legacy (daily-output) production site rather than a land/field business.
const IRON_MINE_MAX_CAPACITY := 20

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
## Startup cash for a field business covers its whole production cycle of
## wages, times this safety factor. The credit line only covers 60 days of the
## wage bill and the reference wage can swing several-fold, so a bare cycle's
## worth runs out before the first harvest (measured: a recreated Farm needs
## ~90 and a Woodlot ~275 for a crew of 4 with the wage at its seed value).
const STARTUP_CASH_SAFETY_FACTOR := 2.0
## Crew a player-created business is authorized to hire.
const NEW_BUSINESS_STARTING_CAPACITY := 4

## A field business also starts with enough of its own product already in
## stock to cover local demand until ITS OWN first harvest lands (see
## _build_world's use of days-until-first-harvest below), with headroom so
## the daily sell-pace mechanic (HESimulation.SELL_PACE_HEADROOM) doesn't
## run it dry a little early.
const STARTING_STOCK_HEADROOM := 1.3

static func _farm_recipe() -> Recipe:
	return Recipe.new("farm", {}, {Commodity.Type.GRAIN: 1.6})

## The Farm record, public so a business can be built mid-run (see
## HESimulation.add_business) with the same land/field setup the seeded one
## gets. A farm built mid-run defaults to every field freshly planted on day 0
## and no day-one staff. With the trial hire gone, a farm at capacity 0 stays
## at zero until the caller passes initial_capacity (TODO: the create-business
## flow should seed one).
static func make_farm(business_id: int, settlement_id: int, initial_capacity: int = 0, field_start_days: Array[int] = [0, 0, 0, 0]) -> HEBusiness:
	var farm := HEBusiness.new(business_id, "Farm", _farm_recipe(), 0, initial_capacity, HEBusiness.Kind.PRODUCTION, settlement_id)
	farm.type_key = "farm"
	farm.configure_land(FARM_LAND_AREA_ACRES, _make_fields(FARM_FIELD_COUNT, FARM_LAND_AREA_ACRES, field_start_days, FARM_LABOR_PER_AREA_PER_DAY), FARM_GROWTH_DAYS, FARM_YIELD_PER_AREA, FARM_LABOR_PER_AREA_PER_DAY)
	return farm

## Factories for every buildable business, public so one can be built mid-run
## (see HESimulation.add_business). Each carries a `type_key` so uniqueness can
## be checked. None sets balance or stock -- _build_world adds the day-one
## cushion afterwards; a business built mid-run starts with neither.
static func make_woodlot(business_id: int, settlement_id: int, initial_capacity: int = 0, field_start_days: Array[int] = [0, 0, 0, 0]) -> HEBusiness:
	var woodlot := HEBusiness.new(business_id, "Woodlot", _woodlot_recipe(), 0, initial_capacity, HEBusiness.Kind.PRODUCTION, settlement_id)
	woodlot.type_key = "woodlot"
	woodlot.configure_land(WOODLOT_LAND_AREA_ACRES, _make_fields(WOODLOT_FIELD_COUNT, WOODLOT_LAND_AREA_ACRES, field_start_days, WOODLOT_LABOR_PER_AREA_PER_DAY), WOODLOT_GROWTH_DAYS, WOODLOT_YIELD_PER_AREA, WOODLOT_LABOR_PER_AREA_PER_DAY)
	return woodlot

static func make_trader(business_id: int, settlement_id: int, initial_capacity: int = 0) -> HEBusiness:
	var trader := HEBusiness.new(business_id, "Trader", null, TRADER_MAX_CAPACITY, initial_capacity, HEBusiness.Kind.TRADER, settlement_id)
	trader.type_key = "trader"
	return trader

## Unlike a field, a herd's cull isn't a guaranteed, dated payoff (see
## HESimulation._hardship_butcher_if_needed's doc comment), so a ranch
## is judged on the short, evidence-based CASH_RUNWAY_DANGER_DAYS leash.
## It starts with no staff but RANCH_STARTING_CAPACITY authorized, filled at
## the weekly reconcile. growth_days is set to
## HESimulation.HERD_EVAL_INTERVAL_DAYS purely so
## rolling_average_revenue_per_worker() smooths over the ranch's own cycle
## length instead of a flat week (see HEBusiness.has_long_cycle()).
static func make_herd(business_id: int, settlement_id: int, species: HEBusiness.Species) -> HEBusiness:
	var is_cattle := species == HEBusiness.Species.CATTLE
	var herd := HEBusiness.new(business_id, "Cattle Ranch" if is_cattle else "Sheep Farm", null, herd_max_capacity(species), RANCH_STARTING_CAPACITY, HEBusiness.Kind.HERD, settlement_id, species, CATTLE_STARTING_HERD if is_cattle else SHEEP_STARTING_HERD)
	herd.type_key = "cattle_ranch" if is_cattle else "sheep_farm"
	herd.growth_days = HESimulation.HERD_EVAL_INTERVAL_DAYS
	return herd

static func make_butcher(business_id: int, settlement_id: int) -> HEBusiness:
	var butcher := HEBusiness.new(business_id, "Butcher", _butcher_recipe(), BUTCHER_MAX_CAPACITY, BUTCHER_MIN_CAPACITY, HEBusiness.Kind.PRODUCTION, settlement_id)
	butcher.type_key = "butcher"
	butcher.processes_livestock = true
	butcher.min_capacity = BUTCHER_MIN_CAPACITY
	# Meat and leather sell down over the following cull cycle, so smooth its
	# revenue over that cycle like a ranch (see HEBusiness.has_long_cycle()).
	butcher.growth_days = HESimulation.HERD_EVAL_INTERVAL_DAYS
	return butcher

static func _woodlot_recipe() -> Recipe:
	return Recipe.new("woodlot", {}, {Commodity.Type.TIMBER: 1.0})

## Wood stands in for charcoal (no separate charcoal good in H1 yet -- see
## he_simulation.gd's _run_input_purchasing doc comment). recipe.inputs is
## an input:output RATIO (units consumed per unit of iron produced), unlike
## recipe.outputs which is a per-worker-per-day rate -- 2 wood + 1 ore make
## 1 iron here. At full BLOOMERY_MAX_CAPACITY staffing and unconstrained
## inputs that's 20 workers * 0.5 = 10 iron/day, needing 20 wood/day (well
## within a fully-staffed Woodlot's ~50/day) and 10 ore/day (well within a
## Trader's import capacity at a handful of employed workers -- see
## HESimulation.TRADER_CAPACITY_PER_WORKER).
##
## Per worker per day at full input supply: pays for 1 wood (1.0) + 0.5 ore
## (2.0 each -- see HESimulation.BASE_PRICE) = 2.0 spent, and sells 0.5 iron
## through the Trader's export at HALF its 15.0 base price = 3.75 earned --
## net ~1.75/worker/day against a reference wage of roughly 1.0, chosen
## deliberately high (see BASE_PRICE's Iron comment) since, unlike Farm/
## Woodlot, EVERY unit the Bloomery sells goes through that same export
## discount rather than mostly selling to local households at full price.
## Outputs only: the butchery pass (he_simulation.gd's _run_butchery) draws on
## live livestock instead of recipe.inputs. The rates are the nominal output
## per worker-day working cattle, which is what the "planned" figure shows.
static func _butcher_recipe() -> Recipe:
	var cattle := HEBusiness.Species.CATTLE
	var cattle_head_per_worker_day: float = 1.0 / HESimulation.BUTCHERY_WORKER_DAYS_PER_HEAD[cattle]
	return Recipe.new("butcher", {}, {
		Commodity.Type.MEAT: HESimulation.BUTCHERY_MEAT_PER_HEAD[cattle] * cattle_head_per_worker_day,
		Commodity.Type.LEATHER: HESimulation.BUTCHERY_LEATHER_PER_HEAD[cattle] * cattle_head_per_worker_day,
	})

static func _bloomery_recipe() -> Recipe:
	return Recipe.new("bloomery", {Commodity.Type.TIMBER: 2.0, Commodity.Type.IRON_ORE: 1.0}, {Commodity.Type.IRON: 0.5})

static func _iron_mine_recipe() -> Recipe:
	return Recipe.new("iron_mine", {}, {Commodity.Type.IRON_ORE: 1.0})

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
## Cash a business needs to pay `crew` workers through one production cycle
## (growth_days, or STARTING_CASH_RESERVE_DAYS if it has no cycle) at the seed
## wage, with a safety margin. Used for the day-one Farm/Woodlot and for
## player-created businesses (HESimulation.add_new_business).
static func startup_cash(b: HEBusiness, crew: int) -> float:
	var days := maxf(float(b.growth_days), STARTING_CASH_RESERVE_DAYS)
	return STARTUP_CASH_SAFETY_FACTOR * days * _estimated_starting_reference_wage() * crew

static func _estimated_starting_reference_wage() -> float:
	var dependency_ratio: float = float(HOUSEHOLD_SIZE) / float(WORKER_CAPACITY)
	var per_person_cost: float = HESimulation.BASE_PRICE[Commodity.Type.GRAIN] * HENeeds.units_per_person_daily(Commodity.Type.GRAIN) \
		+ HESimulation.BASE_PRICE[Commodity.Type.TIMBER] * HENeeds.units_per_person_daily(Commodity.Type.TIMBER)
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

## `farm_capacity`/`woodlot_capacity`/`trader_capacity`/`bloomery_capacity`
## are each business's STARTING capacity and how many workers are actually
## assigned there on day one (they should sum to HOUSEHOLD_COUNT *
## WORKER_CAPACITY so nobody starts unemployed by construction, unless a
## scenario deliberately wants that). `bloomery_capacity` defaults to 0,
## meaning "no Bloomery at all" -- the toggle a caller wants IS which
## scenario builder it picks (see he_dashboard.gd's SCENARIOS and
## build_three_business_economy_with_bloomery below), not a capacity of
## zero on a business that still exists: a Bloomery that was never
## constructed here can never later appear on its own, since there is no
## such business id in `businesses`.
static func _build_world(farm_capacity: int, woodlot_capacity: int, trader_capacity: int, bloomery_capacity: int = 0, iron_mine_capacity: int = 0) -> Dictionary:
	var settlement := HESettlement.new(SETTLEMENT_ID, "Testholm")

	var farm := make_farm(FARM_BUSINESS_ID, SETTLEMENT_ID, farm_capacity, FARM_FIELD_START_DAYS)

	var woodlot := make_woodlot(WOODLOT_BUSINESS_ID, SETTLEMENT_ID, woodlot_capacity, WOODLOT_FIELD_START_DAYS)

	var trader := make_trader(TRADER_BUSINESS_ID, SETTLEMENT_ID, trader_capacity)

	# Ranches aren't seeded with any day-one employees (unlike Farm/Woodlot/
	# Trader above) -- see make_herd for their starting crew allowance.
	var cattle_ranch := make_herd(CATTLE_RANCH_BUSINESS_ID, SETTLEMENT_ID, HEBusiness.Species.CATTLE)
	var sheep_farm := make_herd(SHEEP_FARM_BUSINESS_ID, SETTLEMENT_ID, HEBusiness.Species.SHEEP)

	var butcher := make_butcher(BUTCHER_BUSINESS_ID, SETTLEMENT_ID)

	var estimated_wage := _estimated_starting_reference_wage()
	farm.balance = startup_cash(farm, farm_capacity)
	woodlot.balance = startup_cash(woodlot, woodlot_capacity)
	trader.balance = STARTING_CASH_RESERVE_DAYS * estimated_wage * trader_capacity
	butcher.balance = STARTING_CASH_RESERVE_DAYS * estimated_wage * BUTCHER_MIN_CAPACITY
	cattle_ranch.balance = STARTING_CASH_RESERVE_DAYS * estimated_wage * RANCH_STARTING_CAPACITY
	sheep_farm.balance = STARTING_CASH_RESERVE_DAYS * estimated_wage * RANCH_STARTING_CAPACITY

	var farm_days_to_first_harvest: int = FARM_GROWTH_DAYS - FARM_FIELD_START_DAYS.max()
	farm.add_stock(Commodity.Type.GRAIN, HOUSEHOLD_COUNT * HOUSEHOLD_SIZE * HENeeds.units_per_person_daily(Commodity.Type.GRAIN) * farm_days_to_first_harvest * STARTING_STOCK_HEADROOM)
	var woodlot_days_to_first_harvest: int = WOODLOT_GROWTH_DAYS - WOODLOT_FIELD_START_DAYS.max()
	woodlot.add_stock(Commodity.Type.TIMBER, HOUSEHOLD_COUNT * HOUSEHOLD_SIZE * HENeeds.units_per_person_daily(Commodity.Type.TIMBER) * woodlot_days_to_first_harvest * STARTING_STOCK_HEADROOM)

	var businesses: Dictionary[int, HEBusiness] = {
		FARM_BUSINESS_ID: farm,
		WOODLOT_BUSINESS_ID: woodlot,
		TRADER_BUSINESS_ID: trader,
		CATTLE_RANCH_BUSINESS_ID: cattle_ranch,
		SHEEP_FARM_BUSINESS_ID: sheep_farm,
		BUTCHER_BUSINESS_ID: butcher,
	}
	settlement.business_ids.append(FARM_BUSINESS_ID)
	settlement.business_ids.append(WOODLOT_BUSINESS_ID)
	settlement.business_ids.append(TRADER_BUSINESS_ID)
	settlement.business_ids.append(CATTLE_RANCH_BUSINESS_ID)
	settlement.business_ids.append(SHEEP_FARM_BUSINESS_ID)
	settlement.business_ids.append(BUTCHER_BUSINESS_ID)

	var bloomery: HEBusiness = null
	if bloomery_capacity > 0:
		bloomery = HEBusiness.new(BLOOMERY_BUSINESS_ID, "Bloomery", _bloomery_recipe(), BLOOMERY_MAX_CAPACITY, bloomery_capacity, HEBusiness.Kind.PRODUCTION, SETTLEMENT_ID)
		bloomery.balance = STARTING_CASH_RESERVE_DAYS * estimated_wage * bloomery_capacity
		# Its timber input is the furnace's heat, which any heat fuel can supply.
		bloomery.need_inputs = {Commodity.Type.TIMBER: HENeed.Id.HEAT}
		businesses[BLOOMERY_BUSINESS_ID] = bloomery
		settlement.business_ids.append(BLOOMERY_BUSINESS_ID)

	var iron_mine: HEBusiness = null
	if iron_mine_capacity > 0:
		iron_mine = HEBusiness.new(IRON_MINE_BUSINESS_ID, "Iron Mine", _iron_mine_recipe(), IRON_MINE_MAX_CAPACITY, iron_mine_capacity, HEBusiness.Kind.PRODUCTION, SETTLEMENT_ID)
		iron_mine.balance = STARTING_CASH_RESERVE_DAYS * estimated_wage * iron_mine_capacity
		businesses[IRON_MINE_BUSINESS_ID] = iron_mine
		settlement.business_ids.append(IRON_MINE_BUSINESS_ID)

	var grain_buffer := HOUSEHOLD_SIZE * HENeeds.units_per_person_daily(Commodity.Type.GRAIN) * STARTING_BUFFER_DAYS
	var timber_buffer := HOUSEHOLD_SIZE * HENeeds.units_per_person_daily(Commodity.Type.TIMBER) * STARTING_BUFFER_DAYS
	var wool_buffer := HOUSEHOLD_SIZE * HENeeds.units_per_person_daily(Commodity.Type.WOOL) * STARTING_BUFFER_DAYS

	var households: Dictionary[int, HEHousehold] = {}
	var farm_workers_assigned := 0
	var woodlot_workers_assigned := 0
	var bloomery_workers_assigned := 0
	var iron_mine_workers_assigned := 0
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
		elif bloomery != null and bloomery_workers_assigned < bloomery_capacity:
			household.employer_business_id = BLOOMERY_BUSINESS_ID
			bloomery_workers_assigned += WORKER_CAPACITY
		elif iron_mine != null and iron_mine_workers_assigned < iron_mine_capacity:
			household.employer_business_id = IRON_MINE_BUSINESS_ID
			iron_mine_workers_assigned += WORKER_CAPACITY
		elif trader_workers_assigned < trader_capacity:
			household.employer_business_id = TRADER_BUSINESS_ID
			trader_workers_assigned += WORKER_CAPACITY
		# else: stays unemployed (-1) -- only happens if the capacities don't
		# cover the whole population, which a scenario may want.

		households[household_id] = household
		settlement.household_ids.append(household_id)

	add_government(settlement, households, businesses, GOVERNMENT_BUSINESS_ID)

	return {"settlements": {SETTLEMENT_ID: settlement}, "households": households, "businesses": businesses}

## Adds a Government business to `settlement` and employs one existing
## household as its permanent administrator (the last unemployed household,
## else the last one of the most-staffed business, so the existing day-one
## staffing barely shifts -- population is unchanged; the donor employer's
## weekly reconcile refills the slot). Starts with a small treasury float
## (STARTING_TREASURY_DAYS of wages); after that the administrator is paid out
## of sales tax alone. Public so a multi-town
## builder (the valley) can give each settlement its own, with a unique id.
## TODO(builders): seed builder_slots and builder households here once the
## builder jobs are modeled (see HEBusiness.builder_slots).
static func add_government(settlement: HESettlement, households: Dictionary, businesses: Dictionary, government_id: int) -> HEBusiness:
	var gov := HEBusiness.new(government_id, "Government", null, WORKER_CAPACITY, WORKER_CAPACITY, HEBusiness.Kind.GOVERNMENT, settlement.id)
	# A small float so day-one wages aren't rationed while the first sales
	# tax trickles in (probed: an empty treasury rationed the administrator
	# for ~9 days); from then on tax alone sustains the wage.
	gov.balance = STARTING_TREASURY_DAYS * _estimated_starting_reference_wage() * WORKER_CAPACITY
	businesses[government_id] = gov
	settlement.business_ids.append(government_id)
	var admin: HEHousehold = null
	for household_id in settlement.household_ids:
		var h: HEHousehold = households[household_id]
		if h.worker_capacity() > 0 and h.employer_business_id == -1:
			admin = h
	if admin == null:
		# Draw from the business with the most households (its last one) --
		# the small Trader/Bloomery/Mine slices are tuned tightly and a day-
		# one short crew there visibly shifts trade (see the Trader churn and
		# Bloomery checks in run_household_economy.gd).
		var staff_by_employer: Dictionary = {}
		for household_id in settlement.household_ids:
			var h: HEHousehold = households[household_id]
			if h.worker_capacity() > 0 and h.employer_business_id != -1:
				staff_by_employer[h.employer_business_id] = staff_by_employer.get(h.employer_business_id, 0) + 1
		var donor_id := -1
		for employer_id in staff_by_employer.keys():
			if donor_id == -1 or staff_by_employer[employer_id] > staff_by_employer[donor_id] or (staff_by_employer[employer_id] == staff_by_employer[donor_id] and employer_id < donor_id):
				donor_id = employer_id
		for household_id in settlement.household_ids:
			var h: HEHousehold = households[household_id]
			if h.worker_capacity() > 0 and h.employer_business_id == donor_id:
				admin = h
	if admin != null:
		admin.employer_business_id = government_id
	return gov

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

## Same as build_three_business_economy, plus a fourth, opt-in business: the
## Bloomery, which buys wood from the Woodlot and iron ore imported by the
## Trader to smelt iron, then relies on that same Trader to export every bit
## of it (see he_simulation.gd's _run_input_purchasing/_run_trade -- no
## household ever wants iron directly, so it all leaves the settlement).
## This is the toggle: pick this builder (see he_dashboard.gd's SCENARIOS)
## instead of build_three_business_economy to turn the Bloomery on for a new
## sim, or the plain builder above to leave it out entirely.
static func build_three_business_economy_with_bloomery(_rng: RandomNumberGenerator) -> Dictionary:
	var trader := 8
	var bloomery := 8
	var remainder := HOUSEHOLD_COUNT * WORKER_CAPACITY - trader - bloomery
	var half := (remainder / WORKER_CAPACITY / 2) * WORKER_CAPACITY
	return _build_world(half, remainder - half, trader, bloomery)

## Local-ore variant: the Iron Mine puts ore into its business inventory,
## where the Bloomery buys it on the following day before the Trader gets a
## chance to export any remaining surplus. _run_input_purchasing also
## prefers this local seller over the Trader's outside-import fallback.
static func build_economy_with_bloomery_and_iron_mine(_rng: RandomNumberGenerator) -> Dictionary:
	var trader := 8
	var bloomery := 8
	var iron_mine := 8
	var remainder := HOUSEHOLD_COUNT * WORKER_CAPACITY - trader - bloomery - iron_mine
	var half := (remainder / WORKER_CAPACITY / 2) * WORKER_CAPACITY
	return _build_world(half, remainder - half, trader, bloomery, iron_mine)

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

## Player-chosen roster from the household economy config page. `included`
## is an array of business ids (the *_BUSINESS_ID constants); anything absent
## is built by _build_world and then dropped, so it never exists in the sim.
## Trader/Bloomery/Iron Mine start with the same 8-worker slices the presets
## use, and whatever is left splits evenly between Farm and Woodlot (or all
## goes to whichever one is present). Ranches self-bootstrap, so they take no
## day-one staff. Needs Farm or Woodlot -- nothing else makes grain or fuel.
static func build_custom(_rng: RandomNumberGenerator, included: Array) -> Dictionary:
	var trader: int = 8 if included.has(TRADER_BUSINESS_ID) else 0
	var bloomery: int = 8 if included.has(BLOOMERY_BUSINESS_ID) else 0
	var iron_mine: int = 8 if included.has(IRON_MINE_BUSINESS_ID) else 0
	var remainder := HOUSEHOLD_COUNT * WORKER_CAPACITY - trader - bloomery - iron_mine
	var has_farm := included.has(FARM_BUSINESS_ID)
	var has_woodlot := included.has(WOODLOT_BUSINESS_ID)
	var farm := 0
	var woodlot := 0
	if has_farm and has_woodlot:
		farm = (remainder / WORKER_CAPACITY / 2) * WORKER_CAPACITY
		woodlot = remainder - farm
	elif has_farm:
		farm = remainder
	elif has_woodlot:
		woodlot = remainder
	var world := _build_world(farm, woodlot, trader, bloomery, iron_mine)
	var businesses: Dictionary = world["businesses"]
	var settlement: HESettlement = world["settlements"][SETTLEMENT_ID]
	for business_id in businesses.keys():
		if business_id != GOVERNMENT_BUSINESS_ID and not included.has(business_id):
			businesses.erase(business_id)
			settlement.business_ids.erase(business_id)
	return world

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
