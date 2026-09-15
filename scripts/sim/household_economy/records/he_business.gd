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

const Recipe = preload("res://scripts/sim/records/recipe.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")

const WAGE_ROLLING_WINDOW_DAYS := 7

enum Kind { PRODUCTION, TRADER }

var id: int
var name: String
var kind: Kind
var recipe: Recipe # null for Kind.TRADER
var max_capacity: int
var capacity: int

var inventory: Dictionary[Commodity.Type, float] = {}
var balance: float = 0.0

## Yesterday's actual sales revenue for this business's output good --
## today's wage payment divides this by today's employed worker count (see
## he_simulation.gd._pay_wages), the same "use yesterday's settled number,
## not a live one" discipline the household market's same-day balance
## snapshot uses to avoid circularity.
var last_revenue: float = 0.0

## Rolling wage-per-worker history, oldest first, capped -- smooths the
## weekly expand/contract decision against single noisy day. See
## he_simulation.gd._evaluate_business_capacity.
var _wage_history: Array[float] = []

var last_planned_units: float = 0.0
var last_actual_units: float = 0.0
var last_output_produced: Dictionary[Commodity.Type, float] = {}
var last_wage_per_worker: float = 0.0

## Kind.TRADER only: units of each commodity exported today, for reporting
## -- see he_simulation.gd._run_trade. Always empty for a PRODUCTION
## business.
var last_exported: Dictionary[Commodity.Type, float] = {}

func _init(p_id: int, p_name: String, p_recipe: Recipe, p_max_capacity: int, p_initial_capacity: int, p_kind: Kind = Kind.PRODUCTION) -> void:
	id = p_id
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
