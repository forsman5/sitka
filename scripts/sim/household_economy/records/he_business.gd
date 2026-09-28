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
## A PRODUCTION business's `recipe.inputs` (e.g. the Bloomery: wood +
## iron ore -> iron) are bought fresh every day, business-to-business, by
## he_simulation.gd's _run_input_purchasing -- never stockpiled between
## days. An input nothing local produces (iron ore) is supplied by the
## settlement's Trader instead, importing it from outside the settlement on
## the spot; see that function's doc comment for the full mechanism.

const Recipe = preload("res://scripts/sim/records/recipe.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")
const HEField = preload("res://scripts/sim/household_economy/records/he_field.gd")

const WAGE_ROLLING_WINDOW_DAYS := 7

## Independent of WAGE_ROLLING_WINDOW_DAYS -- this backs the dashboard's
## cash-trend sparkline (see he_simulation.gd's get_business_reports()),
## which reads better over a longer stretch than the weekly self-tuning
## signal needs.
const BALANCE_HISTORY_WINDOW_DAYS := 90

enum Kind { PRODUCTION, TRADER }

var id: int
var settlement_id: int
var name: String
var kind: Kind
var recipe: Recipe # null for Kind.TRADER
var max_capacity: int
var capacity: int

var inventory: Dictionary[Commodity.Type, float] = {}
var balance: float = 0.0

## Land-based PRODUCTION businesses (Farm, Woodlot) only -- see
## configure_land()/uses_field_model(). Zero/empty for Kind.TRADER and for
## any legacy PRODUCTION business that never had configure_land() called on
## it, which keeps producing instantly from `recipe` every tick exactly as
## before (see he_simulation.gd's _run_production).
var land_area_acres: float = 0.0
var fields: Array[HEField] = []
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

## Rolling daily balance, oldest first, capped at BALANCE_HISTORY_WINDOW_
## DAYS -- purely a reporting aid (see balance_history()/record_balance_day()
## below), read by nothing that affects simulation outcomes.
var _balance_history: Array[float] = []

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

## Kind.TRADER only: units of each commodity imported (from outside the
## settlement, on behalf of a local buyer) today, for reporting -- see
## he_simulation.gd._run_input_purchasing. Always empty for a PRODUCTION
## business.
var last_imported: Dictionary[Commodity.Type, float] = {}

## PRODUCTION only: how much of this business's labor-implied planned
## output it actually got to make today, after recipe.inputs affordability/
## availability capped it -- 1.0 (the default) for a business with no
## inputs (Farm, Woodlot) or one that got everything it needed. Set by
## he_simulation.gd._run_input_purchasing, read by _run_production to scale
## planned_units down to last_actual_units. Every input is drawn down
## proportionally to this SAME ratio rather than each hitting its own
## independent cap, mirroring the field model's one-efficiency-number-
## covers-the-whole-harvest approach.
var last_input_fulfillment_ratio: float = 1.0

func _init(p_id: int, p_name: String, p_recipe: Recipe, p_max_capacity: int, p_initial_capacity: int, p_kind: Kind = Kind.PRODUCTION, p_settlement_id: int = 0) -> void:
	id = p_id
	settlement_id = p_settlement_id
	name = p_name
	recipe = p_recipe
	max_capacity = p_max_capacity
	capacity = p_initial_capacity
	kind = p_kind

## H1's PRODUCTION businesses each have exactly one recipe output (Farm ->
## grain, Woodlot -> timber); a business with a multi-output recipe isn't
## supported by this single-commodity assumption. Never called on a
## Kind.TRADER business, which has no recipe.
func output_commodity() -> Commodity.Type:
	return recipe.outputs.keys()[0]

func stock(commodity: Commodity.Type) -> float:
	return inventory.get(commodity, 0.0)

func add_stock(commodity: Commodity.Type, amount: float) -> void:
	inventory[commodity] = stock(commodity) + amount

func consume(commodity: Commodity.Type, amount: float) -> float:
	var available := stock(commodity)
	var taken: float = min(available, amount)
	inventory[commodity] = available - taken
	return taken

## Called once per business per day by he_simulation.gd's
## _record_business_revenue_history() -- the existing once-a-day-per-
## business bookkeeping pass, not a new one of its own.
func record_balance_day() -> void:
	_balance_history.append(balance)
	if _balance_history.size() > BALANCE_HISTORY_WINDOW_DAYS:
		_balance_history.pop_front()

## Duplicated -- callers (see he_simulation.gd's get_business_reports()) may
## not mutate simulation state through a query result.
func balance_history() -> Array[float]:
	return _balance_history.duplicate()

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

func uses_field_model() -> bool:
	return not fields.is_empty()

## Smallest (fields - growth_days - days_growing) across every field --
## i.e. how many days until the NEXT field to mature is harvested and adds
## fresh stock. -1 for a business with no fields (Trader, legacy).
func days_until_next_harvest() -> int:
	if fields.is_empty():
		return -1
	var min_days := growth_days
	for f in fields:
		min_days = mini(min_days, growth_days - f.days_growing)
	return min_days

## rolling_average_wage()'s window is a flat 7 days regardless of business
## kind. rolling_average_revenue_per_worker() instead uses this business's
## own crop cycle for field-model businesses (see he_simulation.gd's
## _evaluate_business_capacity doc comment for why a full cycle, not a
## fixed week, is the right smoothing window when income arrives in
## lumps at harvest rather than daily) -- Trader and legacy PRODUCTION
## businesses fall back to the same WAGE_ROLLING_WINDOW_DAYS as the wage.
func rolling_window_days() -> int:
	return growth_days if uses_field_model() else WAGE_ROLLING_WINDOW_DAYS

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
