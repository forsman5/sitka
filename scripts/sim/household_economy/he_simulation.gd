class_name HESimulation
extends RefCounted

## H1, labor-market cut: deterministic, tick-based household economies with
## settlement-local markets and labor pools. Opt-in and separate from
## Simulation (scripts/sim/simulation.gd)'s pooled valley model. Businesses
## (Farm, Woodlot, and the
## Trader -- see he_business.gd) are city-owned productive sites that hire
## households as labor, sell on the market, and pay wages; households own no
## production themselves -- they supply labor, earn wages, and buy grain/
## timber to survive. A business's employee-slot count self-tunes weekly:
## paying above the going subsistence-equivalent wage lets it grow, paying
## below shrinks it, so labor drifts from an unprofitable business to a
## profitable one without anyone hand-tuning production rates. Real
## consequences for going hungry exist here (unlike the earlier
## owner-operator cut): a household on the brink of starvation loses
## members to emigration and can cease to exist. "Emigrate" is a
## placeholder label for now, not an actual migration model -- there's
## no inter-settlement migration exists yet; see
## remove_member_for_emigration()'s note for why it's still an improvement
## over calling it "death". Workers also exit the workforce naturally via
## old age (see he_household.gd's evaluate_old_age_death()) -- unlike
## emigration this isn't a hardship signal, so it's tracked and reported
## separately. Advanced only through advance_ticks(); nothing here reads or
## writes the scene tree.
##
## API boundary, same discipline as the pooled Simulation: callers use these
## query methods only, never the households/businesses Dictionaries
## directly. Returned dictionaries/arrays are snapshots and cannot mutate
## simulation state:
##   get_settlement_ids(), get_household_ids(settlement_id),
##   get_clock_summary(), get_household_summary(id),
##   get_settlement_summary(id), get_business_reports(settlement_id),
##   get_market_summary(settlement_id), get_market_report(settlement_id, commodity),
##   get_daily_history(days), get_trade_transactions(business_id, days),
##   get_business_employment_events(business_id, event_type, limit),
##   get_event_log(limit), get_event_log_days(days)

const Commodity = preload("res://scripts/sim/records/commodity.gd")
const Household = preload("res://scripts/sim/records/household.gd")
const HEHousehold = preload("res://scripts/sim/household_economy/records/he_household.gd")
const HEBusiness = preload("res://scripts/sim/household_economy/records/he_business.gd")
const HEHouse = preload("res://scripts/sim/household_economy/records/he_house.gd")
const HEField = preload("res://scripts/sim/household_economy/records/he_field.gd")
const HESettlement = preload("res://scripts/sim/household_economy/records/he_settlement.gd")
const HEMarket = preload("res://scripts/sim/household_economy/records/he_market.gd")
const HENeed = preload("res://scripts/sim/household_economy/records/he_need.gd")
const HENeeds = preload("res://scripts/sim/household_economy/data/he_needs.gd")
const HEWages = preload("res://scripts/sim/household_economy/he_wages.gd")

## H1's local household goods: every good that satisfies one of HENeeds' needs
## (food, heat, clothing). Grain (food) is survival-critical and drives
## food_stress/starvation; fuel and wool have the same local demand/market/
## reference-wage treatment but do NOT feed the stress engine -- see
## _run_consumption and HENeed.drives_lifecycle. Wool joined once the Cattle
## Ranch/Sheep Farm (Kind.HERD) started producing it, mirroring the pooled
## model's own convention of treating wool as an ordinary per-person
## consumption good (see simulation.gd's WOOL_PER_PERSON_PER_DAY) while
## cattle/sheep themselves are NOT -- see HERD_EXPORT_PRICE's doc comment for
## why those two stay Trader-export-only. Derived, so a new satisfier added to
## HENeeds joins every market, reserve and summary loop automatically.
static var SUBSISTENCE_COMMODITIES: Array[Commodity.Type] = HENeeds.satisfier_commodities()

## A household requests up to this many days' worth of buffer; there is no
## "protected" seller buffer any more -- businesses aren't consumers of
## their own output, so they always offer everything they have.
const TARGET_BUFFER_DAYS := 3.0

## A recipe-input business tries to carry this many days of inputs at its
## current staffed production rate. The stock is real business inventory:
## purchasing transfers it in, production consumes it later. This lets a
## workshop bridge intermittent supplier availability instead of requiring
## every input to be purchasable on every single production day.
const PRODUCTION_INPUT_BUFFER_DAYS := 14.0

## Order matters here beyond readability: get_market_summary() and the
## dashboard's market grid both iterate BASE_PRICE.keys() directly to decide
## which commodities get a market row at all, so a commodity's column shows
## up in this order.
const BASE_PRICE: Dictionary[Commodity.Type, float] = {
	Commodity.Type.GRAIN: 1.0,
	Commodity.Type.TIMBER: 1.0,
	## 3.8 / 4 heat = 0.95 per heat unit, just under timber's 1.0, so
	## households switch once a burner exists. See he_scenario_seeds.gd's
	## _charcoal_burner_recipe for the worked-out burner economics.
	Commodity.Type.CHARCOAL: 3.8,
	Commodity.Type.WOOL: 2.0, # matches Simulation.BASE_PRICE[WOOL]
	Commodity.Type.IRON_ORE: 2.0, # authored placeholder, not yet tuned
	## Heavy and low-value: one unit per worker-day exported at the Trader's
	## half-price bid still clears the reference wage (~1.0). Its buyers are the
	## Government Warehouse (construction) and the Trader's export.
	Commodity.Type.STONE: 4.0, # authored placeholder, not yet tuned
	## Priced high enough that the Bloomery clears the reference wage even
	## though EVERY unit it sells goes through the Trader's discounted
	## Port's outside export channel -- unlike Farm/Woodlot,
	## which sell most of their output to local households at full price and
	## only route surplus through that same discount. See he_scenario_
	## seeds.gd's _bloomery_recipe doc comment for the worked-out numbers.
	## 30, not 15: its income is pinned (export bid x 0.5 recipe output) while the
	## reference wage it pays swings ~0.3 to 3.5 with grain, so at 15 it was
	## insolvent through every price spike. Swept 15/25/30/40 over five rosters:
	## 30 is the lowest value that kept it solvent in all of them.
	Commodity.Type.IRON: 30.0,
	## Meat packs twice grain's food into a unit (see he_needs.gd) and leather
	## is a one-for-one substitute for wool's clothing, so households compare
	## each by price per need-unit. Both start a little under parity (grain
	## and wool are 1.0 and 2.0 per unit; meat is 1.6 for two units' worth),
	## and their price floor (a quarter of this) sits below grain's and wool's,
	## so even when a glut has pushed the baseline to its floor the newcomer
	## can still win on price rather than tie and go unbought.
	Commodity.Type.MEAT: 1.6,
	Commodity.Type.LEATHER: 1.6,
	## Above the pooled model's 6.0 because iron costs 30 here (see its comment):
	## 9.0 keeps iron to about a quarter of the tool's price at 0.07 per tool.
	## A small, durable purchase: at 0.005 per person per day a household
	## spends 0.045 per person, well under a fifth of what it spends on food.
	Commodity.Type.TOOLS: 9.0,
}
## Largest one-day price move, as a fraction of the opening price.
const PRICE_ADJUST_STEP := 0.05
## A funded shortage or unsold offer of this share of the day's volume (the
## larger of offer and funded requests) moves the price by the full step; a
## smaller share moves it proportionally.
const PRICE_ADJUST_FULL_STEP_SHARE := 0.2
## Smoothed pressure within this band of zero (a share of volume, so it ignores
## rounding noise) leaves the price alone.
const PRICE_NEUTRAL_BAND := 0.02
## How much of each day's pressure enters the running average (0..1). Lower is
## calmer: a single quiet day or lumpy harvest barely moves the trend.
const PRICE_SIGNAL_SMOOTHING := 0.3
const PRICE_MULTIPLIER_MIN := 0.25
const PRICE_MULTIPLIER_MAX := 4.0

## Default commodities a Trader moves OUT of the settlement -- a superset of
## SUBSISTENCE_COMMODITIES (households never need iron, so its seller has no
## local use to protect and offers everything it makes; see
## _seller_trade_offer), plus live cattle and sheep from the ranches. IRON goes FIRST, ahead of GRAIN and
## TIMBER, on purpose: Farm/Woodlot earn most of their revenue from local
## household sales and only use export for supplemental income on top, so
## losing a turn at a capacity-constrained Trader barely dents them, but
## export is the BLOOMERY's entire revenue (no household ever buys iron
## directly) -- and Farm/Woodlot's own seeded starting stock is oversized
## enough (STARTING_STOCK_HEADROOM) that their early surplus alone can
## fully consume the Trader's daily capacity for its first several weeks.
## Putting iron last would starve the Bloomery of any revenue at all during
## exactly that early window, well before its own weekly capacity
## self-tuning gets a fair read -- see he_scenario_seeds.gd's
## build_three_business_economy_with_bloomery.
const EXPORT_COMMODITIES: Array[Commodity.Type] = [Commodity.Type.IRON, Commodity.Type.GRAIN, Commodity.Type.TIMBER, Commodity.Type.CHARCOAL, Commodity.Type.STONE, Commodity.Type.CATTLE, Commodity.Type.SHEEP]
## Goods that jump the queue for shared Trader capacity, in order. Everything
## else exportable follows in Commodity.ALL order, then EXPORT_PINNED_LAST. Only
## goods whose place matters belong here: iron first (see above), and culled
## livestock last because the Butcher gets first call on it anyway (see
## _run_livestock_purchasing).
const EXPORT_PINNED_FIRST: Array[Commodity.Type] = [Commodity.Type.IRON, Commodity.Type.GRAIN, Commodity.Type.TIMBER, Commodity.Type.CHARCOAL, Commodity.Type.MEAT, Commodity.Type.LEATHER]
const EXPORT_PINNED_LAST: Array[Commodity.Type] = [Commodity.Type.CATTLE, Commodity.Type.SHEEP]
## Every good the Trader can export, in the fixed order it draws on shared
## capacity -- so changing checkboxes never silently reorders which good gets
## first use of it. Derived rather than hand-listed: a good is exportable if it
## has a market price (BASE_PRICE) or is livestock (which has no household market
## but a posted price), so a new commodity shows up as an export setting without
## anyone remembering to add it. It starts disabled unless it is also in
## EXPORT_COMMODITIES: ore, meat and leather stay off because the Butcher's
## output is for the settlement's own households and a Trader dumping it at half
## price would only undercut them, and any newly added good (wool included)
## starts off for the same reason. Culled cattle and sheep start enabled: they
## are a ranch's only export. The settings page additionally hides goods with no
## seller in the Trader's settlement (see get_trader_export_settings).
static var EXPORT_PRIORITY: Array[Commodity.Type] = _build_export_priority()

static func _build_export_priority() -> Array[Commodity.Type]:
	var out: Array[Commodity.Type] = []
	var exportable: Array[Commodity.Type] = []
	for commodity in Commodity.ALL:
		if BASE_PRICE.has(commodity) or LIVESTOCK_GOODS.has(commodity):
			exportable.append(commodity)
	for commodity in EXPORT_PINNED_FIRST:
		if exportable.has(commodity):
			out.append(commodity)
	for commodity in exportable:
		if not out.has(commodity) and not EXPORT_PINNED_LAST.has(commodity):
			out.append(commodity)
	for commodity in EXPORT_PINNED_LAST:
		if exportable.has(commodity):
			out.append(commodity)
	return out

static func _default_export_enabled() -> Dictionary:
	var enabled := {}
	for commodity in EXPORT_PRIORITY:
		enabled[commodity] = EXPORT_COMMODITIES.has(commodity)
	return enabled

const MIGRATION_PRESSURE_EVAL_INTERVAL_DAYS := 7
const EMIGRATION_EVAL_INTERVAL_DAYS := 30 # matches Simulation's cadence choice

## Standalone towns trade with the outside market through a Port. In valley
## mode, Traders additionally carry goods between towns; they never trade
## with the outside market.
const PORT_BUY_PRICE_FRACTION := 0.5 # Port's outside purchase bid; authored placeholder, not yet tuned
## A seller's export decision (_seller_trade_offer). Local use is forecast from its
## last SELLER_FORECAST_WINDOW_DAYS of ledger once it has SELLER_FORECAST_MIN_ROWS
## days of it; stock beyond SELLER_SALVAGE_COVER_DAYS more days of routine use is
## excess and sold at any bid; SELLER_STARTING_COST_RATIO is the cost-to-value
## quote used until a full production cycle has been observed (the old half
## price, so a new seller behaves as exports always did). The cost ratio is
## capped at SELLER_COST_RATIO_CAP.
const SELLER_FORECAST_WINDOW_DAYS := 30
const SELLER_FORECAST_MIN_ROWS := 14
const SELLER_SALVAGE_COVER_DAYS := 30.0
const SELLER_STARTING_COST_RATIO := 0.5
const SELLER_COST_RATIO_CAP := 2.0
## Fully utilized, a Trader's margin per worker is
## TRADER_CAPACITY_PER_WORKER * price * (1 - PORT_BUY_PRICE_FRACTION) --
## i.e. just `price` at the 0.5 fraction above. That has to clear the
## reference wage with real room to spare even once oversupply has pushed
## price all the way down to its floor, or the Trader never grows past a
## knife-edge break-even (and a bad week tips it into capacity 0). A trader moving
## goods should scale per worker far better than a farmhand growing food by
## hand, hence the large jump from the first authored guess of 2.0.
const TRADER_CAPACITY_PER_WORKER := 8.0
## Valley shipments are booked every two days, so a Trader can handle two
## days of freight per dispatch without changing the standalone daily market.
const VALLEY_TRADER_CAPACITY_PER_WORKER := TRADER_CAPACITY_PER_WORKER * 2.0
## Outside demand is unlimited for every current market good; Port staffing is
## the throughput constraint. Keep the original port goods first, then add all
## remaining goods, so the expanded list preserves established capacity order.
static var PORT_GOODS: Array[Commodity.Type] = _build_port_goods()

static func _build_port_goods() -> Array[Commodity.Type]:
	var out: Array[Commodity.Type] = [Commodity.Type.IRON, Commodity.Type.TOOLS,
		Commodity.Type.CHARCOAL, Commodity.Type.WOOL, Commodity.Type.LEATHER, Commodity.Type.STONE]
	for commodity in _build_export_priority():
		if not out.has(commodity):
			out.append(commodity)
	return out

## Herds: two more workplace kinds (he_business.gd's HEBusiness.Kind.HERD),
## a Cattle Ranch and a Sheep Farm, whose live herd_size grows/thins on its
## own and is improved by the husbandry staff they employ (see
## HERD_LABOR_PER_HEAD_PER_DAY) -- see _run_herds. Cadence matches the
## pooled model's DAYS_PER_SEASON (simulation.gd) rather than HE's usual
## weekly/monthly evaluation intervals, since reproduction/mortality are
## seasonal-scale processes, not daily ones.
const HERD_EVAL_INTERVAL_DAYS := 90

# ---------------------------------------------------------------------------
# Seasons
# ---------------------------------------------------------------------------

## Four 90-day seasons make a 360-day year, the same calendar the pooled
## valley (simulation.gd) runs. Day 0 is the first day of spring; a season is
## a pure function of the day, so it needs no stored state and is identical
## in every run. HERD_EVAL_INTERVAL_DAYS equals DAYS_PER_SEASON, so every
## herd review closes exactly one season (the one containing `day` when
## (day + 1) is a multiple of 90).
const DAYS_PER_SEASON := 90
const SEASONS_PER_YEAR := 4
const DAYS_PER_YEAR := DAYS_PER_SEASON * SEASONS_PER_YEAR
enum Season { SPRING, SUMMER, AUTUMN, WINTER }
const SEASON_NAMES: Array[String] = ["Spring", "Summer", "Autumn", "Winter"]

## Output multipliers by the season a harvest or shearing LANDS in, copied
## from the pooled valley's seed (valley_seed.gd). They set the SHAPE of the
## year; what a harvest or wool review actually adds to a business's
## inventory is scaled by seasonal_yield_scale (the curve divided by its own
## yearly mean), so H1's calibrated annual output -- FARM_YIELD_PER_AREA and
## friends were sized to hit a yearly target -- is unchanged and seasons only
## move WHEN it arrives. Nothing else is touched, so every unit is still
## produced once, held by one business, and sold or consumed through the
## usual market and ledgers. Goods not listed (iron, charcoal...) are not
## seasonal.
const SEASONAL_OUTPUT_MODIFIER: Dictionary[Commodity.Type, Array] = {
	Commodity.Type.GRAIN: [0.8, 1.0, 1.6, 0.1],
	Commodity.Type.TIMBER: [1.0, 1.0, 1.0, 0.6],
	Commodity.Type.WOOL: [1.5, 1.5, 0.5, 0.2],
}

## How far ahead a seller looks for a lean season it must carry stock into
## (seasonal_carry_days): two seasons, so the glut that arrives in autumn is
## held for winter but summer's harvest is not held for a winter 270 days off.
const SEASONAL_CARRY_LOOKAHEAD_DAYS := 180

## Winter fodder: grain each head of a herd needs over a winter. Cattle carry
## the pooled valley's FODDER_PER_HEAD_PER_SEASON (3.0); sheep scale it by the
## forage ratio H1 already uses for grazing land (SHEEP_LAND_PER_HEAD over
## CATTLE_LAND_PER_HEAD), since a sheep is worth ~1/5 of a cow here and a
## flat 3.0 would cost more than the animal. Ranches buy it ahead of winter
## (_run_fodder_purchasing) and eat it from their own inventory at the winter
## review. The share of the need actually covered sets that winter's
## mortality: full cover is the usual FED rate, none is the NEGLECTED rate,
## linear between (underfed herds lose more).
const FODDER_PER_HEAD_PER_WINTER: Dictionary[HEBusiness.Species, float] = {
	HEBusiness.Species.CATTLE: 3.0,
	HEBusiness.Species.SHEEP: 0.6, # 3.0 * SHEEP_LAND_PER_HEAD (0.6) / CATTLE_LAND_PER_HEAD (3.0)
}

static func season_of_day(p_day: int) -> int:
	return (p_day / DAYS_PER_SEASON) % SEASONS_PER_YEAR

static func season_name_of_day(p_day: int) -> String:
	return SEASON_NAMES[season_of_day(p_day)]

## The authored valley multiplier for `commodity` on `p_day`; 1.0 for a good
## with no seasonal curve.
static func seasonal_output_modifier(commodity: Commodity.Type, p_day: int) -> float:
	if not SEASONAL_OUTPUT_MODIFIER.has(commodity):
		return 1.0
	return float((SEASONAL_OUTPUT_MODIFIER[commodity] as Array)[season_of_day(p_day)])

## Days of ordinary local use the lean seasons AHEAD leave unsupplied, looking
## SEASONAL_CARRY_LOOKAHEAD_DAYS forward from `p_day`: for each day, how far its
## multiplier falls below the curve's mean (as a share of the mean), summed.
## Grain carries ~80 days through autumn, tapering through winter, and almost
## nothing in spring and summer; 0 for a good with no curve. A seller keeps this
## much back from export on top of its usual cover (_seller_trade_offer), so an
## autumn glut is carried through the winter it was meant for rather than
## shipped out at the floor price, while spring and summer exports are
## untouched. It only withholds EXPORT; local sales are unaffected.
static func seasonal_carry_days(commodity: Commodity.Type, p_day: int) -> float:
	if not SEASONAL_OUTPUT_MODIFIER.has(commodity):
		return 0.0
	var curve: Array = SEASONAL_OUTPUT_MODIFIER[commodity]
	var total := 0.0
	for modifier in curve:
		total += float(modifier)
	var mean: float = total / float(curve.size())
	var days := 0.0
	for offset in SEASONAL_CARRY_LOOKAHEAD_DAYS:
		days += maxf(0.0, mean - seasonal_output_modifier(commodity, p_day + offset)) / mean
	return days

## What a harvest or shearing on `p_day` is actually multiplied by: the
## authored multiplier over the curve's yearly mean, so the four seasons
## average exactly 1.0 and a year's output matches the unseasonal model.
static func seasonal_yield_scale(commodity: Commodity.Type, p_day: int) -> float:
	if not SEASONAL_OUTPUT_MODIFIER.has(commodity):
		return 1.0
	var curve: Array = SEASONAL_OUTPUT_MODIFIER[commodity]
	var total := 0.0
	for modifier in curve:
		total += float(modifier)
	return seasonal_output_modifier(commodity, p_day) * float(curve.size()) / total

## Grazing land. Each ranch owns its own acreage (HEBusiness.land_area_acres,
## like a farm's land) and its herd is bounded by it: land / acres-per-head.
## Acres per head are from extension-service stocking rates: a 1,000 lb cow
## with calf is one animal unit (AU), which a temperate, unimproved pasture
## carries on roughly 1.2-3 acres a year (Penn State: 1.2 ac/AU on good
## orchardgrass-clover; semi-arid rangeland needs far more); a mature sheep
## is ~0.2 AU (0.27 with a lamb at foot). So cattle take 3.0 acres a head
## here, the thin end of that range: unimproved pasture with no fertilizer,
## and the ranch's own hay meadow, rest rotation and yards counted in -- and
## sheep 0.6, a 1:5 ratio.
## Grazing-only: a rancher buying grain to cover a shortfall is a possible
## future mechanic, not implemented. A herd past its land stops growing at
## that ceiling and takes the harsher "neglected" mortality rate below.
const CATTLE_LAND_PER_HEAD := 3.0
const SHEEP_LAND_PER_HEAD := 0.6

## Share of a ranch's carrying capacity its cull target sits at: culling back
## to this, rather than to the ceiling itself, leaves room to grow between
## reviews and a margin for a bad year (range advice is to stock well below
## capacity; tame pasture can run higher).
const HERD_STOCKING_UTILIZATION := 0.75

## Acreage a new ranch starts with: 600 acres of cattle pasture carries 200
## head and culls at 150; 160 acres of sheep pasture carries 266 and culls
## at 200 (the targets the pooled model used before ranches had land). Big
## enough that the town view's plot holds a full default herd.
const DEFAULT_RANCH_LAND_ACRES: Dictionary[HEBusiness.Species, float] = {
	HEBusiness.Species.CATTLE: 600.0,
	HEBusiness.Species.SHEEP: 160.0,
}

static func land_per_head(species: HEBusiness.Species) -> float:
	return CATTLE_LAND_PER_HEAD if species == HEBusiness.Species.CATTLE else SHEEP_LAND_PER_HEAD

## Most head `land_acres` of pasture can carry (the herd's hard ceiling).
static func herd_land_capacity(species: HEBusiness.Species, land_acres: float) -> float:
	return land_acres / land_per_head(species)

## Default cull target for a ranch of `land_acres`: the stocking utilization
## share of its carrying capacity, rounded to whole head.
static func default_cull_target(species: HEBusiness.Species, land_acres: float) -> float:
	return roundf(herd_land_capacity(species, land_acres) * HERD_STOCKING_UTILIZATION)

## Reproduction, per HERD_EVAL_INTERVAL_DAYS: cattle bear a single calf on
## a roughly annual cycle; sheep both lamb more prolifically per ewe (often
## 1.4+ lambs/lambing) and more frequently, so sheep's realized reproduction
## rate is set to roughly 2.5-3x cattle's. These are the research-backed
## rates -- tune overall PACE with HERD_GROWTH_RATE_MULTIPLIER below rather
## than editing these directly, so the relative cattle-vs-sheep ratio (and
## the doc comment above) stays meaningful.
const HERD_GROWTH_RATE: Dictionary[HEBusiness.Species, float] = {
	HEBusiness.Species.CATTLE: 0.035,
	HEBusiness.Species.SHEEP: 0.10,
}

## Single knob for how fast herds grow overall, independent of the
## realistic per-species rates above. At 1.0 (HERD_GROWTH_RATE as
## authored), a ranch takes on the order of 2000+ days to reach its first
## the default cull target from its seeded starting size -- too slow to feel like
## a lever the player is pulling in a short early-preview session. 1.6
## instead lands both ranches' first cull around ~900 days, without
## touching HERD_LOSS_RATE_FED/NEGLECTED (mortality stays at the
## research-backed rate; only reproduction speeds up). Applied only to
## HERD_GROWTH_RATE in _run_herds, never to the loss rates.
const HERD_GROWTH_RATE_MULTIPLIER := 1.6

## Mortality, per HERD_EVAL_INTERVAL_DAYS. FED applies while herd_size fits
## within what this ranch's own land can carry; NEGLECTED
## applies once it's grown past what the land can support (see
## _run_herds). Sheep run a higher baseline AND a harsher neglected rate
## than cattle -- flocks are individually more fragile despite working
## marginal land cattle can't graze efficiently -- which offsets their
## faster reproduction rather than letting sheep dominate by default.
const HERD_LOSS_RATE_FED: Dictionary[HEBusiness.Species, float] = {
	HEBusiness.Species.CATTLE: 0.015,
	HEBusiness.Species.SHEEP: 0.03,
}
const HERD_LOSS_RATE_NEGLECTED: Dictionary[HEBusiness.Species, float] = {
	HEBusiness.Species.CATTLE: 0.12,
	HEBusiness.Species.SHEEP: 0.20,
}

## Husbandry (the herd analogue of a field's labor_per_area_per_day). A herd
## of N head needs N * labor_per_head workers on the job every day for FULL
## care; the staffed share of that, averaged over the review interval, is
## what _run_herds turns into wool, mortality and reproduction. This is what
## gives a herd's labor a real marginal product -- without it a herd earned
## the same with 0 or 4 workers and the capacity tuner (which compares
## revenue per worker to the reference wage) had no stable staffing level to
## find. Also sets each ranch's max_capacity (ceil(cull target *
## labor_per_head)), the way a field business derives it from acreage.
## Sheep need more hands per head than cattle (lambing, dipping, shearing,
## predator watch) even though a sheep is far smaller.
const HERD_LABOR_PER_HEAD_PER_DAY: Dictionary[HEBusiness.Species, float] = {
	HEBusiness.Species.CATTLE: 1.0 / 150.0,
	HEBusiness.Species.SHEEP: 1.0 / 120.0,
}

## What staffing BUYS, as upsides over the authored free-range baseline (the
## HERD_GROWTH_RATE / HERD_LOSS_RATE_* / WOOL_PER_HEAD_PER_INTERVAL values
## above are what an UNSTAFFED herd does). That baseline matters: a ranch has
## no income until its first cull, so a herd that only grew when staffed
## could never afford the staff -- a poverty trap. Each effect scales with
## the staffed share (0..1) of the care the herd needs, from
## HERD_LABOR_PER_HEAD_PER_DAY.
## Calving/lambing assistance: reproduction x (1 + bonus * staffed share).
const HERD_STAFFED_REPRODUCTION_BONUS := 0.5
## Fewer deaths (predators, disease, injury): loss rate x (1 - cut * share).
const HERD_STAFFED_MORTALITY_CUT := 0.6
## Sheep only: a full, properly shorn clip vs. what an untended flock sheds
## and loses: wool x (1 + bonus * share).
const HERD_STAFFED_WOOL_BONUS := 1.0

## Once herd_size crosses this, the ranch culls straight back down to it
## every eval interval, moving the excess into its own inventory as
## herd_commodity() units. The target is derived from the ranch's land (see
## default_cull_target); the default ranches land on 150 cattle / 200 sheep,
## 1.5x / 2x their starting herd, so the time to first cull is unchanged
## (~900 days at HERD_GROWTH_RATE_MULTIPLIER). A player-set cull_target
## overrides it.
## (Per-species default cull targets come from a ranch's land: see
## default_cull_target.)
##
## Dynamic cull (HEBusiness.dynamic_cull, on by default): a ranch does not sit
## on a growing herd for years waiting to hit the target. Once the herd is past
## a breeding-stock floor (this share of its cull target) it also sells part of
## each review's net growth, ramping from none at the floor up to all of it as
## the herd nears the target. A young herd keeps what it needs to breed; a
## near-full one sells its whole increase and settles at the target. The target
## stays a hard cap either way. Turn it off for the old hold-then-cull behavior.
const HERD_BREEDING_STOCK_FLOOR := 0.4

## Sheep only: a renewable trickle straight into inventory from live
## herd_size every eval interval, independent of culling -- wool doesn't
## require slaughtering the animal the way a cull does. Cattle have no
## equivalent passive yield.
const WOOL_PER_HEAD_PER_INTERVAL := 0.75

## Monetization for culled herd stock (Commodity.Type.CATTLE/SHEEP -- the
## whole animal, standing in for meat and hides bundled together, same
## simplification the pooled model makes with its own CATTLE/SHEEP
## commodities). Unlike grain/timber/wool, no household buys a live animal
## at a per-person daily rate -- the pooled model treats cattle/sheep as
## pure "herd capital... not consumed at a daily rate by anything this model
## tracks" (see simulation.gd's REFERENCE_STOCK doc comment), so they never
## join SUBSISTENCE_COMMODITIES and never run through the local clearing
## market. Instead a ranch's culled stock sells through two business-to-
## business channels -- the Butcher's local purchase and the Trader's export,
## quoted separately by livestock_quote -- both derived from this flat
## reference price rather than a live locally-drifting one: there's no local
## supply/demand signal to drift one against.
##
## Cattle deliberately DIVERGES from Simulation.BASE_PRICE[CATTLE] (5.0) --
## historically cattle were a genuinely high-value good (often the primary
## store of wealth in a subsistence economy, arguably more so than grain),
## and at the old parity price the ranch's entire steady-state cull volume
## was worth pennies, nowhere near enough to fund even one wage-earning
## worker (before herd_max_capacity() and husbandry made staffing pay).
## Raised until a fully-staffed ranch's export income can actually clear
## the reference wage -- verified empirically, not just priced up
## arbitrarily. See _run_port_trade's herd export pass.
const HERD_EXPORT_PRICE: Dictionary[HEBusiness.Species, float] = {
	HEBusiness.Species.CATTLE: 60.0,
	HEBusiness.Species.SHEEP: 3.0,
}

## Culled cattle and sheep are saleable goods: they sit in a ranch's (or the
## Butcher's) business inventory, show on the Goods page, and are bought by the
## Butcher or the Trader. They are NOT in BASE_PRICE or SUBSISTENCE_COMMODITIES:
## they have no single local clearing price, households never request them, and
## they never run through the ordinary household clearing. The living herd
## (herd_size) is ranch state, not stock, and is not part of this list.
const LIVESTOCK_GOODS: Array[Commodity.Type] = [Commodity.Type.CATTLE, Commodity.Type.SHEEP]

## Everything that can sit in some business's or household's inventory: the
## priced market goods plus livestock. Used wherever stock is counted or written
## off, instead of each caller appending the livestock goods itself. Deliberately
## unfiltered, unlike get_market_summary()'s active-goods filter.
static func inventory_goods() -> Array[Commodity.Type]:
	var goods: Array[Commodity.Type] = BASE_PRICE.keys()
	goods.append_array(LIVESTOCK_GOODS)
	return goods

static func is_livestock(commodity: Commodity.Type) -> bool:
	return LIVESTOCK_GOODS.has(commodity)

## The species whose culled head `commodity` is. Only meaningful for a livestock
## good (see is_livestock).
static func livestock_species(commodity: Commodity.Type) -> HEBusiness.Species:
	return HEBusiness.Species.CATTLE if commodity == Commodity.Type.CATTLE else HEBusiness.Species.SHEEP

## The prices a head of livestock is quoted at, all off one posted price:
## POSTED is the good's price (HERD_EXPORT_PRICE), the analogue of another good's
## market price -- what its row shows, and what an export is worth to the closed
## system; TRADER_BID is what the Port pays a ranch, the same
## PORT_BUY_PRICE_FRACTION of the posted price it pays for every export; and
## BUTCHER_PURCHASE is what the Butcher pays a ranch locally. This is the one
## place that turns a species into a price.
enum LivestockQuote { POSTED, TRADER_BID, BUTCHER_PURCHASE }

static func livestock_quote(species: HEBusiness.Species, quote: LivestockQuote) -> float:
	var posted: float = HERD_EXPORT_PRICE[species]
	match quote:
		LivestockQuote.TRADER_BID:
			return posted * PORT_BUY_PRICE_FRACTION
		LivestockQuote.BUTCHER_PURCHASE:
			return posted * BUTCHERY_PURCHASE_PRICE_FRACTION
	return posted

## The Butcher (HEBusiness.processes_livestock) buys culled head from the
## settlement's ranches and turns each into MEAT and LEATHER. A local sale
## replaces the Trader's discounted raw export, so the ranch is paid
## BUTCHERY_PURCHASE_PRICE_FRACTION of HERD_EXPORT_PRICE: more than the
## Trader's PORT_BUY_PRICE_FRACTION, less than the full reference price,
## which leaves the Butcher the margin for the value it adds (meat that feeds
## households, leather that clothes them).
##
## Labor is the Butcher's constraint: each head costs worker-days, a cow far
## more than a sheep. A day's crew works through whatever livestock it holds,
## cattle first. Yields are authored placeholders, not yet tuned: a cow gives
## roughly ten times a sheep's meat, while a hide is a small amount of
## leather either way.
# TODO: 0.75 is arbitrary -- only "above the Trader's PORT_BUY_PRICE_FRACTION, below
# the full posted price" is justified, and the Butcher's margin is large enough
# (a cow is ~120 meat + 6 leather for ~45) that nothing pins this value. Revisit
# when the Butcher's economics get tuned: derive it from the value the Butcher
# adds and its labor, rather than splitting the difference.
const BUTCHERY_PURCHASE_PRICE_FRACTION := 0.75
const BUTCHERY_WORKER_DAYS_PER_HEAD: Dictionary[HEBusiness.Species, float] = {
	HEBusiness.Species.CATTLE: 3.0,
	HEBusiness.Species.SHEEP: 0.5,
}
const BUTCHERY_MEAT_PER_HEAD: Dictionary[HEBusiness.Species, float] = {
	HEBusiness.Species.CATTLE: 120.0,
	HEBusiness.Species.SHEEP: 12.0,
}
const BUTCHERY_LEATHER_PER_HEAD: Dictionary[HEBusiness.Species, float] = {
	HEBusiness.Species.CATTLE: 6.0,
	HEBusiness.Species.SHEEP: 1.0,
}
## Species the Butcher works through, in order. Cattle first: more meat per
## worker-day and a far higher price, so a crew short of time does the most
## valuable work.
const BUTCHERY_SPECIES_ORDER: Array[HEBusiness.Species] = [HEBusiness.Species.CATTLE, HEBusiness.Species.SHEEP]
## Days of work the Butcher stocks livestock for. A ranch's cull arrives in
## one lump every HERD_EVAL_INTERVAL_DAYS, far more than a crew handles in a
## day, so the Butcher holds live animals and works through them.
const BUTCHERY_INPUT_BUFFER_DAYS := 30.0
## How far into the red the Butcher may go to buy a cull. A cull is a lump
## bought up front and paid back as meat sells over the following weeks, the
## same way a wage bill may run negative (WAGE_NEGATIVE_BALANCE_FLOOR_DAYS).
## Inputs are bought on credit down to this balance, but the wage overdraft
## still applies on the next payroll, so a Butcher is expected to hold working
## capital for its first cull (HEScenarioSeeds seeds it) and the livestock it
## holds secures that overdraft (_butchery_collateral).
const BUTCHERY_CREDIT_LIMIT := 2000.0
## The Butcher buys livestock only as far as it expects to sell the meat: its
## finished meat plus the meat in the animals it holds may not exceed this many
## days of what it has been selling locally (never less than the floor below).
## Without it the Butcher worked through every cull whatever households would
## buy, sat on thousands of unsold meat while the price fell to its floor, and
## ran out of cash. The floor keeps it producing a little while no one is buying
## so demand (affluent households, a Trader bid) can show up and scale it.
## The Butcher's crew follows its work (see _livestock_crew_target): it is hired
## once a ranch holds culled livestock or its herd is within this share of its
## cull target (a cull is a review away), and released when there is none. Hired
## from day one it paid wages for a year or more before the first head arrived
## and failed before the work it was hired for.
const BUTCHERY_HIRE_NEAR_TARGET := 0.9
const BUTCHERY_FINISHED_COVER_DAYS := 45.0
const BUTCHERY_MIN_FINISHED_MEAT := 150.0

## Home butchery: a ranch's culled animals go to a staffed Butcher or Trader
## when one exists. Otherwise the ranch butchers them itself (see
## _butcher_stock_at_home) -- same poor yield and extra work as below, so it
## is never preferred over a real outlet -- so a ranch never holds a standing
## stock of livestock. Its meat is sold locally like a hardship slaughter's.
##
## Hardship butchering (see _hardship_butcher_if_needed): a herd has no
## guaranteed near-term payoff the way a field does -- its cull can be many
## HERD_EVAL_INTERVAL_DAYS cycles away from a fresh or just-culled herd, far
## longer than WAGE_NEGATIVE_BALANCE_FLOOR_DAYS' cushion covers. Rather than
## let it borrow indefinitely against a payoff that may never arrive in
## time, once that cushion runs out its crew slaughters some of its own live
## herd at home, with no Trader or Butcher involved. The meat stays in the
## ranch's inventory and sells on the local market to the town's households
## (the ranch's own workers among them), so cash arrives as it sells rather
## than at once. It is deliberately a worse deal than the Butcher: far less
## meat per head (HOME_BUTCHER_MEAT_PER_HEAD, about a twelfth of
## BUTCHERY_MEAT_PER_HEAD, with no leather saved), and the work takes
## HOME_BUTCHER_WORK_MULTIPLIER times the Butcher's worker-days per head,
## which comes out of the herd's husbandry (care_worker_days). So a ranch
## never prefers this over patiently waiting for a normal sale -- it's a last
## resort, not a revenue strategy. Never slaughters below this floor, so
## there's always enough left to regrow from. Cattle's floor scales with its
## bigger default cull target (still ~20% of target, same proportion as before)
## so a hardship slaughter can't gut just as large a fraction of the
## now-bigger herd.
const HOME_BUTCHER_MEAT_PER_HEAD: Dictionary[HEBusiness.Species, float] = {
	HEBusiness.Species.CATTLE: 10.0,
	HEBusiness.Species.SHEEP: 1.0,
}
const HOME_BUTCHER_WORK_MULTIPLIER := 2.0
const HARDSHIP_BUTCHER_MIN_HERD: Dictionary[HEBusiness.Species, float] = {
	HEBusiness.Species.CATTLE: 30.0,
	HEBusiness.Species.SHEEP: 20.0,
}

## _run_input_purchasing reuses TRADER_CAPACITY_PER_WORKER and
## PORT_BUY_PRICE_FRACTION for the Trader's IMPORT side too (buy outside
## at that same fraction of the local price, resell locally at full local
## price -- the same margin shape as export, just run in reverse), but
## tracks import capacity as its OWN pool for the day rather than sharing
## _run_trade's export pool. An authored simplification -- not a claim that
## hauling goods in and out wouldn't compete for the same wagons in
## reality -- kept separate because import has to happen early in the tick
## (before _run_production) while export happens late (after the local
## market), so there's no single point in the day where one shared number
## could be threaded through both.

## Weekly self-tuning: a business earning (rolling-average) more than
## WAGE_PROFIT_MARGIN above the going reference wage grows; one earning that
## much below shrinks. The margin is a dead-band so a business hovering near
## break-even doesn't thrash every week. Outside the dead-band, the MOVE
## size is proportional to how far off the wage is, not a flat step -- see
## _evaluate_business_capacity's doc comment for why a fixed-size step
## regardless of error magnitude was itself a driver of the boom-bust cycles
## seen in long (4000+ day) runs. CAPACITY_STEP_MAX_WORKERS is the ceiling on
## that proportional move (reached once the wage is WAGE_RATIO_CLAMP-or-more
## away from reference, so a single unusually noisy week can't cause an
## unbounded lurch).
const CAPACITY_EVAL_INTERVAL_DAYS := 7
## Trader revenue arrives in batches after supplier harvests; one decision
## per roughly farm-harvest interval avoids reacting to the same gap weekly.
const TRADER_CAPACITY_EVAL_INTERVAL_DAYS := 21
const CAPACITY_STEP_MAX_WORKERS := 4
## The cash-runway guard only forces a shrink on a crew bigger than this.
const CASH_RUNWAY_GUARD_MIN_CAPACITY := 4
const WAGE_PROFIT_MARGIN := 0.1
## How far avg_wage can be from reference_wage, as a fraction of
## reference_wage, before the proportional step maxes out at
## CAPACITY_STEP_MAX_WORKERS -- 1.0 means "wage at double reference (or at
## zero)" already gets the full move; anything further off doesn't move
## capacity any faster. Keeps one wildly noisy week (e.g. a business with
## only a handful of employed workers, where a single day's revenue swing
## can spike the wage 5-10x) from producing a bigger single-week swing than
## a business that's merely somewhat off.
const WAGE_RATIO_CLAMP := 1.0

## Wages are always paid in full at the going reference wage (see
## HEWages.pay_wages) -- there's no more "yesterday's revenue divided by headcount"
## ceiling, so a business's balance is allowed to run negative to cover a
## bad stretch rather than instantly rationing pay the moment cash runs out.
## The allowance is deliberately generous (measured in DAYS of the
## business's own current wage bill, so it scales with headcount) --
## sustained insolvency is meant to be caught and corrected by the weekly
## cash-runway guard in _evaluate_business_capacity (shrink the business),
## not by rationing take-home pay day to day.
const WAGE_NEGATIVE_BALANCE_FLOOR_DAYS := 60.0
## Share of its herd's value (at the Trader's bid) a ranch may borrow against to
## make payroll -- see HEWages.overdraft_limit. Half, so the lender's loss is
## covered even if a cull has to go to the Trader at its bid.
const HERD_COLLATERAL_FRACTION := 0.5

## Inputs may be bought on credit beyond cash, up to this many days of the
## business's own input cost (and never below the wage floor above). Matches
## the input buffer it tries to hold, see PRODUCTION_INPUT_BUFFER_DAYS.
const INPUT_CREDIT_DAYS := 14.0

## Weekly cash-runway guard (see _evaluate_business_capacity): a business
## whose balance plus its current stock's market value can't cover its own
## daily wage bill for this many more days gets forced to shrink, on top of
## (never instead of) whatever the revenue-vs-reference-wage signal already
## decided. For a field-model business the REQUIRED runway is instead
## "until its own next harvest" (see HEBusiness.days_until_next_harvest) --
## relief is a known, dated event, not a guess -- so this fallback only
## applies to Kind.TRADER and legacy non-field PRODUCTION businesses, which
## have no such harvest date to aim for.
const CASH_RUNWAY_DANGER_DAYS := 14.0

## "Sell down evenly until the next harvest" (see _clear_market_for) offers
## slightly MORE than a perfectly even pace every day, so a stock backlog
## (built up on a day demand happened to be thin) actually drains rather
## than being carried forward at the same fraction forever.
const SELL_PACE_HEADROOM := 1.15

const HISTORY_MAX_DAYS := 730
## Per-ranch history kept on HEBusiness.herd_events (see its doc comment).
const HERD_EVENT_HISTORY_MAX := 60
## Event retention is day-based so a burst of hiring/firing cannot evict
## quieter notification types from the same recent-time window. The
## dashboard queries a smaller slice through get_event_log_days().
const EVENT_LOG_RETENTION_DAYS := 730
## Employment changes are sparse for a stable business. Keep the latest
## events of EACH type regardless of age, so filtering to firings or hires
## still shows the last change after a long quiet period.
const EMPLOYMENT_EVENTS_PER_TYPE := 100

## Government: a flat sales tax on every DOMESTIC sale (household purchases
## and business-to-business input purchases, local or Trader-supplied),
## remitted by the seller to the settlement's Kind.GOVERNMENT business -- see
## _collect_sales_tax. Exports are deliberately untaxed for now (a future
## export duty), and a settlement with no government taxes nothing, so
## scenarios that don't seed one behave exactly as before. Authored
## placeholder: tuned (see run_household_economy.gd's government check) so a
## ~30-household town's tax comfortably covers its one administrator's wage
## with a modest surplus left over for the (stubbed) builder jobs.
const SALES_TAX_RATE := 0.05

var settlements: Dictionary[int, HESettlement] = {}
var households: Dictionary[int, HEHousehold] = {}

## Derived employment index: business ID -> ordered employee household IDs
## (households' iteration order, so wage accumulation order matches the old
## full scans). Membership only; worker totals are summed from current
## demographics at query time so aging/death/emigration can never leave them
## stale. Rebuilt lazily in one household pass after anything marks it dirty:
## an employer change (HEHousehold.employment_changed), or a household being
## added or removed. Rebuilds replace the dictionary rather than mutating it,
## so a reference taken earlier stays a valid snapshot.
var _employment_members: Dictionary = {}
var _employment_dirty := true
var _employment_rebuild_count := 0
var businesses: Dictionary[int, HEBusiness] = {}
## Houses, keyed by their own id space (not shared with `businesses`). Each
## household lives in one (HEHousehold.dwelling_id) -- see _reconcile_housing.
var dwellings: Dictionary[int, HEHouse] = {}

## Housing rules, applied only to settlements with HESettlement.housing_modeled.
## When every house is taken (households >= capacity) a household's monthly
## birth chance is scaled by this: births fall by 80% rather than stopping.
const HOUSING_SATURATED_BIRTH_SCALE := 0.2
## Households without an assigned house are homeless. Assignment is sticky and
## fills by ascending household id, so these are the newest households. Each
## homeless household has this chance per EMIGRATION_EVAL_INTERVAL_DAYS of
## losing a member to emigration, on top of any starvation emigration.
const HOMELESS_EMIGRATION_CHANCE := 0.3
var markets: Dictionary[int, HEMarket] = {}
var _trader_export_enabled: Dictionary[int, Dictionary] = {} # trader business_id -> commodity -> bool

var rng: RandomNumberGenerator
var day: int = 0

## Optional map positions, used only to order hiring (see _reconcile_employment).
## `(kind: String, id: int) -> Vector2` where kind is "business" or "dwelling"
## and the result is a position in one shared coordinate space, or Vector2.INF
## when unknown. Unset (the default, and every headless run) keeps hiring in
## plain household-id order. The sim has no geography of its own: the town
## layout supplies this.
var position_lookup: Callable = Callable()

## Lets a scenario prove accounting with fixed quotes first before
## exercising the bounded price-drift rule.
var price_adjustment_enabled: bool = true
## True only for economies coordinated by ValleyEconomy. Standalone trade
## goes through a Port, while these towns can also stock intertown Trader goods.
var intertown_trading_enabled: bool = false
## Inventory committed to an agreed onward sale while a shipment passes
## through this Trader. It remains real stock but is unavailable locally.
var _valley_reserved_stock: Dictionary = {}
var _valley_reserved_destination: Dictionary = {}
var _valley_reserved_unit_cost: Dictionary = {}
var _pending_valley_transactions: Array[Dictionary] = []

## Industrial tools (docs/tools-industrial-demand-plan.md): businesses that use
## tools (HEBusiness.uses_tools) wear them out, buy replacements from the
## town's tool seller (_run_tool_purchasing) and produce less without them --
## but only in a town where a business sells tools, so towns without a
## Toolsmith are unaffected.
##
## A business short of its target tool stock asks for at most this share of the
## shortfall a day (or three days of wear, whichever is more), so equipping a
## new crew from nothing takes a couple of weeks instead of draining the
## Toolsmith in a day and crowding households out.
const TOOL_FILL_FRACTION_PER_DAY := 0.1

## Sales tax fraction, a plain variable (not the const) so harnesses and a
## future player policy can change it per sim. 0.0 turns the tax off.
var sales_tax_rate: float = SALES_TAX_RATE

## Player tax policy range and its morale effect: every point below the
## default is worth +TAX_MORALE_PER_POINT morale (so 2% = +10%), every point
## above is worth the same penalty (15% = -33%).
const MAX_SALES_TAX_RATE := 0.15
const TAX_MORALE_PER_POINT := 10.0 / 3.0 / 100.0

func set_sales_tax_rate(rate: float) -> void:
	sales_tax_rate = clampf(rate, 0.0, MAX_SALES_TAX_RATE)

## Morale shift from the tax rate, applied to every person: positive below
## the default rate, negative above it.
func tax_morale_effect() -> float:
	return (SALES_TAX_RATE - sales_tax_rate) * 100.0 * TAX_MORALE_PER_POINT

## Named "emigrate" rather than "die" -- placeholder terminology until H1
## actually connects to the wider valley (see docs/river-valley-vertical-
## slice.md) and a household on the brink of starvation has somewhere real
## to go. The mechanic underneath is unchanged for now: this is a cosmetic
## rename, not a new migration model.
var _emigrations_total := 0
## Separate counter from _emigrations_total -- old age isn't a hardship
## signal (see he_household.gd's evaluate_old_age_death() doc comment), so
## it's worth being able to tell the two apart in city/dashboard reporting
## rather than lumping every population loss under one number.
var _old_age_deaths_total := 0
## Wage model, reference wage and payroll (he_wages.gd).
var wages := HEWages.new(self)
var _money_written_off_total := 0.0
## The same total split by cause ("emigration", "old_age", "business_failure"),
## so the money audit can say which sink is draining the town.
var _money_written_off_by_cause: Dictionary = {}
## Cash handed to a business at creation (startup_cash + tools): a source of
## new money alongside export revenue.
var _startup_injection_total := 0.0
var _goods_written_off_total: Dictionary[Commodity.Type, float] = {}
var _births_total := 0
var _worker_promotions_total := 0
## Next ID to assign a newly-split household -- initialized in _init() past
## whatever the world-seed builder already used, so a split can never
## collide with a seeded household's ID.
var _next_household_id := 1

## The one legitimate source of NEW money in this otherwise closed system
## (mirroring how starvation write-offs are the one legitimate sink): every
## unit the Trader exports is valued at that day's market price, split
## between what it pays the seller and its own margin -- see _run_trade.
## Tracked explicitly, like money_written_off_total, so the accounting
## stays honest about where money entered rather than silently not adding
## up.
var _export_revenue_total := 0.0

## The mirror-image sink to _export_revenue_total: whatever a Trader pays
## to import a commodity nothing local produces (iron ore) from outside the
## settlement, valued at import cost, leaves the closed system the same way
## a starvation write-off does -- see _run_input_purchasing. Tracked
## explicitly for the same "stays honest about where money went" reason.
var _import_cost_total := 0.0

## Days between a water source's servicings (HEBusiness.Kind.WATER). Each one
## costs the source's water_upkeep_timber and water_upkeep_stone from the Government Warehouse and
## needs government staff to do the work.
const WATER_SERVICE_INTERVAL_DAYS := 365
## The water need's "met by" rows, one per kind of source (HEBusiness.name).
const WATER_SOURCE_NAMES := ["Well", "River Intake"]
## Today's drinks supplied per source kind, by settlement id: {name: people}.
var _water_met_by: Dictionary = {}

## House upkeep (HEHouse.neglect_years): government staff deliver it in slices
## of HOUSE_VISIT_YEARS of a year's upkeep, at most HOUSE_VISITS_PER_STAFF
## houses a day per government worker household, visiting houses round robin.
## A house is only visited once a slice is owed, so a healthy town carries no
## morale penalty (HEHousehold.home_overdue_years counts only the excess).
const HOUSE_VISIT_YEARS := 0.25
const HOUSE_VISITS_PER_STAFF := 4

## Per settlement: the last dwelling id visited (the round-robin cursor) and
## the dwellings that received a delivery on the latest day (read by the town
## view, which walks government workers to them).
var _house_cursor: Dictionary = {}
var _house_deliveries: Dictionary = {}

## Treasury money spent on constructing government buildings
## (build_government_building) -- it leaves circulation like _import_cost_total
## does, and is tracked for the same reason. Goods the warehouse BUYS are not
## here: that is an ordinary purchase from a local seller or the Trader.
var _construction_spend_total := 0.0

## Days a government build stands as a foundation before the building opens
## (see build_government_building). The cost is paid when it is ordered.
const CONSTRUCTION_DAYS := 2
## 0 opens government builds instantly (the harness's cost checks use this).
var construction_days: int = CONSTRUCTION_DAYS
## Government builds paid for but not yet standing, oldest first:
## {settlement_id, record (HEBusiness or HEHouse, its id reserved), startup,
## upgrade_dwelling_id (-1 unless a tenement upgrades that house), complete_day}.
## TODO(construction): no labor yet -- a build just waits out the days.
var _constructions: Array[Dictionary] = []

## Most units of one good a warehouse order buys or sells in a day, so a single
## order cannot drain a town's stock (or flood the Trader) in one tick.
const WAREHOUSE_DAILY_TRADE_CAP := 10.0

## Treasury days of wages a warehouse purchase leaves untouched, so stocking
## the warehouse never starves the administrator and its own crew.
const WAREHOUSE_WAGE_RESERVE_DAYS := 3.0

## Today's business-to-business purchases from local sellers, rebuilt every
## tick by _run_input_purchasing: settlement_id -> commodity -> {offer: the
## seller's paced offer BEFORE any B2B buy, sold: units bought from it,
## requested: cash-funded units asked for}. _clear_market_for reads it so
## households clear against what's left of the same offer.
var _b2b_today: Dictionary = {}

## Cash-funded household demand during pre-market business purchasing only:
## settlement_id -> Commodity.Type -> float. Household balances, inventories,
## and prices stay fixed in this window; alternative availability is invalidated
## when a purchase changes membership in a need's household cascade.
var _funded_demand_cache_active := false
var _funded_demand_cache: Dictionary = {}

## Trailing per-settlement, per-commodity price history, oldest first, capped to the SAME
## window a business's own wage is smoothed over
## (HEBusiness.WAGE_ROLLING_WINDOW_DAYS, referenced directly rather than
## re-authored here so the two windows can never drift apart) -- see
## HEWages.reference_wage_per_worker for why the reference wage reads this average
## instead of the live spot price.
var _price_history: Dictionary[int, Dictionary] = {} # settlement_id -> {Commodity.Type -> Array[float]}

var _history: Array[Dictionary] = []
## Blotter: one entry per birth/death/split, newest appended last -- see
## get_event_log() and _log_event().
var _event_log: Array[Dictionary] = []
var _employment_event_log: Dictionary[int, Array] = {} # business_id -> events, oldest first

func _init(seed: int, builder: Callable, p_price_adjustment_enabled: bool = true) -> void:
	rng = RandomNumberGenerator.new()
	rng.seed = seed
	price_adjustment_enabled = p_price_adjustment_enabled
	var world: Dictionary = builder.call(rng)
	if world.has("settlements"):
		settlements.assign(world["settlements"])
	else:
		var legacy_settlement: HESettlement = world["settlement"]
		settlements[legacy_settlement.id] = legacy_settlement
	households = world["households"]
	_invalidate_employment()
	businesses = world["businesses"]
	if world.has("dwellings"):
		dwellings = world["dwellings"]
	for business_id in businesses.keys():
		if (businesses[business_id] as HEBusiness).kind != HEBusiness.Kind.TRADER:
			continue
		_trader_export_enabled[business_id] = _default_export_enabled()
	for settlement_id in settlements.keys():
		markets[settlement_id] = HEMarket.new(BASE_PRICE.duplicate())
	# Normalize business locality first so the household pass can reject any
	# pre-seeded cross-settlement employer reference, including legacy records
	# whose constructor left settlement_id at zero.
	for settlement_id in settlements.keys():
		var business_settlement: HESettlement = settlements[settlement_id]
		for business_id in business_settlement.business_ids:
			(businesses[business_id] as HEBusiness).settlement_id = settlement_id
	for settlement_id in settlements.keys():
		var household_settlement: HESettlement = settlements[settlement_id]
		for household_id in household_settlement.household_ids:
			var h: HEHousehold = households[household_id]
			h.settlement_id = settlement_id
			h.demographics.settlement_id = settlement_id
			if h.employer_business_id != -1:
				var employer: HEBusiness = businesses[h.employer_business_id]
				if employer.settlement_id != settlement_id:
					h.employer_business_id = -1
	for settlement_id in settlements.keys():
		var housing_settlement: HESettlement = settlements[settlement_id]
		for dwelling_id in housing_settlement.dwelling_ids:
			(dwellings[dwelling_id] as HEHouse).settlement_id = settlement_id
	_next_household_id = 1
	for household_id in households.keys():
		_next_household_id = maxi(_next_household_id, household_id + 1)
	_reconcile_all_housing()

## Registers a business built after the sim started. Takes a free id from
## next_business_id(); the caller builds the record. Nothing is charged -- the
## business starts with whatever balance/stock the record already carries.
func add_business(b: HEBusiness) -> void:
	assert(not businesses.has(b.id), "Business id %d already exists" % b.id)
	assert(settlements.has(b.settlement_id), "Unknown settlement %d" % b.settlement_id)
	businesses[b.id] = b
	(settlements[b.settlement_id] as HESettlement).business_ids.append(b.id)
	if b.kind == HEBusiness.Kind.TRADER:
		_trader_export_enabled[b.id] = _default_export_enabled()
	if b.kind == HEBusiness.Kind.WATER and b.next_service_day < 0:
		b.next_service_day = day + WATER_SERVICE_INTERVAL_DAYS

## Adds a business the player created mid-run, with a startup allowance so it
## can actually get going (see HEScenarioSeeds.startup_cash): a starting crew,
## seed cash, and a grace period until its first harvest (or
## CASH_RUNWAY_DANGER_DAYS if it has no cycle) before the tuner judges it.
## TODO creation cost: the seed cash is free money injected into the economy
## (it shows up in next day's opening money), and should be paid for by the
## player or the treasury.
func add_new_business(b: HEBusiness) -> void:
	var crew := clampi(HEScenarioSeeds.NEW_BUSINESS_STARTING_CAPACITY, _capacity_floor(b), b.max_capacity)
	b.capacity = crew
	var startup_allowance: float = HEScenarioSeeds.startup_cash(b, crew)
	# A crew of tool users also needs its first tools, bought from the town's
	# tool seller -- but only in a town that has one.
	if b.uses_tools() and _tools_in_play(b.settlement_id):
		startup_allowance += float(crew) * b.tools_per_worker * (markets[b.settlement_id] as HEMarket).price[Commodity.Type.TOOLS]
	b.balance += startup_allowance
	_startup_injection_total += startup_allowance
	b.ledger_add("injection", startup_allowance)
	var startup_cycle := maxi(b.growth_days, b.startup_cycle_days)
	b.startup_grace_until_day = day + (startup_cycle if startup_cycle > 0 else int(CASH_RUNWAY_DANGER_DAYS))
	add_business(b)

## Registers a house built after the sim started. The caller builds the record
## with a free id from next_dwelling_id(); nothing is charged here.
func add_dwelling(house: HEHouse) -> void:
	assert(not dwellings.has(house.id), "Dwelling id %d already exists" % house.id)
	assert(settlements.has(house.settlement_id), "Unknown settlement %d" % house.settlement_id)
	dwellings[house.id] = house
	var s: HESettlement = settlements[house.settlement_id]
	s.dwelling_ids.append(house.id)
	s.housing_modeled = true
	_reconcile_housing(house.settlement_id)

func next_dwelling_id() -> int:
	var next_id := 1
	for dwelling_id in dwellings.keys():
		next_id = maxi(next_id, dwelling_id + 1)
	for entry in _constructions:
		if entry["record"] is HEHouse:
			next_id = maxi(next_id, (entry["record"] as HEHouse).id + 1)
	return next_id

## One entry per house, ascending id: {dwelling_id, settlement_id, name,
## type_key, capacity, occupant_household_ids (ascending)}. Houses live in
## `dwellings`, a separate id space from businesses, so they never appear in
## get_business_reports(); a town layout reads this.
func get_dwelling_reports(settlement_id: int = -1) -> Array:
	var occupants := _occupants_by_dwelling()
	var out: Array = []
	var ids := dwellings.keys()
	ids.sort()
	for dwelling_id in ids:
		var house: HEHouse = dwellings[dwelling_id]
		if settlement_id != -1 and house.settlement_id != settlement_id:
			continue
		out.append({
			"dwelling_id": house.id,
			"settlement_id": house.settlement_id,
			"name": house.name,
			"type_key": house.type_key,
			"capacity": house.capacity_households,
			"stone": house.is_stone,
			"neglect_years": maxf(house.neglect_years, 0.0),
			"occupant_household_ids": occupants.get(house.id, [] as Array[int]),
		})
	return out

## One entry per household of the settlement, ascending id -- the cheap roster
## a town renderer reads every tick (get_household_summary is far heavier):
## {household_id, dwelling_id, employer_business_id, housing_status,
## worker_ages, dependent_ages, worker_sexes, dependent_sexes}. Ages are in
## days and sexes are HEHousehold.SEX_*, one entry per member.
func get_villager_reports(settlement_id: int) -> Array:
	var out: Array = []
	for household_id in get_household_ids(settlement_id):
		var h: HEHousehold = households[household_id]
		out.append({
			"household_id": h.id,
			"dwelling_id": h.dwelling_id,
			"employer_business_id": h.employer_business_id,
			"housing_status": _housing_status_of(h),
			"worker_ages": PackedInt32Array(h.worker_ages()),
			"dependent_ages": PackedInt32Array(h.dependent_ages()),
			"worker_sexes": PackedInt32Array(h.worker_sexes()),
			"dependent_sexes": PackedInt32Array(h.dependent_sexes()),
		})
	return out

## dwelling_id -> ascending ids of the households living there.
func _occupants_by_dwelling() -> Dictionary:
	var occupants: Dictionary = {}
	var ids := households.keys()
	ids.sort()
	for household_id in ids:
		var dwelling_id: int = (households[household_id] as HEHousehold).dwelling_id
		if dwelling_id == -1:
			continue
		if not occupants.has(dwelling_id):
			occupants[dwelling_id] = [] as Array[int]
		(occupants[dwelling_id] as Array[int]).append(household_id)
	return occupants

func _reconcile_all_housing() -> void:
	for settlement_id in settlements.keys():
		_reconcile_housing(settlement_id)

## Brings house assignments in `settlement_id` in line with its households and
## houses. The only writer of HEHousehold.dwelling_id. Rules:
## - Sticky: a housed household keeps its house until it ceases to exist.
## - A house holds capacity_households households (1, or 4 for a tenement); an
##   upgrade in place adds free slots to the same house.
## - Unhoused households, ascending id, each take a slot in the lowest-id house
##   with room (ids follow placement order, so the innermost first).
## - A household whose house is gone, belongs to another settlement, or is over
##   capacity (highest ids leave first) is unhoused before refilling.
## - A settlement that does not model housing houses nobody.
## New households always get higher ids than existing ones, so the homeless
## are always the newest households -- the rule housing used before houses were
## assigned -- and homeless counts are unchanged by assignment.
func _reconcile_housing(settlement_id: int) -> void:
	_assign_dwellings(settlement_id)
	var residents: Dictionary = {} # dwelling_id -> households living there
	for household_id in (settlements[settlement_id] as HESettlement).household_ids:
		var lodger: HEHousehold = households[household_id]
		if lodger.dwelling_id != -1:
			residents[lodger.dwelling_id] = int(residents.get(lodger.dwelling_id, 0)) + 1
	for household_id in (settlements[settlement_id] as HESettlement).household_ids:
		var h: HEHousehold = households[household_id]
		h.home_morale_bonus = (dwellings[h.dwelling_id] as HEHouse).morale_bonus() if dwellings.has(h.dwelling_id) else 0.0
		var home: HEHouse = dwellings.get(h.dwelling_id)
		var sharers: int = maxi(int(residents.get(h.dwelling_id, 1)), 1)
		h.home_upkeep_timber = home.upkeep_timber() / float(sharers) if home != null else 0.0
		h.home_upkeep_stone = home.upkeep_stone() / float(sharers) if home != null else 0.0
		h.home_heat_factor = (dwellings[h.dwelling_id] as HEHouse).heat_factor() if dwellings.has(h.dwelling_id) else 1.0

func _assign_dwellings(settlement_id: int) -> void:
	var s: HESettlement = settlements[settlement_id]
	var ids: Array[int] = []
	ids.assign(s.household_ids)
	ids.sort()
	if not s.housing_modeled:
		for household_id in ids:
			(households[household_id] as HEHousehold).dwelling_id = -1
		return
	var free: Dictionary = {} # dwelling_id -> slots left
	for dwelling_id in s.dwelling_ids:
		free[dwelling_id] = (dwellings[dwelling_id] as HEHouse).capacity_households
	var unhoused: Array[int] = []
	for household_id in ids:
		var h: HEHousehold = households[household_id]
		if h.dwelling_id != -1 and int(free.get(h.dwelling_id, 0)) > 0:
			free[h.dwelling_id] = int(free[h.dwelling_id]) - 1
		else:
			h.dwelling_id = -1
			unhoused.append(household_id)
	if unhoused.is_empty():
		return
	var houses: Array[int] = []
	houses.assign(s.dwelling_ids)
	houses.sort()
	var cursor := 0
	for household_id in unhoused:
		while cursor < houses.size() and int(free[houses[cursor]]) <= 0:
			cursor += 1
		if cursor == houses.size():
			break
		(households[household_id] as HEHousehold).dwelling_id = houses[cursor]
		free[houses[cursor]] = int(free[houses[cursor]]) - 1

## Housing state of one settlement. `modeled` is false for a world that never
## set housing up (then nothing below limits it). `capacity` counts
## households, `homeless_households` the ones past it, and `saturated` is true
## when no house is free -- the condition that cuts births.
func get_housing_report(settlement_id: int) -> Dictionary:
	var s: HESettlement = settlements[settlement_id]
	var capacity := 0
	for dwelling_id in s.dwelling_ids:
		capacity += (dwellings[dwelling_id] as HEHouse).capacity_households
	var household_count := s.household_ids.size()
	return {
		"modeled": s.housing_modeled,
		"houses": s.dwelling_ids.size(),
		"upgradable_houses": _count_plain_houses(s),
		"capacity": capacity,
		"households": household_count,
		"homeless_households": maxi(0, household_count - capacity) if s.housing_modeled else 0,
		"saturated": s.housing_modeled and household_count >= capacity,
		"maintenance_deliveries": get_house_deliveries(settlement_id).duplicate(),
	}

## The lowest-id plain house of the settlement, or null. Ids are handed out in
## placement order (nearest the civic anchor first), so this is the innermost.
func _innermost_plain_house(settlement_id: int) -> HEHouse:
	var best: HEHouse = null
	for dwelling_id in (settlements[settlement_id] as HESettlement).dwelling_ids:
		var house: HEHouse = dwellings[dwelling_id]
		if house.is_plain() and not _upgrade_pending(house.id) and (best == null or house.id < best.id):
			best = house
	return best

## Whether a tenement under construction already targets house `dwelling_id`.
func _upgrade_pending(dwelling_id: int) -> bool:
	for entry in _constructions:
		if entry["upgrade_dwelling_id"] == dwelling_id:
			return true
	return false

func _count_plain_houses(s: HESettlement) -> int:
	var count := 0
	for dwelling_id in s.dwelling_ids:
		if (dwellings[dwelling_id] as HEHouse).is_plain():
			count += 1
	return count

## Ids (ascending) of the settlement's households with no house, after
## bringing assignments up to date.
func _homeless_household_ids(settlement_id: int) -> Array[int]:
	var homeless: Array[int] = []
	_reconcile_housing(settlement_id)
	if not (settlements[settlement_id] as HESettlement).housing_modeled:
		return homeless
	for household_id in get_household_ids(settlement_id):
		if (households[household_id] as HEHousehold).dwelling_id == -1:
			homeless.append(household_id)
	return homeless

## "housed", "homeless", or "unlimited" (housing not modeled). Reads the
## assignment, checking the house still stands in this settlement in case a
## caller changed `dwellings` since the last reconcile.
func _housing_status_of(h: HEHousehold) -> String:
	var s: HESettlement = settlements[h.settlement_id]
	if not s.housing_modeled:
		return "unlimited"
	if h.dwelling_id != -1 and s.dwelling_ids.has(h.dwelling_id) and dwellings.has(h.dwelling_id):
		return "housed"
	return "homeless"

## The settlement's Government Warehouse, or null if it has not built one.
func _government_warehouse(settlement_id: int) -> HEBusiness:
	for business_id in businesses.keys():
		var b: HEBusiness = businesses[business_id]
		if b.kind == HEBusiness.Kind.WAREHOUSE and b.settlement_id == settlement_id:
			return b
	return null

## What the settlement's Government Warehouse holds, as
## [{"commodity", "name", "units"}] with units > 0, most units first. Empty
## when no warehouse is built (or it holds nothing).
func get_warehouse_inventory(settlement_id: int) -> Array:
	var rows: Array = []
	var warehouse := _government_warehouse(settlement_id)
	if warehouse == null:
		return rows
	for commodity in warehouse.inventory:
		var units: float = warehouse.inventory[commodity]
		if units > 0.0001:
			rows.append({"commodity": commodity, "name": Commodity.name_of(commodity), "units": units})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["units"] > b["units"])
	return rows

## What `option` costs in `settlement_id` right now: its `upgrade_cost` while
## it would upgrade an existing house in place (a tenement with a plain house
## left), otherwise its `cost`. Every build-cost reader goes through this.
func build_cost_for(settlement_id: int, option: Dictionary) -> Dictionary:
	if option.has("upgrade_cost") and settlements.has(settlement_id) \
			and _innermost_plain_house(settlement_id) != null:
		return option["upgrade_cost"]
	return option["cost"]

## Why `option` (an entry of HEScenarioSeeds.government_buildings()) cannot be
## built in `settlement_id` right now -- "" when it can. Checks, in order: a
## government exists, the type is not already built, the treasury covers the
## gold cost, and the Government Warehouse holds the goods cost.
func government_build_blocker(settlement_id: int, option: Dictionary) -> String:
	var gov := _settlement_government(settlement_id) if settlements.has(settlement_id) else null
	if gov == null:
		return "no government"
	var repeatable: bool = option.get("repeatable", false)
	if not repeatable and has_business_of_type(settlement_id, option["type_key"]):
		return "already built"
	if not repeatable and _construction_pending(settlement_id, option["type_key"]):
		return "under construction"
	if option.get("upgrade_only", false) and _innermost_plain_house(settlement_id) == null:
		return "no plain house to upgrade"
	var cost: Dictionary = build_cost_for(settlement_id, option)
	if gov.balance < float(cost.get("gold", 0.0)):
		return "treasury too low (%.0f g)" % gov.balance
	var goods: Dictionary = cost.get("goods", {})
	if not goods.is_empty():
		var warehouse := _government_warehouse(settlement_id)
		if warehouse == null:
			return "needs a government warehouse"
		for commodity in goods:
			var held := warehouse.stock(commodity) if warehouse != null else 0.0
			if held < float(goods[commodity]):
				return "needs %.0f %s in the warehouse (has %.0f)" % [goods[commodity], Commodity.name_of(commodity), held]
	return ""

## Builds a government building (HEScenarioSeeds.government_buildings()) out of
## the settlement's treasury and warehouse. The gold cost is spent (it leaves
## the treasury and is booked in _construction_spend_total -- a government
## building has no cash of its own, it runs on the treasury); the goods cost is
## consumed from the Government Warehouse. A `startup` option is a player
## business kind and goes through add_new_business (crew + seed cash) rather
## than add_business. Returns false -- building nothing -- for an unknown type
## or when government_build_blocker() says no.
## TODO(multiple-buildings): every government building is unique per town
## today (has_business_of_type) -- no second warehouse, and the UI/orders
## assume exactly one. If that is ever relaxed, order panels, the treasury
## wage reserve and _ensure_warehouse_staff all need to handle several, and
## the build cost should probably scale with how many already exist.
func build_government_building(settlement_id: int, type_key: String) -> bool:
	var gov := _settlement_government(settlement_id) if settlements.has(settlement_id) else null
	if gov == null:
		return false
	for option in HEScenarioSeeds.government_buildings():
		if option["type_key"] != type_key:
			continue
		if government_build_blocker(settlement_id, option) != "":
			return false
		var cost: Dictionary = build_cost_for(settlement_id, option)
		var gold: float = cost.get("gold", 0.0)
		var goods: Dictionary = cost.get("goods", {})
		if not goods.is_empty():
			var warehouse := _government_warehouse(settlement_id)
			for commodity in goods:
				warehouse.consume(commodity, goods[commodity])
		gov.balance -= gold
		gov.last_cash_change -= gold
		_construction_spend_total += gold
		var entry := {"settlement_id": settlement_id, "startup": option.get("startup", false),
			"upgrade_dwelling_id": -1, "complete_day": day + construction_days}
		if option.get("category", "") == "housing":
			var house: HEHouse = option["make"].call(next_dwelling_id(), settlement_id)
			var upgradable := _innermost_plain_house(settlement_id) if (house.is_dense() or house.is_stone) and not option.get("new_only", false) else null
			if upgradable != null:
				entry["upgrade_dwelling_id"] = upgradable.id
			entry["record"] = house
		else:
			entry["record"] = option["make"].call(next_business_id(), settlement_id)
		_constructions.append(entry)
		_finish_due_constructions()
		return true
	return false

## Whether a non-repeatable `type_key` is already paid for and being built.
func _construction_pending(settlement_id: int, type_key: String) -> bool:
	for entry in _constructions:
		if entry["settlement_id"] == settlement_id and entry["record"].type_key == type_key:
			return true
	return false

## Services every water source whose yearly servicing is due: the government's
## own staff (administrator or warehouse crew) do the work, with timber from the
## Government Warehouse. If either is missing the source falls into disrepair
## (it supplies nobody) and is retried every day until it can be paid for.
## Nothing here touches wages, markets or the treasury, so a town with no water
## source behaves exactly as before.
func _run_water_maintenance(record: Dictionary) -> void:
	var ids := businesses.keys()
	ids.sort()
	for business_id in ids:
		var b: HEBusiness = businesses[business_id]
		if b.kind != HEBusiness.Kind.WATER or day < b.next_service_day:
			continue
		var warehouse := _government_warehouse(b.settlement_id)
		if warehouse != null and _government_staff_count(b.settlement_id) > 0 and warehouse.stock(Commodity.Type.TIMBER) >= b.water_upkeep_timber and warehouse.stock(Commodity.Type.STONE) >= b.water_upkeep_stone:
			warehouse.consume(Commodity.Type.TIMBER, b.water_upkeep_timber)
			warehouse.consume(Commodity.Type.STONE, b.water_upkeep_stone)
			_accumulate(record["consumed"], Commodity.name_of(Commodity.Type.TIMBER), b.water_upkeep_timber)
			_accumulate(record["consumed"], Commodity.name_of(Commodity.Type.STONE), b.water_upkeep_stone)
			b.in_disrepair = false
			b.next_service_day = day + WATER_SERVICE_INTERVAL_DAYS
		else:
			b.in_disrepair = true

## Accrues a day of upkeep on every lived-in house, then sends government staff
## round to the houses that are owed a slice, round robin from just after the
## last one visited. The staff do the work; the goods come from the households
## living there, who buy them on the market (_desired_purchase) and hand over
## their share. A house whose households do not all hold their share is skipped,
## so its backlog (and their "Home in disrepair" morale penalty) keeps growing;
## an empty house owes nothing until someone moves in. Without government staff
## nobody visits.
func _run_house_maintenance(record: Dictionary) -> void:
	var residents: Dictionary = {} # dwelling_id -> Array[HEHousehold]
	for household in households.values():
		var lodger: HEHousehold = household
		if lodger.dwelling_id != -1:
			(residents.get_or_add(lodger.dwelling_id, []) as Array).append(lodger)
	var settlement_ids := settlements.keys()
	settlement_ids.sort()
	var goods_used: Dictionary = {} # settlement id -> {commodity: units}
	for settlement_id in settlement_ids:
		var ids: Array = []
		for dwelling_id in (settlements[settlement_id] as HESettlement).dwelling_ids:
			if dwellings.has(dwelling_id):
				ids.append(dwelling_id)
		ids.sort()
		var deliveries: Array[int] = []
		_house_deliveries[settlement_id] = deliveries
		if ids.is_empty():
			continue
		for dwelling_id in ids:
			var house: HEHouse = dwellings[dwelling_id]
			if house.neglect_years < 0.0:
				# Stagger the first visits so they do not all fall on one day.
				house.neglect_years = fposmod(dwelling_id * 0.37, 1.0) * HOUSE_VISIT_YEARS
			if residents.has(dwelling_id):
				house.neglect_years += 1.0 / 365.0
		var budget := _government_staff_count(settlement_id) * HOUSE_VISITS_PER_STAFF
		if budget > 0:
			var start := ids.bsearch(_house_cursor.get(settlement_id, -1), false)
			for step in ids.size():
				if budget <= 0:
					break
				var dwelling_id: int = ids[(start + step) % ids.size()]
				var house: HEHouse = dwellings[dwelling_id]
				if house.neglect_years < HOUSE_VISIT_YEARS or not residents.has(dwelling_id):
					continue
				var lodgers: Array = residents[dwelling_id]
				var supplied := true
				for lodger in lodgers:
					for good in [Commodity.Type.TIMBER, Commodity.Type.STONE]:
						if (lodger as HEHousehold).stock(good) < (lodger as HEHousehold).upkeep_slice(good) - 0.0001:
							supplied = false
				if not supplied:
					continue
				for lodger in lodgers:
					for good in [Commodity.Type.TIMBER, Commodity.Type.STONE]:
						var slice: float = (lodger as HEHousehold).upkeep_slice(good)
						if slice > 0.0:
							var used: float = (lodger as HEHousehold).consume(good, slice)
							_accumulate(record["consumed"], Commodity.name_of(good), used)
							_accumulate(goods_used.get_or_add(settlement_id, {}), good, used)
				house.neglect_years -= HOUSE_VISIT_YEARS
				deliveries.append(dwelling_id)
				_house_cursor[settlement_id] = dwelling_id
				budget -= 1
	for household in households.values():
		var h: HEHousehold = household
		var home: HEHouse = dwellings.get(h.dwelling_id)
		h.home_overdue_years = maxf(home.neglect_years - HOUSE_VISIT_YEARS, 0.0) if home != null else 0.0
	for settlement_id in settlement_ids:
		var settlement: HESettlement = settlements[settlement_id]
		var used: Dictionary = goods_used.get(settlement_id, {})
		var entry := {
			"visits": (_house_deliveries.get(settlement_id, []) as Array).size(),
			"timber_used": float(used.get(Commodity.Type.TIMBER, 0.0)),
			"stone_used": float(used.get(Commodity.Type.STONE, 0.0)),
			"overdue_houses": 0, "backlog_years": 0.0, "households_overdue": 0, "stone_bonus_lost": 0,
		}
		for dwelling_id in settlement.dwelling_ids:
			var house: HEHouse = dwellings.get(dwelling_id)
			if house == null:
				continue
			entry["backlog_years"] += maxf(house.neglect_years, 0.0)
			if house.neglect_years > HOUSE_VISIT_YEARS:
				entry["overdue_houses"] += 1
		for household_id in settlement.household_ids:
			var lodger: HEHousehold = households[household_id]
			if lodger.home_overdue_years > 0.0:
				entry["households_overdue"] += 1
				if lodger.home_morale_bonus > 0.0:
					entry["stone_bonus_lost"] += 1
		record["maintenance"][settlement_id] = entry

## The dwelling ids that received a maintenance delivery on the latest day.
func get_house_deliveries(settlement_id: int) -> Array:
	return _house_deliveries.get(settlement_id, [])

## House upkeep at a glance: {houses, owed_years (total), overdue (houses past
## one visit interval), worst_years, upkeep_timber, upkeep_stone (a year's bill
## for every house), delivered_today}.
func get_house_maintenance_summary(settlement_id: int) -> Dictionary:
	var houses := 0
	var owed := 0.0
	var overdue := 0
	var worst := 0.0
	var timber := 0.0
	var stone := 0.0
	if settlements.has(settlement_id):
		for dwelling_id in (settlements[settlement_id] as HESettlement).dwelling_ids:
			var house: HEHouse = dwellings.get(dwelling_id)
			if house == null:
				continue
			houses += 1
			owed += maxf(house.neglect_years, 0.0)
			worst = maxf(worst, house.neglect_years)
			timber += house.upkeep_timber()
			stone += house.upkeep_stone()
			if house.neglect_years > HOUSE_VISIT_YEARS:
				overdue += 1
	return {"houses": houses, "owed_years": owed, "overdue": overdue, "worst_years": worst,
		"upkeep_timber": timber, "upkeep_stone": stone,
		"delivered_today": get_house_deliveries(settlement_id).size()}

## Households working for the settlement's Government or its Warehouse.
func _government_staff_count(settlement_id: int) -> int:
	var count := 0
	for business_id in (settlements[settlement_id] as HESettlement).business_ids:
		var b: HEBusiness = businesses.get(business_id)
		if b != null and (b.kind == HEBusiness.Kind.GOVERNMENT or b.kind == HEBusiness.Kind.WAREHOUSE):
			count += _business_employed_household_count(business_id)
	return count

## The town's drinking water at a glance: {sources, serving, in_disrepair,
## capacity (people the working sources supply), population, coverage (0..1,
## 1 when nobody lives there), upkeep_timber (a year's servicing for all),
## next_service_days (soonest, -1 with no sources)}. The coverage is what
## _run_water_need feeds into every household's thirst.
func get_water_summary(settlement_id: int) -> Dictionary:
	var sources := 0
	var serving := 0
	var capacity := 0
	var upkeep := 0.0
	var upkeep_stone := 0.0
	var soonest := -1
	if settlements.has(settlement_id):
		for business_id in (settlements[settlement_id] as HESettlement).business_ids:
			var b: HEBusiness = businesses.get(business_id)
			if b == null or b.kind != HEBusiness.Kind.WATER:
				continue
			sources += 1
			upkeep += b.water_upkeep_timber
			upkeep_stone += b.water_upkeep_stone
			if not b.in_disrepair:
				serving += 1
				capacity += b.water_capacity
			var due := maxi(0, b.next_service_day - day)
			soonest = due if soonest == -1 else mini(soonest, due)
	var population := _total_population(settlement_id)
	return {
		"sources": sources,
		"serving": serving,
		"in_disrepair": sources - serving,
		"capacity": capacity,
		"population": population,
		"coverage": 1.0 if population <= 0 else minf(1.0, float(capacity) / float(population)),
		"upkeep_timber": upkeep,
		"upkeep_stone": upkeep_stone,
		"next_service_days": soonest,
	}

## Opens every construction whose days are up: the building joins the town
## exactly as an instant build used to.
func _finish_due_constructions() -> void:
	var waiting: Array[Dictionary] = []
	for entry in _constructions:
		if day < int(entry["complete_day"]):
			waiting.append(entry)
			continue
		var record = entry["record"]
		if record is HEHouse:
			var target: int = entry["upgrade_dwelling_id"]
			if target != -1 and dwellings.has(target) and (dwellings[target] as HEHouse).is_plain():
				if (record as HEHouse).is_stone:
					(dwellings[target] as HEHouse).upgrade_to_stone()
				else:
					(dwellings[target] as HEHouse).upgrade_to_dense()
				_reconcile_housing(int(entry["settlement_id"]))
			else:
				add_dwelling(record)
		elif entry["startup"]:
			add_new_business(record)
		else:
			add_business(record)
	_constructions = waiting

## One entry per government build still standing as a foundation, oldest
## first: {settlement_id, type_key, name, business_id, dwelling_id (each -1
## unless the build is that kind; the id is the one the finished building
## keeps), upgrade_dwelling_id, complete_day, days_left}.
func get_construction_reports(settlement_id: int = -1) -> Array:
	var out: Array = []
	for entry in _constructions:
		if settlement_id != -1 and entry["settlement_id"] != settlement_id:
			continue
		var record = entry["record"]
		var is_house: bool = record is HEHouse
		out.append({
			"settlement_id": entry["settlement_id"],
			"type_key": record.type_key,
			"name": record.name,
			"business_id": -1 if is_house else record.id,
			"dwelling_id": record.id if is_house and entry["upgrade_dwelling_id"] == -1 else -1,
			"upgrade_dwelling_id": entry["upgrade_dwelling_id"],
			"complete_day": entry["complete_day"],
			"days_left": maxi(0, int(entry["complete_day"]) - day),
		})
	return out

## What the warehouse still lacks for `option`'s goods cost: commodity ->
## missing units, empty when the cost has no goods or the warehouse covers it
## (or there is no warehouse -- then nothing can be ordered either).
func _goods_shortfall(settlement_id: int, option: Dictionary) -> Dictionary:
	var shortfall: Dictionary = {}
	var warehouse := _government_warehouse(settlement_id)
	if warehouse == null:
		return shortfall
	var goods: Dictionary = build_cost_for(settlement_id, option).get("goods", {})
	for commodity in goods:
		var missing: float = float(goods[commodity]) - warehouse.stock(commodity)
		if missing > 0.0:
			shortfall[commodity] = missing
	return shortfall

## Where a goods-priced government build stands on its warehouse stock:
##   "none"      -- nothing to order (no goods cost, already covered, no
##                  warehouse, no government, already built, treasury short)
##   "can_order" -- everything else is in place and goods are missing, and
##                  no standing order covers them yet
##   "ordered"   -- a standing buy order already targets the full cost; the
##                  warehouse is just waiting for the goods to arrive
func build_goods_order_state(settlement_id: int, option: Dictionary) -> String:
	var gov := _settlement_government(settlement_id) if settlements.has(settlement_id) else null
	if gov == null:
		return "none"
	if not option.get("repeatable", false) and (has_business_of_type(settlement_id, option["type_key"]) \
			or _construction_pending(settlement_id, option["type_key"])):
		return "none"
	if gov.balance < float(build_cost_for(settlement_id, option).get("gold", 0.0)):
		return "none"
	var shortfall := _goods_shortfall(settlement_id, option)
	if shortfall.is_empty():
		return "none"
	var warehouse := _government_warehouse(settlement_id)
	for commodity in shortfall:
		var order: Dictionary = warehouse.warehouse_orders.get(commodity, {})
		if float(order.get("buy_up_to", 0.0)) < float(build_cost_for(settlement_id, option)["goods"][commodity]):
			return "can_order"
	return "ordered"

## The Government build button's action. Starts building `type_key` if it can
## be built right now ("built" -- paid for; it stands as a foundation for
## construction_days first). Otherwise, if the only thing missing is warehouse goods,
## sets the warehouse's standing buy order for each missing good up to the
## build's cost ("ordered") -- the player presses again once the goods arrive.
## The order is left standing, so the warehouse keeps restocking for the next
## one. Returns "" when nothing was done.
func request_government_build(settlement_id: int, type_key: String) -> String:
	if build_government_building(settlement_id, type_key):
		return "built"
	for option in HEScenarioSeeds.government_buildings():
		if option["type_key"] != type_key:
			continue
		if build_goods_order_state(settlement_id, option) != "can_order":
			return ""
		var warehouse := _government_warehouse(settlement_id)
		var goods: Dictionary = build_cost_for(settlement_id, option)["goods"]
		for commodity in _goods_shortfall(settlement_id, option):
			var existing: Dictionary = warehouse.warehouse_orders.get(commodity, {})
			var target := maxf(float(existing.get("buy_up_to", 0.0)), float(goods[commodity]))
			var sells: bool = existing.get("sell", false)
			# A standing sell order must not export the goods being saved up.
			var keep := maxf(float(existing.get("keep", 0.0)), float(goods[commodity])) if sells else float(existing.get("keep", 0.0))
			set_warehouse_order(warehouse.id, commodity, target, sells, keep)
		return "ordered"
	return ""

## Sets a Government Warehouse's standing order for one good: buy until it
## holds `buy_up_to` units (0 = don't buy), and -- if `sell` -- export whatever
## it holds above `keep` units through the Trader. Both run daily, paced by
## WAREHOUSE_DAILY_TRADE_CAP (see _run_warehouse_orders). Returns false for a
## business that is not a warehouse or a good that has no local market (live
## animals).
func set_warehouse_order(business_id: int, commodity: Commodity.Type, buy_up_to: float, sell: bool, keep: float) -> bool:
	var b: HEBusiness = businesses.get(business_id)
	if b == null or b.kind != HEBusiness.Kind.WAREHOUSE or is_livestock(commodity):
		return false
	var order := {"buy_up_to": maxf(buy_up_to, 0.0), "sell": sell, "keep": maxf(keep, 0.0)}
	if order["buy_up_to"] <= 0.0 and not sell:
		b.warehouse_orders.erase(commodity)
	else:
		b.warehouse_orders[commodity] = order
	return true

## Lowest crew the tuner may set: one worker (or the business's own
## min_capacity if higher), unless max_capacity itself is 0.
func _capacity_floor(b: HEBusiness) -> int:
	if b.processes_livestock:
		return 0 # follows its work, see _livestock_crew_target
	return mini(maxi(b.min_capacity, 1), b.max_capacity)

func next_business_id() -> int:
	var next_id := 1
	for business_id in businesses.keys():
		next_id = maxi(next_id, business_id + 1)
	for entry in _constructions:
		if entry["record"] is HEBusiness:
			next_id = maxi(next_id, (entry["record"] as HEBusiness).id + 1)
	return next_id

## Whether `settlement_id` already has a business of buildable kind
## `type_key` (see HEBusiness.type_key) -- how "unique building" limits are checked.
func has_business_of_type(settlement_id: int, type_key: String) -> bool:
	for business_id in businesses.keys():
		var b: HEBusiness = businesses[business_id]
		if b.settlement_id == settlement_id and b.type_key == type_key:
			return true
	return false

func advance_ticks(days: int) -> void:
	for i in days:
		_daily_tick()
		day += 1
		_finish_due_constructions()

# ---------------------------------------------------------------------------
# Public query contract
# ---------------------------------------------------------------------------

func get_settlement_ids() -> Array[int]:
	var ids: Array[int] = []
	ids.assign(settlements.keys())
	ids.sort()
	return ids

func get_household_ids(settlement_id: int = -1) -> Array[int]:
	var ids: Array[int] = []
	if settlement_id == -1:
		ids.assign(households.keys())
	elif settlements.has(settlement_id):
		ids.assign((settlements[settlement_id] as HESettlement).household_ids)
	ids.sort()
	return ids

## day, plus the calendar it falls in: season index (Season), season_name,
## day_of_season (0-based) and year (0-based, DAYS_PER_YEAR days each).
func get_clock_summary() -> Dictionary:
	return {
		"day": day,
		"season": season_of_day(day),
		"season_name": season_name_of_day(day),
		"day_of_season": day % DAYS_PER_SEASON,
		"year": day / DAYS_PER_YEAR,
	}

## Lightweight rows for the household table: exactly the fields it shows, in
## one pass, with no need arrays, explanations, or per-person detail. Use
## get_household_summary() for the one household a detail panel shows. Rows are
## in household-ID order. Presentation data: treat as immutable.
##   id, employer_business_id, housing_status, dwelling_id (-1 if none),
##   workers, oldest_worker, dependents, oldest_dependent, stock {commodity -> float} for every
##   SUBSISTENCE_COMMODITIES entry, balance, stress, scarcity (total unmet
##   for scarcity today), unaffordable (total unmet for lack of funds today).
func get_household_table_snapshot(settlement_id: int = -1) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for household_id in get_household_ids(settlement_id):
		var h: HEHousehold = households[household_id]
		var worker_ages := h.worker_ages()
		var dependent_ages := h.dependent_ages()
		var stock := {}
		var scarcity := 0.0
		var unaffordable := 0.0
		for c in SUBSISTENCE_COMMODITIES:
			stock[c] = h.stock(c)
			scarcity += h.last_unmet_scarcity.get(c, 0.0)
			unaffordable += h.last_unmet_unaffordable.get(c, 0.0)
		rows.append({
			"id": household_id,
			"employer_business_id": h.employer_business_id,
			"housing_status": _housing_status_of(h),
			"dwelling_id": h.dwelling_id,
			"workers": worker_ages.size(),
			"oldest_worker": worker_ages.max() if not worker_ages.is_empty() else 0,
			"dependents": dependent_ages.size(),
			"oldest_dependent": dependent_ages.max() if not dependent_ages.is_empty() else 0,
			"stock": stock,
			"balance": h.balance,
			"stress": h.demographics.food_stress,
			"scarcity": scarcity,
			"unaffordable": unaffordable,
		})
	return rows

## Workers and households with no employer, for the Jobs tab.
func get_unemployment_summary(settlement_id: int = -1) -> Dictionary:
	var workers := 0
	var household_count := 0
	for household_id in get_household_ids(settlement_id):
		var h: HEHousehold = households[household_id]
		if h.is_employed():
			continue
		household_count += 1
		workers += h.worker_capacity()
	return {"workers": workers, "households": household_count}

func get_household_summary(household_id: int) -> Dictionary:
	var h: HEHousehold = households[household_id]
	var inventory := {}
	var unmet_scarcity := {}
	var unmet_unaffordable := {}
	for c in SUBSISTENCE_COMMODITIES:
		var name := Commodity.name_of(c)
		inventory[name] = h.stock(c)
		unmet_scarcity[name] = h.last_unmet_scarcity.get(c, 0.0)
		unmet_unaffordable[name] = h.last_unmet_unaffordable.get(c, 0.0)

	# Today's outcome per NEED, in need units, with the satisfier goods that
	# met it. This -- not a per-good "demand" -- is what a household requires.
	var needs: Array[Dictionary] = []
	for need in HENeeds.felt():
		if need.is_service() and not h.last_need_required.has(need.id):
			continue # a service need (water) the town does not provide
		var satisfiers: Array[Dictionary] = []
		for c in need.satisfiers():
			satisfiers.append({"name": Commodity.name_of(c), "consumed": h.last_consumed.get(c, 0.0)})
		needs.append({
			"label": need.label,
			"required": h.last_need_required.get(need.id, 0.0),
			"provided": h.last_need_provided.get(need.id, 0.0),
			"stress": h.stress_of(need.id),
			"effect": need.effect_text,
			"satisfiers": satisfiers,
		})

	return {
		"id": h.id,
		"settlement_id": h.settlement_id,
		"worker_capacity": h.worker_capacity(),
		"dependents": h.demographics.dependents,
		"headcount": h.headcount(),
		"employer_business_id": h.employer_business_id,
		"is_employed": h.is_employed(),
		"housing_status": _housing_status_of(h),
		"dwelling_id": h.dwelling_id,
		"inventory": inventory,
		"balance": h.balance,
		"food_stress": h.demographics.food_stress,
		"health": h.health(),
		"morale": h.morale(1.0, true, tax_morale_effect()),
		"health_losses": h.health_losses(),
		"morale_penalties": h.morale_penalties(1.0, true, tax_morale_effect()),
		"morale_bonuses": h.morale_bonuses(),
		"rolling_grain_fulfillment_30d": h.rolling_grain_fulfillment(),
		"has_migration_pressure": h.demographics.has_migration_pressure,
		"is_starvation_candidate": h.demographics.is_starvation_candidate(),
		"dependent_ages": h.dependent_ages(),
		"worker_ages": h.worker_ages(),
		"dependent_sexes": h.dependent_sexes(),
		"worker_sexes": h.worker_sexes(),
		"needs": needs,
		"unmet_scarcity_today": unmet_scarcity,
		"unmet_unaffordable_today": unmet_unaffordable,
	}

## Town-wide headcount with the average health and morale PER PERSON (so a
## big household counts for more than a small one), using the same
## age-vulnerability and employment rules as get_person_summary().
##
## "health_factors" and "morale_factors" explain why those averages aren't
## 100%: [{label, avg_loss, people}] sorted biggest first, where avg_loss is
## the average points lost per person across the WHOLE town (0..1) and
## `people` is how many of them that factor touches at all.
func get_population_wellbeing(settlement_id: int = -1) -> Dictionary:
	var population := 0
	var unemployed := 0
	var health_total := 0.0
	var morale_total := 0.0
	var health_factors := {}
	var morale_factors := {}
	var tax_effect := tax_morale_effect()
	var morale_bonus_factors := {}
	for household_id in get_household_ids(settlement_id):
		var h: HEHousehold = households[household_id]
		if not h.is_employed():
			unemployed += h.worker_capacity()
		var members: Array[Dictionary] = []
		for age in h.worker_ages():
			members.append({"works": true, "v": HEHousehold.vulnerability_of(true, age)})
		for age in h.dependent_ages():
			members.append({"works": false, "v": HEHousehold.vulnerability_of(false, age)})
		for member in members:
			var v: float = member["v"]
			health_total += h.health(v)
			morale_total += h.morale(v, member["works"], tax_effect)
			population += 1
			for loss in h.health_losses(v):
				_add_factor(health_factors, loss["label"], loss["loss"])
			for penalty in h.morale_penalties(v, member["works"], tax_effect):
				_add_factor(morale_factors, penalty["label"], penalty["penalty"])
			for bonus in h.morale_bonuses():
				_add_factor(morale_bonus_factors, bonus["label"], bonus["bonus"])
	return {
		"population": population,
		"unemployed": unemployed,
		"avg_health": (health_total / population) if population > 0 else 1.0,
		"avg_morale": (morale_total / population) if population > 0 else 1.0,
		"health_factors": _factor_list(health_factors, population),
		"morale_factors": _factor_list(morale_factors, population),
		# Same shape, but avg_loss is points GAINED (needs met that lift morale).
		"morale_bonus_factors": _factor_list(morale_bonus_factors, population),
	}

func _add_factor(factors: Dictionary, label: String, amount: float) -> void:
	if absf(amount) <= 0.001:
		return
	var entry: Dictionary = factors.get_or_add(label, {"total": 0.0, "people": 0})
	entry["total"] += amount
	entry["people"] += 1

func _factor_list(factors: Dictionary, population: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for label in factors.keys():
		out.append({"label": label, "avg_loss": factors[label]["total"] / population, "people": factors[label]["people"]})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["avg_loss"] > b["avg_loss"])
	return out

## One member of a household, by their 1-based member number (workers first,
## then dependents -- the household detail's numbering). Members have no
## persistent identity, so everything here is DERIVED from the household: the
## household's shared stores are split evenly, and the person's own age
## decides how hard a shortfall hits them. Returns {} if there is no such member.
func get_person_summary(household_id: int, member_number: int) -> Dictionary:
	if not households.has(household_id):
		return {}
	var h: HEHousehold = households[household_id]
	var workers := h.worker_ages()
	var dependents := h.dependent_ages()
	var index := member_number - 1
	if index < 0 or index >= workers.size() + dependents.size():
		return {}
	var is_worker := index < workers.size()
	var age: int = workers[index] if is_worker else dependents[index - workers.size()]
	var sexes := h.worker_sexes() if is_worker else h.dependent_sexes()
	var sex: int = sexes[index if is_worker else index - workers.size()]
	var vulnerability := HEHousehold.vulnerability_of(is_worker, age)
	var role := "Worker"
	var life_stage := "Adult"
	var note := ""
	if is_worker:
		if vulnerability > 1.0:
			life_stage = "Elderly"
		note = "%d days until old age" % maxi(HEHousehold.LIFESPAN_DAYS - age, 0)
	elif age < HEHousehold.AGING_THRESHOLD_DAYS:
		role = "Dependent"
		life_stage = "Child"
		note = "%d days until adulthood" % (HEHousehold.AGING_THRESHOLD_DAYS - age)
	else:
		role = "Dependent"
		life_stage = "Adult living at home"
		note = "%.0f%% chance per month of leaving to found a household, once the home is crowded or a house is free" % (HEHousehold.leave_home_chance(age) * 100.0)

	var needs: Array[Dictionary] = []
	for need in HENeeds.felt():
		if need.is_service() and not h.last_need_required.has(need.id):
			continue
		var required := need.per_person_daily * h.need_scale(need)
		var household_required: float = h.last_need_required.get(need.id, 0.0)
		var ratio: float = (h.last_need_provided.get(need.id, 0.0) / household_required) if household_required > 0.0 else 1.0
		needs.append({
			"label": need.label,
			"required": required,
			"provided": required * ratio,
			"stress": minf(h.stress_of(need.id) * vulnerability, 1.0),
			"health_loss": need.health_weight * h.stress_of(need.id) * vulnerability,
			"effect": need.effect_text,
		})
	return {
		"household_id": household_id,
		"member_number": member_number,
		"role": role,
		"life_stage": life_stage,
		"age_days": age,
		"sex": sex,
		"note": note,
		"vulnerability": vulnerability,
		"health": h.health(vulnerability),
		"morale": h.morale(vulnerability, is_worker, tax_morale_effect()),
		"morale_penalties": h.morale_penalties(vulnerability, is_worker, tax_morale_effect()),
		"morale_bonuses": h.morale_bonuses(),
		"needs": needs,
		"employer_business_id": h.employer_business_id if is_worker else -1,
	}

func get_business_reports(settlement_id: int = -1, include_detail: bool = true, only_business_id: int = -1) -> Array:
	var out: Array = []
	var ids := businesses.keys()
	ids.sort()
	for business_id in ids:
		if only_business_id != -1 and business_id != only_business_id:
			continue
		var b: HEBusiness = businesses[business_id]
		if settlement_id != -1 and b.settlement_id != settlement_id:
			continue
		var reference_wage := wages.reference_wage_per_worker(b.settlement_id)
		var report := {
			"business_id": b.id,
			"settlement_id": b.settlement_id,
			"name": b.name,
			"type_key": b.type_key,
			"kind": _kind_name(b.kind),
			"capacity": b.capacity,
			"max_capacity": b.max_capacity,
			"employed_workers": _business_employed_worker_count(business_id),
			"employed_household_count": _business_employed_household_count(business_id),
			"balance": b.balance,
			"last_revenue": b.last_revenue,
			"last_wages_paid": b.last_wages_paid,
			"last_cash_change": b.last_cash_change,
			"last_planned_units": b.last_planned_units,
			"last_actual_units": b.last_actual_units,
			"last_wage_per_worker": b.last_wage_per_worker,
			"rolling_average_wage": b.rolling_average_wage(),
			"rolling_average_revenue_per_worker": b.rolling_average_revenue_per_worker(),
			"reference_wage_per_worker": reference_wage,
			"cash_runway_days": _business_cash_runway_days(b),
			"wage_shortfall": b.last_wage_shortfall,
			"land_area_acres": b.land_area_acres,
			# A herd's "harvest" is the shared review tick (_run_herds), so
			# report the real countdown to it, not days_until_next_harvest()'s
			# constant growth_days stand-in (which sell-pace logic wants).
			"days_to_next_harvest": (HERD_EVAL_INTERVAL_DAYS - day % HERD_EVAL_INTERVAL_DAYS) if b.kind == HEBusiness.Kind.HERD else b.days_until_next_harvest(),
		}
		if include_detail:
			var recent_ledger := b.ledger_history(1)
			report["balance_history"] = b.balance_history()
			report["ledger"] = recent_ledger.back() if not recent_ledger.is_empty() else {}
			report["ledger_history"] = b.ledger_history()
			report["fields"] = _field_reports(b)
		if b.uses_field_model():
			var projection := _next_harvest_projection(b, int(report["employed_workers"]))
			report["next_harvest_expected_units"] = projection["expected_units"]
			report["next_harvest_yield_fraction"] = projection["yield_fraction"]
			report["next_harvest_season_modifier"] = projection["season_modifier"]
		if b.kind == HEBusiness.Kind.TRADER:
			report["recipe_id"] = "trade"
			report["output_commodity"] = _trade_summary(b)
			report["stock"] = 0.0 # exports convert straight to money; the Trader never holds inventory
		elif b.kind == HEBusiness.Kind.PORT:
			report["recipe_id"] = "port"
			report["output_commodity"] = "Outside trade"
			var port_inventory: Dictionary = {}
			var total_port_stock := 0.0
			for commodity in b.inventory:
				var units: float = b.stock(commodity)
				port_inventory[Commodity.name_of(commodity)] = units
				total_port_stock += units
			report["inventory"] = port_inventory
			report["stock"] = total_port_stock
		elif b.kind == HEBusiness.Kind.GOVERNMENT:
			# Same keys the production branch fills, so detail pages that
			# read them need no government special case.
			report["recipe_id"] = "government"
			report["output_commodity"] = "Public administration"
			report["stock"] = 0.0
			report["treasury"] = b.balance
			report["last_tax_collected"] = b.last_tax_collected
			report["tax_collected_total"] = b.tax_collected_total
			report["sales_tax_rate"] = sales_tax_rate
			report["builder_slots"] = b.builder_slots
		elif b.kind == HEBusiness.Kind.WATER:
			report["recipe_id"] = "water"
			report["output_commodity"] = "Safe drinking water"
			report["stock"] = 0.0
		elif b.kind == HEBusiness.Kind.WAREHOUSE:
			report["recipe_id"] = "warehouse"
			report["output_commodity"] = "Construction inventory"
			var held_units := 0.0
			for held in b.inventory.values():
				held_units += held
			report["stock"] = held_units
			# No cash of its own: the books it shows are the treasury's.
			var treasury := _settlement_government(b.settlement_id)
			if treasury != null:
				report["balance"] = treasury.balance
				report["last_cash_change"] = treasury.last_cash_change
				if include_detail:
					report["balance_history"] = treasury.balance_history()
				report["cash_runway_days"] = _business_cash_runway_days(treasury)
			if include_detail:
				report["warehouse_orders"] = _warehouse_order_rows(b)
		elif b.kind == HEBusiness.Kind.HERD:
			var herd_commodity := b.herd_commodity()
			report["recipe_id"] = "herd"
			report["species"] = "Cattle" if b.species == HEBusiness.Species.CATTLE else "Sheep"
			report["herd_size"] = b.herd_size
			report["output_commodity"] = Commodity.name_of(herd_commodity)
			report["stock"] = b.stock(herd_commodity)
			report["wool_stock"] = b.stock(Commodity.Type.WOOL) if b.species == HEBusiness.Species.SHEEP else 0.0
			report["last_wool_produced"] = b.last_wool_produced
			report["last_hardship_butchered"] = b.last_hardship_butchered
			if include_detail:
				report["herd_events"] = b.herd_events.duplicate(true)
				report["cull_target"] = herd_cull_target(b)
				report["dynamic_cull"] = b.dynamic_cull
				report["cull_target_min"] = herd_cull_target_range(b).x
				report["cull_target_max"] = herd_cull_target_range(b).y
			if include_detail and b.species == HEBusiness.Species.SHEEP:
				var sustaining := wool_sustaining_herd_counts(b)
				report["wool_sustaining_unstaffed"] = int(sustaining.x)
				report["wool_sustaining_current"] = int(sustaining.y)
				report["wool_sustaining_staffed"] = int(sustaining.z)
			report["care_fraction"] = b.last_care_fraction
			# Care so far this review window: care_fraction only moves at a
			# review, so on its own it reads 0 for up to a season after a ranch
			# is first staffed. -1 on the first day of a window (nothing accrued).
			var window_days: int = day % HERD_EVAL_INTERVAL_DAYS
			var window_need: float = b.herd_size * HERD_LABOR_PER_HEAD_PER_DAY[b.species] * window_days
			report["care_fraction_now"] = clampf(b.care_worker_days / window_need, 0.0, 1.0) if window_need > 0.0 else -1.0
			var fodder_target: float = b.herd_size * FODDER_PER_HEAD_PER_WINTER[b.species]
			report["fodder_stock"] = b.stock(Commodity.Type.GRAIN)
			report["fodder_target"] = fodder_target
			report["fodder_cover"] = minf(1.0, b.stock(Commodity.Type.GRAIN) / fodder_target) if fodder_target > 0.0 else 1.0
			report["last_review_season"] = b.last_review_season
			report["last_review_season_name"] = SEASON_NAMES[b.last_review_season] if b.last_review_season >= 0 else ""
			report["last_fodder_needed"] = b.last_fodder_needed
			report["last_fodder_eaten"] = b.last_fodder_eaten
			report["wool_season_modifier"] = seasonal_yield_scale(Commodity.Type.WOOL, day) if b.species == HEBusiness.Species.SHEEP else 1.0
			report["care_workers_needed"] = b.herd_size * HERD_LABOR_PER_HEAD_PER_DAY[b.species]
		else:
			var output_commodity := b.output_commodity()
			report["recipe_id"] = b.recipe.id
			report["output_commodity"] = Commodity.name_of(output_commodity)
			report["stock"] = b.stock(output_commodity)
			if include_detail:
				var input_inventory := {}
				for input_commodity in b.recipe.inputs.keys():
					input_inventory[Commodity.name_of(input_commodity)] = b.stock(input_commodity)
				report["input_inventory"] = input_inventory
				# {flow: [{"commodity": name, "values": Array[float]}]} -- one entry
				# per good, so a multi-good recipe is just more series.
				var flow_history := {}
				for flow in HEBusiness.ALL_SERIES:
					var flow_series: Array = []
					var history := b.flow_history(flow)
					for commodity in history.keys():
						flow_series.append({"commodity": Commodity.name_of(commodity), "values": history[commodity]})
					flow_history[flow] = flow_series
				report["flow_history"] = flow_history
		if include_detail and b.uses_tools():
			var tool_crew := _business_employed_worker_count(b.id)
			report["tools"] = {
				"active": _tools_in_play(b.settlement_id),
				"stock": b.stock(Commodity.Type.TOOLS),
				"needed": float(tool_crew) * b.tools_per_worker,
				"wear_per_day": float(tool_crew) * b.tool_wear_per_worker_day,
				"coverage": b.tool_coverage(tool_crew),
				"productivity": _tool_productivity(b),
				"floor": HEBusiness.TOOL_PRODUCTIVITY_FLOOR,
			}
		if include_detail and (b.kind == HEBusiness.Kind.PRODUCTION or b.kind == HEBusiness.Kind.HERD):
			report["crew_morale"] = _business_crew_morale(b.id)
		if b.kind == HEBusiness.Kind.WATER:
			report["water"] = {
				"people": b.water_capacity,
				"serving": 0 if b.in_disrepair else b.water_capacity,
				"in_disrepair": b.in_disrepair,
				"upkeep_timber": b.water_upkeep_timber,
				"upkeep_stone": b.water_upkeep_stone,
				"days_to_service": maxi(0, b.next_service_day - day),
			}
		out.append(report)
	return out

## One row per good the warehouse can trade (everything with a local market
## except live animals), for the order panel: what it holds, today's price, and
## the standing order (buy_up_to 0 / sell false when none is set).
func _warehouse_order_rows(b: HEBusiness) -> Array:
	var rows: Array = []
	var market: HEMarket = markets[b.settlement_id]
	var commodities: Array = market.price.keys()
	commodities.sort()
	for commodity in commodities:
		if is_livestock(commodity):
			continue
		var order: Dictionary = b.warehouse_orders.get(commodity, {})
		rows.append({
			"commodity": commodity,
			"name": Commodity.name_of(commodity),
			"stock": b.stock(commodity),
			"price": market.price[commodity],
			"buy_up_to": order.get("buy_up_to", 0.0),
			"sell": order.get("sell", false),
			"keep": order.get("keep", 0.0),
			"has_local_seller": _business_selling(b.settlement_id, commodity) != null,
		})
	return rows

func _kind_name(kind: HEBusiness.Kind) -> String:
	match kind:
		HEBusiness.Kind.TRADER: return "trader"
		HEBusiness.Kind.PORT: return "port"
		HEBusiness.Kind.HERD: return "herd"
		HEBusiness.Kind.GOVERNMENT: return "government"
		HEBusiness.Kind.WAREHOUSE: return "warehouse"
		HEBusiness.Kind.WATER: return "water"
		_: return "production"

## "Export (Grain, Timber) / Import (Iron Ore)" -- whichever commodities the
## Trader actually moved today in each direction, sorted for determinism
## (see run_household_economy.gd's same-seed determinism check, which
## compares whole report dictionaries). Either half is omitted entirely
## when empty; a Trader with neither just reads "Trade".
func _trade_summary(b: HEBusiness) -> String:
	var parts: Array[String] = []
	if not b.last_exported.is_empty():
		parts.append("Export (%s)" % ", ".join(_sorted_commodity_names(b.last_exported.keys())))
	if not b.last_imported.is_empty():
		parts.append("Import (%s)" % ", ".join(_sorted_commodity_names(b.last_imported.keys())))
	return " / ".join(parts) if not parts.is_empty() else "Trade"

func _sorted_commodity_names(commodity_ids: Array) -> Array[String]:
	commodity_ids.sort()
	var names: Array[String] = []
	for c in commodity_ids:
		names.append(Commodity.name_of(c))
	return names

## Per-field progress for a land-based business's report (empty for Trader/
## legacy businesses with no fields at all) -- see get_business_reports.
func _field_reports(b: HEBusiness) -> Array:
	var out: Array = []
	for f in b.fields:
		out.append({"area": f.area, "days_growing": f.days_growing, "growth_days": b.growth_days})
	return out

## Forecast for the next field to mature, assuming today's crew stays at
## its current size until that harvest. Yield uses actual accumulated
## worker-days plus the work that current staffing would add over the
## remaining growth days, against the same requirement used at harvest.
func _next_harvest_projection(b: HEBusiness, employed: int) -> Dictionary:
	if not b.uses_field_model():
		return {"expected_units": 0.0, "yield_fraction": 0.0}
	var next_field: HEField = b.fields[0]
	var days_remaining := b.growth_days - next_field.days_growing
	for f in b.fields:
		var candidate_days: int = b.growth_days - f.days_growing
		if candidate_days < days_remaining:
			next_field = f
			days_remaining = candidate_days
	var daily_labor: float = float(employed) * (next_field.area / b.land_area_acres) if b.land_area_acres > 0.0 else 0.0
	var projected_labor: float = next_field.labor_applied + daily_labor * maxi(0, days_remaining)
	var required_labor: float = next_field.area * b.labor_per_area_per_day * b.growth_days
	var yield_fraction: float = clampf(projected_labor / required_labor, 0.0, 1.0) if required_labor > 0.0 else 0.0
	# The harvest lands `days_remaining` days from now, in that day's season.
	var season_modifier := seasonal_yield_scale(b.output_commodity(), day + maxi(0, days_remaining))
	return {
		"expected_units": next_field.area * b.yield_per_area * yield_fraction * season_modifier,
		"yield_fraction": yield_fraction,
		"season_modifier": season_modifier,
	}

## Every commodity with a REAL presence in this settlement's market right
## now -- BASE_PRICE.keys() (not just SUBSISTENCE_COMMODITIES, so a
## business-to-business good like iron ore/iron is eligible at all -- see
## _run_input_purchasing/_run_trade, the only places that ever populate
## their last_clearing entries), filtered down to ones _commodity_active_in_
## market says actually have a buyer or seller. A caller (the dashboard's
## market grid) is expected to show only what this returns, not a fixed
## list, so an inactive good's row disappears entirely rather than sitting
## there reading all zeroes forever.
func get_market_summary(settlement_id: int = -1) -> Dictionary:
	settlement_id = _resolve_settlement_id(settlement_id)
	var local_market: HEMarket = markets[settlement_id]
	var out := {}
	for c in BASE_PRICE.keys():
		if not _commodity_active_in_market(settlement_id, c):
			continue
		out[Commodity.name_of(c)] = {
			"price": local_market.price[c],
			"last_clearing": (local_market.last_clearing.get(c, {}) as Dictionary).duplicate(true),
			"stored": _town_stored(settlement_id, c),
		}
	# Culled livestock follows the priced goods, listed only while a ranch of that
	# species or a Butcher exists (see _livestock_active). Its row reads like any
	# other good's: one trading price, with the Trader as just another buyer.
	for c in LIVESTOCK_GOODS:
		if _livestock_active(settlement_id, c):
			var entry := _livestock_summary_entry(c)
			entry["stored"] = _town_stored(settlement_id, c)
			out[Commodity.name_of(c)] = entry
	return out

## Total `commodity` physically held in `settlement_id` right now: every
## household's and business's stock added up (the same holdings
## get_market_detail lists individually). Livestock is held only by businesses.
func _town_stored(settlement_id: int, commodity: Commodity.Type) -> float:
	var total := 0.0
	if is_livestock(commodity):
		for business_id in businesses.keys():
			var b: HEBusiness = businesses[business_id]
			if b.settlement_id == settlement_id:
				total += livestock_holding_value(b, commodity)["quantity"]
		return total
	for household_id in get_household_ids(settlement_id):
		total += (households[household_id] as HEHousehold).stock(commodity)
	for business_id in businesses.keys():
		var b: HEBusiness = businesses[business_id]
		if b.settlement_id == settlement_id:
			total += b.stock(commodity)
	return total

## Whether culled `commodity` livestock has any real presence in the settlement:
## a ranch of that species can offer it, or a Butcher (which buys either species)
## can take it. A settlement with neither shows no livestock row, and a Trader
## alone does not create one -- spare export capacity is not local demand.
func _livestock_active(settlement_id: int, commodity: Commodity.Type) -> bool:
	var species := livestock_species(commodity)
	for business_id in businesses.keys():
		var b: HEBusiness = businesses[business_id]
		if b.settlement_id != settlement_id:
			continue
		if b.kind == HEBusiness.Kind.HERD and b.species == species:
			return true
		if b.processes_livestock:
			return true
	return false

## The price a livestock good's row shows: its posted price, the analogue of
## another good's market price. Like every other good, the Trader pays a fraction
## of it (PORT_BUY_PRICE_FRACTION), and the Butcher pays its own, without
## either becoming a second price on the row -- leather's households and Trader
## differ the same way.
func _livestock_price(commodity: Commodity.Type) -> float:
	return livestock_quote(livestock_species(commodity), LivestockQuote.POSTED)

## Yesterday's (the latest completed day's) livestock totals for `commodity`:
## offered/requested/bought/exported head. All zero before any day has run.
func _livestock_last_day(commodity: Commodity.Type) -> Dictionary:
	var zero := {"offered": 0.0, "requested": 0.0, "bought": 0.0, "exported": 0.0}
	if _history.is_empty():
		return zero
	return ((_history.back() as Dictionary)["livestock_market"] as Dictionary).get(Commodity.name_of(commodity), zero)

func _livestock_summary_entry(commodity: Commodity.Type) -> Dictionary:
	var last := _livestock_last_day(commodity)
	return {
		"price": _livestock_price(commodity),
		# "Traded" is local sales only; head the Trader took are in "exported".
		"last_clearing": {
			"total_offered": last["offered"],
			"total_requested_funded": last["requested"],
			"quantity_traded": last["bought"],
			"exported": last["exported"],
		},
	}

## Whether `commodity` has any real presence in `settlement_id`'s market --
## a local PRODUCTION business sells it, OR some local PRODUCTION business
## wants to BUY it as a recipe input (whether from that local seller or, for
## something nothing local produces, via the settlement's Trader importing
## it -- see _run_input_purchasing). Computed structurally from which
## businesses exist rather than from today's last_clearing, so it's correct
## from day 0 (before any tick has run) and doesn't flicker off on a single
## quiet day.
func _commodity_active_in_market(settlement_id: int, commodity: Commodity.Type) -> bool:
	for business_id in businesses.keys():
		var b: HEBusiness = businesses[business_id]
		if b.settlement_id != settlement_id:
			continue
		# A herd sells its wool trickle locally (culled animals go through
		# the Trader instead, never the local market).
		if b.kind == HEBusiness.Kind.HERD and commodity == Commodity.Type.WOOL and b.species == HEBusiness.Species.SHEEP:
			return true
		# ... and a ranch's home-butchered meat (culls with no outlet, hardship).
		if b.kind == HEBusiness.Kind.HERD and commodity == Commodity.Type.MEAT:
			return true
		if b.kind != HEBusiness.Kind.PRODUCTION:
			continue
		if b.sells(commodity):
			return true
		if b.recipe.inputs.has(commodity):
			return true
	return false

func get_market_report(settlement_id: int, commodity: Commodity.Type) -> Dictionary:
	if is_livestock(commodity):
		return _livestock_market_report(settlement_id, commodity)
	var local_market: HEMarket = markets[settlement_id]
	return {
		"settlement_id": settlement_id,
		"commodity_id": commodity,
		"price": local_market.price[commodity],
		"last_clearing": (local_market.last_clearing.get(commodity, {}) as Dictionary).duplicate(true),
		"supplied_history": local_market.supplied_history(commodity),
		"demanded_history": local_market.demanded_history(commodity),
		"demanded_with_export_history": local_market.demanded_with_export_history(commodity),
		"household_demand": local_market.household_demand(commodity),
		"household_wanted_history": local_market.household_wanted_history(commodity),
		"household_funded_history": local_market.household_funded_history(commodity),
		"household_bought_history": local_market.household_bought_history(commodity),
		"need": _market_need_report(settlement_id, commodity),
		"price_signal": (local_market.last_price_signal.get(commodity, {}) as Dictionary).duplicate(),
		"price_floor_days": local_market.floor_days.get(commodity, 0),
		"price_ceiling_days": local_market.ceiling_days.get(commodity, 0),
		"seller": _market_seller_report(settlement_id, commodity),
	}

## The local seller's real warehouse stock, kept apart from what it actually
## puts up for sale today (a field-model seller paces a harvest over the days
## until the next one), so a shortage under paced sales reads as that rather
## than as stock being withheld. Empty when nobody local sells the good.
func _market_seller_report(settlement_id: int, commodity: Commodity.Type) -> Dictionary:
	var seller := _business_selling(settlement_id, commodity)
	if seller == null:
		return {}
	return {
		"name": seller.name,
		"stock": seller.stock(commodity),
		"paced_offer": _paced_offer(seller, commodity),
		"paced": seller.has_long_cycle(),
		"days_until_harvest": seller.days_until_next_harvest(),
	}

## Daily requirement of the need `commodity` helps satisfy, in need units and
## counted once per need (not per satisfier), so timber and wool do not each
## claim the same heat requirement. Empty for goods that satisfy no need.
## Histories are one point per simulated day, oldest first.
func _market_need_report(settlement_id: int, commodity: Commodity.Type) -> Dictionary:
	var need := HENeeds.for_commodity(commodity)
	if need == null:
		return {}
	var required_history: Array = []
	var provided_history: Array = []
	var start: int = maxi(0, _history.size() - HEMarket.SUPPLY_DEMAND_HISTORY_WINDOW_DAYS)
	for i in range(start, _history.size()):
		var entry: Dictionary = (_history[i] as Dictionary)["needs_by_settlement"].get(settlement_id, {}).get(need.id, {})
		required_history.append(entry.get("required", 0.0))
		provided_history.append(entry.get("provided", 0.0))
	return {
		"id": need.id,
		"label": need.label,
		"satisfiers": need.satisfiers().map(func(c): return Commodity.name_of(c)),
		"required_history": required_history,
		"provided_history": provided_history,
	}

## One row per good this valley Trader may ship, in fixed priority order.
## Standalone Ports trade every good automatically and do not use this setting.
func get_trader_export_settings(business_id: int) -> Array:
	var out: Array = []
	if not _trader_export_enabled.has(business_id):
		return out
	var trader: HEBusiness = businesses[business_id]
	for commodity in EXPORT_PRIORITY:
		if _business_selling(trader.settlement_id, commodity) == null:
			continue
		var offer := _seller_trade_offer(_business_selling(trader.settlement_id, commodity), commodity)
		out.append({"commodity_id": commodity, "name": Commodity.name_of(commodity),
			"enabled": _trader_export_enabled[business_id].get(commodity, false),
			"seller_min_price": offer["min_price"], "available": offer["quantity"],
			"stored": _town_stored(trader.settlement_id, commodity)})
	return out

func set_trader_export_enabled(business_id: int, commodity: Commodity.Type, enabled: bool) -> void:
	if not _trader_export_enabled.has(business_id) or not EXPORT_PRIORITY.has(commodity):
		return
	_trader_export_enabled[business_id][commodity] = enabled

## Current participants and physical holdings. Requests/offers are estimates
## from the present state for the next clearing; last_clearing is yesterday's
## completed aggregate and is deliberately kept separate.
func get_market_detail(settlement_id: int, commodity: Commodity.Type) -> Dictionary:
	if is_livestock(commodity):
		return _livestock_market_detail(settlement_id, commodity)
	var report := get_market_report(settlement_id, commodity)
	var buyers: Array = []
	var sellers: Array = []
	var holdings: Array = []
	var price: float = report["price"]
	for household_id in get_household_ids(settlement_id):
		var h: HEHousehold = households[household_id]
		var stock := h.stock(commodity)
		if stock > 0.0001:
			holdings.append({"owner": "Household %d" % household_id, "kind": "household", "quantity": stock})
		if SUBSISTENCE_COMMODITIES.has(commodity):
			var desired: float = _desired_purchase(h, commodity)
			if desired > 0.0001:
				buyers.append({"owner": "Household %d" % household_id, "kind": "household", "requested": desired,
					"funded": minf(desired, maxf(0.0, h.balance / price)) if price > 0.0 else 0.0,
					"stock": stock})
	var business_ids := businesses.keys()
	business_ids.sort()
	for business_id in business_ids:
		var b: HEBusiness = businesses[business_id]
		if b.settlement_id != settlement_id:
			continue
		var stock := b.stock(commodity)
		if stock > 0.0001:
			holdings.append({"owner": b.name, "business_id": b.id, "quantity": stock})
		if b.kind != HEBusiness.Kind.PRODUCTION:
			continue
		if b.sells(commodity):
			var offered := stock
			if SUBSISTENCE_COMMODITIES.has(commodity) and b.uses_field_model():
				offered = minf(stock, stock / float(_days_until_next_supply(b)) * SELL_PACE_HEADROOM)
			elif not SUBSISTENCE_COMMODITIES.has(commodity):
				offered = _seller_trade_offer(b, commodity)["quantity"]
			sellers.append({"owner": b.name, "business_id": b.id, "offered": offered, "stock": stock})
		if commodity == Commodity.Type.TOOLS and b.uses_tools() and _tools_in_play(settlement_id):
			var ask := _tool_request(b, _business_employed_worker_count(b.id))
			if ask["requested"] > 0.0001:
				buyers.append({"owner": b.name, "business_id": b.id, "requested": ask["requested"],
					"funded": minf(ask["requested"], maxf(0.0, b.balance / price)) if price > 0.0 else 0.0,
					"stock": stock})
		if b.recipe.inputs.has(commodity):
			var planned: float = float(_business_employed_worker_count(b.id)) * b.recipe.outputs[b.output_commodity()]
			var desired: float = maxf(0.0, planned * b.recipe.inputs[commodity] * PRODUCTION_INPUT_BUFFER_DAYS - stock)
			if desired > 0.0001:
				buyers.append({"owner": b.name, "business_id": b.id, "requested": desired,
					"funded": minf(desired, maxf(0.0, b.balance / price)) if price > 0.0 else 0.0,
					"stock": stock})
	var local_seller := _business_selling(settlement_id, commodity)
	var trader := _settlement_trader(settlement_id) if intertown_trading_enabled else null
	var trader_stock := maxf(0.0, trader.stock(commodity) - _valley_reserved_stock.get(commodity, 0.0)) if trader != null else 0.0
	var port := _settlement_port(settlement_id)
	if local_seller == null and not buyers.is_empty():
		if trader_stock > 0.0001:
			sellers.append({"owner": "%s (valley stock)" % trader.name, "business_id": trader.id,
				"kind": "import", "capacity": trader_stock})
		elif port != null and _business_employed_worker_count(port.id) > 0:
			var port_capacity := float(_business_employed_worker_count(port.id)) * TRADER_CAPACITY_PER_WORKER
			sellers.append({"owner": "%s (outside import)" % port.name, "business_id": port.id,
				"kind": "import", "capacity": port_capacity})
	if local_seller != null and port != null and _business_employed_worker_count(port.id) > 0:
		var offer := _seller_trade_offer(local_seller, commodity)
		var outside_price := _port_outside_price(settlement_id, commodity)
		var port_bid := maxf(outside_price * PORT_BUY_PRICE_FRACTION, float(offer["min_price"]))
		buyers.append({"owner": "Port (outside market)", "business_id": port.id, "kind": "export",
			"capacity": float(_business_employed_worker_count(port.id)) * TRADER_CAPACITY_PER_WORKER,
			"available": offer["quantity"] if port_bid <= outside_price * 0.9 else 0.0,
			"reference_price": outside_price, "bid_price": port_bid,
			"seller_min_price": offer["min_price"]})
	report["buyers"] = buyers
	report["sellers"] = sellers
	report["holdings"] = holdings
	return report

## One point per recorded day (up to the market history window), oldest first,
## of a livestock good's offered/requested/bought/exported head.
func _livestock_history(commodity: Commodity.Type, key: String) -> Array:
	var name := Commodity.name_of(commodity)
	var out: Array = []
	var start: int = maxi(0, _history.size() - HEMarket.SUPPLY_DEMAND_HISTORY_WINDOW_DAYS)
	for i in range(start, _history.size()):
		var today: Dictionary = ((_history[i] as Dictionary)["livestock_market"] as Dictionary).get(name, {})
		out.append(today.get(key, 0.0))
	return out

## A livestock good's report, in the same shape as any other good's so the Goods
## page reads it unchanged, with the household and price-drift fields honestly
## empty (as for iron): no household buys live animals, and no local price moves
## with demand.
func _livestock_market_report(settlement_id: int, commodity: Commodity.Type) -> Dictionary:
	var summary := _livestock_summary_entry(commodity)
	var offered := _livestock_history(commodity, "offered")
	var requested := _livestock_history(commodity, "requested")
	var exported := _livestock_history(commodity, "exported")
	var requested_with_export: Array = []
	var zeros: Array = []
	for i in requested.size():
		requested_with_export.append(requested[i] + exported[i])
		zeros.append(0.0)
	return {
		"settlement_id": settlement_id,
		"commodity_id": commodity,
		"price": summary["price"],
		"last_clearing": summary["last_clearing"],
		"supplied_history": offered,
		"demanded_history": requested,
		"demanded_with_export_history": requested_with_export,
		"household_demand": {"wanted": 0.0, "funded": 0.0, "bought": 0.0},
		"household_wanted_history": zeros,
		"household_funded_history": zeros.duplicate(),
		"household_bought_history": zeros.duplicate(),
		"need": {},
		"price_signal": {},
		"price_floor_days": 0,
		"price_ceiling_days": 0,
		"seller": {},
	}

## A livestock good's participants and holdings. Sellers are ranches with culled
## head; the only local buyer is a staffed Butcher (what its crew would stock up
## on, within its credit); the Trader appears as an export buyer, as it does for
## any good, with only what the Butcher won't take. Holdings also carry each
## stock's value by channel (see livestock_holding_value). No household ever
## appears: nothing here is a household need.
func _livestock_market_detail(settlement_id: int, commodity: Commodity.Type) -> Dictionary:
	var report := _livestock_market_report(settlement_id, commodity)
	var species := livestock_species(commodity)
	var buyers: Array = []
	var sellers: Array = []
	var holdings: Array = []
	var business_ids := businesses.keys()
	business_ids.sort()
	for business_id in business_ids:
		var b: HEBusiness = businesses[business_id]
		if b.settlement_id != settlement_id:
			continue
		var holding := livestock_holding_value(b, commodity)
		if holding["quantity"] > 0.0001:
			holdings.append({"owner": b.name, "business_id": b.id, "quantity": holding["quantity"],
				"value": holding["value"], "local_value": holding["local_value"], "export_value": holding["export_value"]})
		if b.kind == HEBusiness.Kind.HERD and b.species == species:
			sellers.append({"owner": b.name, "business_id": b.id, "offered": holding["quantity"], "stock": holding["quantity"],
				"local_value": holding["local_value"], "export_value": holding["export_value"]})
		if b.processes_livestock and _business_employed_worker_count(b.id) > 0:
			var price: float = livestock_quote(species, LivestockQuote.BUTCHER_PURCHASE)
			var requested := _butchery_wanted_head(b, species)
			var affordable: float = maxf(0.0, b.balance + BUTCHERY_CREDIT_LIMIT) / price
			buyers.append({"owner": b.name, "business_id": b.id, "kind": "local", "requested": requested,
				"funded": minf(requested, affordable), "stock": holding["quantity"]})
	# The Port buys every supported good outside; valley Traders only buy
	# livestock when that intertown shipment is enabled.
	var port := _settlement_port(settlement_id)
	var trader := _settlement_trader(settlement_id) if intertown_trading_enabled else null
	var outside_enabled := port != null and _business_employed_worker_count(port.id) > 0
	var valley_enabled: bool = trader != null and bool(_trader_export_enabled[trader.id].get(commodity, false))
	if not sellers.is_empty() and (outside_enabled or valley_enabled):
		var buyer: HEBusiness = port if outside_enabled else trader
		var capacity: float = float(_business_employed_worker_count(buyer.id)) * TRADER_CAPACITY_PER_WORKER
		var offered := 0.0
		for seller in sellers:
			offered += seller["stock"]
		buyers.append({"owner": "%s (exports)" % buyer.name, "business_id": buyer.id, "kind": "export",
			"capacity": capacity, "available": minf(capacity, offered)})
	report["buyers"] = buyers
	report["sellers"] = sellers
	report["holdings"] = holdings
	return report

## Local Butcher purchases and Trader exports of one livestock good in a
## settlement over up to the last `days` recorded days, newest first. Each is
## recorded once at its source (_run_livestock_purchasing, _run_trade) and
## normalised here: {day, channel: "butcher_purchase" | "trader_export",
## seller_id, buyer_id, commodity, quantity, unit_price (the reference, for an
## export), paid_price (what the seller received per head)}.
func get_livestock_transactions(settlement_id: int, commodity: Commodity.Type, days: int = 30) -> Array:
	var name := Commodity.name_of(commodity)
	var start: int = maxi(0, _history.size() - days)
	var out: Array = []
	for record_index in range(_history.size() - 1, start - 1, -1):
		var record: Dictionary = _history[record_index]
		var day_entries: Array = []
		for t in record["livestock_transactions"]:
			if t["commodity"] == name and t["settlement_id"] == settlement_id:
				day_entries.append({"day": t["day"], "channel": t["channel"], "seller_id": t["seller_id"], "buyer_id": t["buyer_id"],
					"commodity": name, "quantity": t["quantity"], "unit_price": t["unit_price"], "paid_price": t["unit_price"]})
		for t in record["trader_transactions"]:
			if t["commodity"] == name and t["direction"] == "export" and t.has("seller_id") and t["settlement_id"] == settlement_id:
				day_entries.append({"day": t["day"], "channel": "trader_export", "seller_id": t["seller_id"], "buyer_id": t["business_id"],
					"commodity": name, "quantity": t["quantity"], "unit_price": t["unit_price"], "paid_price": t["paid_price"]})
		day_entries.reverse()
		out.append_array(day_entries)
	return out

## City-wide totals AND distributions -- a healthy average must not hide a
## hungry or unfunded household.
func get_settlement_summary(settlement_id: int) -> Dictionary:
	var s: HESettlement = settlements[settlement_id]
	var household_count := s.household_ids.size()
	var households_short_of_goods := 0
	var households_short_of_funds := 0
	var unemployed_household_count := 0
	var stress_total := 0.0

	for household_id in s.household_ids:
		var h: HEHousehold = households[household_id]
		var scarcity_total := 0.0
		for v in h.last_unmet_scarcity.values():
			scarcity_total += v
		var unaffordable_total := 0.0
		for v in h.last_unmet_unaffordable.values():
			unaffordable_total += v
		if scarcity_total > 0.0001:
			households_short_of_goods += 1
		if unaffordable_total > 0.0001:
			households_short_of_funds += 1
		if not h.is_employed():
			unemployed_household_count += 1
		stress_total += h.demographics.food_stress

	return {
		"id": settlement_id,
		"name": s.name,
		"day": day,
		"household_count": household_count,
		"population": _total_population(settlement_id),
		"unemployed_household_count": unemployed_household_count,
		"total_stock": _total_stock_snapshot(settlement_id),
		"total_money": _total_money(settlement_id),
		"avg_food_stress": (stress_total / household_count) if household_count > 0 else 0.0,
		"households_short_of_goods": households_short_of_goods,
		"households_short_of_funds": households_short_of_funds,
		"emigrations_total": _emigrations_total,
		"old_age_deaths_total": _old_age_deaths_total,
		"money_written_off_total": _money_written_off_total,
		"money_written_off_by_cause": _money_written_off_by_cause.duplicate(),
		"startup_injection_total": _startup_injection_total,
		"births_total": _births_total,
		"worker_promotions_total": _worker_promotions_total,
		"export_revenue_total": _export_revenue_total,
		"import_cost_total": _import_cost_total,
		"construction_spend_total": _construction_spend_total,
		"housing": get_housing_report(settlement_id),
		"market": get_market_summary(settlement_id),
	}

func get_city_summary() -> Dictionary:
	return get_settlement_summary(_resolve_settlement_id(-1))

func _resolve_settlement_id(settlement_id: int) -> int:
	if settlement_id != -1:
		assert(settlements.has(settlement_id), "Unknown settlement id %d" % settlement_id)
		return settlement_id
	var ids := get_settlement_ids()
	assert(ids.size() == 1, "A settlement id is required when the simulation has multiple settlements")
	return ids[0]

## Up to the last `days` daily records, oldest first. Each is deep-copied --
## mutating the returned data cannot affect the simulation.
func get_daily_history(days: int) -> Array:
	var start: int = max(0, _history.size() - days)
	var out: Array = []
	for i in range(start, _history.size()):
		out.append((_history[i] as Dictionary).duplicate(true))
	return out

## This Trader's intertown shipments or this Port's outside transactions from
## up to the last `days` daily records, newest first. Each transaction is
## copied so callers cannot mutate simulation history through the query result.
func get_trade_transactions(business_id: int, days: int = 30) -> Array:
	assert(businesses.has(business_id), "Unknown business id %d" % business_id)
	assert((businesses[business_id] as HEBusiness).kind in [HEBusiness.Kind.TRADER, HEBusiness.Kind.PORT], "Business %d has no trade transactions" % business_id)
	var start: int = max(0, _history.size() - days)
	var out: Array = []
	for record_index in range(_history.size() - 1, start - 1, -1):
		var record: Dictionary = _history[record_index]
		for transaction_index in range((record["trader_transactions"] as Array).size() - 1, -1, -1):
			var transaction: Dictionary = record["trader_transactions"][transaction_index]
			if transaction["business_id"] == business_id:
				out.append(transaction.duplicate(true))
	return out

## Compatibility alias for existing valley callers. Ports and Traders share
## this transaction feed; new code should use get_trade_transactions.
func get_trader_transactions(business_id: int, days: int = 30) -> Array:
	return get_trade_transactions(business_id, days)

## Up to `limit` hiring/firing events for any business, newest first. A type
## filter is applied before the limit; "both" includes hires and firings.
## Returns copies so callers cannot change the stored history.
func get_business_employment_events(business_id: int, event_type: String = "both", limit: int = 50) -> Array:
	# A failed (deleted) business keeps its employment history.
	assert(businesses.has(business_id) or _employment_event_log.has(business_id), "Unknown business id %d" % business_id)
	assert(event_type in ["both", "job", "fired"], "Unknown employment event type %s" % event_type)
	var events: Array = _employment_event_log.get(business_id, [])
	var out: Array = []
	for i in range(events.size() - 1, -1, -1):
		if out.size() >= maxi(limit, 0):
			break
		var event: Dictionary = events[i]
		if event_type == "both" or event["type"] == event_type:
			out.append(event.duplicate(true))
	return out

## Up to the last `limit` blotter entries (births, emigrations, old-age
## deaths, adoptions, splits, hirings/firings, coming-of-age), oldest first -- same
## convention as get_daily_history. Pass -1 (default) for everything
## currently retained (bounded by EVENT_LOG_RETENTION_DAYS regardless). Each entry has
## at least "day" and "type" ("birth"/"emigrate"/"old_age"/"adopted"/
## "split"/"job"/"fired"/"coming_of_age"); see _log_event()'s call sites for the
## type-specific fields.
func get_event_log(limit: int = -1) -> Array:
	var start: int = 0 if limit < 0 else max(0, _event_log.size() - limit)
	var out: Array = []
	for i in range(start, _event_log.size()):
		out.append((_event_log[i] as Dictionary).duplicate(true))
	return out

## Every retained event from the last `days` simulated days, oldest first.
## Unlike get_event_log(limit), a busy event category cannot crowd another
## category out of this query merely by producing more rows.
func get_event_log_days(days: int) -> Array:
	var cutoff_day: int = day - maxi(days, 0)
	var out: Array = []
	for event in _event_log:
		if event["day"] >= cutoff_day:
			out.append((event as Dictionary).duplicate(true))
	return out

# ---------------------------------------------------------------------------
# Daily tick: pay wages (from yesterday's settled revenue) -> replenish
# buffered recipe inputs business-to-business from yesterday's closing
# stock -> produce from those inputs -> clear the market (sets today's revenue
# for TOMORROW's wages) -> trade (export surplus, including today's iron) ->
# consume -> stress/migration-pressure (weekly) -> emigration, old age, then
# aging/births (all monthly, and all ACT) -> business capacity self-tuning +
# labor reallocation (weekly) -> publish.
# ---------------------------------------------------------------------------

func _daily_tick() -> void:
	_record_price_history()
	_reset_household_daily_records()
	# A good with no trade today must not keep showing an older clearing after
	# its export checkbox is disabled or its seller runs out of stock.
	for market in markets.values():
		(market as HEMarket).last_clearing.clear()
		(market as HEMarket).clear_daily_export()
	var record := _new_daily_record()
	if intertown_trading_enabled:
		for business in businesses.values():
			var trader_business: HEBusiness = business
			if trader_business.kind == HEBusiness.Kind.TRADER:
				trader_business.last_exported = {}
				trader_business.last_imported = {}
		record["trader_transactions"].append_array(_pending_valley_transactions)
		_pending_valley_transactions.clear()
	for business in businesses.values():
		var trade_business: HEBusiness = business
		if trade_business.kind == HEBusiness.Kind.PORT:
			trade_business.last_exported = {}
			trade_business.last_imported = {}
			trade_business.last_actual_units = 0.0
			trade_business.last_planned_units = float(_business_employed_worker_count(trade_business.id)) * TRADER_CAPACITY_PER_WORKER
	wages.pay_wages(record)
	_begin_funded_demand_cache()
	_run_input_purchasing(record)
	_run_tool_purchasing(record)
	_end_funded_demand_cache()
	_run_livestock_purchasing(record)
	_run_production(record)
	_run_tool_wear(record)
	_run_market(record)
	_register_business_only_offers()
	_run_warehouse_orders(record)
	_run_port_trade(record)
	_run_water_maintenance(record)
	_run_house_maintenance(record)
	_apply_price_signals()
	for market in markets.values():
		(market as HEMarket).record_supply_demand_history()
	_record_business_revenue_history()
	_run_consumption(record)
	_run_water_need(record)
	if (day + 1) % HERD_EVAL_INTERVAL_DAYS == 0:
		_run_herds(record)
	# After herd production, so a review's wool and culled head land in the day
	# they were made (and in its stock change), not in a row already closed.
	_close_business_ledgers()
	if (day + 1) % MIGRATION_PRESSURE_EVAL_INTERVAL_DAYS == 0:
		_evaluate_migration_pressure()
	if (day + 1) % EMIGRATION_EVAL_INTERVAL_DAYS == 0:
		_evaluate_emigration(record)
		_evaluate_old_age(record)
		_evaluate_life_cycle(record)
	if (day + 1) % CAPACITY_EVAL_INTERVAL_DAYS == 0:
		_evaluate_business_capacity(record)
		_reconcile_employment(record)
	# Emigration, old age, adoption and coming-of-age splits add and remove
	# households; whoever is new or freed a house is (re)housed before the day
	# closes, so every report between ticks reads current assignments.
	_reconcile_all_housing()
	_finalize_daily_record(record)

func _reset_household_daily_records() -> void:
	for household_id in households.keys():
		var h: HEHousehold = households[household_id]
		h.last_need_required = {}
		h.last_need_provided = {}
		h.last_consumed = {}
		h.last_unmet_scarcity = {}
		h.last_unmet_unaffordable = {}

func _new_daily_record() -> Dictionary:
	return {
		"day": day,
		"opening_stock": _total_stock_snapshot(),
		"opening_money": _total_money(),
		"produced": {},
		"consumed": {},
		"unmet_scarcity": {},
		"unmet_unaffordable": {},
		# need id -> {required, provided, met_by: {good name: need units},
		# households_met, households_unmet} -- see _consume_need.
		"needs": {},
		# The same need totals split by settlement: settlement id -> need id -> {required, provided}.
		"needs_by_settlement": {},
		"traded_quantity": {},
		"exported": {},
		"export_revenue": 0.0,
		"imported": {},
		"import_cost": 0.0,
		"trader_transactions": [],
		# Local Butcher purchases of culled livestock, one entry per ranch sale
		# (the Trader's livestock exports are in trader_transactions), and the
		# day's offered/requested/bought/exported head per livestock good --
		# see _run_livestock_purchasing. What the Goods page reads for cattle and sheep.
		"livestock_transactions": [],
		"livestock_market": {},
		"wages_paid": {},
		"emigrations": 0,
		"old_age_deaths": 0,
		"money_written_off": 0.0,
		"goods_written_off": {},
		"births": 0,
		"worker_promotions": 0,
		"capacity_changes": {},
		# settlement id -> {visits, timber_used, stone_used, overdue_houses,
		# backlog_years, households_overdue, stone_bonus_lost}: see _run_house_maintenance.
		"maintenance": {},
	}

func _finalize_daily_record(record: Dictionary) -> void:
	record["closing_stock"] = _total_stock_snapshot()
	record["closing_money"] = _total_money()
	record["population"] = _total_population()
	record["households"] = households.size()
	record["unemployed_households"] = _unemployed_household_count()
	_history.append(record)
	if _history.size() > HISTORY_MAX_DAYS:
		_history.pop_front()

## A business that has used up its whole credit line (the wage floor, see
## WAGE_NEGATIVE_BALANCE_FLOOR_DAYS) fails outright: it is deleted, its
## employees go back to the unemployed pool, and its debt and leftover stock
## are written off through the same closed-economy accounting households use
## (money_written_off / goods_written_off). There is deliberately no revival
## path -- a failed business stays gone, and recreating one is the player's
## job (see add_business). A business may sit at zero workers indefinitely;
## only running out of credit kills it.
func _fail_business(business_id: int, record: Dictionary) -> void:
	var b: HEBusiness = businesses[business_id]
	var laid_off := 0
	for household_id in (_employment_index().get(business_id, []) as Array).duplicate():
		(households[household_id] as HEHousehold).employer_business_id = -1
		laid_off += 1
	var goods_written_off: Dictionary[Commodity.Type, float] = {}
	for c in inventory_goods():
		var amount := b.stock(c)
		if amount > 0.0:
			goods_written_off[c] = amount
			_goods_written_off_total[c] = _goods_written_off_total.get(c, 0.0) + amount
	_money_written_off_total += b.balance
	_money_written_off_by_cause["business_failure"] = float(_money_written_off_by_cause.get("business_failure", 0.0)) + b.balance
	record["money_written_off"] = float(record.get("money_written_off", 0.0)) + b.balance
	_merge_goods_written_off(record, goods_written_off)
	_log_event("business_failed", {
		"business_id": business_id,
		"name": b.name,
		"settlement_id": b.settlement_id,
		"debt": -b.balance,
		"households_laid_off": laid_off,
	})
	(settlements[b.settlement_id] as HESettlement).business_ids.erase(business_id)
	businesses.erase(business_id)

## Kind.HERD only, called from HEWages.pay_wages before its cash allowance is
## computed: if this ranch can't cover today's wage bill even with its
## generous negative-balance allowance, slaughter enough of its own live herd
## at home to cover the gap in meat, which then sells on the local market --
## see HOME_BUTCHER_MEAT_PER_HEAD/HARDSHIP_BUTCHER_MIN_HERD's doc comment
## for why. No money is created here: the meat is "produced" into the ranch's
## inventory (like a sheep farm's wool) and the cash arrives only when
## households buy it in _clear_market_for.
func _hardship_butcher_if_needed(b: HEBusiness, cash_shortfall: float, record: Dictionary) -> void:
	b.last_hardship_butchered = 0.0
	if cash_shortfall <= 0.0001:
		return
	if b.species == HEBusiness.Species.SHEEP:
		# Sheep's ordinary income (wool) comes from a LIVE herd -- unlike
		# cattle, whose only realization event ever was culling the herd
		# either way, selling off sheep early to cover a temporary cash dip
		# would cannibalize the very wool income that was already on track
		# to recover it, a self-reinforcing spiral verified in testing (herd
		# crashed toward its floor and never recovered). Sheep just rides
		# out the dip on the normal WAGE_NEGATIVE_BALANCE_FLOOR_DAYS
		# allowance instead, same as any non-herd business would.
		return
	var meat := Commodity.Type.MEAT
	var meat_price: float = (markets[b.settlement_id] as HEMarket).price[meat]
	var meat_per_head: float = HOME_BUTCHER_MEAT_PER_HEAD[b.species]
	var head_value: float = meat_per_head * meat_price
	if head_value <= 0.0:
		return
	# Meat already on the shelf from an earlier slaughter is income that is
	# still on its way: don't slaughter more until it stops covering the gap.
	if b.stock(meat) * meat_price >= cash_shortfall:
		return
	var available_head: float = max(0.0, b.herd_size - HARDSHIP_BUTCHER_MIN_HERD[b.species])
	# Whole animals only, rounded UP: the shortfall is just today's unpaid
	# wage (cents), so rounding down would never slaughter anything and the
	# ranch would sit past its wage floor paying nobody. One head's meat then
	# sells over the following days and funds their wages, so this fires
	# roughly once per (head value / daily wage) days, not daily.
	var butchered: float = min(floorf(available_head), ceilf((cash_shortfall - b.stock(meat) * meat_price) / head_value))
	if butchered < 1.0:
		return
	b.herd_size -= butchered
	var meat_made: float = butchered * meat_per_head
	b.add_stock(meat, meat_made)
	b.last_hardship_butchered = butchered
	# The crew's time goes into the carcasses instead of husbandry.
	var worker_days: float = butchered * BUTCHERY_WORKER_DAYS_PER_HEAD[b.species] * HOME_BUTCHER_WORK_MULTIPLIER
	b.care_worker_days -= worker_days
	# Booked as production, like a sheep farm's wool: it appears in the
	# ranch's inventory from nothing (the animal was herd_size, not inventory,
	# so no CATTLE stock is consumed), and leaves it again when households buy
	# it, which keeps run_household_economy.gd's stock reconciliation exact.
	_accumulate(record["produced"], Commodity.name_of(meat), meat_made)
	_log_herd_event(b, "hardship_butcher", {
		"business_id": b.id, "head": butchered, "meat": meat_made,
		"worker_days": worker_days, "shortfall": cash_shortfall, "herd_after": b.herd_size,
	})

## Whether a ranch's culled `commodity` animals have anywhere to go in
## `settlement_id`: a staffed Trader that has this good's export enabled takes
## them raw, a staffed Butcher buys them. With neither, the ranch has to butcher
## its own cull (_butcher_stock_at_home).
func _livestock_has_outlet(settlement_id: int, commodity: Commodity.Type) -> bool:
	for business_id in businesses.keys():
		var other: HEBusiness = businesses[business_id]
		if other.settlement_id != settlement_id or _business_employed_worker_count(business_id) <= 0:
			continue
		if other.processes_livestock:
			return true
		if other.kind == HEBusiness.Kind.PORT:
			return true
		if intertown_trading_enabled and other.kind == HEBusiness.Kind.TRADER and _trader_export_enabled[business_id].get(commodity, false):
			return true
	return false

## Kind.HERD only: butchers up to `head` of the ranch's culled livestock
## inventory at home, with the same poor yield and extra work as a hardship
## slaughter (HOME_BUTCHER_MEAT_PER_HEAD / HOME_BUTCHER_WORK_MULTIPLIER). The
## animals leave inventory (booked as consumed, like the Butcher's input) and
## the meat enters it (booked as produced), to sell on the local market. A
## ranch's inventory never holds livestock for long: _run_herds sends a cull
## here straight away when there is no outlet, and clears whatever an outlet
## did not take by the next cull.
func _butcher_stock_at_home(b: HEBusiness, head: float, record: Dictionary) -> void:
	var livestock := b.herd_commodity()
	head = minf(head, b.stock(livestock))
	if head <= 0.0001:
		return
	var meat_made: float = head * HOME_BUTCHER_MEAT_PER_HEAD[b.species]
	b.consume(livestock, head)
	b.add_flow(HEBusiness.FLOW_CONSUMED, livestock, head)
	var animal_name := Commodity.name_of(livestock)
	record["consumed"][animal_name] = record["consumed"].get(animal_name, 0.0) + head
	b.add_stock(Commodity.Type.MEAT, meat_made)
	_accumulate(record["produced"], Commodity.name_of(Commodity.Type.MEAT), meat_made)
	# The crew's time goes into the carcasses instead of husbandry; it is
	# charged against the next review's care, which this cull has just reset.
	var worker_days: float = head * BUTCHERY_WORKER_DAYS_PER_HEAD[b.species] * HOME_BUTCHER_WORK_MULTIPLIER
	b.care_worker_days -= worker_days
	_log_herd_event(b, "home_butcher", {
		"business_id": b.id, "head": head, "meat": meat_made,
		"worker_days": worker_days, "herd_after": b.herd_size,
	})

## Each PRODUCTION business produces its one recipe output using however
## many workers it currently has (derived live from household
## employer_business_id, not cached). A field-model business (Farm,
## Woodlot -- see HEBusiness.configure_land) grows toward a lumpy harvest
## instead (see _run_field_growth); anything else keeps the original
## instant-output-from-recipe behavior, scaled by last_input_fulfillment_
## ratio (1.0 -- i.e. no change at all -- for a business with empty
## recipe.inputs like Farm/Woodlot; see _run_input_purchasing, which runs
## earlier this same tick and sets that ratio). The Trader has no recipe;
## see _run_trade for what it does instead.
func _run_production(record: Dictionary) -> void:
	for business_id in businesses.keys():
		var b: HEBusiness = businesses[business_id]
		if b.kind == HEBusiness.Kind.HERD:
			# Husbandry accrues daily; _run_herds turns it into a care
			# fraction at the next review (HERD_LABOR_PER_HEAD_PER_DAY).
			b.care_worker_days += _business_effective_worker_count(business_id) * _tool_productivity(b)
			continue
		if b.kind != HEBusiness.Kind.PRODUCTION:
			continue
		if b.uses_field_model():
			_run_field_growth(b, record)
			continue
		if b.processes_livestock:
			_run_butchery(b, record)
			continue
		var employed := _business_effective_worker_count(business_id)
		var output_commodity := b.output_commodity()
		var rate: float = b.recipe.outputs[output_commodity]
		var planned: float = employed * rate * _tool_productivity(b)
		var units: float = planned * b.last_input_fulfillment_ratio
		for input_commodity in b.recipe.inputs.keys():
			if b.need_inputs.has(input_commodity):
				_burn_need_input(b, input_commodity, units * b.recipe.inputs[input_commodity], record)
				continue
			var consumed: float = units * b.recipe.inputs[input_commodity]
			b.consume(input_commodity, consumed)
			b.add_flow(HEBusiness.FLOW_CONSUMED, input_commodity, consumed)
			var input_name := Commodity.name_of(input_commodity)
			record["consumed"][input_name] = record["consumed"].get(input_name, 0.0) + consumed
			# Capacity tuning should recognize input cost when the buffered
			# good is USED, while cash changes when it is purchased. Charging
			# a whole buffer refill against one day's revenue would make a
			# sound business look catastrophically unprofitable that week.
			b.last_revenue -= consumed * (markets[b.settlement_id] as HEMarket).price[input_commodity]
		b.add_stock(output_commodity, units)
		b.last_planned_units = planned
		b.last_actual_units = units
		b.last_output_produced = {output_commodity: units}
		var name := Commodity.name_of(output_commodity)
		record["produced"][name] = record["produced"].get(name, 0.0) + units

## The output multiplier `b` gets from the tools it holds today: 1.0 unless
## industrial tools are on, `b` uses tools, and its town has a seller of tools
## (without one there is no tools economy to be short of). See
## HEBusiness.tool_productivity.
func _tool_productivity(b: HEBusiness) -> float:
	if not b.uses_tools() or not _tools_in_play(b.settlement_id):
		return 1.0
	return b.tool_productivity(_business_employed_worker_count(b.id))

func _tools_in_play(settlement_id: int) -> bool:
	return _business_selling(settlement_id, Commodity.Type.TOOLS) != null

## What a tool-using business is short of (target stock minus held) and how
## much of that it asks the seller for today. Shared by purchasing and the
## market view so the Buyers list shows the request purchasing actually makes.
func _tool_request(buyer: HEBusiness, employed: int) -> Dictionary:
	var target: float = float(employed) * (buyer.tools_per_worker + buyer.tool_wear_per_worker_day * PRODUCTION_INPUT_BUFFER_DAYS)
	var shortfall: float = maxf(0.0, target - buyer.stock(Commodity.Type.TOOLS))
	var daily_wear: float = float(employed) * buyer.tool_wear_per_worker_day
	return {"shortfall": shortfall,
		"requested": minf(shortfall, maxf(daily_wear * TARGET_BUFFER_DAYS, shortfall * TOOL_FILL_FRACTION_PER_DAY))}

## Tool-using businesses top their tools up to one per worker plus a buffer of
## wear (PRODUCTION_INPUT_BUFFER_DAYS), buying from the town's tool seller out
## of the same paced offer households draw on (_business_offer -- no reserve for
## households, no Trader import: with no local seller there is no tools economy).
## It runs after recipe inputs so a cash-short business pays for what it
## consumes first, and a missing tool only lowers productivity -- it never
## enters last_input_fulfillment_ratio.
func _run_tool_purchasing(record: Dictionary) -> void:
	var tools := Commodity.Type.TOOLS
	var ids: Array = businesses.keys()
	ids.sort()
	for business_id in ids:
		var buyer: HEBusiness = businesses[business_id]
		if not buyer.uses_tools() or not _tools_in_play(buyer.settlement_id):
			continue
		var employed := _business_employed_worker_count(business_id)
		if employed <= 0:
			continue
		var ask := _tool_request(buyer, employed)
		var shortfall: float = ask["shortfall"]
		if shortfall <= 0.0001:
			continue
		var requested: float = ask["requested"]
		var daily_wear: float = float(employed) * buyer.tool_wear_per_worker_day
		var price: float = (markets[buyer.settlement_id] as HEMarket).price[tools]
		var offer := _business_offer(buyer.settlement_id, tools, {}, false, requested)
		var budget := _input_budget(buyer, employed, daily_wear * price)
		var affordable_ratio: float = clampf(budget / (requested * price), 0.0, 1.0) if price > 0.0 else 1.0
		var purchase_ratio := minf(minf(requested, offer) / requested, affordable_ratio)
		var signal_today := _price_signal_entry(buyer.settlement_id, tools)
		signal_today["funded_business"] += requested * affordable_ratio
		signal_today["business_buffer_request"] += shortfall * affordable_ratio
		if purchase_ratio > 0.0:
			_settle_purchase(buyer, buyer, tools, requested, requested * purchase_ratio, requested * affordable_ratio, record, {})

## Daily wear: each tool-using business loses tool_wear_per_worker_day per
## employed worker from its held tools, booked as consumed goods and charged
## against its revenue at the market price like any other consumed input, so
## capacity tuning sees the cost as the tool is used up. Runs after production,
## which used today's opening stock.
func _run_tool_wear(record: Dictionary) -> void:
	for business_id in businesses.keys():
		var b: HEBusiness = businesses[business_id]
		if not b.uses_tools() or not _tools_in_play(b.settlement_id):
			continue
		var employed := _business_employed_worker_count(business_id)
		if employed <= 0:
			continue
		var worn: float = b.consume(Commodity.Type.TOOLS, float(employed) * b.tool_wear_per_worker_day)
		if worn <= 0.0:
			continue
		b.add_flow(HEBusiness.FLOW_CONSUMED, Commodity.Type.TOOLS, worn)
		var tools_name := Commodity.name_of(Commodity.Type.TOOLS)
		record["consumed"][tools_name] = record["consumed"].get(tools_name, 0.0) + worn
		b.last_revenue -= worn * (markets[b.settlement_id] as HEMarket).price[Commodity.Type.TOOLS]

## Production's use of a need-input slot (HEBusiness.need_inputs): `quantity`
## is in units of the recipe's own input commodity; it is spent from whichever
## satisfiers the business holds, densest first, and booked at each one's own
## price like any other consumed input.
func _burn_need_input(b: HEBusiness, input_commodity: Commodity.Type, quantity: float, record: Dictionary) -> void:
	var need := HENeeds.get_need(b.need_inputs[input_commodity])
	var burn := need.burn(b, quantity * need.value_of(input_commodity))
	for satisfier in burn["burned"].keys():
		var burned_units: float = burn["burned"][satisfier]
		var satisfier_name := Commodity.name_of(satisfier)
		record["consumed"][satisfier_name] = record["consumed"].get(satisfier_name, 0.0) + burned_units
		b.add_flow(HEBusiness.FLOW_CONSUMED, satisfier, burned_units)
		b.last_revenue -= burned_units * (markets[b.settlement_id] as HEMarket).price[satisfier]

## One day of growth for every field of a land-based business: today's
## employed workers are split across ALL of its fields proportional to
## area (every field is always "growing" -- a harvested field is replanted
## the same day, see below -- so there's never an idle field to exclude).
## A field that reaches growth_days is harvested: its yield is area *
## yield_per_area, scaled down by how much of the labor it actually needed
## over the whole cycle (area * labor_per_area_per_day * growth_days) it
## actually got -- understaffing a field for its whole cycle directly
## shrinks that harvest, exactly like the old per-day rate did, just
## resolved once per cycle instead of continuously. The field then
## replants immediately (days_growing/labor_applied reset to 0) rather than
## sitting idle, so total planted area is constant every day by
## construction. last_planned_units/last_actual_units/last_output_produced
## are 0.0 on every non-harvest day -- lumpy, not smoothed -- which is the
## whole point of a harvest cycle over a flat daily rate.
func _run_field_growth(b: HEBusiness, record: Dictionary) -> void:
	var effective_workers := _business_effective_worker_count(b.id) * _tool_productivity(b)
	var output_commodity := b.output_commodity()
	var harvested := 0.0
	for f in b.fields:
		var share: float = effective_workers * (f.area / b.land_area_acres) if b.land_area_acres > 0.0 else 0.0
		f.labor_applied += share
		f.days_growing += 1
		if f.days_growing < b.growth_days:
			continue
		var labor_required: float = f.area * b.labor_per_area_per_day * b.growth_days
		var efficiency: float = clampf(f.labor_applied / labor_required, 0.0, 1.0) if labor_required > 0.0 else 0.0
		harvested += f.area * b.yield_per_area * efficiency * seasonal_yield_scale(output_commodity, day)
		f.days_growing = 0
		f.labor_applied = 0.0
	b.add_stock(output_commodity, harvested)
	b.last_planned_units = effective_workers
	b.last_actual_units = harvested
	b.last_output_produced = {output_commodity: harvested}
	var name := Commodity.name_of(output_commodity)
	record["produced"][name] = record["produced"].get(name, 0.0) + harvested

## Once per day, after both the local market and trade have settled today's
## last_revenue for every business: append revenue-per-employed-worker to
## each business's rolling history (see HEBusiness.record_revenue_per_worker_
## day), the signal _evaluate_business_capacity compares against the
## reference wage. Recorded every day regardless of whether anyone's
## employed (0.0 in that case) so the rolling window always spans real
## calendar days, which matters for a field-model business whose window is
## its own multi-month crop cycle. Also the once-a-day hook for
## HEBusiness.record_balance_day() -- a pure reporting aid, unrelated to the
## revenue-per-worker signal, that just rides along on this same per-
## business daily pass rather than getting one of its own.
func _record_business_revenue_history() -> void:
	for business_id in businesses.keys():
		var b: HEBusiness = businesses[business_id]
		var employed := _business_employed_worker_count(business_id)
		# Revenue that lands on a day with nobody employed is still the
		# payoff of earlier staffed work (a harvest sells a crop, and a cull
		# sells animals, that a crew raised while on the payroll). Recording
		# it as 0.0 per worker made lumpy businesses read as unprofitable
		# exactly when a payoff arrived, and the tuner then kept the crew
		# out. Count it against a crew of at least one.
		var revenue_per_worker: float = b.last_revenue / maxi(employed, 1)
		b.record_revenue_per_worker_day(revenue_per_worker)
		b.record_balance_day()
		b.record_flow_day()

## Closes every business's operating-ledger row for the day (see HEBusiness's
## ledger_*). One reference wage per settlement per day.
func _close_business_ledgers() -> void:
	var wage_by_settlement := {}
	for business_id in businesses.keys():
		var b: HEBusiness = businesses[business_id]
		if not wage_by_settlement.has(b.settlement_id):
			wage_by_settlement[b.settlement_id] = wages.reference_wage_per_worker(b.settlement_id)
		_close_business_ledger(b, wage_by_settlement[b.settlement_id])

## Finishes today's operating ledger row (see HEBusiness.ledger_*): physical
## units sold/produced of the business's own outputs, and its stock valued at
## closing local prices (a ranch's culled animals at what the Trader would pay).
func _close_business_ledger(b: HEBusiness, reference_wage: float) -> void:
	var outputs: Array = _business_output_commodities(b)
	var prices: Dictionary = {}
	for c in (markets[b.settlement_id] as HEMarket).price.keys():
		prices[c] = (markets[b.settlement_id] as HEMarket).price[c]
	# Live animals have no household market, so they are valued by who holds them:
	# a Butcher at what it pays a ranch (so the head it holds and uses are neither
	# free nor marked to a price it never sees), a ranch at what the Trader pays.
	for species in BUTCHERY_SPECIES_ORDER:
		var held_quote := LivestockQuote.BUTCHER_PURCHASE if b.processes_livestock else LivestockQuote.TRADER_BID
		prices[HEBusiness.livestock_commodity(species)] = livestock_quote(species, held_quote)
	var sold := 0.0
	var produced := 0.0
	for c in outputs:
		sold += float((b.todays_flows.get(HEBusiness.FLOW_SOLD, {}) as Dictionary).get(c, 0.0))
	# Production by good: a recipe or harvest sets last_output_produced daily; a
	# herd's wool and culled head exist only on its review day.
	var made: Dictionary = b.last_output_produced.duplicate()
	if b.kind == HEBusiness.Kind.HERD:
		made = {}
		if (day + 1) % HERD_EVAL_INTERVAL_DAYS == 0:
			for c in b.last_culled.keys():
				made[c] = float(b.last_culled[c])
			if b.species == HEBusiness.Species.SHEEP:
				made[Commodity.Type.WOOL] = b.last_wool_produced
	for c in made.keys():
		b.ledger_add_good("produced", c, float(made[c]))
		produced += float(made[c])
	if b.kind == HEBusiness.Kind.TRADER or b.kind == HEBusiness.Kind.PORT:
		for c in b.last_exported.keys():
			sold += b.last_exported[c]
		for c in b.last_imported.keys():
			sold += b.last_imported[c]
	b.ledger_today["reference_wage"] = reference_wage
	b.close_ledger_day(prices, outputs, sold, produced)

## The goods this business makes and sells (empty for a Trader or government).
func _business_output_commodities(b: HEBusiness) -> Array:
	if b.kind == HEBusiness.Kind.PRODUCTION and b.recipe != null:
		return b.recipe.outputs.keys()
	if b.kind == HEBusiness.Kind.HERD:
		var out: Array = [b.herd_commodity()]
		if b.species == HEBusiness.Species.SHEEP:
			out.append(Commodity.Type.WOOL)
		return out
	return []

## One person's daily use of `commodity` lives in HENeeds, so a household's
## need and the reference wage's cost of living can never drift apart.
## `commodity` is expressed as if it were the need's only source; goods that
## satisfy no need return 0.
func _daily_need(h: HEHousehold, commodity: Commodity.Type) -> float:
	var need := HENeeds.for_commodity(commodity)
	return float(h.headcount()) * HENeeds.units_per_person_daily(commodity) * (h.need_scale(need) if need != null else 1.0)

## Whether `need` is part of this settlement's economy at all: always, unless
## the need can only be met by a dedicated business (HENeed.needs_seller) and
## the settlement has none. Judged by the business existing, not by today's
## stock, so a Toolsmith's momentary sell-out doesn't flip the cost of living.
func _need_served(settlement_id: int, need: HENeed) -> bool:
	return not need.needs_seller or _business_selling(settlement_id, need.baseline) != null

## Days until `b`'s next supply arrives (a harvest, or a herd review): the
## stretch its current stock has to cover. A herd has no fields to count down, so
## this is the real countdown to the shared review tick -- not the whole cycle
## HEBusiness.days_until_next_harvest() reports for it. A seller whose output is
## instant restocks tomorrow, so one day.
func _days_until_next_supply(b: HEBusiness) -> int:
	if b.kind == HEBusiness.Kind.HERD:
		return maxi(1, (HERD_EVAL_INTERVAL_DAYS - ((day + 1) % HERD_EVAL_INTERVAL_DAYS)) % HERD_EVAL_INTERVAL_DAYS)
	if b.has_long_cycle():
		return maxi(1, b.days_until_next_harvest())
	return 1

## What `_clear_market_for` puts on offer to households today: local seller
## stock paced over its harvest cycle, plus delivered Trader stock in a valley.
func _household_offer(settlement_id: int, commodity: Commodity.Type) -> float:
	var seller := _business_selling(settlement_id, commodity)
	var local_offer := 0.0
	if seller != null:
		var stock := seller.stock(commodity)
		# A ranch's home-butchered meat goes straight on sale.
		var home_butchered: bool = seller.kind == HEBusiness.Kind.HERD and commodity == Commodity.Type.MEAT
		if seller.has_long_cycle() and not home_butchered:
			var days_until: int = _days_until_next_supply(seller)
			local_offer = minf(stock, stock / float(days_until) * SELL_PACE_HEADROOM)
		else:
			local_offer = stock
	if intertown_trading_enabled:
		var trader := _settlement_trader(settlement_id)
		if trader != null:
			local_offer += maxf(0.0, trader.stock(commodity) - _valley_reserved_stock.get(commodity, 0.0))
	return local_offer

## What a business buyer can actually get of `commodity` today. A local seller
## shares its paced offer with households pro rata (_b2b_offer, sized by the
## buyer's `claim`); there is no household reserve. With no local seller,
## `allow_import` lets the settlement's Trader supply it from outside out of its
## shared per-day import capacity (initialised lazily into
## `trader_import_capacity`, keyed by trader id).
func _business_offer(settlement_id: int, commodity: Commodity.Type, trader_import_capacity: Dictionary, allow_import: bool, claim: float) -> float:
	var seller := _business_selling(settlement_id, commodity)
	if seller != null:
		var local_offer := _b2b_offer(seller, settlement_id, commodity, claim)
		if local_offer > 0.0001:
			return local_offer
		if not intertown_trading_enabled:
			return 0.0
	if intertown_trading_enabled:
		var trader := _settlement_trader(settlement_id)
		if trader != null:
			var valley_stock := maxf(0.0, trader.stock(commodity) - _valley_reserved_stock.get(commodity, 0.0))
			if valley_stock > 0.0001:
				return valley_stock
	var port := _settlement_port(settlement_id)
	if not allow_import or port == null:
		return 0.0
	if not trader_import_capacity.has(port.id):
		var already_imported := 0.0
		for imported in port.last_imported.values():
			already_imported += float(imported)
		trader_import_capacity[port.id] = maxf(0.0,
			float(_business_employed_worker_count(port.id)) * TRADER_CAPACITY_PER_WORKER - already_imported)
	return trader_import_capacity[port.id]

## The satisfiers a buyer can actually draw on today, cheapest per need-unit
## first. `offers` maps a satisfier to how much of it THIS kind of buyer can
## obtain (_household_offer or _business_offer). The baseline is always
## listed, even with nothing on offer, so a shortfall still lands on it; any
## other satisfier is listed only if something can really be bought.
## Near-ties (within a hundredth of a cent) go to the baseline, so a
## settlement with no real alternative behaves exactly as if the baseline
## were the only option. This is the single seam for how buyers choose
## between substitutes.
func _satisfier_cascade(settlement_id: int, need: HENeed, offers: Callable, comfort_first: bool = false) -> Array[Commodity.Type]:
	var cascade: Array[Commodity.Type] = []
	for c in need.satisfiers():
		if c == need.baseline or offers.call(c) > 0.0001:
			cascade.append(c)
	if cascade.size() > 1:
		var local_market: HEMarket = markets[settlement_id]
		cascade.sort_custom(func(a: Commodity.Type, b: Commodity.Type) -> bool:
			# Households clear comfort goods first: a household that prefers one
			# asks it first and falls back to the staples for what it could not get.
			if comfort_first and (need.comfort_of(a) > 0.0) != (need.comfort_of(b) > 0.0):
				return need.comfort_of(a) > 0.0
			var cost_a: float = local_market.price[a] / need.value_of(a)
			var cost_b: float = local_market.price[b] / need.value_of(b)
			if absf(cost_a - cost_b) > 0.0001:
				return cost_a < cost_b
			if a == need.baseline or b == need.baseline:
				return a == need.baseline
			return need.satisfiers().find(a) < need.satisfiers().find(b))
	return cascade

func _household_cascade(settlement_id: int, need: HENeed) -> Array[Commodity.Type]:
	return _satisfier_cascade(settlement_id, need, func(c: Commodity.Type) -> float: return _household_offer(settlement_id, c), true)

func _begin_funded_demand_cache() -> void:
	_funded_demand_cache.clear()
	_funded_demand_cache_active = true

func _end_funded_demand_cache() -> void:
	_funded_demand_cache_active = false
	_funded_demand_cache.clear()

func _funded_demand_for_b2b(settlement_id: int, commodity: Commodity.Type) -> float:
	if not _funded_demand_cache_active:
		return _household_funded_demand(settlement_id, commodity)
	var settlement_cache: Dictionary = _funded_demand_cache.get(settlement_id, {})
	if settlement_cache.has(commodity):
		return settlement_cache[commodity]
	var demand := _household_funded_demand(settlement_id, commodity)
	settlement_cache[commodity] = demand
	_funded_demand_cache[settlement_id] = settlement_cache
	return demand

func _funded_demand_cache_has_need(settlement_id: int, need: HENeed) -> bool:
	var settlement_cache: Dictionary = _funded_demand_cache.get(settlement_id, {})
	for satisfier in need.satisfiers():
		if settlement_cache.has(satisfier):
			return true
	return false

func _invalidate_need_funded_demand(settlement_id: int, need: HENeed) -> void:
	if not _funded_demand_cache.has(settlement_id):
		return
	var settlement_cache: Dictionary = _funded_demand_cache[settlement_id]
	for satisfier in need.satisfiers():
		settlement_cache.erase(satisfier)
	if settlement_cache.is_empty():
		_funded_demand_cache.erase(settlement_id)
	else:
		_funded_demand_cache[settlement_id] = settlement_cache

func _finish_funded_demand_availability_check(settlement_id: int, commodity: Commodity.Type, need: HENeed, was_available: bool) -> void:
	if need == null or not _funded_demand_cache_active:
		return
	var is_available := _household_offer(settlement_id, commodity) > 0.0001
	if is_available != was_available:
		_invalidate_need_funded_demand(settlement_id, need)

## The order `_run_market` clears a settlement's household goods in: each
## need's cascade (cheapest first), then its satisfiers nobody is selling.
## Clearing in cascade order is what lets a need fall back -- a household's
## shortfall after the cheaper good clears is requested from the next one, see
## _desired_purchase. Every satisfier is still cleared each day so its market
## row, price and history stay current.
func _market_clearing_order(settlement_id: int) -> Array[Commodity.Type]:
	var order: Array[Commodity.Type] = []
	for need in HENeeds.all():
		var cascade := _household_cascade(settlement_id, need)
		order.append_array(cascade)
		for c in need.satisfiers():
			if not cascade.has(c):
				order.append(c)
	# Stone has no need, but a stone house or tenement's households buy it for
	# repairs; towns without one leave the stone market to business and export.
	if not order.has(Commodity.Type.STONE):
		for household_id in (settlements[settlement_id] as HESettlement).household_ids:
			if (households[household_id] as HEHousehold).home_upkeep_stone > 0.0:
				order.append(Commodity.Type.STONE)
				break
	return order

## How far a household's own judgement of a non-baseline satisfier's price may
## sit from the posted one, as a fraction (+-35%). Households never all agree
## that meat has just become cheaper than grain: without this, every
## household switches on the same day the price crosses parity, and demand for
## the substitute swings from everyone to no one as the price drifts back and
## forth over it. With it, demand shifts gradually across the range.
const HOUSEHOLD_TASTE_SPREAD := 0.35

## Affluence: how far above subsistence a household's savings sit, from 0
## (comfort goods judged at their posted price, like anything else) to 1 (they
## look AFFLUENCE_PRICE_TOLERANCE cheaper). Measured in days of a basic basket
## for the household, priced at BASE_PRICE so it does not swing with the market.
const AFFLUENCE_MIN_DAYS := 60.0
const AFFLUENCE_FULL_DAYS := 240.0
const AFFLUENCE_PRICE_TOLERANCE := 0.75

## One person's daily basic basket (every need that needs no dedicated seller,
## via its baseline satisfier) at base prices.
static func basket_cost_per_person() -> float:
	var total := 0.0
	for need in HENeeds.all():
		if not need.needs_seller:
			total += need.per_person_daily * BASE_PRICE[need.baseline] / need.value_of(need.baseline)
	return total

## 0..1: see AFFLUENCE_MIN_DAYS.
func _household_affluence(h: HEHousehold) -> float:
	var basket := basket_cost_per_person() * float(maxi(h.headcount(), 1))
	return smoothstep(AFFLUENCE_MIN_DAYS, AFFLUENCE_FULL_DAYS, h.balance / basket)

## A household's fixed, deterministic taste in [-1, 1) -- derived from its id
## rather than drawn from the sim's RNG, so it neither perturbs other random
## draws nor changes between runs.
func _household_taste(h: HEHousehold) -> float:
	return float((h.id * 2654435761) % 1000) / 500.0 - 1.0

## The member of `cascade` this household would reach for first: the lowest
## price per need-unit as the household judges it, i.e. every non-baseline
## satisfier's posted price scaled by its taste (`_household_taste`). Near-ties
## go to the baseline, as in _satisfier_cascade. With a taste of 0 this is just
## the cheapest posted satisfier, the cascade's first entry.
func _household_favourite(h: HEHousehold, need: HENeed, cascade: Array[Commodity.Type]) -> Commodity.Type:
	var local_market: HEMarket = markets[h.settlement_id]
	var taste := _household_taste(h) * HOUSEHOLD_TASTE_SPREAD
	var affluence := _household_affluence(h) if not need.comfort.is_empty() else 0.0
	var best := need.baseline
	var best_cost: float = local_market.price[best] / need.value_of(best)
	for c in cascade:
		if c == need.baseline:
			continue
		var cost: float = local_market.price[c] / need.value_of(c) * (1.0 + taste)
		if need.comfort_of(c) > 0.0:
			cost *= 1.0 - AFFLUENCE_PRICE_TOLERANCE * affluence
		if cost < best_cost - 0.0001:
			best = c
			best_cost = cost
	return best

## How much of `commodity` a household asks for today. The buffer is
## measured in the need's units across every satisfier already held --
## including whatever it bought earlier in today's clearing -- and the shortfall
## is requested from `commodity` only if it is one of the satisfiers actually
## on offer. A need with several satisfiers is cleared cheapest-first, so the
## cheaper good takes what it can and the next one is asked for the rest
## instead of the household going without when the cheaper good runs short.
func _desired_purchase(h: HEHousehold, commodity: Commodity.Type, shared_cascade: Array[Commodity.Type] = []) -> float:
	# Goods the household needs in hand for its house's next repair visit
	# (timber, and stone for a stone house or tenement): bought like any other
	# good, whatever the household uses the same good for otherwise.
	var upkeep := h.upkeep_slice(commodity)
	var need := HENeeds.for_commodity(commodity)
	if need == null or not _need_served(h.settlement_id, need):
		return maxf(0.0, upkeep - h.stock(commodity))
	if need.unit_values.size() > 1:
		# Households clear a need's satisfiers in cascade order (cheapest posted
		# first). Each reaches for its own favourite (see _household_favourite)
		# and anything after it in that order as a fallback; goods that clear
		# BEFORE the favourite are skipped, so a household that finds meat
		# dearer than posted keeps buying grain until meat is clearly cheaper.
		var cascade := shared_cascade if not shared_cascade.is_empty() else _household_cascade(h.settlement_id, need)
		if not cascade.has(commodity):
			return maxf(0.0, upkeep - h.stock(commodity))
		if cascade.find(commodity) < cascade.find(_household_favourite(h, need, cascade)):
			return maxf(0.0, upkeep - h.stock(commodity))
	var target := float(h.headcount()) * need.per_person_daily * h.need_scale(need) * TARGET_BUFFER_DAYS + upkeep * need.value_of(commodity)
	return maxf(0.0, target - need.held(h)) / need.value_of(commodity)

## A household whose need shortfall is below this counts as having met it.
const NEED_MET_EPSILON := 0.0001

## Today's picture of one need across the settlement, for the Needs detail
## view: how many households met or missed it, the stress and emigration
## risk among them, the demand met by each satisfier (need units) versus the
## demand left unmet, plus `days` of daily history. Only needs flagged
## drives_lifecycle (food) feed stress and emigration -- check
## "drives_lifecycle" before presenting those fields for any other need.
func get_need_detail(need_id: int, days: int = 90, settlement_id: int = -1) -> Dictionary:
	var need := HENeeds.get_need(need_id)
	assert(need != null, "Unknown need id %d" % need_id)
	var s: HESettlement = settlements[_resolve_settlement_id(settlement_id)]
	var met := 0
	var unmet := 0
	var unmet_stress_total := 0.0
	var pressure := 0
	var starving := 0
	var required := 0.0
	var provided := 0.0
	var saved := 0.0
	var met_by := {}
	for c in need.satisfiers():
		met_by[Commodity.name_of(c)] = 0.0
	if need.is_service():
		var today: Dictionary = _water_met_by.get(s.id, {})
		for source_name in WATER_SOURCE_NAMES:
			met_by[source_name] = float(today.get(source_name, 0.0))
	for household_id in s.household_ids:
		var h: HEHousehold = households[household_id]
		var h_required: float = h.last_need_required.get(need.id, 0.0)
		var h_provided: float = h.last_need_provided.get(need.id, 0.0)
		required += h_required
		provided += h_provided
		saved += float(h.headcount()) * need.per_person_daily * (1.0 - h.need_scale(need)) if h_required > 0.0 else 0.0
		for c in need.satisfiers():
			met_by[Commodity.name_of(c)] += h.last_consumed.get(c, 0.0) * need.value_of(c)
		if h_required - h_provided > NEED_MET_EPSILON:
			unmet += 1
			unmet_stress_total += h.demographics.food_stress
		else:
			met += 1
		if h.demographics.has_migration_pressure:
			pressure += 1
		if h.demographics.is_starvation_candidate():
			starving += 1

	var met_history := {}
	for c in need.satisfiers():
		met_history[Commodity.name_of(c)] = []
	if need.is_service():
		for source_name in WATER_SOURCE_NAMES:
			met_history[source_name] = []
	var unmet_history: Array = []
	var saved_history: Array = []
	for record in get_daily_history(days):
		var entry: Dictionary = record["needs"].get(need.id, {})
		saved_history.append(float(entry.get("saved", 0.0)))
		for name in met_history.keys():
			met_history[name].append(entry.get("met_by", {}).get(name, 0.0))
		unmet_history.append(maxf(0.0, entry.get("required", 0.0) - entry.get("provided", 0.0)))

	var household_count := met + unmet
	return {
		"id": need.id,
		"label": need.label,
		"drives_lifecycle": need.drives_lifecycle,
		"is_service": need.is_service(),
		"households_met": met,
		"households_unmet": unmet,
		"required": required,
		"provided": provided,
		"unmet": maxf(0.0, required - provided),
		"met_by": met_by,
		"avg_stress_unmet": (unmet_stress_total / unmet) if unmet > 0 else 0.0,
		"households_with_migration_pressure": pressure,
		"households_emigration_candidates": starving,
		"emigration_likelihood": (float(starving) / household_count) if household_count > 0 else 0.0,
		"met_history": met_history,
		"unmet_history": unmet_history,
		# Need units the households' homes spared them (a stone house's heat saving).
		"saved": saved,
		"saved_history": saved_history,
	}

## Consume owned goods -> update household stress/outcomes, purely from
## each household's OWN inventory. Only needs flagged drives_lifecycle (food)
## drive food_stress/migration-pressure/starvation-candidacy (everything
## else is tracked/reported but doesn't feed the reused stress engine,
## mirroring the pooled model's wool/tools-don't-feed-food-stress convention).
func _run_consumption(record: Dictionary) -> void:
	for household_id in households.keys():
		var h: HEHousehold = households[household_id]
		for need in HENeeds.all():
			_consume_need(h, need, record)

## The water need (HENeeds.water): in a town with at least one water source,
## every household is owed a drink per person, and the sources' working capacity
## covers that share of the town's people (the same share for every household).
## Thirst builds stress that costs health and morale. A town with no source at
## all has no water need, so nothing here runs for it.
func _run_water_need(record: Dictionary) -> void:
	var need := HENeeds.water()
	for settlement_id in settlements.keys():
		var settlement: HESettlement = settlements[settlement_id]
		var sources := 0
		var capacity := 0
		var capacity_by_name := {}
		for source_name in WATER_SOURCE_NAMES:
			capacity_by_name[source_name] = 0
		for business_id in settlement.business_ids:
			var b: HEBusiness = businesses.get(business_id)
			if b != null and b.kind == HEBusiness.Kind.WATER:
				sources += 1
				if not b.in_disrepair:
					capacity += b.water_capacity
					capacity_by_name[b.name] = int(capacity_by_name.get(b.name, 0)) + b.water_capacity
		if sources == 0:
			continue
		var population := 0
		for household_id in settlement.household_ids:
			population += (households[household_id] as HEHousehold).headcount()
		var coverage := 1.0 if population <= 0 else minf(1.0, float(capacity) / float(population))
		var need_record: Dictionary = record["needs"].get_or_add(need.id, {
			"required": 0.0, "provided": 0.0, "met_by": {}, "households_met": 0, "households_unmet": 0})
		var town_need: Dictionary = (record["needs_by_settlement"] as Dictionary).get_or_add(settlement_id, {}).get_or_add(need.id, {"required": 0.0, "provided": 0.0})
		var supplied := 0.0
		for household_id in settlement.household_ids:
			var h: HEHousehold = households[household_id]
			var needed := float(h.headcount()) * need.per_person_daily
			var provided := needed * coverage
			supplied += provided
			h.last_need_required[need.id] = needed
			h.last_need_provided[need.id] = provided
			h.record_need_stress(need, needed, provided)
			need_record["required"] += needed
			need_record["provided"] += provided
			town_need["required"] += needed
			town_need["provided"] += provided
			if needed - provided > NEED_MET_EPSILON:
				need_record["households_unmet"] += 1
			else:
				need_record["households_met"] += 1
		# What was supplied came from the working sources, in proportion to what
		# each kind can give.
		var met_by_today := {}
		for source_name in capacity_by_name:
			var share: float = supplied * float(capacity_by_name[source_name]) / float(capacity) if capacity > 0 else 0.0
			met_by_today[source_name] = share
			need_record["met_by"][source_name] = float(need_record["met_by"].get(source_name, 0.0)) + share
		_water_met_by[settlement_id] = met_by_today

## One need for one household: spend satisfiers densest-first until the need
## is met. A shortfall is reported against the need's baseline satisfier, in
## that good's units. The household's record is the need's own outcome
## (required and provided, in need units) plus what each satisfier spent.
func _consume_need(h: HEHousehold, need: HENeed, record: Dictionary) -> void:
	var full_need := float(h.headcount()) * need.per_person_daily
	var needed := full_need * h.need_scale(need)
	var result := need.burn(h, needed)
	var provided: float = result["provided"]
	var burned: Dictionary = result["burned"]
	h.last_need_required[need.id] = needed
	h.last_need_provided[need.id] = provided

	var shortfall_units := (needed - provided) / need.value_of(need.baseline)
	if shortfall_units > 0.0001 and _need_served(h.settlement_id, need):
		_accumulate(h.last_unmet_scarcity, need.baseline, shortfall_units)

	var need_record: Dictionary = record["needs"].get_or_add(need.id, {
		"required": 0.0, "provided": 0.0, "met_by": {}, "households_met": 0, "households_unmet": 0})
	need_record["required"] += needed
	need_record["provided"] += provided
	# What the home spared the household (a stone house's heat saving).
	need_record["saved"] = float(need_record.get("saved", 0.0)) + (full_need - needed)
	var town_need: Dictionary = (record["needs_by_settlement"] as Dictionary).get_or_add(h.settlement_id, {}).get_or_add(need.id, {"required": 0.0, "provided": 0.0})
	town_need["required"] += needed
	town_need["provided"] += provided
	if needed - provided > NEED_MET_EPSILON:
		need_record["households_unmet"] += 1
	else:
		need_record["households_met"] += 1

	for c in need.satisfiers():
		var taken: float = burned.get(c, 0.0)
		h.last_consumed[c] = taken
		var name := Commodity.name_of(c)
		need_record["met_by"][name] = need_record["met_by"].get(name, 0.0) + taken * need.value_of(c)
		record["consumed"][name] = record["consumed"].get(name, 0.0) + taken
		record["unmet_scarcity"][name] = record["unmet_scarcity"].get(name, 0.0) + h.last_unmet_scarcity.get(c, 0.0)
		record["unmet_unaffordable"][name] = record["unmet_unaffordable"].get(name, 0.0) + h.last_unmet_unaffordable.get(c, 0.0)

	if need.drives_lifecycle:
		var daily_ratio := h.record_grain_day(needed, provided)
		var rolling := h.rolling_grain_fulfillment()
		var rolling_is_low := rolling < Household.MIGRATION_PRESSURE_FULFILLMENT_THRESHOLD
		var rolling_is_severe := rolling < Household.STARVATION_FULFILLMENT_THRESHOLD
		h.demographics.apply_daily_fulfillment(daily_ratio, rolling_is_low, rolling_is_severe)
		h.advance_day_for_lifecycle(rolling)
	h.record_need_stress(need, needed, provided)

## Reporting only, exactly like the pooled model's migration pressure --
## does NOT move or remove anyone.
func _evaluate_migration_pressure() -> void:
	for household_id in households.keys():
		(households[household_id] as HEHousehold).demographics.update_migration_pressure()

## Unlike the earlier owner-operator cut, this ACTS: a household that's been
## severely short of food for a sustained stretch loses a member to
## emigration, and a household that runs out of members entirely is
## removed. Its employer (if any) automatically has one fewer worker from
## that point on, since employed-worker counts are always derived live from
## households, never cached. Any residual balance/inventory a household
## still held at the moment it winks out of existence is written off --
## not redistributed, not inherited -- and tracked explicitly (see
## get_city_summary's money_written_off_total) so the closed-economy
## accounting stays honest about where it went instead of just quietly not
## adding up.
##
## "Emigrate" rather than "die" is a placeholder label, not a real
## migration model yet -- see remove_member_for_emigration()'s note.
func _evaluate_emigration(record: Dictionary) -> void:
	var emigrations := 0
	var to_remove: Array[int] = []
	for household_id in households.keys():
		var h: HEHousehold = households[household_id]
		if not h.demographics.is_starvation_candidate():
			continue
		var member_type := "dependent" if h.demographics.dependents > 0 else "worker"
		h.remove_member_for_emigration()
		emigrations += 1
		var household_ended := h.demographics.is_empty()
		_log_event("emigrate", {
			"household_id": household_id, "member_type": member_type,
			"cause": "starvation", "household_ended": household_ended,
		})
		if household_ended:
			to_remove.append(household_id)

	# Homelessness: a household with no house is pushed out a member at a time.
	for settlement_id in settlements.keys():
		for household_id in _homeless_household_ids(settlement_id):
			if to_remove.has(household_id) or rng.randf() >= HOMELESS_EMIGRATION_CHANCE:
				continue
			var homeless_household: HEHousehold = households[household_id]
			var homeless_member_type := "dependent" if homeless_household.demographics.dependents > 0 else "worker"
			homeless_household.remove_member_for_emigration()
			emigrations += 1
			var homeless_household_ended := homeless_household.demographics.is_empty()
			_log_event("emigrate", {
				"household_id": household_id, "member_type": homeless_member_type,
				"cause": "homeless", "household_ended": homeless_household_ended,
			})
			if homeless_household_ended:
				to_remove.append(household_id)

	var written_off := _write_off_and_remove_households(to_remove, "emigration")
	_emigrations_total += emigrations
	record["emigrations"] = emigrations
	record["money_written_off"] = float(record.get("money_written_off", 0.0)) + float(written_off["money"])
	_merge_goods_written_off(record, written_off["goods"])

## Monthly, right after emigration: a worker whose age has crossed
## LIFESPAN_DAYS leaves the workforce (see he_household.gd's
## evaluate_old_age_death()). This is NOT a hardship signal like emigration
## -- it happens to healthy, well-fed households too -- so it gets its own
## counter/event type rather than being folded into emigrations_total.
## A household left with zero workers but still-living dependents has no
## realistic way to keep feeding them -- rather than let it linger and lose
## those dependents one at a time to starvation-emigration (which from the
## outside just looks like "dependents never age up"), it's dissolved
## immediately and its dependents adopted into another working household
## (see _adopt_orphaned_dependents()) so they keep aging normally under a
## family that can actually support them. A household left with neither
## workers nor dependents (or an orphaned one nobody could adopt -- see
## that function's note) is written off and removed exactly like an
## emptied-by-emigration household.
func _evaluate_old_age(record: Dictionary) -> void:
	var deaths := 0
	var to_remove: Array[int] = []
	var orphaned: Array[int] = []
	for household_id in households.keys():
		var h: HEHousehold = households[household_id]
		var died := h.evaluate_old_age_death()
		if died == 0:
			continue
		deaths += died
		_log_event("old_age", {"household_id": household_id, "count": died})
		var heirs := h.promote_adults(died)
		if heirs > 0:
			_log_event("succession", {"household_id": household_id, "count": heirs, "cause": "death"})
		if h.worker_capacity() <= 0:
			h.employer_business_id = -1
			if h.demographics.dependents > 0:
				orphaned.append(household_id)
			else:
				to_remove.append(household_id)

	for household_id in orphaned:
		if not _adopt_orphaned_dependents(household_id):
			to_remove.append(household_id)

	var written_off := _write_off_and_remove_households(to_remove, "old_age")
	_old_age_deaths_total += deaths
	record["old_age_deaths"] = deaths
	record["money_written_off"] = float(record.get("money_written_off", 0.0)) + float(written_off["money"])
	_merge_goods_written_off(record, written_off["goods"])

## Dissolves `household_id` (already confirmed to have zero workers and at
## least one dependent) into another still-working household, transferring
## its dependents -- individual ages preserved, not reset -- plus its
## residual balance/inventory wholesale. Nothing here is written off: it
## isn't lost, just relocated to a household that can actually feed it,
## same spirit as _split_off_new_household's proportional transfer the
## other direction. The adopter is whichever eligible household (worker_
## capacity > 0, not itself orphaned this same tick) currently has the
## FEWEST dependents, lowest ID breaking ties -- spreading adoptions out
## rather than always dumping onto the same lowest-ID household, which
## would otherwise grow one household without bound and undercut the
## whole "more, smaller households" design this economy relies on (see
## he_household.gd's AGING_THRESHOLD_DAYS doc comment). Returns false if
## no eligible adopter exists at all (every household in the city has zero
## workers -- total collapse), leaving the caller to write this household
## off like any other dead end instead.
func _adopt_orphaned_dependents(household_id: int) -> bool:
	var orphan: HEHousehold = households[household_id]
	var adopter_id := -1
	var adopter_dependents := -1
	for candidate_id in households.keys():
		if candidate_id == household_id:
			continue
		var candidate: HEHousehold = households[candidate_id]
		if candidate.settlement_id != orphan.settlement_id:
			continue
		if candidate.worker_capacity() <= 0:
			continue
		var candidate_dependents := candidate.demographics.dependents
		if adopter_id == -1 or candidate_dependents < adopter_dependents \
				or (candidate_dependents == adopter_dependents and candidate_id < adopter_id):
			adopter_id = candidate_id
			adopter_dependents = candidate_dependents
	if adopter_id == -1:
		return false

	var adopter: HEHousehold = households[adopter_id]
	var orphan_ages := orphan.dependent_ages()
	var orphan_sexes := orphan.dependent_sexes()
	for i in orphan_ages.size():
		adopter.add_dependent(orphan_ages[i], orphan_sexes[i])
	adopter.balance += orphan.balance
	for c in SUBSISTENCE_COMMODITIES:
		var amount := orphan.stock(c)
		if amount > 0.0:
			adopter.add_stock(c, amount)

	_log_event("adopted", {
		"household_id": household_id, "adopting_household_id": adopter_id,
		"dependents": orphan.demographics.dependents,
	})
	(settlements[orphan.settlement_id] as HESettlement).household_ids.erase(household_id)
	households.erase(household_id)
	_invalidate_employment()
	return true

## Shared by _evaluate_emigration and _evaluate_old_age: each `household_ids`
## entry has already been confirmed empty (is_empty()) by its caller and has
## nothing left to represent -- write off whatever balance/stock it still
## held (not redistributed, not inherited -- see get_city_summary's
## money_written_off_total) and remove it from settlement/households.
## Returns {"money": float, "goods": Dictionary[Commodity.Type, float]} so
## each caller can fold the totals into ITS OWN daily-record fields under
## its own cause, rather than this helper guessing which one it's for.
func _write_off_and_remove_households(household_ids: Array[int], cause: String = "") -> Dictionary:
	var money_written_off := 0.0
	var goods_written_off: Dictionary[Commodity.Type, float] = {}
	for household_id in household_ids:
		var h: HEHousehold = households[household_id]
		money_written_off += h.balance
		for c in SUBSISTENCE_COMMODITIES:
			var amount := h.stock(c)
			if amount > 0.0:
				goods_written_off[c] = goods_written_off.get(c, 0.0) + amount
		(settlements[h.settlement_id] as HESettlement).household_ids.erase(household_id)
		households.erase(household_id)
	_invalidate_employment()

	_money_written_off_total += money_written_off
	_money_written_off_by_cause[cause] = float(_money_written_off_by_cause.get(cause, 0.0)) + money_written_off
	for c in goods_written_off.keys():
		_goods_written_off_total[c] = _goods_written_off_total.get(c, 0.0) + goods_written_off[c]
	return {"money": money_written_off, "goods": goods_written_off}

## Folds a write-off's goods into `record["goods_written_off"]`, accumulating
## rather than overwriting -- emigration and old age can both write off
## goods on the same monthly tick, and each must add to the day's total
## instead of clobbering the other's contribution.
func _merge_goods_written_off(record: Dictionary, goods: Dictionary) -> void:
	var record_goods: Dictionary = record.get("goods_written_off", {})
	for c in goods.keys():
		record_goods[c] = record_goods.get(c, 0.0) + goods[c]
	record["goods_written_off"] = record_goods

## Monthly, right after emigration and old age so a household that just lost
## a member evaluates aging/births from its post-loss state, not a stale
## one. Aging runs first: a dependent promoted this same period immediately
## frees a pipeline slot a birth could use. Households removed by
## emigration or old age this same tick are gone from `households` already,
## so they're simply skipped -- no explicit guard needed. New households
## created by splitting are collected separately and only added to
## `households`/`settlement` once this pass is done iterating, so a split
## created this same tick is never itself re-evaluated for aging/birth
## before it's even a day old.
func _evaluate_life_cycle(record: Dictionary) -> void:
	var births := 0
	var promotions := 0
	var new_households: Array[HEHousehold] = []
	var saturated: Dictionary = {}
	# Empty houses per settlement; each split-off household takes one, so a full
	# town only sees splits from households over HEHousehold.HOME_HEADCOUNT_CAP.
	var free_houses: Dictionary = {}
	for settlement_id in settlements.keys():
		var housing := get_housing_report(settlement_id)
		saturated[settlement_id] = housing["saturated"]
		free_houses[settlement_id] = maxi(int(housing["capacity"]) - int(housing["households"]), 0) if housing["modeled"] else HEHousehold.FREE_HOUSING_UNLIMITED
	for household_id in households.keys():
		var h: HEHousehold = households[household_id]
		var pre_split_headcount := h.headcount()
		var promoted := h.evaluate_aging(rng, free_houses[h.settlement_id])
		if free_houses[h.settlement_id] < HEHousehold.FREE_HOUSING_UNLIMITED:
			free_houses[h.settlement_id] = maxi(free_houses[h.settlement_id] - promoted, 0)
		for i in promoted:
			_log_event("coming_of_age", {"household_id": household_id})
			new_households.append(_split_off_new_household(h, pre_split_headcount - i, h.last_promoted_member_numbers[i], h.last_promoted_sexes[i], h.last_promoted_ages[i]))
		promotions += promoted
		var birth_scale := HOUSING_SATURATED_BIRTH_SCALE if saturated.get(h.settlement_id, false) else 1.0
		if h.evaluate_birth(rng, birth_scale):
			births += 1
			_log_event("birth", {"household_id": household_id})

	for new_household in new_households:
		households[new_household.id] = new_household
		_invalidate_employment()
		(settlements[new_household.settlement_id] as HESettlement).household_ids.append(new_household.id)

	_births_total += births
	_worker_promotions_total += promotions
	record["births"] = births
	record["worker_promotions"] = promotions

## One newly-adult member leaves `parent` to found its own one-worker,
## zero-dependent, unemployed household -- it has to find its own job
## through the normal weekly hiring pool like anyone else (see
## _reconcile_employment), not inherit the parent's. Takes a proportional
## share of the parent's balance and goods with it (1 / headcount_before_
## leaving, using the headcount as of just before THIS particular member
## left, since evaluate_aging() may have promoted several at once this same
## period) -- a plain transfer, not a gift from nowhere, so total city
## money/goods are unaffected by a household splitting.
func _split_off_new_household(parent: HEHousehold, headcount_before_leaving: int, member_number: int, sex: int, age: int) -> HEHousehold:
	var new_id := _next_household_id
	_next_household_id += 1
	var share: float = 1.0 / float(max(headcount_before_leaving, 1))

	var starting_balance: float = parent.balance * share
	parent.balance -= starting_balance
	var new_household := HEHousehold.new(new_id, 1, 0, starting_balance, parent.settlement_id)
	new_household.seed_worker_ages([age] as Array[int])
	new_household.seed_worker_sexes([sex] as Array[int])

	for c in SUBSISTENCE_COMMODITIES:
		var amount: float = parent.stock(c) * share
		parent.consume(c, amount)
		new_household.add_stock(c, amount)

	_log_event("split", {
		"parent_household_id": parent.id, "new_household_id": new_id,
		"starting_balance": starting_balance, "member_number": member_number,
	})
	return new_household

## Weekly self-tuning step 1: adjust each business's TARGET capacity from
## its own rolling-average sales-revenue-per-worker vs. the going reference
## wage. This only sets the target; _reconcile_employment (called right
## after) is what actually moves households between employers to approach
## it.
##
## Revenue-per-worker, not the wage, is the profitability signal now: since
## HEWages.pay_wages always pays the full reference wage whenever a business can
## afford to (see WAGE_NEGATIVE_BALANCE_FLOOR_DAYS), a solvent business's
## OWN wage is nearly always equal to the reference wage by construction --
## comparing the two would tell us nothing about whether it can actually
## sustain that. What it actually earned per worker (rolling_average_
## revenue_per_worker, smoothed over its own crop cycle for a field-model
## business -- see HEBusiness.rolling_window_days) is the real test.
##
## Outside the WAGE_PROFIT_MARGIN dead-band, the move is proportional to how
## far revenue is from the reference wage (as a fraction of the reference,
## clamped at WAGE_RATIO_CLAMP), not a flat CAPACITY_STEP_MAX_WORKERS
## regardless of magnitude. A business 11% over the line and one 300% over
## it used to get the identical +4 nudge -- a bang-bang response to error
## magnitude is exactly the kind of high-gain control that turns a real but
## modest mismatch into overshoot, which is what a fixed step size was
## doing on top of the wage/price system's own lag. The worst case (revenue
## at or beyond the clamp) still moves by exactly CAPACITY_STEP_MAX_WORKERS,
## same as every move used to -- this only makes moderate mismatches gentler,
## it never makes an extreme one bigger than before.
##
## Cash-runway guard, layered on top (never used to GROW, only to force a
## bigger shrink than the revenue signal alone would): a business whose
## balance plus its stock's market value can't cover its own ACTUAL current
## wage bill for CASH_RUNWAY_DANGER_DAYS more (or, for a field-model
## business, until its own next harvest -- see _business_cash_runway_days)
## is treated as if it needs at least one more full capacity step of
## shrinking this week, regardless of what its revenue-per-worker happened
## to average out to -- a business can look profitable on average while
## still being about to run out of cash before its next payday, and that's
## the case this guard exists to catch. Per this task's brief, going
## negative itself is allowed generously (see WAGE_NEGATIVE_BALANCE_FLOOR_
## DAYS) -- only the FORECAST of running out of runway forces a downsize,
## not the negative balance itself.
##
## Only fires above CASH_RUNWAY_GUARD_MIN_CAPACITY: a small crew's wage bill
## is tiny, so legacy debt makes its runway ratio look alarming long after
## whatever caused it has passed. A business that truly can't keep up is not
## handled here but by running out of credit (see _fail_business), and a
## business that reaches zero workers stays at zero (no trial rehire).
func _evaluate_business_capacity(record: Dictionary) -> void:
	var reference_wages := {}
	for business_id in businesses.keys():
		var b: HEBusiness = businesses[business_id]
		var reference_wage := wages.capacity_benchmark_wage(b.settlement_id)
		reference_wages[b.settlement_id] = reference_wage
		if b.kind == HEBusiness.Kind.GOVERNMENT or b.kind == HEBusiness.Kind.WAREHOUSE or b.kind == HEBusiness.Kind.WATER:
			# Staffed by the seed / _ensure_administrator (a water source has
			# no crew at all), not by revenue
			# signals -- it has no revenue per worker to judge.
			continue
		if b.processes_livestock:
			continue # crew set by _livestock_crew_target in _reconcile_employment
		# Valley Ports are fixed-capacity outside terminals. Their staffed
		# throughput is authored by the town seed; only standalone Ports use
		# the Trader throughput controller below.
		if intertown_trading_enabled and b.kind == HEBusiness.Kind.PORT:
			continue
		# A business is never tuned down to zero: it keeps its last worker and
		# can only go away by exhausting its credit (see _fail_business), so
		# there is no idle zombie and no trial rehire to bring one back.
		b.capacity = maxi(b.capacity, _capacity_floor(b))
		if day < b.startup_grace_until_day:
			continue
		if (day + 1) % _capacity_eval_interval_days(b) != 0:
			# A field-model business's output doesn't respond to a capacity
			# change for up to its own growth_days -- re-evaluating it every
			# single CAPACITY_EVAL_INTERVAL_DAYS week regardless (like a
			# business whose output is instant) means many step changes
			# stack up before the first one's effect on revenue is even
			# visible, a classic control-loop-period-shorter-than-plant-lag
			# recipe for overshoot. See _capacity_eval_interval_days.
			continue
		var staffing := _staffing_decision(b, reference_wage)
		var delta: int = staffing["delta"]
		var change_reason: String = staffing["reason"]
		var avg_revenue: float = staffing["return_per_worker"]
		var cash_runway := INF
		var required_runway := 0.0
		if b.capacity > CASH_RUNWAY_GUARD_MIN_CAPACITY:
			# uses_field_model(), not has_long_cycle(): only a field is
			# guaranteed to pay off within its growth cycle, so only a field
			# gets that long a runway before the guard forces a bigger cut.
			required_runway = float(b.days_until_next_harvest()) if b.uses_field_model() else CASH_RUNWAY_DANGER_DAYS
			cash_runway = _business_cash_runway_days(b)
			if cash_runway < required_runway:
				delta = mini(delta, -CAPACITY_STEP_MAX_WORKERS)
				change_reason = "cash_runway"
		if delta != 0:
			var old_capacity := b.capacity
			b.capacity = clampi(b.capacity + delta, _capacity_floor(b), b.max_capacity)
			if b.capacity != old_capacity:
				record["capacity_changes"][business_id] = {
					"reason": change_reason,
					"old_capacity": old_capacity,
					"new_capacity": b.capacity,
					"average_revenue_per_worker": avg_revenue,
					"reference_wage_per_worker": reference_wage,
					"cash_runway_days": cash_runway,
					"required_runway_days": required_runway,
					"staffing": staffing,
				}
	record["reference_wage_by_settlement"] = reference_wages
	if reference_wages.size() == 1:
		record["reference_wage"] = reference_wages.values()[0]

## Staffing is steered toward the crew whose output the market will actually
## take: saleable units per day divided by what one worker makes. These bound
## how far the current crew may drift from that target before it moves, and how
## much stock may sit unsold before a bigger crew is even considered.
const STAFFING_RETURN_WINDOW_DAYS := 90
const STAFFING_HEADROOM := 0.05
const STAFFING_SHRINK_TOLERANCE := 0.15
const STAFFING_GROW_MIN_SELL_THROUGH := 0.95
const STAFFING_GROW_MAX_STOCK_DAYS := 14.0

## The weekly staffing signal, from the business's own operating ledger over
## its production cycle (HEBusiness.rolling_window_days) instead of revenue per
## worker. Two questions, each from the ledger:
##   1. Does each worker clear the wage? What it actually sold, less the inputs
##      it used up and the tax it remitted, per worker, against the going wage.
##   2. Does the output have a buyer? The crew it takes to make what it is
##      actually SELLING (units sold per day over units one worker makes) is the
##      target; a bigger crew is cut toward it, never past it, so cutting stops
##      once production matches sales instead of chasing a lagging window to
##      zero. Growth needs both a clearing return and sales beyond the current
##      crew's output while stock is nearly gone (sales merely drawn from a
##      pile of old stock are not demand for more workers).
## Judged only once enough ledger rows exist: a field crew's sales (paced from
## stock) over a recent stretch, its production over the whole cycle, so one
## quiet week never dismisses it. The move is bounded by
## CAPACITY_STEP_MAX_WORKERS like every capacity change. Returns {delta, reason,
## return_per_worker, wage, sell_through, target_workers, employed, sales,
## input_cost, taxes, units_sold, units_produced, window}.
func _staffing_decision(b: HEBusiness, reference_wage: float) -> Dictionary:
	var window := b.rolling_window_days()
	var out := {"delta": 0, "reason": "", "return_per_worker": 0.0, "wage": reference_wage, "sell_through": 1.0,
		"target_workers": -1.0, "employed": 0.0, "sales": 0.0, "input_cost": 0.0, "taxes": 0.0,
		"units_sold": 0.0, "units_produced": 0.0, "window": window}
	var needed_rows: int = mini(window, STAFFING_RETURN_WINDOW_DAYS) if b.uses_field_model() else (window if b.has_long_cycle() else mini(window, 14))
	var rows := b.ledger_history(window).size()
	if rows < needed_rows:
		return out
	var full_cycle := rows >= window
	# A field crew's SALES are paced out of stock (see _paced_offer), so the money
	# side is judged over a recent stretch; only production is lumpy.
	var money_window: int = mini(window, STAFFING_RETURN_WINDOW_DAYS) if b.uses_field_model() else window
	var avg_employed := maxf(1.0, b.ledger_average("employed", money_window))
	var sales := 0.0
	for key in ["sales_household", "sales_business", "sales_export", "sales_other", "trade_margin"]:
		sales += b.ledger_average(key, money_window)
	var input_cost := b.ledger_average("input_consumed_value", money_window)
	var taxes := b.ledger_average("taxes", money_window)
	var sold_recent := b.ledger_average("units_sold", money_window)
	var sold_cycle := b.ledger_average("units_sold", window)
	var unmet_recent := b.ledger_average("unmet_demand", money_window)
	var unfunded_recent := b.ledger_average("unfunded_demand", money_window)
	var made := b.ledger_average("units_produced", window)
	var return_per_worker := (sales - input_cost - taxes) / avg_employed
	# Judge the window's return against the window's wage, not today's spot
	# wage: the wage index jumps with consumer prices while a trailing average
	# of sales still holds the cheap days, which would read as a loss every time
	# prices rise.
	var window_wage := b.ledger_average("reference_wage", money_window)
	if window_wage > 0.0:
		reference_wage = window_wage
		out["wage"] = window_wage
	out["return_per_worker"] = return_per_worker
	out["employed"] = avg_employed
	out["sales"] = sales
	out["input_cost"] = input_cost
	out["taxes"] = taxes
	out["units_sold"] = sold_recent
	out["unmet_demand"] = unmet_recent
	out["unfunded_demand"] = unfunded_recent
	out["units_produced"] = made
	var measured_output: bool = b.kind == HEBusiness.Kind.PRODUCTION and made > 0.0001
	if measured_output:
		out["sell_through"] = minf(2.0, sold_cycle / made)
	if reference_wage <= 0.0:
		return out
	var delta := 0
	var reason := ""
	var ratio_error := (return_per_worker - reference_wage) / reference_wage
	if absf(ratio_error) > WAGE_PROFIT_MARGIN:
		delta = roundi(clampf(ratio_error, -WAGE_RATIO_CLAMP, WAGE_RATIO_CLAMP) * CAPACITY_STEP_MAX_WORKERS)
		reason = "low_return" if delta < 0 else "high_return"

	# A Trader's crew is its handling capacity: one worker moves
	# TRADER_CAPACITY_PER_WORKER units a day, and what it earns is a spread on the
	# units it actually moves, which the goods on offer (not its crew) decide. So
	# the crew follows throughput, and it only grows while it is nearly full.
	if b.kind in [HEBusiness.Kind.TRADER, HEBusiness.Kind.PORT]:
		var traded := b.ledger_average("units_sold", window)
		var trader_target := traded * (1.0 + STAFFING_HEADROOM) / TRADER_CAPACITY_PER_WORKER
		# Judged against the slots authorized, not just the ones filled: with labor
		# scarce a Trader can sit at 2 employed under a ceiling of 20, and growing
		# on "nearly full" of the 2 kept raising it until an unemployment wave
		# filled every open slot at once for throughput that needed 2.
		var trader_current := float(maxi(_business_employed_worker_count(b.id), b.capacity))
		out["target_workers"] = trader_target
		out["units_sold"] = traded
		if trader_current > trader_target * (1.0 + STAFFING_SHRINK_TOLERANCE) + 0.5:
			var trader_cut: int = -clampi(floori(trader_current - trader_target), 1, CAPACITY_STEP_MAX_WORKERS)
			if trader_cut < delta or delta == 0:
				delta = trader_cut
				reason = "unused_capacity"
		elif delta > 0 and traded < trader_current * TRADER_CAPACITY_PER_WORKER * 0.8:
			delta = 0
			reason = ""
		out["delta"] = delta
		out["reason"] = reason
		return out

	# The volume question needs a measured output per worker, so a production
	# row (a harvest) inside the window; a field crew also needs the full cycle.
	if measured_output and (full_cycle or not b.uses_field_model()):
		var window_employed := maxf(1.0, b.ledger_average("employed", window))
		var per_worker := made / window_employed
		# Demand is what sold plus what funded buyers could not get: when supply
		# is the binding limit, sales alone understate it.
		var demand := sold_recent + unmet_recent + unfunded_recent
		var target := demand * (1.0 + STAFFING_HEADROOM) / per_worker
		var current := float(_business_employed_worker_count(b.id))
		out["target_workers"] = target
		if current > target * (1.0 + STAFFING_SHRINK_TOLERANCE) + 0.5:
			var cut: int = -clampi(floori(current - target), 1, CAPACITY_STEP_MAX_WORKERS)
			if cut < delta or delta == 0:
				delta = cut
				reason = "unsold_output"
		elif delta > 0:
			var stock_units := 0.0
			for c in _business_output_commodities(b):
				stock_units += b.stock(c)
			var horizon: float = minf(float(_days_until_next_supply(b)), STAFFING_GROW_MAX_STOCK_DAYS) if b.has_long_cycle() else STAFFING_GROW_MAX_STOCK_DAYS
			var drawn_from_stock := stock_units > demand * horizon
			# A clearing return is the case for hiring; what blocks it is output
			# that is not selling through, or sales that are only old stock
			# leaving. Output unsold while households go short of money for it is
			# a purchasing-power gap, not a lack of buyers -- new wages close it.
			var income_constrained := unfunded_recent > sold_recent * 0.05
			if (drawn_from_stock or float(out["sell_through"]) < STAFFING_GROW_MIN_SELL_THROUGH) and not income_constrained:
				delta = 0
				reason = ""
	elif delta > 0 and b.kind == HEBusiness.Kind.PRODUCTION:
		# No measured output per worker yet (no harvest in the window): a good
		# return alone is not enough to add workers.
		delta = 0
		reason = ""
	out["delta"] = delta
	out["reason"] = reason
	return out

## How often (in days, always a whole multiple of CAPACITY_EVAL_INTERVAL_
## DAYS so it still only ever fires on one of the ticks the calling
## _daily_tick has already gated on that cadence) a business's TARGET
## capacity should actually be re-evaluated. Trader uses three weeks because
## its suppliers release stock in harvest batches. A field-model business
## grows its cadence with its production lag (roughly a sixth of its growth
## cycle) so step changes do not compound before output responds.
func _capacity_eval_interval_days(b: HEBusiness) -> int:
	if b.kind in [HEBusiness.Kind.TRADER, HEBusiness.Kind.PORT]:
		return TRADER_CAPACITY_EVAL_INTERVAL_DAYS
	# uses_field_model(), not has_long_cycle() -- only a field is guaranteed to
	# pay off within its growth cycle.
	if not b.uses_field_model():
		return CAPACITY_EVAL_INTERVAL_DAYS
	var weeks: int = maxi(1, roundi(float(b.growth_days) / 6.0 / float(CAPACITY_EVAL_INTERVAL_DAYS)))
	return weeks * CAPACITY_EVAL_INTERVAL_DAYS

## Days until `b`'s balance plus its current stock's market value runs out
## against its own ACTUAL current daily wage bill (reference wage *
## currently employed workers, not max_capacity) -- INF for an unemployed
## business (no bill to run out against). Sized off `employed` on purpose:
## a business with unused land/headroom (high max_capacity, modest current
## headcount) only has to cover what it's ACTUALLY paying today, not a
## hypothetical full crew it doesn't have -- comparing against max_capacity
## would force a perfectly solvent, merely-underutilized business to shrink
## for no reason other than having land to spare. Used only by
## _evaluate_business_capacity's cash-runway guard; never mutates anything.
func _business_cash_runway_days(b: HEBusiness) -> float:
	var employed := _business_employed_worker_count(b.id)
	if employed <= 0:
		return INF
	var daily_wage_bill: float = wages.wage_paid_per_worker(b) * employed
	if daily_wage_bill <= 0.0:
		return INF
	var stock_value := 0.0
	if b.kind == HEBusiness.Kind.PRODUCTION:
		for oc in b.recipe.outputs.keys():
			stock_value += b.stock(oc) * (markets[b.settlement_id] as HEMarket).price[oc]
		if b.processes_livestock:
			# Live animals the Butcher holds are worth what it paid for them.
			stock_value += _livestock_stock_value(b)
	elif b.kind == HEBusiness.Kind.HERD:
		# The culled animal itself has no clearing local price (see
		# HERD_EXPORT_PRICE's doc comment) -- value it at what the Trader would
		# actually pay for it, not the undiscounted reference price, so this
		# doesn't overstate what the ranch could really turn it into (see
		# livestock_holding_value). Wool, unlike the animal, does clear locally,
		# so it's valued at the real local price like any other PRODUCTION stock
		# above.
		stock_value = _livestock_stock_value(b)
		if b.species == HEBusiness.Species.SHEEP:
			stock_value += b.stock(Commodity.Type.WOOL) * (markets[b.settlement_id] as HEMarket).price[Commodity.Type.WOOL]
		# Home-butchered meat clears locally too (see _hardship_butcher_if_needed).
		stock_value += b.stock(Commodity.Type.MEAT) * (markets[b.settlement_id] as HEMarket).price[Commodity.Type.MEAT]
	return (b.balance + stock_value) / daily_wage_bill

## Weekly self-tuning step 2: lay off whole households (highest household ID
## first, an arbitrary but deterministic tie-break) from any business now
## over its (possibly just-reduced) capacity, then let every under-capacity
## business hire from the resulting pool of unemployed households: the one
## living nearest the business first when `position_lookup` is set (household
## ID breaks ties and a home with no known position ranks last), otherwise
## lowest household ID first. Businesses are processed in a fixed ID order for
## hiring, so a lower-ID business gets first pick of the pool when two are
## expanding into the same freed labor at once -- a deterministic but real
## bias, same spirit as the pooled model's documented edge-order bias in
## _run_trade.
func _reconcile_employment(record: Dictionary = {}) -> void:
	var business_ids := businesses.keys()
	business_ids.sort()
	for business_id in business_ids:
		var processor: HEBusiness = businesses[business_id]
		if processor.processes_livestock:
			processor.capacity = _livestock_crew_target(processor)

	# One index snapshot serves the whole layoff pass: a layoff only changes
	# its own business's membership, and each business is visited once.
	var layoff_snapshot := _employment_index()
	for business_id in business_ids:
		var b: HEBusiness = businesses[business_id]
		if b.kind == HEBusiness.Kind.GOVERNMENT or b.kind == HEBusiness.Kind.WAREHOUSE or b.kind == HEBusiness.Kind.WATER:
			continue # never laid off by the capacity loop; see _ensure_administrator
		var employed_ids: Array[int] = []
		employed_ids.assign(layoff_snapshot.get(business_id, []))
		employed_ids.sort()
		var employed_workers := _workers_in(employed_ids)
		var i := employed_ids.size() - 1
		# i >= 1: never lay off the last household, whatever its size.
		while employed_workers > b.capacity and i >= 1:
			var household_id: int = employed_ids[i]
			var h: HEHousehold = households[household_id]
			employed_workers -= h.worker_capacity()
			h.employer_business_id = -1
			var capacity_change: Dictionary = record.get("capacity_changes", {}).get(business_id, {})
			_log_event("fired", {
				"household_id": household_id,
				"business_id": business_id,
				"settlement_id": b.settlement_id,
				"workers": h.worker_capacity(),
				"reason": capacity_change.get("reason", "target_capacity"),
				"old_capacity": capacity_change.get("old_capacity", b.capacity),
				"new_capacity": capacity_change.get("new_capacity", b.capacity),
				"average_revenue_per_worker": capacity_change.get("average_revenue_per_worker", b.rolling_average_revenue_per_worker()),
				"reference_wage_per_worker": capacity_change.get("reference_wage_per_worker", wages.reference_wage_per_worker(b.settlement_id)),
				"cash_runway_days": capacity_change.get("cash_runway_days", _business_cash_runway_days(b)),
				"required_runway_days": capacity_change.get("required_runway_days", 0.0),
			})
			i -= 1

	for settlement_id in get_settlement_ids():
		_ensure_administrator(settlement_id)
		_ensure_warehouse_staff(settlement_id)
		var available: Array[int] = []
		for household_id in (settlements[settlement_id] as HESettlement).household_ids:
			if (households[household_id] as HEHousehold).employer_business_id == -1:
				available.append(household_id)
		available.sort()
		var local_business_ids := (settlements[settlement_id] as HESettlement).business_ids.duplicate()
		local_business_ids.sort()
		# Hires only move unemployed households into the business being
		# filled, so one snapshot gives every business its starting count
		# without a rebuild after each hire.
		var hiring_snapshot := _employment_index()
		var dwelling_positions: Dictionary = {} # dwelling_id -> position, looked up once
		for business_id in local_business_ids:
			var b: HEBusiness = businesses[business_id]
			if b.kind == HEBusiness.Kind.GOVERNMENT or b.kind == HEBusiness.Kind.WATER:
				continue # TODO(builders): hire builder_slots households here once modeled
			var employed_workers := _workers_in(hiring_snapshot.get(business_id, []))
			# A Butcher's capacity is its work (_livestock_crew_target), set above.
			var business_position := _lookup_position("business", business_id)
			# Grown children of the business's own employees fill an opening
			# first; only what is left is hired from the unemployed pool.
			if employed_workers < b.capacity:
				var member_ids: Array[int] = []
				member_ids.assign(hiring_snapshot.get(business_id, []))
				member_ids.sort()
				for member_id in member_ids:
					if employed_workers >= b.capacity:
						break
					var joined := (households[member_id] as HEHousehold).promote_adults(b.capacity - employed_workers)
					if joined > 0:
						employed_workers += joined
						_log_event("succession", {"household_id": member_id, "count": joined, "cause": "hired"})
			while employed_workers < b.capacity and not available.is_empty():
				var household_id: int = available.pop_at(_nearest_available_index(available, business_position, dwelling_positions))
				var h: HEHousehold = households[household_id]
				if h.worker_capacity() <= 0:
					continue
				h.employer_business_id = business_id
				employed_workers += h.worker_capacity()
				_log_event("job", {"household_id": household_id, "business_id": business_id, "settlement_id": settlement_id, "workers": h.worker_capacity()})

## Position of a business or house from `position_lookup`, or Vector2.INF.
func _lookup_position(kind: String, id: int) -> Vector2:
	if not position_lookup.is_valid() or id == -1:
		return Vector2.INF
	return position_lookup.call(kind, id)

## Index in `available` (ascending household ids) of the household that lives
## nearest `business_position`; the lowest id wins a tie. Households with an
## unknown home, or any pick when the business position is unknown, rank last,
## so with no position data this is index 0: plain ascending id order.
func _nearest_available_index(available: Array[int], business_position: Vector2, dwelling_positions: Dictionary) -> int:
	if not business_position.is_finite():
		return 0
	var best := 0
	var best_distance := INF
	for i in available.size():
		var dwelling_id: int = (households[available[i]] as HEHousehold).dwelling_id
		if not dwelling_positions.has(dwelling_id):
			dwelling_positions[dwelling_id] = _lookup_position("dwelling", dwelling_id)
		var home: Vector2 = dwelling_positions[dwelling_id]
		if not home.is_finite():
			continue
		var distance := home.distance_squared_to(business_position)
		if distance < best_distance:
			best_distance = distance
			best = i
	return best

## Step: prepare and clear local offers/requests, one commodity at a time.
## Snapshots every household's balance ONCE before either commodity clears
## (today's wage is already in that balance, paid earlier this same tick),
## and reserves spend against that snapshot across both commodities -- a
## household that wants to buy both grain and timber the same day can't
## double-spend the same money twice just because it's requesting two goods
## in the same pass.
func _run_market(record: Dictionary) -> void:
	for settlement_id in get_settlement_ids():
		var starting_balance: Dictionary = {}
		for household_id in (settlements[settlement_id] as HESettlement).household_ids:
			starting_balance[household_id] = (households[household_id] as HEHousehold).balance
		var reserved_spend: Dictionary = {}
		for commodity in _market_clearing_order(settlement_id):
			_clear_market_for(settlement_id, commodity, record, starting_balance, reserved_spend)

## What `seller` puts up for local sale today. A legacy (non-field) business
## offers its ENTIRE current stock -- it has no reason to hold any back. A
## field-model (or herd) business offers stock / days_until_next_harvest (with
## a little SELL_PACE_HEADROOM) so a lump harvest sells down evenly until the
## next one. Households and input-buying businesses share this one offer.
func _paced_offer(seller: HEBusiness, commodity: Commodity.Type) -> float:
	var stock := seller.stock(commodity)
	if seller.has_long_cycle():
		var days_until: int = _days_until_next_supply(seller)
		return minf(stock, stock / float(days_until) * SELL_PACE_HEADROOM)
	return stock

## Cash-funded household demand for `commodity` right now -- what households
## would ask for in today's market, used only to size a business buyer's
## fair share of the seller's offer before households have cleared.
func _household_funded_demand(settlement_id: int, commodity: Commodity.Type) -> float:
	var price: float = (markets[settlement_id] as HEMarket).price[commodity]
	if price <= 0.0:
		return 0.0
	var need := HENeeds.for_commodity(commodity)
	var cascade: Array[Commodity.Type] = []
	if need != null and need.unit_values.size() > 1:
		cascade = _household_cascade(settlement_id, need)
	var total := 0.0
	for household_id in (settlements[settlement_id] as HESettlement).household_ids:
		var h: HEHousehold = households[household_id]
		total += minf(_desired_purchase(h, commodity, cascade), maxf(0.0, h.balance / price))
	return total

## One commodity's daily clearing. The seller side is now a single business
## (whichever one's recipe outputs this commodity, or none). A legacy
## (non-field) business still offers its ENTIRE current stock -- it has no
## reason to hold any back, since it doesn't consume its own product. A
## field-model business instead offers stock / days_until_next_harvest (with
## a little SELL_PACE_HEADROOM) so a lump harvest sells down evenly over the
## stretch until the next one, rather than dumping the whole thing on the
## market the day it's picked (see he_business.gd's days_until_next_harvest).
## The buyer side is unchanged: household requests are sized against
## subsistence need before affordability caps them, capped by what's left of
## this household's snapshotted starting balance.
##
## When one side outnumbers the other, both sides are scaled by a single
## ratio (quantity_traded / that side's total) -- pure proportional scaling
## over continuous float quantities, so there is no remainder to round and
## therefore no room for a lowest-household-ID-eats-first bias.
func _clear_market_for(settlement_id: int, commodity: Commodity.Type, record: Dictionary, starting_balance: Dictionary, reserved_spend: Dictionary) -> void:
	var local_market: HEMarket = markets[settlement_id]
	var price: float = local_market.price[commodity]
	var seller: HEBusiness = _business_selling(settlement_id, commodity)
	var importer: HEBusiness = _settlement_trader(settlement_id) if intertown_trading_enabled else null
	var total_offer := _household_offer(settlement_id, commodity)
	var imported_offer: float = maxf(0.0, importer.stock(commodity) - _valley_reserved_stock.get(commodity, 0.0)) if importer != null else 0.0
	var local_offer: float = maxf(0.0, total_offer - imported_offer)
	# Today's input purchases (_run_input_purchasing) already took their
	# pro-rata share of this seller's paced offer; households clear against
	# what's left of it, and the price signal below sees both sides' demand.
	var b2b: Dictionary = _b2b_today.get(settlement_id, {}).get(commodity, {})
	var b2b_sold: float = b2b.get("sold", 0.0)
	if seller != null and not b2b.is_empty():
		local_offer = minf(seller.stock(commodity), maxf(0.0, b2b["offer"] - b2b_sold))
		total_offer = local_offer + imported_offer

	# A satisfier that is not last in its need's cascade passes whatever it
	# could not supply on to the next one, so that shortfall is not yet a
	# household going without -- only the last satisfier records it as unmet.
	var need := HENeeds.for_commodity(commodity)
	var defers_shortfall := false
	var cascade: Array[Commodity.Type] = []
	if need != null and need.unit_values.size() > 1:
		cascade = _household_cascade(settlement_id, need)
		defers_shortfall = cascade.has(commodity) and cascade.back() != commodity

	var requests_funded: Dictionary = {}
	var total_funded_request := 0.0
	var total_wanted := 0.0

	for household_id in (settlements[settlement_id] as HESettlement).household_ids:
		var h: HEHousehold = households[household_id]
		var desired_qty: float = _desired_purchase(h, commodity, cascade)
		if desired_qty > 0.0001:
			total_wanted += desired_qty
			var available_balance: float = starting_balance[household_id] - reserved_spend.get(household_id, 0.0)
			var affordable_qty: float = (available_balance / price) if price > 0.0 else 0.0
			var funded_qty: float = min(desired_qty, max(0.0, affordable_qty))
			if funded_qty > 0.0001:
				requests_funded[household_id] = funded_qty
				total_funded_request += funded_qty
			var unaffordable: float = desired_qty - funded_qty
			if unaffordable > 0.0001 and not defers_shortfall:
				_accumulate(h.last_unmet_unaffordable, commodity, unaffordable)

	var quantity_traded: float = min(total_offer, total_funded_request)
	var name := Commodity.name_of(commodity)

	if quantity_traded > 0.0001:
		var buy_scale: float = quantity_traded / total_funded_request
		for household_id in requests_funded.keys():
			var funded: float = requests_funded[household_id]
			var bought: float = funded * buy_scale
			var h: HEHousehold = households[household_id]
			h.balance -= bought * price
			reserved_spend[household_id] = reserved_spend.get(household_id, 0.0) + bought * price
			h.add_stock(commodity, bought)
			var scarcity_shortfall: float = funded - bought
			if scarcity_shortfall > 0.0001 and not defers_shortfall:
				_accumulate(h.last_unmet_scarcity, commodity, scarcity_shortfall)

		var local_sold: float = quantity_traded * local_offer / total_offer if total_offer > 0.0 else 0.0
		if seller != null and local_sold > 0.0:
			seller.consume(commodity, local_sold)
			seller.add_flow(HEBusiness.FLOW_SOLD, commodity, local_sold)
			var gross_revenue := local_sold * price
			var sales_tax := _collect_sales_tax(settlement_id, gross_revenue)
			var revenue := gross_revenue - sales_tax
			seller.ledger_add("sales_household", gross_revenue)
			seller.ledger_add_good("local", commodity, quantity_traded)
			seller.ledger_add("taxes", sales_tax)
			seller.balance += revenue
			# += , not = -- HEWages.pay_wages already zeroed this at the top of the
			# tick, and _run_input_purchasing may have already added this
			# same seller's business-to-business sales today (e.g. Woodlot
			# selling wood to the Bloomery before households ever got a
			# chance to buy any).
			seller.last_revenue += revenue
			seller.last_cash_change += revenue
		var imported_sold: float = maxf(0.0, quantity_traded - local_sold)
		if importer != null and imported_sold > 0.0:
			importer.consume(commodity, imported_sold)
			importer.add_flow(HEBusiness.FLOW_SOLD, commodity, imported_sold)
			var import_gross := imported_sold * price
			var import_tax := _collect_sales_tax(settlement_id, import_gross)
			var import_revenue := import_gross - import_tax
			importer.balance += import_revenue
			importer.ledger_add("sales_household", import_gross)
			importer.ledger_add("taxes", import_tax)
			importer.last_revenue += import_revenue
			importer.last_cash_change += import_revenue

	# Records only the household pass; the business-to-business sales were
	# already merged in _run_input_purchasing. The PRICE signal below sees both.
	local_market.merge_clearing(commodity, total_offer, total_funded_request, quantity_traded, price)
	local_market.record_household_demand(commodity, total_wanted, total_funded_request, maxf(0.0, quantity_traded))
	record["traded_quantity"][name] = record["traded_quantity"].get(name, 0.0) + quantity_traded

	# Feeds the day's single price signal (see _apply_price_signals); household
	# and business passes both add to it, nothing adjusts the price here.
	var signal_today := _price_signal_entry(settlement_id, commodity)
	signal_today["offer"] = maxf(signal_today["offer"], total_offer + b2b_sold)
	# A seller whose output is instant offers its whole stock, so what it carries
	# overnight is working inventory, not a glut: allow one day's output of float
	# before leftover counts as unsold. (A paced field seller's offer is already
	# a daily slice, so it gets none.)
	if seller != null and not seller.has_long_cycle():
		signal_today["working_stock"] = maxf(signal_today["working_stock"], float(seller.last_output_produced.get(commodity, 0.0)))
	signal_today["funded_household"] = total_funded_request
	signal_today["wanted_household"] = total_wanted
	signal_today["unfunded_household"] = maxf(0.0, total_wanted - total_funded_request)

## A good only businesses buy (iron ore) never goes through _clear_market_for,
## which is what feeds a seller's offer into the price signal. Without this its
## signal would carry business requests but no offer, so every request read as a
## funded shortage and the price could only climb -- to its ceiling, however much
## unsold ore the mine was holding. Registers the local seller's offer the same
## way _clear_market_for does for household goods.
func _register_business_only_offers() -> void:
	for business_id in businesses.keys():
		var seller: HEBusiness = businesses[business_id]
		if seller.kind != HEBusiness.Kind.PRODUCTION or seller.recipe == null:
			continue
		for commodity in seller.recipe.outputs.keys():
			if HENeeds.for_commodity(commodity) != null or _business_selling(seller.settlement_id, commodity) != seller:
				continue
			if not _has_local_buyers(seller.settlement_id, commodity):
				continue
			var b2b: Dictionary = _b2b_today.get(seller.settlement_id, {}).get(commodity, {})
			var sold: float = b2b.get("sold", 0.0)
			var remaining := _household_offer(seller.settlement_id, commodity)
			if not b2b.is_empty():
				remaining = minf(seller.stock(commodity), maxf(0.0, b2b["offer"] - sold))
			var signal_today := _price_signal_entry(seller.settlement_id, commodity)
			signal_today["offer"] = maxf(signal_today["offer"], remaining + sold)
			if not seller.has_long_cycle():
				signal_today["working_stock"] = maxf(signal_today["working_stock"], float(seller.last_output_produced.get(commodity, 0.0)))

## Today's accumulating inputs to each good's price signal, by settlement then
## commodity. Reset when input purchasing starts the day; consumed (and cleared)
## by _apply_price_signals once every local pass has run.
var _price_signal_today: Dictionary = {}

func _price_signal_entry(settlement_id: int, commodity: Commodity.Type) -> Dictionary:
	var by_commodity: Dictionary = _price_signal_today.get_or_add(settlement_id, {})
	return by_commodity.get_or_add(commodity, {
		"offer": 0.0, "funded_household": 0.0, "funded_business": 0.0,
		"business_buffer_request": 0.0, "import_capacity": 0.0, "working_stock": 0.0,
		"wanted_household": 0.0, "unfunded_household": 0.0})

## Does anyone local ever buy `commodity` -- a household need it satisfies, or
## a business recipe input? A good nobody buys (iron, which only the Trader
## exports) has no local price signal: its unsold stock is not a sign the
## price is wrong, and export appetite is deliberately not local demand.
func _has_local_buyers(settlement_id: int, commodity: Commodity.Type) -> bool:
	if HENeeds.for_commodity(commodity) != null:
		return true
	for business_id in (settlements[settlement_id] as HESettlement).business_ids:
		var b: HEBusiness = businesses[business_id]
		if b.recipe != null and b.recipe.inputs.has(commodity):
			return true
	return false

## One price move per town and good per day, from the complete local picture:
## the seller's offer against funded household and business requests. Funded
## shortage (buyers could pay, the offer could not fill them) pushes the price
## up; unsold offer pushes it down -- including when households want goods they
## cannot afford, since dearer would only make that worse. Need without
## purchasing power is recorded (unfunded_household) but does not bid a price
## up by itself, and Trader exports stay out of it entirely. Every transaction
## today already used the opening price; this sets TOMORROW's.
##
## The pressure is the net shortage-or-unsold share of the day's volume,
## smoothed over days; the move is proportional to it, capped at
## PRICE_ADJUST_STEP, and skipped inside PRICE_NEUTRAL_BAND.
func _apply_price_signals() -> void:
	for settlement_id in _price_signal_today.keys():
		var local_market: HEMarket = markets[settlement_id]
		for commodity in _price_signal_today[settlement_id].keys():
			if not _has_local_buyers(settlement_id, commodity):
				continue
			var s: Dictionary = _price_signal_today[settlement_id][commodity]
			var funded: float = s["funded_household"] + s["funded_business"]
			var offer: float = s["offer"]
			# Import capacity is what the Trader COULD bring in, not stock sitting
			# unsold in town: the unused part must not read as a glut. Imports
			# that met the funded requests count as matched supply (no pressure);
			# funded requests beyond the capacity are a real shortage.
			if s["import_capacity"] > 0.0:
				offer = maxf(offer, minf(s["import_capacity"], funded))
			var shortage := maxf(0.0, funded - offer)
			var local_seller := _business_selling(settlement_id, commodity)
			if local_seller != null:
				if shortage > 0.0:
					local_seller.ledger_add("unmet_demand", shortage)
				if s["unfunded_household"] > 0.0:
					local_seller.ledger_add("unfunded_demand", s["unfunded_household"])
			var unsold := maxf(0.0, offer - funded - s["working_stock"])
			var volume := maxf(offer, funded)
			var opening: float = local_market.price[commodity]
			var pressure: float = local_market.price_pressure.get(commodity, 0.0)
			var reason := "no activity"
			if volume > 0.0001:
				var today := (shortage - unsold) / volume
				pressure += PRICE_SIGNAL_SMOOTHING * (today - pressure)
				local_market.price_pressure[commodity] = pressure
				reason = "balanced (within neutral band)"
				if absf(pressure) > PRICE_NEUTRAL_BAND:
					reason = "funded shortage" if pressure > 0.0 else "unsold offer"
			var closing := opening
			var base: float = BASE_PRICE[commodity]
			var bound := ""
			if price_adjustment_enabled and reason != "no activity" and not reason.begins_with("balanced"):
				var step := clampf(pressure / PRICE_ADJUST_FULL_STEP_SHARE, -1.0, 1.0) * PRICE_ADJUST_STEP
				closing = clampf(opening * (1.0 + step), base * PRICE_MULTIPLIER_MIN, base * PRICE_MULTIPLIER_MAX)
				local_market.price[commodity] = closing
			elif not price_adjustment_enabled:
				reason += " (price adjustment off)"
			if closing <= base * PRICE_MULTIPLIER_MIN + 0.00001:
				bound = "floor"
				local_market.floor_days[commodity] = local_market.floor_days.get(commodity, 0) + 1
			elif closing >= base * PRICE_MULTIPLIER_MAX - 0.00001:
				bound = "ceiling"
				local_market.ceiling_days[commodity] = local_market.ceiling_days.get(commodity, 0) + 1
			local_market.last_price_signal[commodity] = {
				"opening_price": opening, "closing_price": closing,
				"offer": offer, "funded_household": s["funded_household"], "funded_business": s["funded_business"],
				"business_buffer_request": s["business_buffer_request"], "import_capacity": s["import_capacity"], "working_stock": s["working_stock"],
				"shortage": shortage, "unsold": unsold,
				"wanted_household": s["wanted_household"], "unfunded_household": s["unfunded_household"],
				"pressure": pressure, "reason": reason, "bound": bound,
			}
	_price_signal_today = {}

## Valley mode: the seller's reserve and minimum price are the constraints.
## The standalone Trader's low excess-clearing bid is deliberately not used.
## The coordinator compares this floor with the destination's market price.
func get_valley_trade_offer(commodity: Commodity.Type) -> Dictionary:
	var settlement_id := _resolve_settlement_id(-1)
	var trader := _settlement_trader(settlement_id)
	var seller := _business_selling(settlement_id, commodity)
	if trader == null:
		return {"quantity": 0.0, "min_price": 0.0}
	if not _trader_export_enabled.get(trader.id, {}).get(commodity, false):
		return {"quantity": 0.0, "min_price": 0.0}
	var capacity: float = float(_business_employed_worker_count(trader.id)) * VALLEY_TRADER_CAPACITY_PER_WORKER
	var held := minf(trader.stock(commodity), _valley_reserved_stock.get(commodity, 0.0))
	var offer := _seller_trade_offer(seller, commodity) if seller != null else {"quantity": 0.0, "min_price": 0.0}
	var floor_price: float = offer["min_price"]
	if held > 0.0001:
		floor_price = maxf(floor_price, _valley_reserved_unit_cost.get(commodity, 0.0))
	return {"quantity": minf(capacity, held + offer["quantity"]), "min_price": floor_price, "held": held}

## Bounded interest a neighboring Trader can act on. Charcoal is only attractive
## when its delivered price beats timber's heat value, and imports are limited
## to a month of likely household use. Stone fills a small construction reserve.
func get_valley_import_interest(commodity: Commodity.Type, delivered_price: float, in_transit: float = 0.0) -> float:
	var settlement_id := _resolve_settlement_id(-1)
	if delivered_price <= 0.0:
		return 0.0
	var trader := _settlement_trader(settlement_id)
	var held := trader.stock(commodity) if trader != null else 0.0
	if commodity in [Commodity.Type.CHARCOAL, Commodity.Type.STONE] and _business_selling(settlement_id, commodity) != null:
		return 0.0 # local producers do not import their own output
	if commodity == Commodity.Type.CHARCOAL:
		var market: HEMarket = markets[settlement_id]
		var heat_need := 0.0
		var household_stock := 0.0
		var household_timber_stock := 0.0
		for household_id in (settlements[settlement_id] as HESettlement).household_ids:
			var h: HEHousehold = households[household_id]
			heat_need += float(h.headcount()) * 0.1 / 4.0
			household_stock += h.stock(commodity)
			household_timber_stock += h.stock(Commodity.Type.TIMBER)
		# Timber is the baseline heat source; charcoal must offer at least as
		# much heat per coin when timber is actually available. A town whose
		# Woodlot has run dry can still bid for dearer charcoal to avoid cold.
		var timber_available: float = _household_offer(settlement_id, Commodity.Type.TIMBER) + household_timber_stock / TARGET_BUFFER_DAYS
		if delivered_price / 4.0 > market.price[Commodity.Type.TIMBER] * 1.03 and timber_available >= heat_need * 4.0:
			return 0.0
		var business_use := _business_input_daily_use(settlement_id, commodity, null)
		var business_stock := 0.0
		for business in businesses.values():
			if business.settlement_id == settlement_id and business.recipe != null and business.recipe.inputs.has(commodity):
				business_stock += business.stock(commodity)
		var local_seller := _business_selling(settlement_id, commodity)
		var seller_stock := local_seller.stock(commodity) if local_seller != null else 0.0
		var business_reserve := maxf(0.0, business_use * 30.0 - business_stock)
		return maxf(0.0, heat_need * 30.0 + business_reserve - held - household_stock - seller_stock - in_transit)
	if commodity == Commodity.Type.STONE:
		var target := 20.0 # small repair stock; construction can place a larger order
		return maxf(0.0, target - _town_stored(settlement_id, commodity) - in_transit)
	return 0.0

func get_valley_trader_capacity() -> float:
	var trader := _settlement_trader(_resolve_settlement_id(-1))
	return float(_business_employed_worker_count(trader.id)) * VALLEY_TRADER_CAPACITY_PER_WORKER if trader != null else 0.0

func get_valley_trader_purchase_capacity(unit_price: float) -> float:
	var settlement_id := _resolve_settlement_id(-1)
	var trader := _settlement_trader(settlement_id)
	if trader == null or unit_price <= 0.0:
		return 0.0
	var employed := _business_employed_worker_count(trader.id)
	if employed <= 0:
		return 0.0
	# Neighbor contracts turn over within days; holding a full month of wages
	# idle prevented otherwise funded relay purchases in small towns.
	var wage_reserve := 7.0 * wages.liquidity_scale(settlement_id) * employed
	return maxf(0.0, trader.balance - wage_reserve) / unit_price

func get_valley_relay_destination(commodity: Commodity.Type) -> int:
	return int(_valley_reserved_destination.get(commodity, -1))

func get_valley_relay_reserved_stock(commodity: Commodity.Type) -> float:
	return float(_valley_reserved_stock.get(commodity, 0.0))

func get_valley_trade_price(commodity: Commodity.Type) -> float:
	var settlement_id := _resolve_settlement_id(-1)
	if is_livestock(commodity):
		return _export_reference_price(settlement_id, commodity)
	return 0.5 * (markets[settlement_id] as HEMarket).price[commodity] + 0.5 * _average_price_history(settlement_id, commodity)

func get_valley_port_buy_price(commodity: Commodity.Type) -> float:
	var settlement_id := _resolve_settlement_id(-1)
	var port := _settlement_port(settlement_id)
	if not PORT_GOODS.has(commodity) or port == null or _business_employed_worker_count(port.id) <= 0:
		return 0.0
	return PORT_BUY_PRICE_FRACTION * _port_outside_price(settlement_id, commodity)

## The outside market has a stable reference price even when a local glut
## drives Staithe's household quote to its floor.
func _port_outside_price(settlement_id: int, commodity: Commodity.Type) -> float:
	if is_livestock(commodity):
		return _export_reference_price(settlement_id, commodity)
	return maxf(BASE_PRICE[commodity], (markets[settlement_id] as HEMarket).price[commodity])

## A town without an outside Port buys iron and ore for its staffed workshops,
## not because an inactive market still displays its base quote.
func get_valley_workshop_import_need(commodity: Commodity.Type, in_transit: float) -> float:
	var settlement_id := _resolve_settlement_id(-1)
	var daily_use := _business_input_daily_use(settlement_id, commodity, null)
	return maxf(0.0, daily_use * 30.0 - _town_stored(settlement_id, commodity) - in_transit)

## A staffed Port buys whatever local sellers can spare and sells it to an
## unlimited outside market. Port staffing limits daily throughput.
func _run_port_trade(record: Dictionary) -> void:
	for settlement_id in settlements.keys():
		var port := _settlement_port(settlement_id)
		if port == null:
			continue
		var capacity: float = float(_business_employed_worker_count(port.id)) * TRADER_CAPACITY_PER_WORKER
		var remaining := maxf(0.0, capacity - port.last_actual_units)
		for commodity in PORT_GOODS:
			if remaining <= 0.0001:
				break
			var handling_available := remaining
			var exported_for_good := 0.0
			var market_price := _port_outside_price(settlement_id, commodity)
			var offered := 0.0
			var port_stock := port.stock(commodity)
			if port_stock > 0.0001:
				offered += port_stock
				var imported_quantity := minf(remaining, port_stock)
				var imported_revenue := imported_quantity * market_price
				port.consume(commodity, imported_quantity)
				port.add_flow(HEBusiness.FLOW_SOLD, commodity, imported_quantity)
				port.balance += imported_revenue
				port.ledger_add("sales_export", imported_revenue)
				port.ledger_add_good("export", commodity, imported_quantity)
				port.last_revenue += imported_revenue
				port.last_exported[commodity] = port.last_exported.get(commodity, 0.0) + imported_quantity
				port.last_actual_units += imported_quantity
				exported_for_good += imported_quantity
				var imported_name := Commodity.name_of(commodity)
				record["exported"][imported_name] = record["exported"].get(imported_name, 0.0) + imported_quantity
				record["export_revenue"] += imported_revenue
				record["trader_transactions"].append({"day": day + 1, "business_id": port.id,
					"settlement_id": settlement_id, "direction": "export", "commodity": imported_name,
					"quantity": imported_quantity, "unit_price": market_price,
					"paid_price": market_price * PORT_BUY_PRICE_FRACTION,
					"local_value": imported_revenue, "route": "Outside"})
				if is_livestock(commodity):
					_livestock_market_today(record, commodity)["exported"] += imported_quantity
				_export_revenue_total += imported_revenue
				remaining -= imported_quantity
			var seller := _business_selling(settlement_id, commodity)
			if seller != null:
				var offer := _seller_trade_offer(seller, commodity)
				offered += float(offer["quantity"])
				var outside_bid := market_price * PORT_BUY_PRICE_FRACTION
				var seller_meets_floor := outside_bid + 0.00001 >= float(offer["min_price"]) \
					and maxf(outside_bid, float(offer["min_price"])) <= market_price * 0.9
				var seller_bid := maxf(outside_bid, float(offer["min_price"])) if seller_meets_floor else outside_bid
				var eligible: float = float(offer["quantity"]) if seller_meets_floor else float(offer["salvage_quantity"])
				if seller_meets_floor:
					var quantity := minf(remaining, eligible)
					if quantity > 0.0001:
						seller.consume(commodity, quantity)
						seller.add_flow(HEBusiness.FLOW_SOLD, commodity, quantity)
						seller.balance += quantity * seller_bid
						seller.ledger_add("sales_export", quantity * seller_bid)
						seller.ledger_add_good("export", commodity, quantity)
						seller.last_revenue += quantity * seller_bid
						var margin := quantity * (market_price - seller_bid)
						port.balance += margin
						port.ledger_add("trade_margin", margin)
						port.ledger_add_good("export", commodity, quantity)
						port.last_revenue += margin
						port.last_exported[commodity] = port.last_exported.get(commodity, 0.0) + quantity
						port.last_actual_units += quantity
						exported_for_good += quantity
						var name := Commodity.name_of(commodity)
						record["exported"][name] = record["exported"].get(name, 0.0) + quantity
						record["export_revenue"] += quantity * market_price
						record["trader_transactions"].append({"day": day + 1, "business_id": port.id,
							"settlement_id": settlement_id, "direction": "export", "commodity": name,
							"seller_id": seller.id, "quantity": quantity, "unit_price": market_price,
							"paid_price": seller_bid, "local_value": quantity * market_price})
						if is_livestock(commodity):
							_livestock_market_today(record, commodity)["exported"] += quantity
						_export_revenue_total += quantity * market_price
						remaining -= quantity
				elif not seller_meets_floor:
					var salvage_quantity := minf(remaining, eligible)
					if salvage_quantity > 0.0001:
						seller.consume(commodity, salvage_quantity)
						seller.add_flow(HEBusiness.FLOW_SOLD, commodity, salvage_quantity)
						seller.balance += salvage_quantity * seller_bid
						seller.ledger_add("sales_export", salvage_quantity * seller_bid)
						seller.ledger_add_good("export", commodity, salvage_quantity)
						seller.last_revenue += salvage_quantity * seller_bid
						var salvage_margin := salvage_quantity * (market_price - seller_bid)
						port.balance += salvage_margin
						port.ledger_add("trade_margin", salvage_margin)
						port.ledger_add_good("export", commodity, salvage_quantity)
						port.last_revenue += salvage_margin
						port.last_exported[commodity] = port.last_exported.get(commodity, 0.0) + salvage_quantity
						port.last_actual_units += salvage_quantity
						exported_for_good += salvage_quantity
						var salvage_name := Commodity.name_of(commodity)
						record["exported"][salvage_name] = record["exported"].get(salvage_name, 0.0) + salvage_quantity
						record["export_revenue"] += salvage_quantity * market_price
						record["trader_transactions"].append({"day": day + 1, "business_id": port.id,
							"settlement_id": settlement_id, "direction": "export", "commodity": salvage_name,
							"seller_id": seller.id, "quantity": salvage_quantity, "unit_price": market_price,
							"paid_price": seller_bid, "local_value": salvage_quantity * market_price})
						if is_livestock(commodity):
							_livestock_market_today(record, commodity)["exported"] += salvage_quantity
						_export_revenue_total += salvage_quantity * market_price
						remaining -= salvage_quantity
			var local_market: HEMarket = markets[settlement_id]
			local_market.record_export(commodity, handling_available, exported_for_good)
			if not SUBSISTENCE_COMMODITIES.has(commodity) and not is_livestock(commodity):
				local_market.merge_clearing(commodity, offered, offered, exported_for_good, market_price)
		port.last_planned_units = capacity

func get_valley_market_prices() -> Dictionary:
	var settlement_id := _resolve_settlement_id(-1)
	var prices := {}
	for commodity in BASE_PRICE:
		prices[Commodity.name_of(commodity)] = (markets[settlement_id] as HEMarket).price[commodity]
	return prices

## The origin Trader buys at the negotiated seller price and sells to the
## destination Trader at the intertown price. Both values come from the matched
## valley opportunity, never from the standalone excess-clearing bid.
func dispatch_valley_shipment(commodity: Commodity.Type, requested: float, sale_price: float, seller_price: float, route_cost: float = 0.0) -> float:
	var offer := get_valley_trade_offer(commodity)
	if sale_price + 0.00001 < seller_price:
		return 0.0
	var quantity: float = minf(requested, offer["quantity"])
	if quantity <= 0.0001:
		return 0.0
	var settlement_id := _resolve_settlement_id(-1)
	var trader := _settlement_trader(settlement_id)
	var seller := _business_selling(settlement_id, commodity)
	var held_sale := minf(quantity, _valley_reserved_stock.get(commodity, 0.0))
	if held_sale > 0.0:
		var held_unit_cost: float = _valley_reserved_unit_cost.get(commodity, 0.0)
		_valley_reserved_stock[commodity] = maxf(0.0, _valley_reserved_stock.get(commodity, 0.0) - held_sale)
		if _valley_reserved_stock[commodity] <= 0.0001:
			_valley_reserved_stock.erase(commodity)
			_valley_reserved_destination.erase(commodity)
			_valley_reserved_unit_cost.erase(commodity)
		trader.consume(commodity, held_sale)
		trader.add_flow(HEBusiness.FLOW_SOLD, commodity, held_sale)
		trader.balance += held_sale * (sale_price - route_cost)
		var held_margin := held_sale * (sale_price - route_cost - held_unit_cost)
		trader.ledger_add("trade_margin", held_margin)
		trader.ledger_add("transport_cost", held_sale * route_cost)
		trader.ledger_add_good("export", commodity, held_sale)
		trader.last_revenue += held_margin
	var local_sale := quantity - held_sale
	if local_sale > 0.0001:
		if seller == null:
			return held_sale
		var local_offer := _seller_trade_offer(seller, commodity)
		if seller_price + 0.00001 < local_offer["min_price"]:
			return held_sale
		local_sale = minf(local_sale, local_offer["quantity"])
		quantity = held_sale + local_sale
		seller.consume(commodity, local_sale)
		seller.add_flow(HEBusiness.FLOW_SOLD, commodity, local_sale)
		seller.balance += local_sale * seller_price
		seller.ledger_add("sales_export", local_sale * seller_price)
		seller.ledger_add_good("export", commodity, local_sale)
		seller.last_revenue += local_sale * seller_price
		var margin := local_sale * (sale_price - seller_price - route_cost)
		trader.balance += margin
		trader.ledger_add("trade_margin", margin)
		trader.ledger_add("transport_cost", local_sale * route_cost)
		trader.last_revenue += margin
	trader.last_exported[commodity] = trader.last_exported.get(commodity, 0.0) + quantity
	_export_revenue_total += quantity * sale_price
	return quantity

func pay_for_valley_shipment(commodity: Commodity.Type, quantity: float, unit_price: float) -> void:
	var trader := _settlement_trader(_resolve_settlement_id(-1))
	if trader != null:
		trader.balance -= quantity * unit_price
		_import_cost_total += quantity * unit_price

func receive_valley_shipment(commodity: Commodity.Type, quantity: float, relay_destination: int = -1, unit_cost: float = 0.0, port_terminal: bool = false) -> void:
	var trader := _settlement_trader(_resolve_settlement_id(-1))
	var port := _settlement_port(_resolve_settlement_id(-1))
	if port_terminal and trader != null and port != null:
		var settlement_id := _resolve_settlement_id(-1)
		var unit_price := get_valley_port_buy_price(commodity)
		var gross := quantity * unit_price
		var tax := _collect_sales_tax(settlement_id, gross)
		trader.add_flow(HEBusiness.FLOW_SOLD, commodity, quantity)
		trader.balance += gross - tax
		trader.ledger_add("sales_business", gross)
		trader.ledger_add("taxes", tax)
		trader.last_revenue += gross - tax
		trader.last_cash_change += gross - tax
		port.add_stock(commodity, quantity)
		port.add_flow(HEBusiness.FLOW_BOUGHT, commodity, quantity)
		port.balance -= gross
		port.ledger_add("input_local", gross)
		port.last_imported[commodity] = port.last_imported.get(commodity, 0.0) + quantity
		var name := Commodity.name_of(commodity)
		var transaction := {"day": day + 1, "business_id": port.id, "direction": "import",
			"commodity": name, "quantity": quantity, "unit_price": unit_price,
			"local_value": gross, "route": "Valley Trader"}
		_pending_valley_transactions.append(transaction)
	elif trader != null:
		trader.add_stock(commodity, quantity)
		if relay_destination >= 0:
			var previous_quantity: float = _valley_reserved_stock.get(commodity, 0.0)
			var previous_cost: float = _valley_reserved_unit_cost.get(commodity, 0.0)
			_valley_reserved_stock[commodity] = previous_quantity + quantity
			_valley_reserved_unit_cost[commodity] = (previous_quantity * previous_cost + quantity * unit_cost) / (previous_quantity + quantity)
			_valley_reserved_destination[commodity] = relay_destination

func record_valley_transaction(direction: String, commodity: Commodity.Type, quantity: float, unit_price: float, route: String, on_arrival: bool = false) -> void:
	var trader := _settlement_trader(_resolve_settlement_id(-1))
	if trader == null:
		return
	var transaction := {
		"day": day + 1 if on_arrival else day,
		"business_id": trader.id,
		"direction": direction,
		"commodity": Commodity.name_of(commodity),
		"quantity": quantity,
		"unit_price": unit_price,
		"local_value": quantity * unit_price,
		"route": route,
	}
	if on_arrival or _history.is_empty():
		_pending_valley_transactions.append(transaction)
	else:
		(_history.back() as Dictionary)["trader_transactions"].append(transaction)

## A good's value for splitting costs among co-products and estimating seller costs.
func _good_reference_value(commodity: Commodity.Type) -> float:
	if is_livestock(commodity):
		return livestock_quote(livestock_species(commodity), LivestockQuote.POSTED)
	return BASE_PRICE.get(commodity, 0.0)

## A seller's decision about what to export: stock it can spare after its own
## forecast of local use until its next supply, and the least it will take.
##   reserve = routine local use x days until next supply
##           + today's outstanding funded shortage (counted once)
##           + known input needs of staffed local businesses tomorrow
## Units above the reserve are offered, at no less than `min_price`; units above
## the reserve PLUS SELLER_SALVAGE_COVER_DAYS more of routine use are excess and
## go at any bid (`salvage_quantity`). A good no one locally uses has no reserve
## and no cover to protect, so everything is salvage.
## KNOWN LIMIT (measured, see the PR): that means an export-only good (iron, and
## livestock no Butcher buys) is never held to `min_price`. Holding its first 30
## days of output behind the floor stopped iron exporting at all (the Trader's
## bid ceiling leaves a wage of spread, below iron's cost ratio) and starved the
## Bloomery, so the bypass is load-bearing until iron's recipe/price is retuned.
func _seller_trade_offer(seller: HEBusiness, commodity: Commodity.Type) -> Dictionary:
	var horizon := float(_days_until_next_supply(seller)) + seasonal_carry_days(commodity, day)
	var routine := _routine_local_use(seller, commodity)
	var outstanding := _outstanding_funded_shortage(seller.settlement_id, commodity)
	var next_day := _next_day_input_need(seller, commodity)
	var stock := seller.stock(commodity)
	var reserve := routine * horizon + outstanding + next_day
	var salvage_floor := routine * (horizon + SELLER_SALVAGE_COVER_DAYS) + outstanding + next_day
	return {
		"stock": stock, "horizon": horizon, "routine_use": routine, "outstanding": outstanding,
		"next_day_need": next_day, "reserve": reserve,
		"quantity": maxf(0.0, stock - reserve),
		"salvage_quantity": maxf(0.0, stock - salvage_floor),
		"min_price": _seller_min_price(seller, commodity),
	}

## Units per day the seller sells (or would) to local buyers: what its ledger
## shows over SELLER_FORECAST_WINDOW_DAYS, never less than what its customers
## are known to use -- households' daily need and staffed workshops' planned
## input use -- because sales cannot exceed what was in stock to sell, so a seller
## that sold out recently would otherwise forecast a lower demand than exists.
## Until the ledger has SELLER_FORECAST_MIN_ROWS days, the known use alone.
func _routine_local_use(seller: HEBusiness, commodity: Commodity.Type) -> float:
	var observed := 0.0
	if seller.ledger_row_count() >= SELLER_FORECAST_MIN_ROWS:
		observed = seller.ledger_good_average("local", commodity, SELLER_FORECAST_WINDOW_DAYS)
	return maxf(observed, _known_daily_local_use(seller, commodity))

func _known_daily_local_use(seller: HEBusiness, commodity: Commodity.Type) -> float:
	if is_livestock(commodity):
		return 0.0
	var use := _settlement_daily_demand(seller.settlement_id, commodity) + _business_input_daily_use(seller.settlement_id, commodity, seller)
	if commodity == Commodity.Type.GRAIN:
		# Herd fodder is bought in a short autumn window but consumed once per
		# winter. Include its annual average in the seller's baseline forecast so
		# a Port cannot export the grain that ranches will need later in the year.
		for business_id in businesses.keys():
			var herd: HEBusiness = businesses[business_id]
			if herd.settlement_id == seller.settlement_id and herd.kind == HEBusiness.Kind.HERD:
				use += herd.herd_size * FODDER_PER_HEAD_PER_WINTER[herd.species] / float(DAYS_PER_YEAR)
	return use

## Funded requests today's local clearing could not fill (counted once, not per
## day to the next supply: it is a backlog, not a rate). Zero for a good with no
## local clearing.
func _outstanding_funded_shortage(settlement_id: int, commodity: Commodity.Type) -> float:
	var signal_today: Dictionary = (_price_signal_today.get(settlement_id, {}) as Dictionary).get(commodity, {})
	if signal_today.is_empty():
		return 0.0
	return maxf(0.0, signal_today["funded_household"] + signal_today["funded_business"] - signal_today["offer"])

## What staffed local businesses (other than the seller) will use of `commodity`
## tomorrow beyond what they already hold. Production runs before the next day's
## local purchasing, so this is protected explicitly. Animals need none: the
## Butcher buys before anything is exported (see _run_livestock_purchasing), and a
## ranch's forecast of Butcher purchases already keeps head back for it.
func _next_day_input_need(seller: HEBusiness, commodity: Commodity.Type) -> float:
	if is_livestock(commodity):
		return 0.0
	var total := 0.0
	for business_id in businesses.keys():
		var b: HEBusiness = businesses[business_id]
		if b == seller or b.settlement_id != seller.settlement_id or b.kind != HEBusiness.Kind.PRODUCTION or b.recipe == null:
			continue
		if not b.recipe.inputs.has(commodity):
			continue
		var planned: float = float(_business_employed_worker_count(business_id)) * b.recipe.outputs[b.output_commodity()]
		total += maxf(0.0, planned * b.recipe.inputs[commodity] - b.stock(commodity))
	return total

## The least a seller will take for one unit of `commodity`: its cost to make a
## unit of its output, over its production cycle, times the good's value. See
## _seller_cost_ratio.
func _seller_min_price(seller: HEBusiness, commodity: Commodity.Type) -> float:
	return _seller_cost_ratio(seller) * _good_reference_value(commodity)

## Cost per unit of output value over the seller's whole production cycle:
## (wages + inputs consumed) / (units produced x each good's reference value).
## Shared costs are allocated among a business's co-products (wool and animals,
## meat and leather) by reference value, so every good it makes carries the same
## cost-to-value ratio. Measured on units PRODUCED over a full cycle, not units
## sold over a short window: a harvest crew's wages precede a lump of output, and
## a ranch's wool and culls arrive once a review. Until a full cycle of ledger
## rows exists (or nothing has been produced), the documented starting quote
## SELLER_STARTING_COST_RATIO applies -- the Trader's old fixed half price.
func _seller_cost_ratio(seller: HEBusiness) -> float:
	var window := maxi(seller.rolling_window_days(), SELLER_FORECAST_WINDOW_DAYS)
	if seller.ledger_row_count() < window:
		return SELLER_STARTING_COST_RATIO
	var cost := seller.ledger_average("wages", window) + seller.ledger_average("input_consumed_value", window)
	var value := 0.0
	for commodity in _business_output_commodities(seller):
		value += seller.ledger_good_average("produced", commodity, window) * _good_reference_value(commodity)
	if value <= 0.0001:
		return SELLER_STARTING_COST_RATIO
	return clampf(cost / value, 0.0, SELLER_COST_RATIO_CAP)

## The price an export of `commodity` is valued at, and that the Trader's bid
## (PORT_BUY_PRICE_FRACTION of it) is a fraction of: the settlement's market
## price, or for livestock -- which has no household market -- its posted price.
func _export_reference_price(settlement_id: int, commodity: Commodity.Type) -> float:
	if is_livestock(commodity):
		return livestock_quote(livestock_species(commodity), LivestockQuote.POSTED)
	return (markets[settlement_id] as HEMarket).price[commodity]

## The herd size `b` culls back down to each review: its own player-set
## cull_target, or the species default if none was ever set.
func herd_cull_target(b: HEBusiness) -> float:
	return b.cull_target if b.cull_target > 0.0 else default_cull_target(b.species, ranch_land(b))

## Share (0..1) of a review's net herd growth a dynamic-cull ranch sells at
## `herd_size` against `target`: 0 at the breeding-stock floor, 1 at the target.
static func dynamic_cull_share(herd_size: float, target: float) -> float:
	if target <= 0.0:
		return 0.0
	return clampf((herd_size / target - HERD_BREEDING_STOCK_FLOOR) / (1.0 - HERD_BREEDING_STOCK_FLOOR), 0.0, 1.0)

## Player-facing switch for a ranch's dynamic cull. Returns the applied value,
## or false for an unknown / non-herd business.
func set_herd_dynamic_cull(business_id: int, enabled: bool) -> bool:
	if not businesses.has(business_id):
		return false
	var b: HEBusiness = businesses[business_id]
	if b.kind != HEBusiness.Kind.HERD:
		return false
	b.dynamic_cull = enabled
	return enabled

## A ranch's acreage: its own land_area_acres, or the species default for a
## builder that never set one.
func ranch_land(b: HEBusiness) -> float:
	return b.land_area_acres if b.land_area_acres > 0.0 else DEFAULT_RANCH_LAND_ACRES[b.species]

## The range a ranch's cull target may be set to: never below the hardship
## butchering floor (selling down to it would otherwise fight the cull), and
## never above what the ranch's own land can carry.
func herd_cull_target_range(b: HEBusiness) -> Vector2:
	var lowest: float = HARDSHIP_BUTCHER_MIN_HERD[b.species]
	var highest: float = maxf(lowest, floorf(herd_land_capacity(b.species, ranch_land(b))))
	return Vector2(lowest, highest)

## How many sheep it takes to cover this settlement's current household wool
## demand (population x wool's per-person daily use), as (no staff, at the
## ranch's CURRENT staffing, full crew) head counts. Each sheep's yield is
## the base fleece x (1 + HERD_STAFFED_WOOL_BONUS x care), so more care means
## fewer sheep are needed. "Current" uses the care the last review applied
## (b.last_care_fraction). Informational only (a hint for setting the sheep
## cull target); Vector3.ZERO for a non-sheep business.
func wool_sustaining_herd_counts(b: HEBusiness) -> Vector3:
	if b.kind != HEBusiness.Kind.HERD or b.species != HEBusiness.Species.SHEEP:
		return Vector3.ZERO
	var population := 0
	for household_id in (settlements[b.settlement_id] as HESettlement).household_ids:
		population += (households[household_id] as HEHousehold).headcount()
	var demand_per_day: float = population * HENeeds.units_per_person_daily(Commodity.Type.WOOL)
	var wool_per_head_per_day: float = WOOL_PER_HEAD_PER_INTERVAL / float(HERD_EVAL_INTERVAL_DAYS)
	if wool_per_head_per_day <= 0.0:
		return Vector3.ZERO
	var at_care := func(care: float) -> float:
		return ceilf(demand_per_day / (wool_per_head_per_day * (1.0 + HERD_STAFFED_WOOL_BONUS * care)))
	return Vector3(at_care.call(0.0), at_care.call(b.last_care_fraction), at_care.call(1.0))

## Player-facing setter for a ranch's cull target. Clamps to
## herd_cull_target_range(), re-derives the ranch's staff ceiling from the
## new target (the same formula the scenario seeds use, so a bigger herd to
## look after raises it and a smaller one lowers it), and returns the value
## actually applied. A herd already above a lowered target is culled down to
## it at the next review. No-op (returns -1) for a non-herd business.
func set_herd_cull_target(business_id: int, value: float) -> float:
	if not businesses.has(business_id):
		return -1.0
	var b: HEBusiness = businesses[business_id]
	if b.kind != HEBusiness.Kind.HERD:
		return -1.0
	var limits := herd_cull_target_range(b)
	b.cull_target = clampf(value, limits.x, limits.y)
	b.max_capacity = ceili(b.cull_target * HERD_LABOR_PER_HEAD_PER_DAY[b.species])
	if b.capacity > b.max_capacity:
		b.capacity = b.max_capacity
	return b.cull_target

## Every HERD_EVAL_INTERVAL_DAYS: each ranch grazes, breeds/dies, and culls
## on its own -- no employment, no wages, no market clearing (see
## he_business.gd's Kind.HERD doc comment for why). Ranches within the same
## settlement are processed in a fixed id order (same deterministic-bias
## convention as _run_trade's edge order). Each ranch grazes its own land.
func _run_herds(record: Dictionary) -> void:
	var herd_ids: Array[int] = []
	for business_id in businesses.keys():
		if (businesses[business_id] as HEBusiness).kind == HEBusiness.Kind.HERD:
			herd_ids.append(business_id)
	herd_ids.sort()

	for business_id in herd_ids:
		var b: HEBusiness = businesses[business_id]
		var max_herd_by_land: float = herd_land_capacity(b.species, ranch_land(b))

		# Fed if the herd already fits its land; a herd that has outgrown it
		# is neglected -- no grain is bought to make up the gap (see
		# CATTLE_LAND_PER_HEAD's doc comment).
		var fed := b.herd_size <= max_herd_by_land
		var herd_before: float = b.herd_size

		# Care: the staffed share of the worker-days this herd needs for full
		# care over the interval. 0 = nobody employed (free-range baseline),
		# 1 = fully staffed. Drives the upsides in HERD_STAFFED_*.
		var care_required: float = herd_before * HERD_LABOR_PER_HEAD_PER_DAY[b.species] * HERD_EVAL_INTERVAL_DAYS
		var care: float = clampf(b.care_worker_days / care_required, 0.0, 1.0) if care_required > 0.0 else 1.0
		b.care_worker_days = 0.0
		b.last_care_fraction = care

		# The review closes the season containing `day`. A winter review also
		# eats the herd's own fodder, and how much of it there was moves the
		# herd's mortality from FED toward NEGLECTED. Births stay a flat
		# per-review rate: bunching them into three seasons made each cull a
		# third bigger and skipped winter's, more than the Butcher could take.
		var review_season := season_of_day(day)
		var fodder_needed := 0.0
		var fodder_eaten := 0.0
		var fodder_cover := 1.0
		if review_season == Season.WINTER:
			fodder_needed = herd_before * FODDER_PER_HEAD_PER_WINTER[b.species]
			fodder_eaten = b.consume(Commodity.Type.GRAIN, fodder_needed)
			fodder_cover = fodder_eaten / fodder_needed if fodder_needed > 0.0 else 1.0
			if fodder_eaten > 0.0:
				b.add_flow(HEBusiness.FLOW_CONSUMED, Commodity.Type.GRAIN, fodder_eaten)
				_accumulate(record["consumed"], Commodity.name_of(Commodity.Type.GRAIN), fodder_eaten)
		var base_loss: float = HERD_LOSS_RATE_FED[b.species] if fed else HERD_LOSS_RATE_NEGLECTED[b.species]
		var starved_loss: float = lerpf(HERD_LOSS_RATE_NEGLECTED[b.species], HERD_LOSS_RATE_FED[b.species], fodder_cover)
		var loss_rate: float = maxf(base_loss, starved_loss) * (1.0 - HERD_STAFFED_MORTALITY_CUT * care)
		var born: float = herd_before * HERD_GROWTH_RATE[b.species] * HERD_GROWTH_RATE_MULTIPLIER * (1.0 + HERD_STAFFED_REPRODUCTION_BONUS * care)
		var died: float = herd_before * loss_rate
		b.herd_size = clampf(herd_before + born - died, 0.0, max_herd_by_land)
		b.last_review_season = review_season
		b.last_fodder_needed = fodder_needed
		b.last_fodder_eaten = fodder_eaten
		_log_herd_event(b, "herd_birth", {"born": born, "died": died, "fed": fed, "care": care, "herd_after": b.herd_size, "season": review_season, "fodder_needed": fodder_needed, "fodder_eaten": fodder_eaten})

		b.last_wool_produced = 0.0
		if b.species == HEBusiness.Species.SHEEP:
			var wool: float = b.herd_size * WOOL_PER_HEAD_PER_INTERVAL * (1.0 + HERD_STAFFED_WOOL_BONUS * care) * seasonal_yield_scale(Commodity.Type.WOOL, day)
			b.add_stock(Commodity.Type.WOOL, wool)
			b.last_wool_produced = wool
			_accumulate(record["produced"], Commodity.name_of(Commodity.Type.WOOL), wool)

		# Whatever the Trader or Butcher did not take of the last cull in a
		# whole review is butchered at home now: a ranch holds no standing stock.
		_butcher_stock_at_home(b, b.stock(b.herd_commodity()), record)

		b.last_culled = {}
		b.last_actual_units = 0.0
		var target: float = herd_cull_target(b)
		# Dynamic cull: sell a share of this review's net growth ahead of the
		# hard cap, so income starts well before the herd fills its target.
		var growth_sold := 0.0
		if b.dynamic_cull and b.herd_size < target:
			growth_sold = maxf(b.herd_size - herd_before, 0.0) * dynamic_cull_share(b.herd_size, target)
			b.herd_size -= growth_sold
		if growth_sold > 0.0 or b.herd_size > target:
			var excess: float = growth_sold + maxf(b.herd_size - target, 0.0)
			b.herd_size = minf(b.herd_size, target)
			var commodity := b.herd_commodity()
			b.add_stock(commodity, excess)
			b.last_culled[commodity] = excess
			b.last_actual_units = excess
			_accumulate(record["produced"], Commodity.name_of(commodity), excess)
			_log_herd_event(b, "herd_cull", {"head": excess, "herd_after": b.herd_size})
			# With no staffed Trader or Butcher to take the cull, the ranch
			# butchers it itself right away instead of stockpiling it.
			if not _livestock_has_outlet(b.settlement_id, commodity):
				_butcher_stock_at_home(b, excess, record)

		b.collateral_herd = b.herd_size

func _accumulate(dict: Dictionary, key, amount: float) -> void:
	dict[key] = dict.get(key, 0.0) + amount

## Appends one blotter row tagged with the current day, then drops events
## older than EVENT_LOG_RETENTION_DAYS. Retention follows simulation time,
## not event count, so bursts cannot erase other same-period event types.
func _log_event(type: String, data: Dictionary) -> void:
	var entry := {"day": day, "type": type}
	for key in data.keys():
		entry[key] = data[key]
	_event_log.append(entry)
	if type in ["job", "fired"]:
		var business_id: int = entry["business_id"]
		if not _employment_event_log.has(business_id):
			_employment_event_log[business_id] = []
		var employment_events: Array = _employment_event_log[business_id]
		employment_events.append(entry)
		var same_type_count := 0
		for employment_event in employment_events:
			if employment_event["type"] == type:
				same_type_count += 1
		if same_type_count > EMPLOYMENT_EVENTS_PER_TYPE:
			for i in employment_events.size():
				if employment_events[i]["type"] == type:
					employment_events.remove_at(i)
					break
	var cutoff_day: int = day - EVENT_LOG_RETENTION_DAYS + 1
	while not _event_log.is_empty() and _event_log[0]["day"] < cutoff_day:
		_event_log.pop_front()

## One entry point for every ranch event: appended to the ranch's own
## bounded history (shown in its detail view) AND to the shared blotter,
## tagged with business_id either way so one formatter serves both.
func _log_herd_event(b: HEBusiness, type: String, data: Dictionary) -> void:
	var payload := data.duplicate()
	payload["business_id"] = b.id
	_log_event(type, payload)
	b.herd_events.append(_event_log.back().duplicate())
	if b.herd_events.size() > HERD_EVENT_HISTORY_MAX:
		b.herd_events.pop_front()

## Resolves whichever business sells `commodity` locally -- a PRODUCTION
## business whose recipe outputs it, (WOOL only) whichever Sheep Farm holds it,
## or (a livestock good) the ranch of that species holding culled head. No
## household buys a live animal, so livestock never joins the household market;
## the seller it resolves here is what a Trader export draws on, and the Butcher
## buys from ranches directly (see _run_livestock_purchasing).
func _business_selling(settlement_id: int, commodity: Commodity.Type) -> HEBusiness:
	for business_id in businesses.keys():
		var b: HEBusiness = businesses[business_id]
		if b.settlement_id != settlement_id:
			continue
		if b.sells(commodity):
			return _home_butchery_seller(settlement_id, commodity, b)
		if b.kind == HEBusiness.Kind.HERD and b.species == HEBusiness.Species.SHEEP and commodity == Commodity.Type.WOOL:
			return b
		if b.kind == HEBusiness.Kind.HERD and is_livestock(commodity) and b.herd_commodity() == commodity:
			return b
	return _home_butchery_seller(settlement_id, commodity, null)

## A market has one seller per good, but meat can come from two places: the
## Butcher, or a ranch's own hardship slaughter (_hardship_butcher_if_needed).
## The Butcher keeps the market while it holds meat; a ranch's home-butchered
## meat sells when the Butcher is absent or sold out, so it is never stranded.
func _home_butchery_seller(settlement_id: int, commodity: Commodity.Type, primary: HEBusiness) -> HEBusiness:
	if commodity != Commodity.Type.MEAT or (primary != null and primary.stock(commodity) > 0.0001):
		return primary
	for herd_id in _herd_business_ids(settlement_id):
		if (businesses[herd_id] as HEBusiness).stock(commodity) > 0.0001:
			return businesses[herd_id]
	return primary

## Sorted for the same deterministic-processing-order reason every other
## per-settlement business list in this file is sorted -- see _run_trade's
## herd export pass.
func _herd_business_ids(settlement_id: int) -> Array[int]:
	var ids: Array[int] = []
	for business_id in businesses.keys():
		var b: HEBusiness = businesses[business_id]
		if b.kind == HEBusiness.Kind.HERD and b.settlement_id == settlement_id:
			ids.append(business_id)
	ids.sort()
	return ids

## The settlement's Trader (lowest business_id if it somehow had more than
## one), or null if it has none -- the supplier of last resort for a
## recipe.inputs commodity nothing local produces. See
## _run_input_purchasing.
func _settlement_trader(settlement_id: int) -> HEBusiness:
	var ids := businesses.keys()
	ids.sort()
	for business_id in ids:
		var b: HEBusiness = businesses[business_id]
		if b.settlement_id == settlement_id and b.kind == HEBusiness.Kind.TRADER:
			return b
	return null

func _settlement_port(settlement_id: int) -> HEBusiness:
	for business_id in businesses.keys():
		var b: HEBusiness = businesses[business_id]
		if b.settlement_id == settlement_id and b.kind == HEBusiness.Kind.PORT:
			return b
	return null

## What staffed local businesses (other than `seller` itself) plan to use of
## `commodity` per day as a recipe input: part of the routine local use a seller
## forecasts (see _routine_local_use).
func _business_input_daily_use(settlement_id: int, commodity: Commodity.Type, seller: HEBusiness) -> float:
	var total := 0.0
	for business_id in businesses.keys():
		var b: HEBusiness = businesses[business_id]
		if b == seller or b.settlement_id != settlement_id or b.kind != HEBusiness.Kind.PRODUCTION or b.recipe == null:
			continue
		if not b.recipe.inputs.has(commodity):
			continue
		var planned: float = float(_business_employed_worker_count(business_id)) * b.recipe.outputs[b.output_commodity()]
		total += planned * b.recipe.inputs[commodity]
	return total

## The `_b2b_today` entry for this seller/commodity, created on first use
## with the seller's paced offer as it stood before any business bought from it.
func _b2b_entry(settlement_id: int, commodity: Commodity.Type, seller: HEBusiness) -> Dictionary:
	if not _b2b_today.has(settlement_id):
		_b2b_today[settlement_id] = {}
	if not _b2b_today[settlement_id].has(commodity):
		_b2b_today[settlement_id][commodity] = {"offer": _paced_offer(seller, commodity), "sold": 0.0, "requested": 0.0}
	return _b2b_today[settlement_id][commodity]

## How much of a local seller's output a business buyer can claim today.
## There is NO reserve held back for households: the buyer and the
## settlement's households split the seller's paced offer in proportion to
## what each asks for (`claim`: the buyer's request, which callers cap at the
## same TARGET_BUFFER_DAYS horizon households ask over, so a business's
## larger working buffer doesn't let it crowd them out), and the buyer's purchase feeds the same price signal
## households' do (see _clear_market_for), so a scarce good gets dearer until
## whoever values it least drops out. Nothing here knows which commodity it
## is -- wood, charcoal or any future burnable goes through the same path.
func _b2b_offer(seller: HEBusiness, settlement_id: int, commodity: Commodity.Type, claim: float) -> float:
	var entry := _b2b_entry(settlement_id, commodity, seller)
	var remaining: float = maxf(0.0, entry["offer"] - entry["sold"])
	if claim <= 0.0001:
		return remaining
	var household_demand := _funded_demand_for_b2b(settlement_id, commodity)
	if claim + household_demand <= 0.0001:
		return remaining
	return minf(remaining, seller.stock(commodity)) * claim / (claim + household_demand)

## Runs first thing in the tick (right after HEWages.pay_wages, before
## _run_production) so a PRODUCTION business with recipe.inputs buys toward
## PRODUCTION_INPUT_BUFFER_DAYS of real input inventory from what suppliers
## held at the END of yesterday. _run_production consumes that inventory
## later in the tick. A business with empty recipe.inputs is untouched
## beyond having last_input_fulfillment_ratio set to 1.0.
##
## Every input is bought business-to-business at today's posted local
## price, the same mechanism grain/timber use to sell to households, just
## with another business as the buyer. An input some local PRODUCTION
## business already sells (wood, from the Woodlot) is bought straight from
## its stock, sharing the seller's offer with local households pro rata
## (_b2b_offer) rather than behind a household reserve. An input nothing local produces (iron ore)
## has no such seller; the settlement's Trader supplies it instead,
## importing it from outside on the spot at PORT_BUY_PRICE_FRACTION of
## the local price and reselling it at that same local price -- it never
## actually holds ore in its own inventory even for an instant, just
## pockets the spread as margin (see TRADER_CAPACITY_PER_WORKER's doc
## comment for why this is its own capacity pool rather than shared with
## _run_trade's export side). What the Trader pays to import is new money
## LEAVING the closed system -- see _import_cost_total -- the mirror image
## of _run_trade's export revenue entering it.
##
## Buffer purchases are proportional across inputs: if the business can
## fill only half of one desired refill, it fills half of every desired
## refill. Production itself is then capped by whichever stored input is
## scarcest, so no input can be consumed without its recipe partners.
func _run_input_purchasing(record: Dictionary) -> void:
	var trader_import_capacity: Dictionary = {} # trader business_id -> units still importable today
	_b2b_today = {}
	_price_signal_today = {}
	for business_id in businesses.keys():
		var trade_business: HEBusiness = businesses[business_id]
		if trade_business.kind in [HEBusiness.Kind.TRADER, HEBusiness.Kind.PORT]:
			trade_business.last_imported = {}

	for business_id in businesses.keys():
		var buyer: HEBusiness = businesses[business_id]
		buyer.last_input_fulfillment_ratio = 1.0
		if buyer.kind != HEBusiness.Kind.PRODUCTION or buyer.recipe == null or buyer.recipe.inputs.is_empty():
			continue

		var employed := _business_employed_worker_count(business_id)
		var output_commodity := buyer.output_commodity()
		var planned_units: float = float(employed) * buyer.recipe.outputs[output_commodity]
		if planned_units <= 0.0001:
			continue

		var local_market: HEMarket = markets[buyer.settlement_id]
		var purchase_ratio := 1.0

		# What to buy of each good. A fixed input is the recipe quantity. A
		# need-input slot (HEBusiness.need_inputs) is measured in the need's
		# units: the heat (etc.) already held in ANY satisfier counts against
		# the buffer, and what is still missing is split across the satisfiers
		# this business can actually get, cheapest first
		# (_allocate_need_purchase). Insertion follows recipe order so
		# purchases happen in the same order they always did.
		var needed_by_commodity: Dictionary[Commodity.Type, float] = {}
		var requested_by_commodity: Dictionary[Commodity.Type, float] = {}
		var slot_requirements: Array[Dictionary] = [] # {need, needed}, in need units
		var seller_only: Dictionary[Commodity.Type, bool] = {} # slot satisfiers that may not come from the Trader's imports
		var daily_need_by_commodity: Dictionary[Commodity.Type, float] = {} # purchased commodity -> units used per day, sizes its claim on a seller's offer
		var total_cost_if_fully_supplied := 0.0
		for slot_commodity in buyer.recipe.inputs.keys():
			if buyer.need_inputs.has(slot_commodity):
				var need := HENeeds.get_need(buyer.need_inputs[slot_commodity])
				var needed_units: float = planned_units * buyer.recipe.inputs[slot_commodity] * need.value_of(slot_commodity)
				slot_requirements.append({"need": need, "needed": needed_units})
				var shortfall: float = max(0.0, needed_units * PRODUCTION_INPUT_BUFFER_DAYS - need.held(buyer))
				var allocation := _allocate_need_purchase(buyer.settlement_id, need, shortfall, trader_import_capacity)
				for satisfier in allocation.keys():
					requested_by_commodity[satisfier] = allocation[satisfier]
					seller_only[satisfier] = satisfier != need.baseline
					daily_need_by_commodity[satisfier] = needed_units / need.value_of(satisfier)
			else:
				var needed: float = planned_units * buyer.recipe.inputs[slot_commodity]
				needed_by_commodity[slot_commodity] = needed
				daily_need_by_commodity[slot_commodity] = needed
				requested_by_commodity[slot_commodity] = max(0.0, needed * PRODUCTION_INPUT_BUFFER_DAYS - buyer.stock(slot_commodity))

		# Pass 1: how much of EACH input is actually available (locally sold
		# stock above reserve, or the settlement's shared Trader-import
		# capacity), independent of cash -- cash is a single pool shared
		# across every input, so it's checked once below instead of
		# per-input (checking it here too would let the same balance count
		# toward affording wood AND ore independently, as if the business
		# had that much cash for each).
		var offers_seen: Dictionary[Commodity.Type, float] = {}
		var claims_seen: Dictionary[Commodity.Type, float] = {}
		var daily_input_cost := 0.0
		for commodity in daily_need_by_commodity.keys():
			daily_input_cost += daily_need_by_commodity[commodity] * local_market.price[commodity]
		# The most a business buys of one input in a day is the same
		# TARGET_BUFFER_DAYS horizon households ask over -- a real purchase
		# limit, not just the weight of its share of a seller's offer -- so a
		# 14-day working buffer fills over a few days instead of crowding
		# households out or hoarding at a spiking price. The uncapped refill
		# is kept as a planning figure for the price signal's report.
		var buffer_request: Dictionary[Commodity.Type, float] = {}
		for commodity in requested_by_commodity.keys():
			buffer_request[commodity] = requested_by_commodity[commodity]
			var daily_use: float = daily_need_by_commodity.get(commodity, 0.0)
			if daily_use > 0.0001:
				requested_by_commodity[commodity] = minf(requested_by_commodity[commodity], daily_use * TARGET_BUFFER_DAYS)
		for commodity in requested_by_commodity.keys():
			var requested: float = requested_by_commodity[commodity]
			if requested <= 0.0001:
				continue

			var price: float = local_market.price[commodity]
			total_cost_if_fully_supplied += requested * price
			var claim := requested
			var offer := _business_offer(buyer.settlement_id, commodity, trader_import_capacity, not seller_only.get(commodity, false), claim)
			offers_seen[commodity] = offer
			claims_seen[commodity] = claim

			purchase_ratio = minf(purchase_ratio, min(requested, offer) / requested)

		# Pass 1b: fold in the single shared cash constraint across every
		# input at once. The budget is cash plus a bounded credit line (see
		# _input_budget), so a business already in debt can still restock.
		var affordable_ratio := 1.0
		if total_cost_if_fully_supplied > 0.0001:
			var budget := _input_budget(buyer, employed, daily_input_cost)
			affordable_ratio = clampf(budget / total_cost_if_fully_supplied, 0.0, 1.0)
			purchase_ratio = minf(purchase_ratio, affordable_ratio)

		# The price signal sees every funded input request, even one nothing was
		# on offer for -- but only the part eligible to compete for today's
		# offer (the claim, capped at TARGET_BUFFER_DAYS of use), not the whole
		# PRODUCTION_INPUT_BUFFER_DAYS refill, which is kept apart as a
		# planning figure. A good with no local seller is supplied from the
		# Trader's import capacity, recorded as capacity rather than as an offer
		# (see _apply_price_signals).
		for commodity in offers_seen.keys():
			var signal_today := _price_signal_entry(buyer.settlement_id, commodity)
			signal_today["funded_business"] += claims_seen[commodity] * affordable_ratio
			signal_today["business_buffer_request"] += buffer_request[commodity] * affordable_ratio
			if _business_selling(buyer.settlement_id, commodity) == null:
				signal_today["import_capacity"] = maxf(signal_today["import_capacity"], offers_seen[commodity])

		for commodity in requested_by_commodity.keys():
			var requested: float = requested_by_commodity[commodity]
			if requested <= 0.0001 or purchase_ratio <= 0.0:
				continue
			_settle_purchase(buyer, buyer, commodity, requested, requested * purchase_ratio, requested * affordable_ratio, record, trader_import_capacity)

		var production_ratio := 1.0
		for commodity in needed_by_commodity.keys():
			var needed: float = needed_by_commodity[commodity]
			if needed > 0.0001:
				production_ratio = minf(production_ratio, minf(needed, buyer.stock(commodity)) / needed)
		for slot in slot_requirements:
			var slot_need: HENeed = slot["need"]
			var slot_needed: float = slot["needed"]
			if slot_needed > 0.0001:
				production_ratio = minf(production_ratio, minf(slot_needed, slot_need.held(buyer)) / slot_needed)
		buyer.last_input_fulfillment_ratio = production_ratio

	_run_fodder_purchasing(record, trader_import_capacity)

## What a ranch may spend on fodder today: its cash plus half of the wage
## overdraft it is allowed (HEWages.overdraft_limit, which a ranch backs with its
## herd), so fodder can never use up the credit its crew is paid from. A herd
## that cannot be fed on that budget goes into winter underfed.
func _fodder_budget(b: HEBusiness) -> float:
	var wage_bill: float = float(_business_employed_worker_count(b.id)) * wages.wage_paid_per_worker(b)
	return maxf(0.0, b.balance + 0.5 * wages.overdraft_limit(b, wage_bill))

## Ranches stock their winter fodder in the autumn (and top up through
## winter, up to the review that eats it). It is an ordinary purchase --
## the same local seller or Trader import, price, tax and ledger lines as a
## recipe input, paid from the ranch's own cash within the same bounded
## credit -- so the grain, the money and the seller's sale are all
## accounted exactly as any other business input. The need is spread over the
## days left in the buying window rather than bought at once.
func _run_fodder_purchasing(record: Dictionary, trader_import_capacity: Dictionary) -> void:
	var s := season_of_day(day)
	if s < Season.AUTUMN:
		return
	# Autumn buys against the days until winter starts; winter against the days
	# until its review closes the season.
	var window_end: int = (day / DAYS_PER_SEASON + (1 if s == Season.AUTUMN else 2)) * DAYS_PER_SEASON
	var days_left: int = maxi(1, window_end - day)
	for business_id in businesses.keys():
		var buyer: HEBusiness = businesses[business_id]
		if buyer.kind != HEBusiness.Kind.HERD or buyer.herd_size <= 0.0:
			continue
		var wanted: float = maxf(0.0, buyer.herd_size * FODDER_PER_HEAD_PER_WINTER[buyer.species] - buyer.stock(Commodity.Type.GRAIN))
		var requested: float = wanted / float(days_left)
		if requested <= 0.0001:
			continue
		var price: float = (markets[buyer.settlement_id] as HEMarket).price[Commodity.Type.GRAIN]
		var offer := _business_offer(buyer.settlement_id, Commodity.Type.GRAIN, trader_import_capacity, true, requested)
		var ratio := minf(1.0, offer / requested)
		var cost := requested * price
		var affordable_ratio := 1.0
		if cost > 0.0001:
			affordable_ratio = clampf(_fodder_budget(buyer) / cost, 0.0, 1.0)
		var signal_today := _price_signal_entry(buyer.settlement_id, Commodity.Type.GRAIN)
		signal_today["funded_business"] += requested * affordable_ratio
		signal_today["business_buffer_request"] += wanted * affordable_ratio
		if _business_selling(buyer.settlement_id, Commodity.Type.GRAIN) == null:
			signal_today["import_capacity"] = maxf(signal_today["import_capacity"], offer)
		var purchase_ratio := minf(ratio, affordable_ratio)
		if purchase_ratio <= 0.0:
			continue
		_settle_purchase(buyer, buyer, Commodity.Type.GRAIN, requested, requested * purchase_ratio, requested * affordable_ratio, record, trader_import_capacity)

## Executes one business purchase of `bought` units of `commodity` at today's
## posted price: `payer` is debited (the buyer itself for a recipe input, the
## treasury for a warehouse), the goods land in `buyer`'s inventory, and they
## come from the local seller's stock, else from the settlement's Trader as an
## import out of its shared `trader_import_capacity`. `requested` is what the
## buyer asked for (for the market's offered/requested record) and
## `b2b_requested` the funded part of it (for the seller-pair report).
func _settle_purchase(buyer: HEBusiness, payer: HEBusiness, commodity: Commodity.Type, requested: float, bought: float, b2b_requested: float, record: Dictionary, trader_import_capacity: Dictionary) -> void:
	var local_market: HEMarket = markets[buyer.settlement_id]
	var price: float = local_market.price[commodity]
	var cost: float = bought * price
	var availability_need: HENeed = null
	var alternative_was_available := false
	if bought > 0.0 and _funded_demand_cache_active:
		var candidate_need := HENeeds.for_commodity(commodity)
		if candidate_need != null and candidate_need.unit_values.size() > 1 and commodity != candidate_need.baseline and _funded_demand_cache_has_need(buyer.settlement_id, candidate_need):
			availability_need = candidate_need
			alternative_was_available = _household_offer(buyer.settlement_id, commodity) > 0.0001
	payer.balance -= cost
	payer.last_cash_change -= cost
	buyer.add_stock(commodity, bought)
	buyer.add_flow(HEBusiness.FLOW_BOUGHT, commodity, bought)
	var name := Commodity.name_of(commodity)
	record["traded_quantity"][name] = record["traded_quantity"].get(name, 0.0) + bought

	var seller := _business_selling(buyer.settlement_id, commodity)
	var local_offer := _b2b_offer(seller, buyer.settlement_id, commodity, bought) if seller != null else 0.0
	if local_offer <= 0.0001:
		seller = null
	if seller != null:
		var b2b: Dictionary = _b2b_entry(buyer.settlement_id, commodity, seller)
		b2b["sold"] += bought
		b2b["requested"] += b2b_requested
		seller.consume(commodity, bought)
		seller.add_flow(HEBusiness.FLOW_SOLD, commodity, bought)
		var b2b_tax := _collect_sales_tax(buyer.settlement_id, cost)
		var net_cost := cost - b2b_tax
		seller.balance += net_cost
		seller.ledger_add("sales_business", cost)
		seller.ledger_add_good("local", commodity, bought)
		seller.ledger_add("taxes", b2b_tax)
		payer.ledger_add("input_local", cost)
		seller.last_revenue += net_cost
		seller.last_cash_change += net_cost
		# Business-to-business sale (e.g. Iron Mine -> Bloomery): no
		# household or Trader pass records it, so without this the
		# good's market shows 0 supplied / 0 requested.
		var offer_before_sale: float = b2b["offer"]
		local_market.merge_clearing(commodity, offer_before_sale, requested, bought, price)
	else:
		var trader := _settlement_trader(buyer.settlement_id) if intertown_trading_enabled else null
		var trader_stock := maxf(0.0, trader.stock(commodity) - _valley_reserved_stock.get(commodity, 0.0)) if trader != null else 0.0
		if trader != null and trader_stock > 0.0001:
			var offer_before: float = trader_stock
			trader.consume(commodity, bought)
			trader.add_flow(HEBusiness.FLOW_SOLD, commodity, bought)
			var valley_tax := _collect_sales_tax(buyer.settlement_id, cost)
			var valley_net := cost - valley_tax
			trader.balance += valley_net
			trader.ledger_add("sales_business", cost)
			trader.ledger_add("taxes", valley_tax)
			payer.ledger_add("input_local", cost)
			trader.last_revenue += valley_net
			trader.last_cash_change += valley_net
			local_market.merge_clearing(commodity, offer_before, requested, bought, price)
			_finish_funded_demand_availability_check(buyer.settlement_id, commodity, availability_need, alternative_was_available)
			return
		var port := _settlement_port(buyer.settlement_id)
		if port == null:
			local_market.merge_clearing(commodity, 0.0, requested, 0.0, price)
			return
		if not trader_import_capacity.has(port.id):
			var already_imported := 0.0
			for imported in port.last_imported.values():
				already_imported += float(imported)
			trader_import_capacity[port.id] = maxf(0.0,
				float(_business_employed_worker_count(port.id)) * TRADER_CAPACITY_PER_WORKER - already_imported)
		var offer_before: float = trader_import_capacity[port.id]
		trader_import_capacity[port.id] = maxf(0.0, offer_before - bought)
		var import_cost: float = cost * PORT_BUY_PRICE_FRACTION
		# The sale to the local buyer is taxed; the Port, as seller,
		# bears it out of its import margin (never out of import_cost,
		# which leaves the closed system).
		var import_tax := _collect_sales_tax(buyer.settlement_id, cost)
		var margin: float = cost - import_cost - import_tax
		port.balance += margin
		port.ledger_add("trade_margin", cost - import_cost)
		port.ledger_add("taxes", import_tax)
		payer.ledger_add("input_import", cost)
		port.last_revenue += margin
		port.last_cash_change += margin
		port.last_imported[commodity] = port.last_imported.get(commodity, 0.0) + bought
		port.last_actual_units += bought
		record["imported"][name] = record["imported"].get(name, 0.0) + bought
		record["trader_transactions"].append({
			"day": day + 1,
			"business_id": port.id,
			"direction": "import",
			"commodity": name,
			"quantity": bought,
			"unit_price": price,
			"local_value": cost,
		})
		record["import_cost"] += import_cost
		_import_cost_total += import_cost
		local_market.merge_clearing(commodity, offer_before, requested, bought, price)
	_finish_funded_demand_availability_check(buyer.settlement_id, commodity, availability_need, alternative_was_available)

## Runs after _run_trade, before the day's price signal: every Government
## Warehouse works its standing orders (set_warehouse_order) against the local
## market. Households and recipe-input buyers have already cleared, so the
## warehouse only ever takes what they left -- it can raise a price but never
## starve a household of the day's offer.
##
## BUY (buy_up_to): up to WAREHOUSE_DAILY_TRADE_CAP a day toward the target,
## from the local seller's remaining paced offer, else imported through the
## Trader (what is left of its import capacity after today's input
## purchases), paid out of the treasury down to a few days of wages. A funded
## request feeds the price signal like any other business's.
##
## SELL (sell + keep): up to the same daily cap of whatever is held above
## `keep`, exported through the Trader at its export bid, within what is left
## of its daily export capacity; the treasury receives the bid. Selling back
## into the local market is not offered -- a good with a local seller already
## has one seller per market (see _business_selling).
func _run_warehouse_orders(record: Dictionary) -> void:
	var warehouse_ids: Array[int] = []
	for business_id in businesses.keys():
		if (businesses[business_id] as HEBusiness).kind == HEBusiness.Kind.WAREHOUSE:
			warehouse_ids.append(business_id)
	warehouse_ids.sort()
	for warehouse_id in warehouse_ids:
		var warehouse: HEBusiness = businesses[warehouse_id]
		var treasury := _settlement_government(warehouse.settlement_id)
		if treasury == null or warehouse.warehouse_orders.is_empty():
			continue
		var settlement_id := warehouse.settlement_id
		var local_market: HEMarket = markets[settlement_id]
		var port := _settlement_port(settlement_id)
		# What is left of the Trader's daily import capacity after today's
		# recipe-input purchases (the Port's `last_imported`).
		var import_capacity: Dictionary = {}
		if port != null:
			var used := 0.0
			for imported in port.last_imported.values():
				used += imported
			import_capacity[port.id] = maxf(0.0, float(_business_employed_worker_count(port.id)) * TRADER_CAPACITY_PER_WORKER - used)
		var wage_reserve: float = WAREHOUSE_WAGE_RESERVE_DAYS * wages.liquidity_scale(settlement_id) \
			* float(_business_employed_worker_count(treasury.id) + _business_employed_worker_count(warehouse.id))

		var commodities: Array = warehouse.warehouse_orders.keys()
		commodities.sort()
		for commodity in commodities:
			var order: Dictionary = warehouse.warehouse_orders[commodity]
			var price: float = local_market.price[commodity]

			var shortfall: float = order["buy_up_to"] - warehouse.stock(commodity)
			if shortfall > 0.0001 and price > 0.0:
				var requested := minf(shortfall, WAREHOUSE_DAILY_TRADE_CAP)
				var affordable: float = maxf(0.0, treasury.balance - wage_reserve) / price
				var funded := minf(requested, affordable)
				if funded > 0.0001:
					var signal_today := _price_signal_entry(settlement_id, commodity)
					signal_today["funded_business"] += funded
					signal_today["business_buffer_request"] += funded
					var offer := _business_offer(settlement_id, commodity, import_capacity, true, funded)
					var bought := minf(funded, offer)
					if bought > 0.0001:
						_settle_purchase(warehouse, treasury, commodity, funded, bought, funded, record, import_capacity)

			if order["sell"] and port != null:
				var sellable: float = warehouse.stock(commodity) - order["keep"]
				var capacity_left: float = float(_business_employed_worker_count(port.id)) * TRADER_CAPACITY_PER_WORKER - port.last_actual_units
				var quantity := minf(minf(sellable, WAREHOUSE_DAILY_TRADE_CAP), capacity_left)
				if quantity > 0.0001:
					var local_price := _export_reference_price(settlement_id, commodity)
					var pay_price := local_price * PORT_BUY_PRICE_FRACTION
					warehouse.consume(commodity, quantity)
					warehouse.add_flow(HEBusiness.FLOW_SOLD, commodity, quantity)
					treasury.balance += quantity * pay_price
					treasury.last_revenue += quantity * pay_price
					treasury.last_cash_change += quantity * pay_price
					treasury.ledger_add("sales_export", quantity * pay_price)
					var margin := quantity * (local_price - pay_price)
					port.balance += margin
					port.ledger_add("trade_margin", margin)
					port.last_revenue += margin
					port.last_actual_units += quantity
					port.last_exported[commodity] = port.last_exported.get(commodity, 0.0) + quantity
					var name := Commodity.name_of(commodity)
					record["exported"][name] = record["exported"].get(name, 0.0) + quantity
					record["trader_transactions"].append({
						"day": day + 1,
						"business_id": port.id,
						"settlement_id": settlement_id,
						"direction": "export",
						"commodity": name,
						"seller_id": warehouse.id,
						"quantity": quantity,
						"unit_price": local_price,
						"paid_price": pay_price,
						"local_value": quantity * local_price,
					})
					# New money entering the closed system, as in _run_trade.
					record["export_revenue"] += quantity * local_price
					_export_revenue_total += quantity * local_price

## Splits a business's missing `shortfall` of a need (in need units) across
## the satisfiers it can actually obtain today, cheapest per unit first --
## "obtain" meaning what _business_offer says, so stock that exists but is
## already spoken for by households does not count, and a cheaper good with nothing
## available to this buyer simply isn't asked for. Only the baseline may come
## from the Trader's imports. Returns {satisfier: units to request}.
##
## When the baseline is the only option (the need has no other satisfier, or
## no other satisfier is on offer to this buyer), the whole shortfall is
## requested from it even if little or none is on offer: that is how an unmet
## input shows up in the purchase ratio, exactly as for a fixed input. With
## real alternatives, only what each can supply is requested; a total
## shortage then shows up as a low production ratio from what is held.
func _allocate_need_purchase(settlement_id: int, need: HENeed, shortfall: float, trader_import_capacity: Dictionary) -> Dictionary:
	var allocation := {}
	if shortfall <= 0.0:
		return allocation
	var offers := func(c: Commodity.Type) -> float:
		return _business_offer(settlement_id, c, trader_import_capacity, c == need.baseline, 0.0)
	var cascade := _satisfier_cascade(settlement_id, need, offers)
	if cascade.size() == 1:
		allocation[need.baseline] = shortfall / need.value_of(need.baseline)
		return allocation
	var remaining := shortfall
	for c in cascade:
		if remaining <= 0.0:
			break
		var units: float = minf(remaining / need.value_of(c), offers.call(c))
		if units > 0.0:
			allocation[c] = units
			remaining -= units * need.value_of(c)
	return allocation

## What an input buyer can spend today: its cash plus a bounded credit line.
## Wages already run on credit (WAGE_NEGATIVE_BALANCE_FLOOR_DAYS), but inputs
## were capped at the cash balance, so a staffed business whose balance had
## gone even slightly negative could pay its crew and never restock -- it
## produced nothing, earned nothing, and stayed in debt for good. Inputs are
## the working capital that makes the wages productive, so they draw on the
## same credit line: down to the wage floor, and no more than INPUT_CREDIT_DAYS
## of today's input cost beyond cash. That keeps credit bounded to the
## buffer the business would hold anyway, and a business with no cash and no
## headroom (at its wage floor) is still locked out.
func _input_budget(buyer: HEBusiness, employed: int, daily_input_cost: float) -> float:
	var wage_floor := -WAGE_NEGATIVE_BALANCE_FLOOR_DAYS * wages.wage_paid_per_worker(buyer) * employed
	var headroom := maxf(0.0, buyer.balance - wage_floor)
	return maxf(buyer.balance, 0.0) + minf(headroom, INPUT_CREDIT_DAYS * daily_input_cost)

## What `quantity` head of `commodity` held by `b` are worth, by channel:
## "local_value" at the Butcher's purchase quote (what a local sale would bring),
## "export_value" at the lower Trader bid, and "value" -- the one a business's
## own books use: a Butcher's held animals at what it paid (cost basis), a
## ranch's at the Trader bid it can count on without a staffed Butcher.
func livestock_holding_value(b: HEBusiness, commodity: Commodity.Type) -> Dictionary:
	var species := livestock_species(commodity)
	var quantity := b.stock(commodity)
	var local_value: float = quantity * livestock_quote(species, LivestockQuote.BUTCHER_PURCHASE)
	var export_value: float = quantity * livestock_quote(species, LivestockQuote.TRADER_BID)
	return {
		"quantity": quantity,
		"local_value": local_value,
		"export_value": export_value,
		"value": local_value if b.processes_livestock else export_value,
	}

## Total value (see livestock_holding_value) of every livestock good `b` holds.
func _livestock_stock_value(b: HEBusiness) -> float:
	var total := 0.0
	for commodity in LIVESTOCK_GOODS:
		total += livestock_holding_value(b, commodity)["value"]
	return total

## Worker-days of processing the livestock `b` holds represents.
func _butchery_held_worker_days(b: HEBusiness) -> float:
	var total := 0.0
	for species in BUTCHERY_SPECIES_ORDER:
		total += b.stock(HEBusiness.livestock_commodity(species)) * BUTCHERY_WORKER_DAYS_PER_HEAD[species]
	return total

## Runs right after _run_input_purchasing: each staffed Butcher tops its
## livestock up to BUTCHERY_INPUT_BUFFER_DAYS of work from the settlement's
## ranches, cattle first, paying each ranch the BUTCHER_PURCHASE quote. This is a
## plain business-to-business transfer -- no money or animals enter or leave the
## system -- and it happens before _run_trade's herd export, so the Butcher
## always gets first call on a cull. Each purchase is recorded once, here, in the
## day's "livestock_transactions" (what the Goods page reads), and the day's
## offered/requested/bought head in "livestock_market".
func _run_livestock_purchasing(record: Dictionary) -> void:
	var business_ids := businesses.keys()
	business_ids.sort()
	for business_id in business_ids:
		var butcher: HEBusiness = businesses[business_id]
		if not butcher.processes_livestock:
			continue
		var workers := _business_employed_worker_count(business_id)
		if workers <= 0:
			continue
		var wanted_worker_days: float = float(workers) * BUTCHERY_INPUT_BUFFER_DAYS - _butchery_held_worker_days(butcher)
		var meat_room := _butchery_meat_room(butcher)
		for species in BUTCHERY_SPECIES_ORDER:
			if wanted_worker_days <= 0.0001 or meat_room <= 0.0001:
				break
			var commodity := HEBusiness.livestock_commodity(species)
			var price: float = livestock_quote(species, LivestockQuote.BUTCHER_PURCHASE)
			var worker_days_per_head: float = BUTCHERY_WORKER_DAYS_PER_HEAD[species]
			var market_today := _livestock_market_today(record, commodity)
			market_today["requested"] += wanted_worker_days / worker_days_per_head
			for herd_id in _herd_business_ids(butcher.settlement_id):
				var herd: HEBusiness = businesses[herd_id]
				if herd.species != species:
					continue
				market_today["offered"] += herd.stock(commodity)
				var affordable: float = maxf(0.0, butcher.balance + BUTCHERY_CREDIT_LIMIT) / price
				var head: float = minf(minf(herd.stock(commodity), wanted_worker_days / worker_days_per_head), affordable)
				head = minf(head, meat_room / BUTCHERY_MEAT_PER_HEAD[species])
				if head <= 0.0001:
					continue
				var cost: float = head * price
				herd.consume(commodity, head)
				herd.add_flow(HEBusiness.FLOW_SOLD, commodity, head)
				var net_cost := cost - _collect_sales_tax(butcher.settlement_id, cost)
				herd.balance += net_cost
				herd.ledger_add("sales_business", cost)
				herd.ledger_add_good("local", commodity, head)
				herd.ledger_add("taxes", cost - net_cost)
				butcher.ledger_add("input_local", cost)
				herd.last_revenue += net_cost
				herd.last_cash_change += net_cost
				butcher.balance -= cost
				butcher.last_cash_change -= cost
				butcher.add_stock(commodity, head)
				butcher.add_flow(HEBusiness.FLOW_BOUGHT, commodity, head)
				var name := Commodity.name_of(commodity)
				record["traded_quantity"][name] = record["traded_quantity"].get(name, 0.0) + head
				market_today["bought"] += head
				record["livestock_transactions"].append({
					"day": day + 1,
					"settlement_id": butcher.settlement_id,
					"channel": "butcher_purchase",
					"seller_id": herd.id,
					"buyer_id": butcher.id,
					"commodity": name,
					"quantity": head,
					"unit_price": price,
					"value": cost,
				})
				wanted_worker_days -= head * worker_days_per_head
				meat_room -= head * BUTCHERY_MEAT_PER_HEAD[species]

## The crew a livestock processor needs: the worker-days of livestock it holds
## and that ranches hold culled, over a crew's buffer of days; at least one
## worker while a herd is within BUTCHERY_HIRE_NEAR_TARGET of its cull target,
## and none when there is nothing to process or expect (a household is always
## kept by the layoff rule, so an idle Butcher costs one wage, not a crew's).
func _livestock_crew_target(b: HEBusiness) -> int:
	var work := _butchery_held_worker_days(b)
	var cull_near := false
	for herd_id in _herd_business_ids(b.settlement_id):
		var herd: HEBusiness = businesses[herd_id]
		work += herd.stock(herd.herd_commodity()) * BUTCHERY_WORKER_DAYS_PER_HEAD[herd.species]
		if herd.herd_size >= herd_cull_target(herd) * BUTCHERY_HIRE_NEAR_TARGET:
			cull_near = true
	var crew := ceili(work / BUTCHERY_INPUT_BUFFER_DAYS)
	if cull_near:
		crew = maxi(crew, 1)
	return clampi(crew, 0, b.max_capacity)

## How much more meat a Butcher can expect to sell, in meat units: the cover it
## is allowed (BUTCHERY_FINISHED_COVER_DAYS of its local sales, or the floor)
## less the meat it already holds and the meat in the live animals it holds.
func _butchery_meat_room(butcher: HEBusiness) -> float:
	var sold_per_day := _routine_local_use(butcher, Commodity.Type.MEAT)
	var allowed := maxf(BUTCHERY_MIN_FINISHED_MEAT, sold_per_day * BUTCHERY_FINISHED_COVER_DAYS)
	var held := butcher.stock(Commodity.Type.MEAT)
	for species in BUTCHERY_SPECIES_ORDER:
		held += butcher.stock(HEBusiness.livestock_commodity(species)) * BUTCHERY_MEAT_PER_HEAD[species]
	return maxf(0.0, allowed - held)

## Today's livestock market totals for `commodity` in the daily record: head the
## ranches offered the Butcher, head its crews asked for, head actually bought,
## and head the Trader exported. Created on first use, so a day with no
## livestock activity records nothing.
func _livestock_market_today(record: Dictionary, commodity: Commodity.Type) -> Dictionary:
	var today: Dictionary = record["livestock_market"]
	var name := Commodity.name_of(commodity)
	if not today.has(name):
		today[name] = {"offered": 0.0, "requested": 0.0, "bought": 0.0, "exported": 0.0}
	return today[name]

## Head of `species` that this one staffed `butcher`'s crew would stock up on
## from its settlement's ranches (cattle first, bounded by the crew's
## worker-days): the crew's request as the purchase pass records it, not capped by
## what the ranches hold (earlier species still use up worker-days only as far as
## the ranches can supply them). Zero for an unstaffed Butcher.
func _butchery_wanted_head(butcher: HEBusiness, species: HEBusiness.Species) -> float:
	var workers := _business_employed_worker_count(butcher.id)
	if workers <= 0:
		return 0.0
	var wanted_worker_days: float = float(workers) * BUTCHERY_INPUT_BUFFER_DAYS - _butchery_held_worker_days(butcher)
	var meat_room := _butchery_meat_room(butcher)
	for candidate in BUTCHERY_SPECIES_ORDER:
		if wanted_worker_days <= 0.0001 or meat_room <= 0.0001:
			break
		var available: float = 0.0
		for herd_id in _herd_business_ids(butcher.settlement_id):
			var herd: HEBusiness = businesses[herd_id]
			if herd.species == candidate:
				available += herd.stock(HEBusiness.livestock_commodity(candidate))
		var worker_days_per_head: float = BUTCHERY_WORKER_DAYS_PER_HEAD[candidate]
		# Wanted head is what the crew can work AND the meat it expects to sell
		# has room for (_butchery_meat_room), the same limit the purchase obeys.
		var wanted_head: float = minf(wanted_worker_days / worker_days_per_head, meat_room / BUTCHERY_MEAT_PER_HEAD[candidate])
		if candidate == species:
			return wanted_head
		var taken_head: float = minf(wanted_head, available)
		wanted_worker_days -= taken_head * worker_days_per_head
		meat_room -= taken_head * BUTCHERY_MEAT_PER_HEAD[candidate]
	return 0.0

## One day of butchery: the crew's worker-days go to the livestock the Butcher
## holds, cattle first, and each head becomes meat and leather at once. The
## animals are booked as a cost at what the Butcher paid for them (the same
## way a recipe input is costed when consumed), so capacity tuning sees the
## net revenue the work really earns.
func _run_butchery(b: HEBusiness, record: Dictionary) -> void:
	var workers := _business_employed_worker_count(b.id)
	var worker_days_left := _business_effective_worker_count(b.id) * _tool_productivity(b)
	var cattle_meat_per_worker_day: float = BUTCHERY_MEAT_PER_HEAD[HEBusiness.Species.CATTLE] / BUTCHERY_WORKER_DAYS_PER_HEAD[HEBusiness.Species.CATTLE]
	var produced: Dictionary[Commodity.Type, float] = {Commodity.Type.MEAT: 0.0, Commodity.Type.LEATHER: 0.0}
	for species in BUTCHERY_SPECIES_ORDER:
		if worker_days_left <= 0.0001:
			break
		var commodity := HEBusiness.livestock_commodity(species)
		var worker_days_per_head: float = BUTCHERY_WORKER_DAYS_PER_HEAD[species]
		var head: float = minf(b.stock(commodity), worker_days_left / worker_days_per_head)
		if head <= 0.0001:
			continue
		b.consume(commodity, head)
		b.add_flow(HEBusiness.FLOW_CONSUMED, commodity, head)
		var animal_name := Commodity.name_of(commodity)
		record["consumed"][animal_name] = record["consumed"].get(animal_name, 0.0) + head
		b.last_revenue -= head * livestock_quote(species, LivestockQuote.BUTCHER_PURCHASE)
		worker_days_left -= head * worker_days_per_head
		produced[Commodity.Type.MEAT] += head * BUTCHERY_MEAT_PER_HEAD[species]
		produced[Commodity.Type.LEATHER] += head * BUTCHERY_LEATHER_PER_HEAD[species]
	for commodity in produced.keys():
		b.add_stock(commodity, produced[commodity])
		var name := Commodity.name_of(commodity)
		record["produced"][name] = record["produced"].get(name, 0.0) + produced[commodity]
	b.last_planned_units = float(workers) * cattle_meat_per_worker_day
	b.last_actual_units = produced[Commodity.Type.MEAT]
	b.last_output_produced = produced

## The settlement's Kind.GOVERNMENT business, or null (a scenario that never
## seeded one -- then nothing is taxed there).
func _settlement_government(settlement_id: int) -> HEBusiness:
	for business_id in (settlements[settlement_id] as HESettlement).business_ids:
		var b: HEBusiness = businesses.get(business_id)
		if b != null and b.kind == HEBusiness.Kind.GOVERNMENT:
			return b
	return null

## Sales tax on one domestic sale of gross value `gross` in `settlement_id`:
## moves sales_tax_rate * gross into that settlement's government treasury and
## returns the amount, which the CALLER must deduct from what the seller keeps
## (seller-remitted, so a buyer's price/affordability math is untouched).
## Returns 0.0 -- taxing nothing -- when there is no government or the rate is
## zero. A pure internal transfer, so total money is conserved.
func _collect_sales_tax(settlement_id: int, gross: float) -> float:
	if sales_tax_rate <= 0.0 or gross <= 0.0:
		return 0.0
	var gov := _settlement_government(settlement_id)
	if gov == null:
		return 0.0
	var tax := gross * sales_tax_rate
	gov.balance += tax
	gov.ledger_add("tax_income", tax)
	gov.last_tax_collected += tax
	gov.last_revenue += tax
	gov.last_cash_change += tax
	gov.tax_collected_total += tax
	return tax

## Keeps a government's administrator permanent: if no household is employed
## by it (the seeded one died of old age, left, etc.), hire a replacement --
## an unemployed household with workers first, else poach a worker household
## from the lowest-id other employer. Called each _reconcile_employment, ahead
## of ordinary hiring so the post gets first pick. No-op without a government
## or when it is already staffed. TODO(builders): the same upkeep for the
## builder_slots once those exist.
func _ensure_administrator(settlement_id: int) -> void:
	var gov := _settlement_government(settlement_id)
	if gov == null or _business_employed_household_count(gov.id) > 0:
		return
	var pick: HEHousehold = null
	var household_ids: Array[int] = []
	household_ids.assign((settlements[settlement_id] as HESettlement).household_ids)
	household_ids.sort()
	for household_id in household_ids:
		var h: HEHousehold = households[household_id]
		if h.worker_capacity() > 0 and h.employer_business_id == -1:
			pick = h
			break
	if pick == null:
		for household_id in household_ids:
			var h: HEHousehold = households[household_id]
			if h.worker_capacity() > 0:
				pick = h
				break
	if pick == null:
		return
	pick.employer_business_id = gov.id
	_log_event("job", {"household_id": pick.id, "business_id": gov.id, "settlement_id": settlement_id, "workers": pick.worker_capacity()})

## Fills a Government Warehouse's fixed admin crew ahead of ordinary hiring,
## the way _ensure_administrator does for the Government: unemployed worker
## households first, else poaching from the lowest-id other private employer
## (never the Government or another warehouse). Stops at the warehouse's
## capacity, or when no worker household is left to take.
func _ensure_warehouse_staff(settlement_id: int) -> void:
	var household_ids: Array[int] = []
	household_ids.assign((settlements[settlement_id] as HESettlement).household_ids)
	household_ids.sort()
	var business_ids: Array = (settlements[settlement_id] as HESettlement).business_ids.duplicate()
	business_ids.sort()
	for business_id in business_ids:
		var warehouse: HEBusiness = businesses[business_id]
		if warehouse.kind != HEBusiness.Kind.WAREHOUSE:
			continue
		var employed := _business_employed_worker_count(warehouse.id)
		while employed < warehouse.capacity:
			var pick: HEHousehold = null
			for household_id in household_ids:
				var h: HEHousehold = households[household_id]
				if h.worker_capacity() > 0 and h.employer_business_id == -1:
					pick = h
					break
			if pick == null:
				for household_id in household_ids:
					var h: HEHousehold = households[household_id]
					var employer: HEBusiness = businesses.get(h.employer_business_id)
					if h.worker_capacity() > 0 and employer != null and employer.kind != HEBusiness.Kind.GOVERNMENT and employer.kind != HEBusiness.Kind.WAREHOUSE:
						pick = h
						break
			if pick == null:
				return
			pick.employer_business_id = warehouse.id
			employed += pick.worker_capacity()
			_log_event("job", {"household_id": pick.id, "business_id": warehouse.id, "settlement_id": settlement_id, "workers": pick.worker_capacity()})

## Read-only treasury view for UI / player actions (build costs will draw on
## it): {} when the settlement has no government.
func get_government_summary(settlement_id: int) -> Dictionary:
	if not settlements.has(settlement_id):
		return {}
	var gov := _settlement_government(settlement_id)
	if gov == null:
		return {}
	var admin_ids: Array[int] = []
	admin_ids.assign(_employment_index().get(gov.id, []))
	admin_ids.sort()
	return {
		"business_id": gov.id,
		"treasury": gov.balance,
		"sales_tax_rate": sales_tax_rate,
		"last_tax_collected": gov.last_tax_collected,
		"tax_collected_total": gov.tax_collected_total,
		"last_wages_paid": gov.last_wages_paid,
		"administrator_household_ids": admin_ids,
		"builder_slots": gov.builder_slots,
	}

## Every government's treasury summed, for the dashboard's top line: the
## balance now and how it has moved over the last `days` days. `change` is
## measured from the oldest closing balance still within the window, so a young
## sim reports `days_covered` < `days` instead of inventing history. Both are
## 0 / empty when no settlement has a government.
func get_treasury_summary(days: int = 30) -> Dictionary:
	var total := 0.0
	var histories: Array = []
	for settlement_id in settlements.keys():
		var gov := _settlement_government(settlement_id)
		if gov == null:
			continue
		total += gov.balance
		histories.append(gov.balance_history())
	if histories.is_empty():
		return {"has_government": false, "treasury": 0.0, "change": 0.0, "days_covered": 0}
	# History holds closing balances, newest last; today's is the latest entry.
	var covered := 0
	for history in histories:
		covered = maxi(covered, mini(days, (history as Array).size() - 1))
	var then := 0.0
	for history in histories:
		var h: Array = history
		var index := h.size() - 1 - covered
		then += h[index] if index >= 0 else 0.0
	return {"has_government": true, "treasury": total, "change": total - then if covered > 0 else 0.0, "days_covered": covered, "then": then}

## Total daily need for `commodity` across every household right now -- the
## households' share of the known routine local use a seller forecasts
## (_known_daily_local_use), so the forecast tracks the settlement's actual
## size/composition rather than a fixed number.
##
## For a good several satisfiers can supply, this is the whole need expressed
## in that good: each good's forecast guards what households COULD draw of it,
## independent of which one they happen to prefer today. (That independence
## also keeps this free of the market state _satisfier_cascade reads, which
## itself depends on reserves.)
func _settlement_daily_demand(settlement_id: int, commodity: Commodity.Type) -> float:
	var need := HENeeds.for_commodity(commodity)
	var is_substitute: bool = need != null and commodity != need.baseline
	var cascade: Array[Commodity.Type] = []
	if is_substitute:
		cascade = _household_cascade(settlement_id, need)
	var total := 0.0
	for household_id in (settlements[settlement_id] as HESettlement).household_ids:
		var h: HEHousehold = households[household_id]
		# Only households whose favourite is a substitute count toward it.
		if is_substitute and _household_favourite(h, need, cascade) != commodity:
			continue
		total += _daily_need(h, commodity) + h.upkeep_per_year(commodity) / 365.0
	return total

func _invalidate_employment() -> void:
	_employment_dirty = true

## Fresh business ID -> Array[int] of employee household IDs. Callers must not
## mutate the arrays.
func _employment_index() -> Dictionary:
	if _employment_dirty:
		var members: Dictionary = {}
		var listener := _invalidate_employment
		for household_id in households.keys():
			var h: HEHousehold = households[household_id]
			h.employment_changed = listener
			if h.employer_business_id == -1:
				continue
			if not members.has(h.employer_business_id):
				members[h.employer_business_id] = [] as Array[int]
			(members[h.employer_business_id] as Array[int]).append(household_id)
		_employment_members = members
		_employment_dirty = false
		_employment_rebuild_count += 1
	return _employment_members

func _workers_in(member_ids: Array) -> int:
	var total := 0
	for household_id in member_ids:
		total += (households[household_id] as HEHousehold).worker_capacity()
	return total

func _business_employed_worker_count(business_id: int) -> int:
	return _workers_in(_employment_index().get(business_id, []))

## Worker count weighted by each employing household's morale bonus (see
## HEHousehold.productivity_multiplier): what production actually gets out of
## the crew. Equals the plain headcount when nobody's morale is above 100%.
func _business_effective_worker_count(business_id: int) -> float:
	var total := 0.0
	for household_id in _employment_index().get(business_id, []):
		var h: HEHousehold = households[household_id]
		total += float(h.worker_capacity()) * h.productivity_multiplier()
	return total

## The crew's average morale (per worker, so a big household counts for more)
## and the output multiplier it earns, for the business detail page. `workers`
## is 0 for an unstaffed business, in which case morale and multiplier are 1.0.
func _business_crew_morale(business_id: int) -> Dictionary:
	var workers := 0
	var morale_total := 0.0
	for household_id in _employment_index().get(business_id, []):
		var h: HEHousehold = households[household_id]
		workers += h.worker_capacity()
		morale_total += float(h.worker_capacity()) * h.morale()
	if workers == 0:
		return {"workers": 0, "avg_morale": 1.0, "multiplier": 1.0}
	return {
		"workers": workers,
		"avg_morale": morale_total / workers,
		"multiplier": _business_effective_worker_count(business_id) / workers,
	}

func _business_employed_household_count(business_id: int) -> int:
	return (_employment_index().get(business_id, []) as Array).size()

## Debug oracle: true when the index equals an independent full scan. Used by
## the acceptance harness after mutation boundaries.
func employment_index_matches_scan() -> bool:
	var scanned: Dictionary = {}
	for household_id in households.keys():
		var employer: int = (households[household_id] as HEHousehold).employer_business_id
		if employer == -1:
			continue
		if not scanned.has(employer):
			scanned[employer] = []
		scanned[employer].append(household_id)
	var indexed := _employment_index()
	if indexed.size() != scanned.size():
		return false
	for business_id in scanned.keys():
		if not indexed.has(business_id) or (indexed[business_id] as Array) != (scanned[business_id] as Array):
			return false
	return true

## Appends today's opening price (this tick's actual clearing price, before
## _adjust_price mutates it for tomorrow) to each commodity's trailing
## history, capped at HEBusiness.WAGE_ROLLING_WINDOW_DAYS -- same ring-buffer
## shape as HEBusiness.record_wage_day. Called first thing in _daily_tick,
## before anything reads today's price.
func _record_price_history() -> void:
	for settlement_id in markets.keys():
		var local_market: HEMarket = markets[settlement_id]
		var by_commodity: Dictionary = _price_history.get(settlement_id, {})
		for c in SUBSISTENCE_COMMODITIES:
			var history: Array = by_commodity.get(c, [])
			history.append(local_market.price[c])
			if history.size() > HEBusiness.WAGE_ROLLING_WINDOW_DAYS:
				history.pop_front()
			by_commodity[c] = history
		_price_history[settlement_id] = by_commodity

## Falls back to the live price only when no history has been recorded yet
## (day 0, before the first _daily_tick has run) -- from day 1 onward there
## is always at least one entry.
func _average_price_history(settlement_id: int, c: Commodity.Type) -> float:
	var history: Array = (_price_history.get(settlement_id, {}) as Dictionary).get(c, [])
	if history.is_empty():
		return (markets[settlement_id] as HEMarket).price[c]
	var total := 0.0
	for p in history:
		total += p
	return total / history.size()

## inventory_goods(), not just SUBSISTENCE_COMMODITIES -- every commodity that
## can actually sit in SOMEONE's inventory: household goods (grain/timber/wool),
## a business's (iron, iron ore, meat, leather), and culled livestock. Iron ore
## never sits in one, see _run_input_purchasing, but costs nothing to include.
## Deliberately UNFILTERED, unlike get_market_summary()'s active-commodity
## filter -- conservation accounting must still count stock of a good that just
## went inactive (e.g. a Bloomery whose capacity self-tuned to zero but still
## has unsold iron sitting in inventory).
func _total_stock_snapshot(settlement_id: int = -1) -> Dictionary:
	var snap := {}
	for c in inventory_goods():
		var total := 0.0
		for household_id in households.keys():
			var h: HEHousehold = households[household_id]
			if settlement_id == -1 or h.settlement_id == settlement_id:
				total += h.stock(c)
		for business_id in businesses.keys():
			var b: HEBusiness = businesses[business_id]
			if settlement_id == -1 or b.settlement_id == settlement_id:
				total += b.stock(c)
		snap[Commodity.name_of(c)] = total
	return snap

func _total_money(settlement_id: int = -1) -> float:
	var total := 0.0
	for household_id in households.keys():
		var h: HEHousehold = households[household_id]
		if settlement_id == -1 or h.settlement_id == settlement_id:
			total += h.balance
	for business_id in businesses.keys():
		var b: HEBusiness = businesses[business_id]
		if settlement_id == -1 or b.settlement_id == settlement_id:
			total += b.balance
	return total

func _unemployed_household_count() -> int:
	var total := 0
	for h in households.values():
		if not (h as HEHousehold).is_employed():
			total += 1
	return total

func _total_population(settlement_id: int = -1) -> int:
	var total := 0
	for household_id in households.keys():
		var h: HEHousehold = households[household_id]
		if settlement_id == -1 or h.settlement_id == settlement_id:
			total += h.headcount()
	return total
