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

## Life cycle (births + aging). Dependents are tracked as individual ages in
## days (not just a headcount) so each can independently cross the aging
## threshold on its own day -- a household's dependents were not all born on
## the same day, even at world-seed time (see HEScenarioSeeds' staggered
## starting ages). There is deliberately no household formation/splitting
## here: an aged-up dependent becomes another worker in the SAME household,
## which can grow without an upper bound on total size over a long enough
## run. That's a real simplification, not an oversight -- splitting a
## household when it gets large is a reasonable later cut, not this one.
const AGING_THRESHOLD_DAYS := 360
## A household needs this many CONSECUTIVE well-fed, low-stress days before
## a birth becomes eligible -- mirrors the same "sustained, not one good
## week" philosophy as migration-pressure/starvation's consecutive-day
## gates, just pointed at prosperity instead of hardship.
const BIRTH_ELIGIBLE_DAYS := 180
## Minimum spacing between a household's births, so a permanently
## prosperous household can't produce a baby every single eligible day.
const BIRTH_COOLDOWN_DAYS := 360
const BIRTH_FULFILLMENT_THRESHOLD := 0.95
const BIRTH_STRESS_THRESHOLD := 0.1
## Caps how many dependents can be IN THE PIPELINE (born but not yet aged
## into a worker) at once -- a soft brake on growth rate, not a cap on the
## household's eventual total size.
const MAX_PENDING_DEPENDENTS := 6

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

## One entry per CURRENT dependent, in days -- see seed_dependent_ages() for
## how starting households get a staggered spread instead of every
## dependent aging up on the exact same day.
var _dependent_ages: Array[int] = []
var _consecutive_prosperous_days: int = 0
## Starts already at the cooldown ceiling so a household prosperous from
## day one isn't artificially blocked from its FIRST birth.
var _days_since_last_birth: int = BIRTH_COOLDOWN_DAYS

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

## World-seed only: sets this household's dependents' starting ages
## directly (must match demographics.dependents in count). Lets
## HEScenarioSeeds stagger starting ages across the population instead of
## every seeded dependent aging into a worker on the exact same day.
func seed_dependent_ages(ages: Array[int]) -> void:
	_dependent_ages = ages.duplicate()

func dependent_ages() -> Array[int]:
	return _dependent_ages.duplicate()

## Called once per day by HESimulation, after today's grain consumption/
## stress update -- ages every current dependent by one day and extends or
## resets this household's prosperity streak from TODAY's rolling grain
## fulfillment and food_stress.
func advance_day_for_lifecycle(rolling_grain_fulfillment_today: float) -> void:
	for i in _dependent_ages.size():
		_dependent_ages[i] += 1
	_days_since_last_birth += 1
	var prosperous := rolling_grain_fulfillment_today >= BIRTH_FULFILLMENT_THRESHOLD \
		and demographics.food_stress <= BIRTH_STRESS_THRESHOLD
	_consecutive_prosperous_days = (_consecutive_prosperous_days + 1) if prosperous else 0

## Wraps demographics.remove_member() for starvation so _dependent_ages
## stays in sync: that pooled method decrements dependents directly with no
## idea this household is also tracking individual ages, so removing a
## dependent here must also pop one age entry -- otherwise _dependent_ages
## ends up with more entries than demographics.dependents actually is, and
## evaluate_aging() below can later drive dependents negative promoting from
## that phantom surplus (which headcount()/is_empty() would then silently
## miscount, since nothing re-checks emptiness after aging).
func remove_member_for_starvation() -> void:
	var removing_a_dependent := demographics.dependents > 0
	demographics.remove_member()
	if removing_a_dependent and not _dependent_ages.is_empty():
		_dependent_ages.pop_back()

## Monthly: promotes every dependent whose age has crossed
## AGING_THRESHOLD_DAYS into a worker (dependents -> worker_capacity, in the
## SAME household -- see the class-level note on why there's no splitting).
## Returns how many were promoted, for HESimulation's reporting.
func evaluate_aging() -> int:
	var promoted := 0
	var remaining: Array[int] = []
	for age in _dependent_ages:
		if age >= AGING_THRESHOLD_DAYS:
			promoted += 1
		else:
			remaining.append(age)
	if promoted == 0:
		return 0
	_dependent_ages = remaining
	demographics.dependents -= promoted
	demographics.worker_capacity += promoted
	return promoted

## Monthly, called after evaluate_aging so a just-freed pipeline slot counts
## this same period: a household that's been prosperous for at least
## BIRTH_ELIGIBLE_DAYS, isn't within BIRTH_COOLDOWN_DAYS of its last birth,
## and has fewer than MAX_PENDING_DEPENDENTS dependents already in the
## pipeline gains one new dependent at age 0. Returns true if a birth
## happened, for HESimulation's reporting.
func evaluate_birth() -> bool:
	if _consecutive_prosperous_days < BIRTH_ELIGIBLE_DAYS:
		return false
	if _days_since_last_birth < BIRTH_COOLDOWN_DAYS:
		return false
	if _dependent_ages.size() >= MAX_PENDING_DEPENDENTS:
		return false
	_dependent_ages.append(0)
	demographics.dependents += 1
	_days_since_last_birth = 0
	return true
