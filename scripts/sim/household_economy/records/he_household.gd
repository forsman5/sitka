class_name HEHousehold
extends RefCounted

## H1 household-economy record: a household that owns its own inventory and
## exchange balance, distinct from the pooled Simulation's Household (which
## has no inventory/purchasing account and applies one settlement-uniform
## fulfillment ratio to everyone).
##
## Households no longer own production directly -- they supply labor to a
## business (see he_business.gd) and earn wages, then buy grain/timber on
## the market with those wages. `demographics` composes the pooled
## Household record so this can reuse its stress/migration-pressure/
## starvation-candidacy logic verbatim, driven by THIS household's own
## rolling grain fulfillment instead of a settlement-wide one. Unlike the
## earlier owner-operator cut, starvation candidacy here is ACTED on (see
## he_simulation.gd._evaluate_starvation) -- a household that can't earn or
## afford enough to eat can actually lose members and, eventually, cease to
## exist, freeing its worker(s) back into (or entirely out of) the labor
## pool.

const Commodity = preload("res://scripts/sim/records/commodity.gd")
const Household = preload("res://scripts/sim/records/household.gd")

const GRAIN_ROLLING_WINDOW_DAYS := 30

## Reused pooled record: worker_capacity, dependents, food_stress,
## apply_daily_fulfillment(), update_migration_pressure(),
## is_starvation_candidate(), remove_member(), is_empty(). Its
## settlement_id/wealth fields are unused placeholders -- ownership lives in
## `inventory`/`balance` below instead.
var demographics: Household

var id: int

## The business currently employing this household's ENTIRE worker_capacity,
## or -1 if unemployed. A household always works as one unit -- it doesn't
## split workers across two employers -- see he_simulation.gd's weekly
## labor reconciliation.
var employer_business_id: int = -1

## Goods this household actually owns. Never a duplicate of settlement/city
## stock -- there is no pooled inventory in this scenario.
var inventory: Dictionary[Commodity.Type, float] = {}

## Abstract accounting units. Earned as wages from its employer, spent
## buying grain/timber. Never created or destroyed except by a matched
## wage-payment or buyer-pays/seller-receives transfer in HESimulation.
var balance: float = 0.0

## This household's OWN rolling grain fulfillment window -- oldest first,
## each entry {demand, taken} -- so its stress/migration-pressure/starvation
## signals are driven by its individual history, not a settlement-wide one.
var _grain_history: Array[Dictionary] = []

## Reported by HESimulation each day, keyed by Commodity.Type. Kept on the
## household (rather than only in the daily ledger) so a caller can read a
## household's current-day outcome without re-deriving it from history.
var last_demand: Dictionary[Commodity.Type, float] = {}
var last_consumed: Dictionary[Commodity.Type, float] = {}
## Wanted but physically unavailable (no stock to buy or consume), separate
## from last_unmet_unaffordable -- see docs/household-economy-next-cut.md:
## "inability to pay must not disappear from hunger statistics or be
## confused with absent goods."
var last_unmet_scarcity: Dictionary[Commodity.Type, float] = {}
## Wanted and physically available to buy, but this household couldn't
## afford the funded quantity at today's posted price.
var last_unmet_unaffordable: Dictionary[Commodity.Type, float] = {}

func _init(p_id: int, p_worker_capacity: int, p_dependents: int, p_starting_balance: float = 0.0) -> void:
	id = p_id
	demographics = Household.new(p_id, 0, p_worker_capacity, p_dependents, 0.0)
	balance = p_starting_balance

func worker_capacity() -> int:
	return demographics.worker_capacity

func set_worker_capacity(value: int) -> void:
	demographics.worker_capacity = value

func headcount() -> int:
	return demographics.headcount()

func is_employed() -> bool:
	return employer_business_id != -1

func stock(commodity: Commodity.Type) -> float:
	return inventory.get(commodity, 0.0)

func add_stock(commodity: Commodity.Type, amount: float) -> void:
	inventory[commodity] = stock(commodity) + amount

## Removes up to `amount` and returns how much was actually removed. Never
## drives stock negative. Pure primitive -- demand/unmet accounting lives in
## HESimulation's daily record, not here.
func consume(commodity: Commodity.Type, amount: float) -> float:
	var available := stock(commodity)
	var taken: float = min(available, amount)
	inventory[commodity] = available - taken
	return taken

## Appends today's grain demand/taken to this household's own rolling window
## and returns taken/demand for TODAY (1.0 if there was no demand) -- the
## immediate daily ratio HESimulation feeds into apply_daily_fulfillment
## alongside the rolling-window flags below.
func record_grain_day(demand: float, taken: float) -> float:
	_grain_history.append({"demand": demand, "taken": taken})
	if _grain_history.size() > GRAIN_ROLLING_WINDOW_DAYS:
		_grain_history.pop_front()
	return (taken / demand) if demand > 0.0 else 1.0

func rolling_grain_fulfillment() -> float:
	var demand_total := 0.0
	var taken_total := 0.0
	for entry in _grain_history:
		demand_total += entry["demand"]
		taken_total += entry["taken"]
	return (taken_total / demand_total) if demand_total > 0.0 else 1.0
