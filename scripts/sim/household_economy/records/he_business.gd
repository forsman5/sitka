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
## It uses the same hiring and wage rules, but its capacity decision uses a
## longer revenue window and review interval to span supplier harvests.
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
##
## A PRODUCTION business's `recipe.inputs` (e.g. the Bloomery: wood +
## iron ore -> iron) are bought business-to-business and retained in its
## inventory until production consumes them. An input nothing local
## produces is supplied by the settlement's Trader, importing it from
## outside the settlement; see he_simulation.gd's _run_input_purchasing.

const Recipe = preload("res://scripts/sim/records/recipe.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")
const HEField = preload("res://scripts/sim/household_economy/records/he_field.gd")

const WAGE_ROLLING_WINDOW_DAYS := 7
## The seeded Woodlot's four stands harvest roughly 45 days apart. A Trader
## can see no export revenue in a one-week window even while its trade is
## profitable over a supplier's harvest cycle.
const TRADER_REVENUE_WINDOW_DAYS := 45

## Independent of WAGE_ROLLING_WINDOW_DAYS -- this backs the dashboard's
## cash-trend sparkline (see he_simulation.gd's get_business_reports()),
## which reads better over a longer stretch than the weekly self-tuning
## signal needs.
const BALANCE_HISTORY_WINDOW_DAYS := 90

## Goods flows tracked for the detail panel's charts. PRODUCED/CONSUMED are
## what the production step actually made and used up; SOLD/BOUGHT are what
## left or entered this business's storage (to households, other businesses
## or the Trader) -- availability to the market, not output.
const FLOW_PRODUCED := "produced"
const FLOW_CONSUMED := "consumed"
const FLOW_SOLD := "sold"
const FLOW_BOUGHT := "bought"
const ALL_FLOWS := [FLOW_PRODUCED, FLOW_CONSUMED, FLOW_SOLD, FLOW_BOUGHT]

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

## Kind.PRODUCTION only: recipe inputs that are really an HENeed rather than a
## fixed feedstock, recipe input commodity -> HENeed.Id. The recipe quantity
## is read in the need's units (a furnace's TIMBER input is heat), so any
## satisfier of that need may fill it -- see he_simulation.gd's
## _run_input_purchasing and _run_production. A business whose input must stay
## that exact good (a charcoal burner's timber is raw material) leaves it empty.
var need_inputs: Dictionary[Commodity.Type, int] = {}

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
## Kind.HERD only, reporting: head sold off today via he_simulation.gd's
## _hardship_butcher_if_needed to cover a wage shortfall the ranch's own
## cash couldn't. 0.0 on any ordinary day.
var last_hardship_butchered: float = 0.0
## Kind.HERD only: this ranch's own recent births / culls / hardship sales,
## oldest first, bounded by he_simulation.gd's HERD_EVENT_HISTORY_MAX. Kept
## per business (not just in the shared blotter) because the blotter's
## 200-entry ring fills with household chatter long before a ranch's rare
## events would age out of a per-business detail view.
var herd_events: Array[Dictionary] = []
## Kind.HERD only: worker-days of husbandry applied since the last review
## (employed workers added daily by he_simulation.gd's _run_production),
## consumed and reset by _run_herds -- the herd analogue of a field's
## labor_applied.
var care_worker_days: float = 0.0
## Kind.HERD only: the herd size this ranch culls back down to each review.
## Seeded from he_simulation.gd's HERD_CULL_TARGET species default and then
## player-configurable through HESimulation.set_herd_cull_target(), which
## also re-derives max_capacity from it. 0.0 = "not set, use the species
## default" (any builder that doesn't seed one still works).
var cull_target: float = 0.0
## Kind.HERD only, reporting: the effective care (free-range baseline plus
## staffed share, 0..1) the last review applied to wool, mortality and
## reproduction. Starts at the baseline an unstaffed herd gets.
var last_care_fraction: float = 0.0

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

## Rolling daily balance, oldest first, capped at BALANCE_HISTORY_WINDOW_
## DAYS -- purely a reporting aid (see balance_history()/record_balance_day()
## below), read by nothing that affects simulation outcomes.
var _balance_history: Array[float] = []

## Reporting only: today's goods movements through this business's own
## storage, {flow: {Commodity.Type: units}}, where flow is one of the FLOW_*
## constants below (PRODUCED is derived from last_output_produced instead).
## Reset every tick by he_simulation.gd's _pay_wages, filled by add_flow()
## from each place goods actually move, and folded into _flow_history by
## record_flow_day() at the end of the day.
var todays_flows: Dictionary = {}

## Reporting only: rolling daily history of each flow per commodity,
## {flow: {Commodity.Type: Array[float]}}, oldest first, each series capped at
## BALANCE_HISTORY_WINDOW_DAYS. Keyed by commodity so a multi-good recipe just
## adds series. Field-model businesses show lumpy PRODUCED spikes on harvest
## days, since last_output_produced is 0.0 on every other day.
var _flow_history: Dictionary = {}

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

func add_flow(flow: String, commodity: Commodity.Type, amount: float) -> void:
	var by_commodity: Dictionary = todays_flows.get_or_add(flow, {})
	by_commodity[commodity] = by_commodity.get(commodity, 0.0) + amount

## Called once per day alongside record_balance_day(). A commodity that has
## moved before keeps getting a 0.0 on idle days so every series stays aligned
## to the same calendar days.
func record_flow_day() -> void:
	for flow in ALL_FLOWS:
		var today: Dictionary = last_output_produced if flow == FLOW_PRODUCED else todays_flows.get(flow, {})
		var history: Dictionary = _flow_history.get_or_add(flow, {})
		for commodity in today.keys():
			if not history.has(commodity):
				var backfill: Array[float] = []
				backfill.resize(_balance_history.size() - 1)
				backfill.fill(0.0)
				history[commodity] = backfill
		for commodity in history.keys():
			var series: Array = history[commodity]
			series.append(today.get(commodity, 0.0))
			if series.size() > BALANCE_HISTORY_WINDOW_DAYS:
				series.pop_front()

## Duplicated like balance_history(). Returns {Commodity.Type: Array[float]}
## for one flow (empty if that flow never moved anything).
func flow_history(flow: String) -> Dictionary:
	var out := {}
	var history: Dictionary = _flow_history.get(flow, {})
	for commodity in history.keys():
		out[commodity] = (history[commodity] as Array).duplicate()
	return out

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
## arrives in lumps at harvest rather than daily). Trader revenue is also
## harvest-driven; only legacy instant-output businesses use the wage window.
func rolling_window_days() -> int:
	if has_long_cycle():
		return growth_days
	if kind == Kind.TRADER:
		return TRADER_REVENUE_WINDOW_DAYS
	return WAGE_ROLLING_WINDOW_DAYS

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
