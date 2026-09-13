class_name Household
extends RefCounted

## Milestone 0.76 tuning constants. Placeholders, not final balance --
## expect to retune alongside playtesting.
const STRESS_RECOVERY_PER_DAY := 0.05
const STRESS_GAIN_PER_SHORTAGE := 0.25
const EMIGRATION_FULFILLMENT_THRESHOLD := 0.75
const EMIGRATION_MIN_CONSECUTIVE_DAYS := 21
const EMIGRATION_STRESS_THRESHOLD := 0.5
const STARVATION_FULFILLMENT_THRESHOLD := 0.25
const STARVATION_MIN_CONSECUTIVE_DAYS := 60
const STARVATION_STRESS_THRESHOLD := 0.9

var id: int
var settlement_id: int
var worker_capacity: int
var dependents: int
var wealth: float

var food_stress: float = 0.0

## Wants to leave for a settlement with better food security, but there is
## nowhere to go: Milestone 2's transport/shipments don't exist yet, and
## person-movement between settlements needs that same infrastructure. So
## this is expressed desire only -- it never actually removes the household.
## See docs/river-valley-vertical-slice.md Milestone 0.76.
var wants_to_emigrate: bool = false

var _consecutive_low_fulfillment_days: int = 0
var _consecutive_severe_shortage_days: int = 0

func _init(p_id: int, p_settlement_id: int, p_worker_capacity: int, p_dependents: int, p_wealth: float = 0.0) -> void:
	id = p_id
	settlement_id = p_settlement_id
	worker_capacity = p_worker_capacity
	dependents = p_dependents
	wealth = p_wealth

func headcount() -> int:
	return worker_capacity + dependents

func is_empty() -> bool:
	return worker_capacity <= 0 and dependents <= 0

## Call once per day with the settlement's grain fulfillment ratio for that
## day (taken / demanded, 1.0 if there was no demand). Updates stress and the
## consecutive-shortage counters that emigration desire and starvation
## eligibility are evaluated from.
func apply_daily_fulfillment(fulfillment_ratio: float) -> void:
	if fulfillment_ratio >= 1.0:
		food_stress = max(food_stress - STRESS_RECOVERY_PER_DAY, 0.0)
	else:
		food_stress = min(food_stress + (1.0 - fulfillment_ratio) * STRESS_GAIN_PER_SHORTAGE, 1.0)

	if fulfillment_ratio < EMIGRATION_FULFILLMENT_THRESHOLD:
		_consecutive_low_fulfillment_days += 1
	else:
		_consecutive_low_fulfillment_days = 0

	if fulfillment_ratio < STARVATION_FULFILLMENT_THRESHOLD:
		_consecutive_severe_shortage_days += 1
	else:
		_consecutive_severe_shortage_days = 0

## Called weekly. One isolated bad day (or week) can't trigger this --
## it requires a sustained run of low-fulfillment days plus elevated stress.
## Recomputed (and cleared) every call, so recovery un-sets it too.
func update_emigration_desire() -> void:
	wants_to_emigrate = _consecutive_low_fulfillment_days >= EMIGRATION_MIN_CONSECUTIVE_DAYS \
		and food_stress >= EMIGRATION_STRESS_THRESHOLD

## Called monthly. Slower and stricter than emigration desire by design --
## starvation is the last resort, not the first response to a bad season.
func is_starvation_candidate() -> bool:
	return _consecutive_severe_shortage_days >= STARVATION_MIN_CONSECUTIVE_DAYS \
		and food_stress >= STARVATION_STRESS_THRESHOLD

## Removes one member (a dependent if any, else a worker) for starvation
## mortality. Caller is responsible for deleting the household once is_empty().
func remove_member() -> void:
	if dependents > 0:
		dependents -= 1
	elif worker_capacity > 0:
		worker_capacity -= 1
