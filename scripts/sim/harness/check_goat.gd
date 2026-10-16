extends SceneTree

## Headless check of the Goat Farm (HEBusiness.Species.GOAT):
##   godot --headless --path . --script res://scripts/sim/harness/check_goat.gd
## A goat herd is opt-in (spec "herds": ["goat_farm"]); it must grow, cull into
## the Butcher/Trader, stay in business, and leave towns without it unchanged.

const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HEPresets = preload("res://scripts/sim/household_economy/data/he_presets.gd")
const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEBusiness = preload("res://scripts/sim/household_economy/records/he_business.gd")

const SEED := 12345
const RUN_DAYS := 1080

var _ok := true

func _init() -> void:
	_check_species_tables()
	_check_opt_in()
	_check_goat_farm_runs()
	print("GOAT %s" % ("OK" if _ok else "FAILED"))
	quit(0 if _ok else 1)

func _assert(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		_ok = false

func _check_species_tables() -> void:
	var goat := HEBusiness.Species.GOAT
	for table in [HESimulation.HERD_GROWTH_RATE, HESimulation.HERD_LOSS_RATE_FED, HESimulation.HERD_LOSS_RATE_NEGLECTED,
			HESimulation.HERD_LABOR_PER_HEAD_PER_DAY, HESimulation.HERD_EXPORT_PRICE, HESimulation.DEFAULT_RANCH_LAND_ACRES,
			HESimulation.FODDER_PER_HEAD_PER_WINTER, HESimulation.BUTCHERY_WORKER_DAYS_PER_HEAD, HESimulation.BUTCHERY_MEAT_PER_HEAD,
			HESimulation.BUTCHERY_LEATHER_PER_HEAD, HESimulation.HOME_BUTCHER_MEAT_PER_HEAD, HESimulation.HARDSHIP_BUTCHER_MIN_HERD]:
		_assert(table.has(goat), "Every per-species table has a goat entry")
	_assert(HEBusiness.livestock_commodity(goat) == Commodity.Type.GOAT, "A goat herd holds goats")
	_assert(HESimulation.livestock_species(Commodity.Type.GOAT) == goat, "Goat commodity maps back to the goat species")
	_assert(HESimulation.is_livestock(Commodity.Type.GOAT), "Goats are livestock")
	_assert(HESimulation.BUTCHERY_SPECIES_ORDER.has(goat), "The Butcher works goats")
	_assert(Commodity.icon_of(Commodity.Type.GOAT) != null, "Goat icon loads")
	_assert(HESimulation.land_per_head(goat) < HESimulation.land_per_head(HEBusiness.Species.SHEEP), "A goat takes a little less land than a sheep")

func _check_opt_in() -> void:
	var plain := HESimulation.new(SEED, Callable(HEScenarioSeeds, "build_preset").bind("mining_village"), true)
	_assert(not plain.businesses.has(HEScenarioSeeds.GOAT_FARM_BUSINESS_ID), "Presets have no goat farm unless asked")
	var spec := HEPresets.custom_spec(["farm", "woodlot", "trader", "goat_farm"], 24)
	_assert(HEPresets.validate(spec).is_empty(), "A goat roster validates")
	var sim := HESimulation.new(SEED, Callable(HEScenarioSeeds, "build_spec").bind(spec), true)
	_assert(sim.has_business_of_type(HEScenarioSeeds.SETTLEMENT_ID, "goat_farm"), "The custom roster builds a goat farm")

func _check_goat_farm_runs() -> void:
	var spec := HEPresets.spec("mining_village")
	spec["herds"] = ["goat_farm"]
	var sim := HESimulation.new(SEED, Callable(HEScenarioSeeds, "build_spec").bind(spec), true)
	var goats: HEBusiness = sim.businesses[HEScenarioSeeds.GOAT_FARM_BUSINESS_ID]
	var start_herd := goats.herd_size
	var culled := 0.0
	var peak_staff := 0
	for d in RUN_DAYS:
		sim.advance_ticks(1)
		if not sim.businesses.has(HEScenarioSeeds.GOAT_FARM_BUSINESS_ID):
			break
		culled += float(goats.last_culled.get(Commodity.Type.GOAT, 0.0)) if (d + 1) % HESimulation.HERD_EVAL_INTERVAL_DAYS == 0 else 0.0
		peak_staff = maxi(peak_staff, goats.capacity)
	_assert(sim.businesses.has(HEScenarioSeeds.GOAT_FARM_BUSINESS_ID), "The Goat Farm is still in business after %d days" % RUN_DAYS)
	print("  goat herd %.0f -> %.0f, culled %.0f, peak crew %d, balance %.0f" % [start_herd, goats.herd_size, culled, peak_staff, goats.balance])
	_assert(goats.herd_size > start_herd or culled > 0.0, "The goat herd grows or is culled")
	_assert(culled > 0.0, "The goat herd reached its first cull")
	var goat_export_listed := false
	for setting in sim.get_trader_export_settings(HEScenarioSeeds.TRADER_BUSINESS_ID):
		if setting["commodity_id"] == Commodity.Type.GOAT:
			goat_export_listed = true
	_assert(goat_export_listed, "Goats appear as a Trader export setting")
