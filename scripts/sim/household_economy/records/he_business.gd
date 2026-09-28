class_name HEBusiness
extends RefCounted

## A city-owned productive site -- a "Farm" or "Woodlot" building, not
## something any household owns. It hires households (as whole units, never
## splitting one household's workers across two employers) up to `capacity`,
## produces its one recipe output with however many workers it currently
## has, sells that output on the market into its own inventory/balance, and
## pays its employees a wage drawn from what it actually sold. `capacity` is
## a TARGET employee-slot count that self-tunes weekly based on whether the
## wage it can afford beats what a worker needs to live on -- see
## he_simulation.gd's _evaluate_business_capacity/_reconcile_employment.
## `max_capacity` is a hard land/facility ceiling that tuning can never
## exceed, mirroring the pooled model's target_labor.
##
## Kind.TRADER (the "Trader" business) is the odd one out: it has no
## recipe and produces nothing. Instead it draws down whichever PRODUCTION
## business's stock has grown past a comfortable reserve, converting it to
## money at a deliberately low price -- see he_simulation.gd's _run_trade.
## Everything else about it (hiring, wages, weekly capacity self-tuning) is
## identical to a PRODUCTION business.
##
## Kind.HERD (a "Cattle Ranch" or "Sheep Farm") is a second odd one out, in
## the opposite direction from Kind.TRADER: it has no recipe and no fields.
## It instead carries a live `herd_size` that grows and thins on its own
## each HERD_EVAL_INTERVAL_DAYS, grazing a shared, settlement-wide land pool
## rather than being fed purchased grain (that's a possible future
## mechanic, not this one -- see he_simulation.gd's HERD_EVAL_INTERVAL_DAYS
## doc comment), and sells off excess head straight into its own inventory
## once herd_size crosses a cull target. `species` distinguishes CATTLE
## from SHEEP, which differ in reproduction rate, land use, and mortality --
## see he_simulation.gd's HERD_* constants. Sheep additionally throw off a
## small WOOL trickle from live herd size every interval, independent of
## culling. WOOL is an ordinary local household good (see he_simulation.gd's
## SUBSISTENCE_COMMODITIES and _business_selling) sold through the same
## local market Farm/Woodlot use; the culled animal itself (herd_commodity())
## has no local buyer and is Trader-export-only at a flat reference price
## (see he_simulation.gd's HERD_EXPORT_PRICE and _run_trade's herd export
## pass). It DOES hire and pay wages like any other business -- `growth_days`
## is set to HERD_EVAL_INTERVAL_DAYS (see he_scenario_seeds.gd) purely so it
## gets the same cycle-aware treatment (has_long_cycle(), protected trial
## hires, revenue smoothed over its own cycle rather than a flat week) a
## field-model business gets, even though it has no `fields` of its own --
## see has_long_cycle() and he_simulation.gd's _evaluate_business_capacity.

const Recipe = preload("res://scripts/sim/records/recipe.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")
const HEField = preload("res://scripts/sim/household_economy/records/he_field.gd")

const WAGE_ROLLING_WINDOW_DAYS := 7

enum Kind { PRODUCTION, TRADER, HERD }
enum Species { CATTLE, SHEEP }

var id: int
var settlement_id: int
var name: String
var kind: Kind
var recipe: Recipe # null for Kind.TRADER and Kind.HERD
var max_capacity: int
var capacity: int

var inventory: Dictionary[Commodity.Type, float] = {}
var balance: float = 0.0

## Kind.HERD only -- meaningless for the other two kinds.
var species: Species = Species.CATTLE
var herd_size: float = 0.0
## Kind.HERD only, reporting: units of herd_commodity() moved from herd_size
## into inventory the last time _run_herds culled this business, keyed by
## commodity so a future consumer doesn't have to assume which one it was.
## Empty on any interval with nothing to cull.
var last_culled: Dictionary[Commodity.Type, float] = {}
## Kind.HERD + Species.SHEEP only, reporting: wool added to inventory the
## last time _run_herds ran. Always 0 for cattle.
var last_wool_produced: float = 0.0

## Land-based PRODUCTION businesses (Farm, Woodlot) only -- see
## configure_land()/uses_field_model(). Zero/empty for Kind.TRADER and for
## any legacy PRODUCTION business that never had configure_land() called on
## it, which keeps producing instantly from `recipe` every tick exactly as
## before (see he_simulation.gd's _run_production).
var land_area_acres: float = 0.0
var fields: Array[HEField] = []
## Days in one full production cycle -- set by configure_land() for a
## field-model business, or directly for any other cyclical business that
## has no literal fields (currently just Kind.HERD, to HERD_EVAL_INTERVAL_
## DAYS -- see he_scenario_seeds.gd). 0 means "no cycle, instant output"
## (Trader, a legacy flat-rate PRODUCTION business). See has_long_cycle().
var growth_days: int = 0
var yield_per_area: float = 0.0
var labor_per_area_per_day: float = 0.0

## Yesterday's actual sales revenue for this business's output good --
## today's wage payment divides this by today's employed worker count (see
## he_simulation.gd._pay_wages), the same "use yesterday's settled number,
## not a live one" discipline the household market's same-day balance
## snapshot uses to avoid circularity.
var last_revenue: float = 0.0
var last_wages_paid: float = 0.0
var last_cash_change: float = 0.0

## How much of today's full reference-wage bill this business couldn't
## cover out of its own cash (balance is allowed to run generously negative
## before wages get rationed -- see he_simulation.gd's WAGE_NEGATIVE_
## BALANCE_FLOOR_DAYS and _pay_wages). 0.0 on a day it paid in full.
var last_wage_shortfall: float = 0.0

## Set whenever a zero-capacity business gets its trial crew back (see
## he_simulation.gd's _evaluate_business_capacity) to the day that
## protection should end -- until then, capacity evaluation leaves this
## business alone entirely, growth and shrink signals both, regardless of
## how its average revenue reads. -1 (the initial value) means "not
## currently protected".
var protected_until_day: int = -1

## Rolling wage-per-worker history, oldest first, capped -- smooths the
## weekly expand/contract decision against single noisy day. See
## he_simulation.gd._evaluate_business_capacity.
var _wage_history: Array[float] = []

## Rolling sales-revenue-per-employed-worker-day history, oldest first,
## capped at rolling_window_days() -- THIS, not the wage (which is now
## simply set to the going reference wage every day, see _pay_wages), is
## what _evaluate_business_capacity compares against the reference wage to
## decide growth/shrink, per he_simulation.gd's doc comment there.
var _revenue_per_worker_history: Array[float] = []

var last_planned_units: float = 0.0
var last_actual_units: float = 0.0
var last_output_produced: Dictionary[Commodity.Type, float] = {}
var last_wage_per_worker: float = 0.0

## Kind.TRADER only: units of each commodity exported today, for reporting
## -- see he_simulation.gd._run_trade. Always empty for a PRODUCTION
## business.
var last_exported: Dictionary[Commodity.Type, float] = {}

func _init(p_id: int, p_name: String, p_recipe: Recipe, p_max_capacity: int, p_initial_capacity: int, p_kind: Kind = Kind.PRODUCTION, p_settlement_id: int = 0, p_species: Species = Species.CATTLE, p_herd_size: float = 0.0) -> void:
	id = p_id
	settlement_id = p_settlement_id
	name = p_name
	recipe = p_recipe
	max_capacity = p_max_capacity
	capacity = p_initial_capacity
	kind = p_kind
	species = p_species
	herd_size = p_herd_size

## H1's PRODUCTION businesses each have exactly one recipe output (Farm ->
## grain, Woodlot -> timber); a business with a multi-output recipe isn't
## supported by this single-commodity assumption. Never called on a
## Kind.TRADER or Kind.HERD business, neither of which has a recipe.
func output_commodity() -> Commodity.Type:
	return recipe.outputs.keys()[0]

## Kind.HERD only: which commodity this ranch's live herd converts into when
## culled (see he_simulation.gd's _run_herds). Sheep also produce WOOL, but
## that's a passive trickle from herd_size, not this herd's "primary" output,
## so it isn't returned here.
func herd_commodity() -> Commodity.Type:
	return Commodity.Type.CATTLE if species == Species.CATTLE else Commodity.Type.SHEEP

func stock(commodity: Commodity.Type) -> float:
	return inventory.get(commodity, 0.0)

func add_stock(commodity: Commodity.Type, amount: float) -> void:
	inventory[commodity] = stock(commodity) + amount

func consume(commodity: Commodity.Type, amount: float) -> float:
	var available := stock(commodity)
	var taken: float = min(available, amount)
	inventory[commodity] = available - taken
	return taken

func record_wage_day(wage_per_worker: float) -> void:
	_wage_history.append(wage_per_worker)
	if _wage_history.size() > WAGE_ROLLING_WINDOW_DAYS:
		_wage_history.pop_front()

func rolling_average_wage() -> float:
	if _wage_history.is_empty():
		return 0.0
	var total := 0.0
	for w in _wage_history:
		total += w
	return total / _wage_history.size()

## Wires this PRODUCTION business up to the field/harvest model (see
## he_field.gd and he_simulation.gd's _run_field_growth) instead of the
## legacy instant-production-from-recipe path. Also RE-DERIVES max_capacity
## from the land itself (area * labor_per_area_per_day), overriding whatever
## flat number was passed to _init -- land, not an authored headcount, is
## the hard ceiling for a field-model business.
func configure_land(p_land_area_acres: float, p_fields: Array[HEField], p_growth_days: int, p_yield_per_area: float, p_labor_per_area_per_day: float) -> void:
	land_area_acres = p_land_area_acres
	fields = p_fields
	growth_days = p_growth_days
	yield_per_area = p_yield_per_area
	labor_per_area_per_day = p_labor_per_area_per_day
	max_capacity = int(p_land_area_acres * p_labor_per_area_per_day)

## True only for a business with literal HEField plots (Farm, Woodlot) --
## the one thing that specifically needs the field-growth production path
## (he_simulation.gd's _run_field_growth). For "does this business run on a
## multi-day cycle at all" (which also covers Kind.HERD), use
## has_long_cycle() instead.
func uses_field_model() -> bool:
	return not fields.is_empty()

## True for any business whose income arrives in a lump every growth_days
## rather than continuously -- field-model Farm/Woodlot AND Kind.HERD
## (which sets growth_days directly, with no fields of its own; see this
## class's doc comment). False for Trader and any legacy flat-rate
## PRODUCTION business, whose growth_days stays 0. This is the general
## predicate _evaluate_business_capacity/rolling_window_days should gate
## on -- uses_field_model() only where the code specifically needs actual
## HEField objects.
func has_long_cycle() -> bool:
	return growth_days > 0

## Smallest (fields - growth_days - days_growing) across every field --
## i.e. how many days until the NEXT field to mature is harvested and adds
## fresh stock. For a cyclical business with no literal fields (Kind.HERD),
## there's no per-field countdown to read, so this conservatively returns
## the FULL cycle length instead -- always at least as protective as the
## true countdown would be, never less. -1 for a business with no cycle at
## all (Trader, legacy).
func days_until_next_harvest() -> int:
	if not fields.is_empty():
		var min_days := growth_days
		for f in fields:
			min_days = mini(min_days, growth_days - f.days_growing)
		return min_days
	return growth_days if has_long_cycle() else -1

## rolling_average_wage()'s window is a flat 7 days regardless of business
## kind. rolling_average_revenue_per_worker() instead uses this business's
## own crop/herd cycle for any has_long_cycle() business (see
## he_simulation.gd's _evaluate_business_capacity doc comment for why a
## full cycle, not a fixed week, is the right smoothing window when income
## arrives in lumps at harvest rather than daily) -- Trader and legacy
## PRODUCTION businesses fall back to the same WAGE_ROLLING_WINDOW_DAYS as
## the wage.
func rolling_window_days() -> int:
	return growth_days if has_long_cycle() else WAGE_ROLLING_WINDOW_DAYS

func record_revenue_per_worker_day(value: float) -> void:
	_revenue_per_worker_history.append(value)
	var window := rolling_window_days()
	while _revenue_per_worker_history.size() > window:
		_revenue_per_worker_history.pop_front()

func rolling_average_revenue_per_worker() -> float:
	if _revenue_per_worker_history.is_empty():
		return 0.0
	var total := 0.0
	for v in _revenue_per_worker_history:
		total += v
	return total / _revenue_per_worker_history.size()
