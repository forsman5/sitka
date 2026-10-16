extends RefCounted

## Test-only starting worlds for the household-economy harnesses. These are the
## old hand-authored scenarios, kept here (not in production code) so the sim
## checks keep a stable, comparable 30-household fixture. Players start from
## HEPresets; nothing outside scripts/sim/harness should use these.

const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HESettlement = preload("res://scripts/sim/household_economy/records/he_settlement.gd")

## Evenly staffed on day one -- HEScenarioSeeds.HOUSEHOLD_COUNT*HEScenarioSeeds.WORKER_CAPACITY workers split
## with a small slice going to the Trader and the rest split 50/50 between
## Farm and Woodlot. With the recipe rates above, Woodlot's output is
## structurally oversupplied relative to Farm-household fuel demand, so its
## wage should fall below the reference wage and its capacity should
## contract over time, while Farm's grows -- the "let it tune itself"
## scenario, rather than hand-balancing the recipe rates. The Trader takes
## some of the edge off that divergence (it exports Woodlot's surplus
## timber for a bit of extra revenue) without erasing it, since it only
## ever touches stock above a comfortable reserve.
static func build_three_business_economy(_rng: RandomNumberGenerator) -> Dictionary:
	var trader := 8
	var remainder := HEScenarioSeeds.HOUSEHOLD_COUNT * HEScenarioSeeds.WORKER_CAPACITY - trader
	var half := (remainder / HEScenarioSeeds.WORKER_CAPACITY / 2) * HEScenarioSeeds.WORKER_CAPACITY
	return HEScenarioSeeds.build_world(half, remainder - half, trader)

## Same as build_three_business_economy, plus a fourth, opt-in business: the
## Bloomery, which buys wood from the Woodlot and iron ore imported by the
## Trader to smelt iron, then relies on that same Trader to export every bit
## of it (see he_simulation.gd's _run_input_purchasing/_run_trade -- no
## household ever wants iron directly, so it all leaves the settlement).
## This is the toggle: pick this builder (see he_dashboard.gd's SCENARIOS)
## instead of build_three_business_economy to turn the Bloomery on for a new
## sim, or the plain builder above to leave it out entirely.
static func build_three_business_economy_with_bloomery(_rng: RandomNumberGenerator) -> Dictionary:
	var trader := 8
	var bloomery := 8
	var remainder := HEScenarioSeeds.HOUSEHOLD_COUNT * HEScenarioSeeds.WORKER_CAPACITY - trader - bloomery
	var half := (remainder / HEScenarioSeeds.WORKER_CAPACITY / 2) * HEScenarioSeeds.WORKER_CAPACITY
	return HEScenarioSeeds.build_world(half, remainder - half, trader, bloomery)

## Local-ore variant: the Iron Mine puts ore into its business inventory,
## where the Bloomery buys it on the following day before the Trader gets a
## chance to export any remaining surplus. _run_input_purchasing also
## prefers this local seller over the Trader's outside-import fallback.
static func build_economy_with_bloomery_and_iron_mine(_rng: RandomNumberGenerator) -> Dictionary:
	var trader := 8
	var bloomery := 8
	var iron_mine := 8
	var remainder := HEScenarioSeeds.HOUSEHOLD_COUNT * HEScenarioSeeds.WORKER_CAPACITY - trader - bloomery - iron_mine
	var half := (remainder / HEScenarioSeeds.WORKER_CAPACITY / 2) * HEScenarioSeeds.WORKER_CAPACITY
	return HEScenarioSeeds.build_world(half, remainder - half, trader, bloomery, iron_mine)

## A town with a Toolsmith and no iron production of its own: no local seller
## of iron exists, so the Trader imports it (see HESimulation's
## _run_input_purchasing), as the valley's Staithe smithy gets its iron from
## elsewhere. Existing builders leave the Toolsmith out so their outcomes stay
## comparable.
static func build_economy_with_toolsmith(_rng: RandomNumberGenerator) -> Dictionary:
	var trader := 8
	var toolsmith := HEScenarioSeeds.TOOLSMITH_STARTING_CAPACITY
	var remainder := HEScenarioSeeds.HOUSEHOLD_COUNT * HEScenarioSeeds.WORKER_CAPACITY - trader - toolsmith
	var half := (remainder / HEScenarioSeeds.WORKER_CAPACITY / 2) * HEScenarioSeeds.WORKER_CAPACITY
	return HEScenarioSeeds.build_world(half, remainder - half, trader, 0, 0, 0, toolsmith)

## Eight businesses: the Iron Mine scenario plus a Charcoal Burner that turns
## the Woodlot's timber into charcoal. Households switch to charcoal when it
## is the cheaper way to heat a home (see HESimulation._satisfier_cascade);
## the Bloomery's heat is bought the same way. The burner's own timber input
## is raw material, not a need slot, so it stays timber.
static func build_economy_with_charcoal_burner(_rng: RandomNumberGenerator) -> Dictionary:
	var trader := 8
	var bloomery := 8
	var iron_mine := 8
	var charcoal_burner := HEScenarioSeeds.CHARCOAL_BURNER_STARTING_CREW
	var remainder := HEScenarioSeeds.HOUSEHOLD_COUNT * HEScenarioSeeds.WORKER_CAPACITY - trader - bloomery - iron_mine - charcoal_burner
	var half := (remainder / HEScenarioSeeds.WORKER_CAPACITY / 2) * HEScenarioSeeds.WORKER_CAPACITY
	return HEScenarioSeeds.build_world(half, remainder - half, trader, bloomery, iron_mine, charcoal_burner)

## Deliberately mis-staffed the OTHER way on day one -- Woodlot overstaffed,
## Farm understaffed -- to make the self-correction visible fast rather
## than waiting for the balanced scenario's slower drift. The Trader starts
## with a smaller slice still, since it's a release valve, not a primary
## employer.
static func build_lopsided_start(_rng: RandomNumberGenerator) -> Dictionary:
	var trader := 6
	var remainder := HEScenarioSeeds.HOUSEHOLD_COUNT * HEScenarioSeeds.WORKER_CAPACITY - trader
	var farm := int(remainder * 0.2)
	return HEScenarioSeeds.build_world(farm, remainder - farm, trader)

## Player-chosen roster from the household economy config page. `included`
## is an array of business ids (the *_BUSINESS_ID constants); anything absent
## is built by _build_world and then dropped, so it never exists in the sim.
## Trader/Bloomery/Iron Mine start with the same 8-worker slices the presets
## use, and whatever is left splits evenly between Farm and Woodlot (or all
## goes to whichever one is present). Ranches self-bootstrap, so they take no
## day-one staff. Needs Farm or Woodlot -- nothing else makes grain or fuel.
static func build_custom(_rng: RandomNumberGenerator, included: Array) -> Dictionary:
	var trader: int = 8 if included.has(HEScenarioSeeds.TRADER_BUSINESS_ID) else 0
	var bloomery: int = 8 if included.has(HEScenarioSeeds.BLOOMERY_BUSINESS_ID) else 0
	var iron_mine: int = 8 if included.has(HEScenarioSeeds.IRON_MINE_BUSINESS_ID) else 0
	var charcoal_burner: int = HEScenarioSeeds.CHARCOAL_BURNER_STARTING_CREW if included.has(HEScenarioSeeds.CHARCOAL_BURNER_BUSINESS_ID) else 0
	var toolsmith: int = HEScenarioSeeds.TOOLSMITH_STARTING_CAPACITY if included.has(HEScenarioSeeds.TOOLSMITH_BUSINESS_ID) else 0
	var remainder := HEScenarioSeeds.HOUSEHOLD_COUNT * HEScenarioSeeds.WORKER_CAPACITY - trader - bloomery - iron_mine - charcoal_burner - toolsmith
	var has_farm := included.has(HEScenarioSeeds.FARM_BUSINESS_ID)
	var has_woodlot := included.has(HEScenarioSeeds.WOODLOT_BUSINESS_ID)
	var farm := 0
	var woodlot := 0
	if has_farm and has_woodlot:
		farm = (remainder / HEScenarioSeeds.WORKER_CAPACITY / 2) * HEScenarioSeeds.WORKER_CAPACITY
		woodlot = remainder - farm
	elif has_farm:
		farm = remainder
	elif has_woodlot:
		woodlot = remainder
	var world := HEScenarioSeeds.build_world(farm, woodlot, trader, bloomery, iron_mine, charcoal_burner, toolsmith, {"goat_farm": included.has(HEScenarioSeeds.GOAT_FARM_BUSINESS_ID)})
	var businesses: Dictionary = world["businesses"]
	var settlement: HESettlement = world["settlements"][HEScenarioSeeds.SETTLEMENT_ID]
	for business_id in businesses.keys():
		if business_id != HEScenarioSeeds.GOVERNMENT_BUSINESS_ID and not included.has(business_id):
			businesses.erase(business_id)
			settlement.business_ids.erase(business_id)
	return world
