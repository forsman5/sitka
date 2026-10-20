extends SceneTree

## Headless check of the Quarry (HEScenarioSeeds.make_quarry):
##   godot --headless --path . --script res://scripts/sim/harness/check_quarry.gd
## The Quarry must stay in business on Trader exports alone, quarried stone
## must be able to pay for a tenement, and it must share the Iron Mine's
## extractor shape.

const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HEPresets = preload("res://scripts/sim/household_economy/data/he_presets.gd")
const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEBusiness = preload("res://scripts/sim/household_economy/records/he_business.gd")

const SEED := 12345
const RUN_DAYS := 720

var _ok := true

func _init() -> void:
	_check_shared_extractor_shape()
	_check_stone_is_a_good()
	_check_quarry_survives_on_exports()
	_check_stone_pays_for_tenement()
	print("QUARRY %s" % ("OK" if _ok else "FAILED"))
	quit(0 if _ok else 1)

func _assert(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		_ok = false

func _check_shared_extractor_shape() -> void:
	var quarry := HEScenarioSeeds.make_quarry(99, 1, 4)
	var mine := HEScenarioSeeds.make_iron_mine(98, 1, 4)
	_assert(quarry.recipe.inputs.is_empty() and mine.recipe.inputs.is_empty(), "Extractors take no inputs")
	_assert(quarry.recipe.outputs == {Commodity.Type.STONE: HEScenarioSeeds.QUARRY_OUTPUT_PER_WORKER_DAY}, "Quarry digs its stone rate per worker-day")
	_assert(mine.recipe.outputs == {Commodity.Type.IRON_ORE: 1.0}, "Iron Mine digs one ore per worker-day")
	_assert(quarry.max_capacity == mine.max_capacity, "Both extractors share one staffing ceiling")
	_assert(quarry.uses_tools() and mine.uses_tools(), "Both extractors use tools")

func _check_stone_is_a_good() -> void:
	_assert(Commodity.name_of(Commodity.Type.STONE) == "Stone", "Stone has a display name")
	_assert(Commodity.icon_of(Commodity.Type.STONE) != null, "Stone icon loads")
	_assert(HESimulation.BASE_PRICE.has(Commodity.Type.STONE), "Stone has a market price")
	_assert(HESimulation.EXPORT_COMMODITIES.has(Commodity.Type.STONE), "Stone is exported by default")

func _quarry_sim() -> HESimulation:
	var spec := HEPresets.spec("mining_village")
	return HESimulation.new(SEED, Callable(HEScenarioSeeds, "build_spec").bind(spec), true)

func _check_quarry_survives_on_exports() -> void:
	var sim := _quarry_sim()
	_assert(sim.businesses.has(HEScenarioSeeds.QUARRY_BUSINESS_ID), "The mining village has a Quarry")
	var port: HEBusiness = sim.businesses.get(HEScenarioSeeds.PORT_BUSINESS_ID)
	_assert(port != null and port.kind == HEBusiness.Kind.PORT and HESimulation.PORT_GOODS.has(Commodity.Type.STONE), "The Port buys stone for the outside market")
	var early_crew := 0
	var late_crew := 0
	for d in RUN_DAYS:
		sim.advance_ticks(1)
		var quarry: HEBusiness = sim.businesses.get(HEScenarioSeeds.QUARRY_BUSINESS_ID)
		if quarry == null:
			break
		if d == 60:
			early_crew = quarry.capacity
		late_crew = quarry.capacity
	_assert(sim.businesses.has(HEScenarioSeeds.QUARRY_BUSINESS_ID), "The Quarry is still in business after %d days" % RUN_DAYS)
	print("  quarry crew %d -> %d, balance %.0f, stone stock %.0f" % [early_crew, late_crew,
		(sim.businesses[HEScenarioSeeds.QUARRY_BUSINESS_ID] as HEBusiness).balance,
		(sim.businesses[HEScenarioSeeds.QUARRY_BUSINESS_ID] as HEBusiness).stock(Commodity.Type.STONE)])
	_assert(late_crew >= 1, "The Quarry keeps at least one worker employed")
	var held := (sim.businesses[HEScenarioSeeds.QUARRY_BUSINESS_ID] as HEBusiness).stock(Commodity.Type.STONE)
	_assert(held < 400.0, "Unsold stone should not pile up unboundedly (%.0f held)" % held)
	var warehouse := sim._government_warehouse(HEScenarioSeeds.SETTLEMENT_ID)
	print("  warehouse stone %.0f" % warehouse.stock(Commodity.Type.STONE))

func _check_stone_pays_for_tenement() -> void:
	var sim := _quarry_sim()
	sim.construction_days = 0
	var settlement_id := HEScenarioSeeds.SETTLEMENT_ID
	var warehouse := sim._government_warehouse(settlement_id)
	warehouse.inventory[Commodity.Type.STONE] = 0.0
	var tenement: Dictionary = {}
	for option in HEScenarioSeeds.government_buildings():
		if option["type_key"] == "tenement":
			tenement = option
	_assert(sim.build_cost_for(settlement_id, tenement)["goods"].has(Commodity.Type.STONE), "A tenement costs stone")
	_assert(sim.government_build_blocker(settlement_id, tenement) != "", "No stone in the warehouse blocks the tenement")
	warehouse.add_stock(Commodity.Type.STONE, HEScenarioSeeds.TENEMENT_UPGRADE_STONE)
	var gold_needed := float(sim.build_cost_for(settlement_id, tenement)["gold"])
	var gov: HEBusiness = sim.businesses[HEScenarioSeeds.GOVERNMENT_BUSINESS_ID]
	gov.balance = maxf(gov.balance, gold_needed + 100.0)
	var stone_before := warehouse.stock(Commodity.Type.STONE)
	_assert(sim.build_government_building(settlement_id, "tenement"), "Stocked stone builds the tenement")
	_assert(absf(stone_before - warehouse.stock(Commodity.Type.STONE) - HEScenarioSeeds.TENEMENT_UPGRADE_STONE) < 0.001, "The tenement consumed its stone")
