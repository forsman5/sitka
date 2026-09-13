class_name ScenarioSeeds
extends RefCounted

## Milestone 0.76 authored single-settlement scenarios: isolated test worlds
## (no transport, no other settlements) that exercise the food-security
## causal chain in different regimes. Each returns the same valley Dictionary
## shape as ValleySeed.build_default_valley() so Simulation.new(seed,
## Callable(ScenarioSeeds, "...")) can run them directly.
##
## Household composition is fixed (not seed-randomized) so outcomes are easy
## to reason about and tune -- these are controlled experiments, not a
## slice of the authored valley.

const Commodity = preload("res://scripts/sim/records/commodity.gd")
const Household = preload("res://scripts/sim/records/household.gd")
const Settlement = preload("res://scripts/sim/records/settlement.gd")
const Recipe = preload("res://scripts/sim/records/recipe.gd")
const Workplace = preload("res://scripts/sim/records/workplace.gd")
const TransportEdge = preload("res://scripts/sim/records/transport_edge.gd")

const SETTLEMENT_ID := 1
const WORKERS_PER_HOUSEHOLD := 2
const DEPENDENTS_PER_HOUSEHOLD := 1

## Tuned so target_labor's average seasonal output (55 * 0.875 ~= 48.1/day)
## just about matches a 120-population settlement's grain demand
## (120 * 0.4 = 48/day) -- the fixed farm recipe/seasonal curve from
## ValleySeed is reused so this stays one shared carrying-capacity model.
const VIABLE_FARM_TARGET_LABOR := 55.0
const VIABLE_FARM_HOUSEHOLDS := 40 # -> population 120, workers 80

static func _farm_recipe() -> Recipe:
	return Recipe.new(
		"farm",
		{},
		{Commodity.Type.GRAIN: 1.0},
		[0.8, 1.0, 1.6, 0.1],
	)

static func _build_uniform_valley(household_count: int, starting_grain: float, target_labor: float) -> Dictionary:
	var settlement := Settlement.new(SETTLEMENT_ID, "Testfarm")
	settlement.is_player_holding = true
	settlement.add_stock(Commodity.Type.GRAIN, starting_grain)

	var settlements: Dictionary[int, Settlement] = {SETTLEMENT_ID: settlement}

	var households: Dictionary[int, Household] = {}
	for i in household_count:
		var id := i + 1
		var household := Household.new(id, SETTLEMENT_ID, WORKERS_PER_HOUSEHOLD, DEPENDENTS_PER_HOUSEHOLD)
		households[id] = household
		settlement.household_ids.append(id)

	var workplaces: Dictionary[int, Workplace] = {}
	if target_labor > 0.0:
		var workplace := Workplace.new(1, SETTLEMENT_ID, _farm_recipe(), target_labor)
		workplaces[1] = workplace
		settlement.workplace_ids.append(1)

	var transport_edges: Dictionary[int, TransportEdge] = {}

	return {
		"settlements": settlements,
		"households": households,
		"workplaces": workplaces,
		"transport_edges": transport_edges,
	}

## A farm with land/labor comfortably matched to its population: should reach
## a repeatable seasonal equilibrium (stock oscillates with the seasons but
## never runs dry, population never changes) rather than growing or
## collapsing.
static func build_viable_farm(_rng: RandomNumberGenerator) -> Dictionary:
	return _build_uniform_valley(VIABLE_FARM_HOUSEHOLDS, 3000.0, VIABLE_FARM_TARGET_LABOR)

## Same land/labor capacity as the viable farm, but starts well above the
## carrying capacity it supports. Should contract via starvation (emigration
## is desire-only right now -- there's nowhere to go) until population falls
## back toward roughly the same ~120 equilibrium, then stabilize.
static func build_overpopulated_farm(_rng: RandomNumberGenerator) -> Dictionary:
	return _build_uniform_valley(VIABLE_FARM_HOUSEHOLDS * 3, 3000.0, VIABLE_FARM_TARGET_LABOR)

## No farm at all -- a finite starting stock delays the reckoning, but with
## zero production the settlement must eventually exhaust it, then decline
## through emigration desire and starvation to collapse.
static func build_no_food_settlement(_rng: RandomNumberGenerator) -> Dictionary:
	return _build_uniform_valley(VIABLE_FARM_HOUSEHOLDS, 2000.0, 0.0)

## Same viable farm, but with a much thinner starting buffer: a real (not
## just cosmetic) shortage in the first spring, before summer's higher
## output arrives, that should raise stress without crossing the
## emigration/starvation consecutive-day thresholds -- and then recover.
static func build_recovery_boundary(_rng: RandomNumberGenerator) -> Dictionary:
	return _build_uniform_valley(VIABLE_FARM_HOUSEHOLDS, 200.0, VIABLE_FARM_TARGET_LABOR)
