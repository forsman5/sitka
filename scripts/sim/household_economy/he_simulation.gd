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
##   get_daily_history(days), get_trader_transactions(business_id, days),
##   get_business_employment_events(business_id, event_type, limit),
##   get_event_log(limit), get_event_log_days(days)

const Commodity = preload("res://scripts/sim/records/commodity.gd")
const Household = preload("res://scripts/sim/records/household.gd")
const HEHousehold = preload("res://scripts/sim/household_economy/records/he_household.gd")
const HEBusiness = preload("res://scripts/sim/household_economy/records/he_business.gd")
const HEField = preload("res://scripts/sim/household_economy/records/he_field.gd")
const HESettlement = preload("res://scripts/sim/household_economy/records/he_settlement.gd")
const HEMarket = preload("res://scripts/sim/household_economy/records/he_market.gd")
const HENeed = preload("res://scripts/sim/household_economy/records/he_need.gd")
const HENeeds = preload("res://scripts/sim/household_economy/data/he_needs.gd")

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
	## Priced high enough that the Bloomery clears the reference wage even
	## though EVERY unit it sells goes through the Trader's discounted
	## export channel (TRADER_BUY_PRICE_FRACTION) -- unlike Farm/Woodlot,
	## which sell most of their output to local households at full price and
	## only route surplus through that same discount. See he_scenario_
	## seeds.gd's _bloomery_recipe doc comment for the worked-out numbers.
	Commodity.Type.IRON: 15.0,
	## Meat packs twice grain's food into a unit (see he_needs.gd) and leather
	## is a one-for-one substitute for wool's clothing, so households compare
	## each by price per need-unit. Both start a little under parity (grain
	## and wool are 1.0 and 2.0 per unit; meat is 1.6 for two units' worth),
	## and their price floor (a quarter of this) sits below grain's and wool's,
	## so even when a glut has pushed the baseline to its floor the newcomer
	## can still win on price rather than tie and go unbought.
	Commodity.Type.MEAT: 1.6,
	Commodity.Type.LEATHER: 1.6,
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
## SUBSISTENCE_COMMODITIES (households never need iron, so _run_trade's
## reserve calc for it naturally comes out to zero and it exports freely;
## see _seller_surplus_above_reserve). IRON goes FIRST, ahead of GRAIN and
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
const EXPORT_COMMODITIES: Array[Commodity.Type] = [Commodity.Type.IRON, Commodity.Type.GRAIN, Commodity.Type.TIMBER, Commodity.Type.CHARCOAL]
## Priority is fixed so changing checkboxes never silently reorders which
## good gets first use of shared Trader capacity. Ore, meat and leather start
## disabled: the Butcher's output is for the settlement's own households, and
## a Trader dumping it at half price would only undercut them.
const EXPORT_PRIORITY: Array[Commodity.Type] = [Commodity.Type.IRON, Commodity.Type.GRAIN, Commodity.Type.TIMBER, Commodity.Type.CHARCOAL, Commodity.Type.MEAT, Commodity.Type.LEATHER, Commodity.Type.IRON_ORE]

const MIGRATION_PRESSURE_EVAL_INTERVAL_DAYS := 7
const EMIGRATION_EVAL_INTERVAL_DAYS := 30 # matches Simulation's cadence choice

## Trade: a third workplace kind (see he_business.gd's HEBusiness.Kind.
## TRADER) standing in for the pooled model's Workplace.Kind.TRADE_CENTER
## (see simulation.gd's _run_trade), adapted to a single settlement with no
## neighbor to ship to. It buys ONLY the stock a PRODUCTION business is
## holding above a comfortable reserve (TRADER_RESERVE_BUFFER_DAYS worth of
## the settlement's own daily demand) -- never touching what the settlement
## itself might still need -- and pays a price well below the going market
## rate (TRADER_BUY_PRICE_FRACTION) so its purchases can never meaningfully
## move the local price or outbid a household for a good it needs. The gap
## between what it pays and the market rate is its own margin, which funds
## its wages and, like Farm/Woodlot, drives its own weekly capacity
## self-tuning (_evaluate_business_capacity/_reconcile_employment) --
## nothing trade-specific there.
const TRADER_RESERVE_BUFFER_DAYS := 3.0 # matches TARGET_BUFFER_DAYS by choice, not necessity
const TRADER_BUY_PRICE_FRACTION := 0.5 # authored placeholder, not yet tuned
## Fully utilized, a Trader's margin per worker is
## TRADER_CAPACITY_PER_WORKER * price * (1 - TRADER_BUY_PRICE_FRACTION) --
## i.e. just `price` at the 0.5 fraction above. That has to clear the
## reference wage with real room to spare even once oversupply has pushed
## price all the way down to its floor, or the Trader never grows past a
## knife-edge break-even (and a bad week tips it into capacity 0). A trader moving
## goods should scale per worker far better than a farmhand growing food by
## hand, hence the large jump from the first authored guess of 2.0.
const TRADER_CAPACITY_PER_WORKER := 8.0

## Herds: two more workplace kinds (he_business.gd's HEBusiness.Kind.HERD),
## a Cattle Ranch and a Sheep Farm, whose live herd_size grows/thins on its
## own and is improved by the husbandry staff they employ (see
## HERD_LABOR_PER_HEAD_PER_DAY) -- see _run_herds. Cadence matches the
## pooled model's DAYS_PER_SEASON (simulation.gd) rather than HE's usual
## weekly/monthly evaluation intervals, since reproduction/mortality are
## seasonal-scale processes, not daily ones.
const HERD_EVAL_INTERVAL_DAYS := 90

## Both ranches graze the SAME finite pasture, shared per settlement --
## cattle need far more of it per head than sheep (~6-7x, per husbandry
## research: a mature cow's forage need scales with its much larger body
## mass), so the same acreage supports far fewer cattle than sheep. This is
## a deliberately early abstraction: a flat number, not yet tied to
## authored terrain/acreage per settlement, and grazing-only -- a rancher
## buying grain to make up for a shortfall in grazing land is a plausible
## future mechanic (configurable land-vs-fodder tradeoff, priced against
## the grain market) but explicitly not implemented here. For now a herd
## that outgrows its share of the land simply stops growing at that land's
## ceiling and takes the harsher "neglected" mortality rate below. Sized
## with real headroom above both species' HERD_CULL_TARGET at once, now
## that culled stock/wool actually sell for real money (Trader export,
## local wool market) -- see HERD_EXPORT_PRICE's doc comment for why
## cattle's herd was originally kept small (nothing consumed it yet) and
## no longer needs to be.
const SETTLEMENT_GRAZING_LAND := 300.0
const CATTLE_LAND_PER_HEAD := 1.0
const SHEEP_LAND_PER_HEAD := 0.15

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
## HERD_CULL_TARGET from its seeded starting size -- too slow to feel like
## a lever the player is pulling in a short early-preview session. 1.6
## instead lands both ranches' first cull around ~900 days, without
## touching HERD_LOSS_RATE_FED/NEGLECTED (mortality stays at the
## research-backed rate; only reproduction speeds up). Applied only to
## HERD_GROWTH_RATE in _run_herds, never to the loss rates.
const HERD_GROWTH_RATE_MULTIPLIER := 1.6

## Mortality, per HERD_EVAL_INTERVAL_DAYS. FED applies while herd_size fits
## within this ranch's current share of SETTLEMENT_GRAZING_LAND; NEGLECTED
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
## find. Also sets each ranch's max_capacity (ceil(HERD_CULL_TARGET *
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
## herd_commodity() units. Cattle's target keeps the SAME ratio to
## HEScenarioSeeds.CATTLE_STARTING_HERD as before (1.5x) so the time to
## first cull is unchanged (~900 days at HERD_GROWTH_RATE_MULTIPLIER) --
## only the absolute scale moved up, now that a bigger herd has somewhere
## real to go (HERD_EXPORT_PRICE, SETTLEMENT_GRAZING_LAND). Both targets
## stay well under either species' solo claim on SETTLEMENT_GRAZING_LAND
## so the two ranches have real headroom to grow between culls even while
## sharing the same pasture.
const HERD_CULL_TARGET: Dictionary[HEBusiness.Species, float] = {
	HEBusiness.Species.CATTLE: 150.0,
	HEBusiness.Species.SHEEP: 200.0,
}

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
## market. Instead a ranch's culled stock is Trader-export-only, sold at
## this flat reference price rather than a live locally-drifting one --
## there's no local supply/demand signal to drift one against.
##
## Cattle deliberately DIVERGES from Simulation.BASE_PRICE[CATTLE] (5.0) --
## historically cattle were a genuinely high-value good (often the primary
## store of wealth in a subsistence economy, arguably more so than grain),
## and at the old parity price the ranch's entire steady-state cull volume
## was worth pennies, nowhere near enough to fund even one wage-earning
## worker (before herd_max_capacity() and husbandry made staffing pay).
## Raised until a fully-staffed ranch's export income can actually clear
## the reference wage -- verified empirically, not just priced up
## arbitrarily. See _run_trade's herd export pass.
const HERD_EXPORT_PRICE: Dictionary[HEBusiness.Species, float] = {
	HEBusiness.Species.CATTLE: 60.0,
	HEBusiness.Species.SHEEP: 3.0,
}

## Culled herd stock -- never joins SUBSISTENCE_COMMODITIES (see
## HERD_EXPORT_PRICE's doc comment), but still needs to be tracked in
## _total_stock_snapshot() so opening/closing stock accounting (see
## run_household_economy.gd's _check_conservation) covers it too, exactly
## like any other commodity a business can hold and export.
const HERD_COMMODITIES: Array[Commodity.Type] = [Commodity.Type.CATTLE, Commodity.Type.SHEEP]

## The Butcher (HEBusiness.processes_livestock) buys culled head from the
## settlement's ranches and turns each into MEAT and LEATHER. A local sale
## replaces the Trader's discounted raw export, so the ranch is paid
## BUTCHERY_PURCHASE_PRICE_FRACTION of HERD_EXPORT_PRICE: more than the
## Trader's TRADER_BUY_PRICE_FRACTION, less than the full reference price,
## which leaves the Butcher the margin for the value it adds (meat that feeds
## households, leather that clothes them).
##
## Labor is the Butcher's constraint: each head costs worker-days, a cow far
## more than a sheep. A day's crew works through whatever livestock it holds,
## cattle first. Yields are authored placeholders, not yet tuned: a cow gives
## roughly ten times a sheep's meat, while a hide is a small amount of
## leather either way.
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
const BUTCHERY_CREDIT_LIMIT := 2000.0

## Hardship butchering (see _hardship_butcher_if_needed): a herd has no
## guaranteed near-term payoff the way a field does -- its cull can be many
## HERD_EVAL_INTERVAL_DAYS cycles away from a fresh or just-culled herd, far
## longer than WAGE_NEGATIVE_BALANCE_FLOOR_DAYS' cushion covers. Rather than
## let it borrow indefinitely against a payoff that may never arrive in
## time, once that cushion runs out it sells some of its own live herd
## straight to cash, at a real discount off HERD_EXPORT_PRICE (worse than
## even the Trader's already-discounted TRADER_BUY_PRICE_FRACTION) so a
## ranch never prefers this over patiently waiting for a normal export --
## it's a last resort, not a revenue strategy. Never sells below this
## floor, so there's always enough left to regrow from. Cattle's floor
## scales with its bigger HERD_CULL_TARGET (still ~20% of target, same
## proportion as before) so a hardship sale can't gut just as large a
## fraction of the now-bigger herd.
const HARDSHIP_BUTCHER_PRICE_FRACTION := 0.25
const HARDSHIP_BUTCHER_MIN_HERD: Dictionary[HEBusiness.Species, float] = {
	HEBusiness.Species.CATTLE: 30.0,
	HEBusiness.Species.SHEEP: 20.0,
}

## _run_input_purchasing reuses TRADER_CAPACITY_PER_WORKER and
## TRADER_BUY_PRICE_FRACTION for the Trader's IMPORT side too (buy outside
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
## _pay_wages) -- there's no more "yesterday's revenue divided by headcount"
## ceiling, so a business's balance is allowed to run negative to cover a
## bad stretch rather than instantly rationing pay the moment cash runs out.
## The allowance is deliberately generous (measured in DAYS of the
## business's own current wage bill, so it scales with headcount) --
## sustained insolvency is meant to be caught and corrected by the weekly
## cash-runway guard in _evaluate_business_capacity (shrink the business),
## not by rationing take-home pay day to day.
const WAGE_NEGATIVE_BALANCE_FLOOR_DAYS := 60.0

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
var businesses: Dictionary[int, HEBusiness] = {}
var markets: Dictionary[int, HEMarket] = {}
var _trader_export_enabled: Dictionary[int, Dictionary] = {} # trader business_id -> commodity -> bool

var rng: RandomNumberGenerator
var day: int = 0

## Lets a scenario prove accounting with fixed quotes first before
## exercising the bounded price-drift rule.
var price_adjustment_enabled: bool = true

## Sales tax fraction, a plain variable (not the const) so harnesses and a
## future player policy can change it per sim. 0.0 turns the tax off.
var sales_tax_rate: float = SALES_TAX_RATE

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
var _money_written_off_total := 0.0
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

## Today's business-to-business purchases from local sellers, rebuilt every
## tick by _run_input_purchasing: settlement_id -> commodity -> {offer: the
## seller's paced offer BEFORE any B2B buy, sold: units bought from it,
## requested: cash-funded units asked for}. _clear_market_for reads it so
## households clear against what's left of the same offer.
var _b2b_today: Dictionary = {}

## Trailing per-settlement, per-commodity price history, oldest first, capped to the SAME
## window a business's own wage is smoothed over
## (HEBusiness.WAGE_ROLLING_WINDOW_DAYS, referenced directly rather than
## re-authored here so the two windows can never drift apart) -- see
## _reference_wage_per_worker for why the reference wage reads this average
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
	businesses = world["businesses"]
	for business_id in businesses.keys():
		if (businesses[business_id] as HEBusiness).kind != HEBusiness.Kind.TRADER:
			continue
		var enabled := {}
		for commodity in EXPORT_PRIORITY:
			enabled[commodity] = EXPORT_COMMODITIES.has(commodity)
		_trader_export_enabled[business_id] = enabled
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
	_next_household_id = 1
	for household_id in households.keys():
		_next_household_id = maxi(_next_household_id, household_id + 1)

## Registers a business built after the sim started. Takes a free id from
## next_business_id(); the caller builds the record. Nothing is charged -- the
## business starts with whatever balance/stock the record already carries.
func add_business(b: HEBusiness) -> void:
	assert(not businesses.has(b.id), "Business id %d already exists" % b.id)
	assert(settlements.has(b.settlement_id), "Unknown settlement %d" % b.settlement_id)
	businesses[b.id] = b
	(settlements[b.settlement_id] as HESettlement).business_ids.append(b.id)
	if b.kind == HEBusiness.Kind.TRADER:
		var enabled := {}
		for commodity in EXPORT_PRIORITY:
			enabled[commodity] = EXPORT_COMMODITIES.has(commodity)
		_trader_export_enabled[b.id] = enabled

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
	b.balance += HEScenarioSeeds.startup_cash(b, crew)
	var startup_cycle := maxi(b.growth_days, b.startup_cycle_days)
	b.startup_grace_until_day = day + (startup_cycle if startup_cycle > 0 else int(CASH_RUNWAY_DANGER_DAYS))
	add_business(b)

## Builds a government building (HEScenarioSeeds.government_buildings()) out of
## the settlement's treasury: the cost moves from the treasury into the new
## building's balance, so money is conserved. Returns false -- building nothing
## -- for an unknown type, a settlement with no government, a building of that
## type that already exists, or a treasury that cannot cover the cost.
func build_government_building(settlement_id: int, type_key: String) -> bool:
	var gov := _settlement_government(settlement_id) if settlements.has(settlement_id) else null
	if gov == null or has_business_of_type(settlement_id, type_key):
		return false
	for option in HEScenarioSeeds.government_buildings():
		if option["type_key"] != type_key:
			continue
		var cost: float = option["cost"]
		if gov.balance < cost:
			return false
		var building: HEBusiness = option["make"].call(next_business_id(), settlement_id)
		gov.balance -= cost
		gov.last_cash_change -= cost
		building.balance += cost
		add_business(building)
		return true
	return false

## Lowest crew the tuner may set: one worker (or the business's own
## min_capacity if higher), unless max_capacity itself is 0.
func _capacity_floor(b: HEBusiness) -> int:
	return mini(maxi(b.min_capacity, 1), b.max_capacity)

func next_business_id() -> int:
	var next_id := 1
	for business_id in businesses.keys():
		next_id = maxi(next_id, business_id + 1)
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

func get_clock_summary() -> Dictionary:
	return {"day": day}

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
	for need in HENeeds.all():
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
		"inventory": inventory,
		"balance": h.balance,
		"food_stress": h.demographics.food_stress,
		"health": h.health(),
		"morale": h.morale(),
		"health_losses": h.health_losses(),
		"morale_penalties": h.morale_penalties(),
		"rolling_grain_fulfillment_30d": h.rolling_grain_fulfillment(),
		"has_migration_pressure": h.demographics.has_migration_pressure,
		"is_starvation_candidate": h.demographics.is_starvation_candidate(),
		"dependent_ages": h.dependent_ages(),
		"worker_ages": h.worker_ages(),
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
			morale_total += h.morale(v, member["works"])
			population += 1
			for loss in h.health_losses(v):
				_add_factor(health_factors, loss["label"], loss["loss"])
			for penalty in h.morale_penalties(v, member["works"]):
				_add_factor(morale_factors, penalty["label"], penalty["penalty"])
	return {
		"population": population,
		"unemployed": unemployed,
		"avg_health": (health_total / population) if population > 0 else 1.0,
		"avg_morale": (morale_total / population) if population > 0 else 1.0,
		"health_factors": _factor_list(health_factors, population),
		"morale_factors": _factor_list(morale_factors, population),
	}

func _add_factor(factors: Dictionary, label: String, amount: float) -> void:
	if amount <= 0.001:
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
		note = "%.0f%% chance per month of leaving to found a household" % (HEHousehold.leave_home_chance(age) * 100.0)

	var needs: Array[Dictionary] = []
	for need in HENeeds.all():
		var required := need.per_person_daily
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
		"note": note,
		"vulnerability": vulnerability,
		"health": h.health(vulnerability),
		"morale": h.morale(vulnerability, is_worker),
		"morale_penalties": h.morale_penalties(vulnerability, is_worker),
		"needs": needs,
		"employer_business_id": h.employer_business_id if is_worker else -1,
	}

func get_business_reports(settlement_id: int = -1) -> Array:
	var out: Array = []
	var ids := businesses.keys()
	ids.sort()
	for business_id in ids:
		var b: HEBusiness = businesses[business_id]
		if settlement_id != -1 and b.settlement_id != settlement_id:
			continue
		var reference_wage := _reference_wage_per_worker(b.settlement_id)
		var report := {
			"business_id": b.id,
			"settlement_id": b.settlement_id,
			"name": b.name,
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
			"balance_history": b.balance_history(),
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
			"fields": _field_reports(b),
		}
		if b.uses_field_model():
			var projection := _next_harvest_projection(b, int(report["employed_workers"]))
			report["next_harvest_expected_units"] = projection["expected_units"]
			report["next_harvest_yield_fraction"] = projection["yield_fraction"]
		if b.kind == HEBusiness.Kind.TRADER:
			report["recipe_id"] = "trade"
			report["output_commodity"] = _trade_summary(b)
			report["stock"] = 0.0 # exports convert straight to money; the Trader never holds inventory
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
		elif b.kind == HEBusiness.Kind.WAREHOUSE:
			report["recipe_id"] = "warehouse"
			report["output_commodity"] = "Construction inventory"
			report["stock"] = 0.0
			report["construction_fund"] = b.balance
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
			report["herd_events"] = b.herd_events.duplicate(true)
			report["cull_target"] = herd_cull_target(b)
			report["cull_target_min"] = herd_cull_target_range(b).x
			report["cull_target_max"] = herd_cull_target_range(b).y
			if b.species == HEBusiness.Species.SHEEP:
				var sustaining := wool_sustaining_herd_counts(b)
				report["wool_sustaining_unstaffed"] = int(sustaining.x)
				report["wool_sustaining_current"] = int(sustaining.y)
				report["wool_sustaining_staffed"] = int(sustaining.z)
			report["care_fraction"] = b.last_care_fraction
			report["care_workers_needed"] = b.herd_size * HERD_LABOR_PER_HEAD_PER_DAY[b.species]
		else:
			var output_commodity := b.output_commodity()
			report["recipe_id"] = b.recipe.id
			report["output_commodity"] = Commodity.name_of(output_commodity)
			report["stock"] = b.stock(output_commodity)
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
		out.append(report)
	return out

func _kind_name(kind: HEBusiness.Kind) -> String:
	match kind:
		HEBusiness.Kind.TRADER: return "trader"
		HEBusiness.Kind.HERD: return "herd"
		HEBusiness.Kind.GOVERNMENT: return "government"
		HEBusiness.Kind.WAREHOUSE: return "warehouse"
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
	return {
		"expected_units": next_field.area * b.yield_per_area * yield_fraction,
		"yield_fraction": yield_fraction,
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
		}
	return out

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
		if b.kind != HEBusiness.Kind.PRODUCTION:
			continue
		if b.sells(commodity):
			return true
		if b.recipe.inputs.has(commodity):
			return true
	return false

func get_market_report(settlement_id: int, commodity: Commodity.Type) -> Dictionary:
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

func get_trader_export_settings(business_id: int) -> Array:
	var out: Array = []
	if not _trader_export_enabled.has(business_id):
		return out
	for commodity in EXPORT_PRIORITY:
		out.append({"commodity_id": commodity, "name": Commodity.name_of(commodity),
			"enabled": _trader_export_enabled[business_id].get(commodity, false)})
	return out

func set_trader_export_enabled(business_id: int, commodity: Commodity.Type, enabled: bool) -> void:
	if not _trader_export_enabled.has(business_id) or not EXPORT_PRIORITY.has(commodity):
		return
	_trader_export_enabled[business_id][commodity] = enabled

## Current participants and physical holdings. Requests/offers are estimates
## from the present state for the next clearing; last_clearing is yesterday's
## completed aggregate and is deliberately kept separate.
func get_market_detail(settlement_id: int, commodity: Commodity.Type) -> Dictionary:
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
				offered = minf(stock, stock / float(maxi(1, b.days_until_next_harvest())) * SELL_PACE_HEADROOM)
			elif not SUBSISTENCE_COMMODITIES.has(commodity):
				offered = _seller_surplus_above_reserve(b, settlement_id, commodity)
			sellers.append({"owner": b.name, "business_id": b.id, "offered": offered, "stock": stock})
		if b.recipe.inputs.has(commodity):
			var planned: float = float(_business_employed_worker_count(b.id)) * b.recipe.outputs[b.output_commodity()]
			var desired: float = maxf(0.0, planned * b.recipe.inputs[commodity] * PRODUCTION_INPUT_BUFFER_DAYS - stock)
			if desired > 0.0001:
				buyers.append({"owner": b.name, "business_id": b.id, "requested": desired,
					"funded": minf(desired, maxf(0.0, b.balance / price)) if price > 0.0 else 0.0,
					"stock": stock})
	var trader := _settlement_trader(settlement_id)
	if trader != null:
		var capacity: float = float(_business_employed_worker_count(trader.id)) * TRADER_CAPACITY_PER_WORKER
		if _business_selling(settlement_id, commodity) == null and not buyers.is_empty():
			sellers.append({"owner": "%s (imports)" % trader.name, "business_id": trader.id,
				"kind": "import", "capacity": capacity})
		elif _trader_export_enabled[trader.id].get(commodity, false) and _business_selling(settlement_id, commodity) != null:
			var export_seller := _business_selling(settlement_id, commodity)
			buyers.append({"owner": "%s (exports)" % trader.name, "business_id": trader.id, "kind": "export",
				"capacity": capacity,
				"available": minf(capacity, _exportable_surplus(export_seller, settlement_id, commodity))})
	report["buyers"] = buyers
	report["sellers"] = sellers
	report["holdings"] = holdings
	return report

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
		"births_total": _births_total,
		"worker_promotions_total": _worker_promotions_total,
		"export_revenue_total": _export_revenue_total,
		"import_cost_total": _import_cost_total,
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

## This Trader's imports and exports from up to the last `days` daily
## records, newest first. Each transaction is copied so callers cannot
## mutate simulation history through the query result.
func get_trader_transactions(business_id: int, days: int = 30) -> Array:
	assert(businesses.has(business_id), "Unknown business id %d" % business_id)
	assert((businesses[business_id] as HEBusiness).kind == HEBusiness.Kind.TRADER, "Business %d is not a Trader" % business_id)
	var start: int = max(0, _history.size() - days)
	var out: Array = []
	for record_index in range(_history.size() - 1, start - 1, -1):
		var record: Dictionary = _history[record_index]
		for transaction_index in range((record["trader_transactions"] as Array).size() - 1, -1, -1):
			var transaction: Dictionary = record["trader_transactions"][transaction_index]
			if transaction["business_id"] == business_id:
				out.append(transaction.duplicate(true))
	return out

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
	_pay_wages(record)
	_run_input_purchasing(record)
	_run_livestock_purchasing(record)
	_run_production(record)
	_run_market(record)
	_run_trade(record)
	_apply_price_signals()
	for market in markets.values():
		(market as HEMarket).record_supply_demand_history()
	_record_business_revenue_history()
	_run_consumption(record)
	if (day + 1) % HERD_EVAL_INTERVAL_DAYS == 0:
		_run_herds(record)
	if (day + 1) % MIGRATION_PRESSURE_EVAL_INTERVAL_DAYS == 0:
		_evaluate_migration_pressure()
	if (day + 1) % EMIGRATION_EVAL_INTERVAL_DAYS == 0:
		_evaluate_emigration(record)
		_evaluate_old_age(record)
		_evaluate_life_cycle(record)
	if (day + 1) % CAPACITY_EVAL_INTERVAL_DAYS == 0:
		_evaluate_business_capacity(record)
		_reconcile_employment(record)
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
		"wages_paid": {},
		"emigrations": 0,
		"old_age_deaths": 0,
		"money_written_off": 0.0,
		"goods_written_off": {},
		"births": 0,
		"worker_promotions": 0,
		"capacity_changes": {},
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

## Every business pays each currently-employed household a wage per worker
## equal to the settlement's going reference wage (_reference_wage_per_worker)
## -- not a share of what it happened to sell -- drawn from its own cash
## reserve (see WAGE_NEGATIVE_BALANCE_FLOOR_DAYS: balance is allowed to run
## deeply negative before pay actually gets rationed). Paid before today's
## market runs, same as before, so households can spend a wage the same day
## they earn it. Whether a business can actually AFFORD paying the going
## wage long-term is no longer this function's problem -- it always pays as
## much of the full bill as its (generous) cash allowance covers, and the
## weekly cash-runway guard in _evaluate_business_capacity is what actually
## shrinks a business that can't keep this up (see its doc comment). A
## business whose wage bill can't be covered even down to that floor has
## exhausted its credit and is deleted (see _fail_business).
func _pay_wages(record: Dictionary) -> void:
	var failed_ids: Array[int] = []
	for business_id in businesses.keys():
		var b: HEBusiness = businesses[business_id]
		b.last_wages_paid = 0.0
		b.last_cash_change = 0.0
		b.last_wage_shortfall = 0.0
		b.todays_flows = {}
		b.last_tax_collected = 0.0
		# Single reset point for the day, since not every business's
		# last_revenue gets overwritten later the same tick the way a
		# SUBSISTENCE_COMMODITIES seller's does in _clear_market_for --
		# a business selling a commodity nothing local consumes (the
		# Bloomery's iron) is only ever touched by _run_input_purchasing/
		# _run_trade below, both of which now ADD to this baseline rather
		# than assign, so today's contributions from each never clobber
		# each other.
		b.last_revenue = 0.0
		var employed := _business_employed_worker_count(business_id)
		if employed <= 0:
			b.last_wage_per_worker = 0.0
			record["wages_paid"][business_id] = 0.0
			continue
		var reference_wage := _reference_wage_per_worker(b.settlement_id)
		var total_needed: float = reference_wage * employed
		# A government pays only out of what its treasury actually holds -- no
		# overdraft allowance, unlike a business that expects to earn it back.
		# A warehouse's crew is paid by the treasury, which keeps the warehouse's
		# own balance (the construction fund) untouched.
		var payer: HEBusiness = b
		if b.kind == HEBusiness.Kind.WAREHOUSE:
			payer = _settlement_government(b.settlement_id)
			if payer == null:
				payer = b
		var floor: float = 0.0 if b.kind == HEBusiness.Kind.GOVERNMENT or b.kind == HEBusiness.Kind.WAREHOUSE else -WAGE_NEGATIVE_BALANCE_FLOOR_DAYS * total_needed
		if b.kind == HEBusiness.Kind.HERD:
			# Not clamped at the floor: debt already BELOW the floor counts
			# toward what must be raised, so a crew that's hired is always
			# actually paid (a hire into existing debt otherwise worked for 0).
			_hardship_butcher_if_needed(b, maxf(0.0, total_needed - (b.balance - floor)), record)
		var available: float = max(0.0, payer.balance - floor)
		var paid: float = clampf(total_needed, 0.0, available)
		var shortfall: float = total_needed - paid
		var wage_per_worker: float = paid / employed
		b.last_wage_per_worker = wage_per_worker
		b.record_wage_day(wage_per_worker)
		b.last_wage_shortfall = shortfall
		var total_paid := 0.0
		for household_id in households.keys():
			var h: HEHousehold = households[household_id]
			if h.employer_business_id != business_id:
				continue
			var pay: float = wage_per_worker * h.worker_capacity()
			h.balance += pay
			total_paid += pay
		payer.balance -= total_paid
		b.last_wages_paid = total_paid
		payer.last_cash_change -= total_paid
		record["wages_paid"][business_id] = total_paid
		if shortfall > 0.0001 and b.kind != HEBusiness.Kind.GOVERNMENT and b.kind != HEBusiness.Kind.WAREHOUSE:
			failed_ids.append(business_id)
	for business_id in failed_ids:
		_fail_business(business_id, record)

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
	for household_id in households.keys():
		var h: HEHousehold = households[household_id]
		if h.employer_business_id == business_id:
			h.employer_business_id = -1
			laid_off += 1
	var commodities: Array[Commodity.Type] = BASE_PRICE.keys()
	commodities.append_array(HERD_COMMODITIES)
	var goods_written_off: Dictionary[Commodity.Type, float] = {}
	for c in commodities:
		var amount := b.stock(c)
		if amount > 0.0:
			goods_written_off[c] = amount
			_goods_written_off_total[c] = _goods_written_off_total.get(c, 0.0) + amount
	_money_written_off_total += b.balance
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

## Kind.HERD only, called from _pay_wages before its cash allowance is
## computed: if this ranch can't cover today's wage bill even with its
## generous negative-balance allowance, sell enough of its own live herd to
## cover the gap -- see HARDSHIP_BUTCHER_PRICE_FRACTION/HARDSHIP_BUTCHER_
## MIN_HERD's doc comment for why. Routed through the same exported/
## export_revenue ledger _run_trade's Trader export pass uses, so this
## doesn't create money run_household_economy.gd's conservation check can't
## account for -- it's a real sale, just not through the Trader.
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
	var price: float = HERD_EXPORT_PRICE[b.species] * HARDSHIP_BUTCHER_PRICE_FRACTION
	if price <= 0.0:
		return
	var available_head: float = max(0.0, b.herd_size - HARDSHIP_BUTCHER_MIN_HERD[b.species])
	# Whole animals only, rounded UP: the shortfall is just today's unpaid
	# wage (cents), so rounding down would never sell anything and the ranch
	# would sit past its wage floor paying nobody. One head's proceeds then
	# sit in the balance and fund the following days' wages, so this fires
	# roughly once per (head price / daily wage) days, not daily.
	var butchered: float = min(floorf(available_head), ceilf(cash_shortfall / price))
	if butchered < 1.0:
		return
	b.herd_size -= butchered
	var proceeds: float = butchered * price
	b.balance += proceeds
	b.last_hardship_butchered = butchered
	# Money-side only (export_revenue) -- NOT record["exported"]. A normal
	# cull/export moves units OUT OF inventory (produced there by _run_herds,
	# then subtracted here), so recording it as "exported" nets out exactly
	# against that earlier "produced". A hardship sale converts herd_size
	# straight to cash and never touches inventory at all -- it was never
	# "produced" there in the first place, so subtracting it as an export
	# would make run_household_economy.gd's stock reconciliation expect a
	# drop in inventory that never happened (verified: this exact mismatch
	# is what the check caught once hardship butchering actually started
	# firing on a staffed Cattle Ranch).
	record["export_revenue"] += proceeds
	_export_revenue_total += proceeds
	_log_herd_event(b, "hardship_butcher", {
		"business_id": b.id, "head": butchered, "proceeds": proceeds,
		"shortfall": cash_shortfall, "herd_after": b.herd_size,
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
			b.care_worker_days += float(_business_employed_worker_count(business_id))
			continue
		if b.kind != HEBusiness.Kind.PRODUCTION:
			continue
		if b.uses_field_model():
			_run_field_growth(b, record)
			continue
		if b.processes_livestock:
			_run_butchery(b, record)
			continue
		var employed := _business_employed_worker_count(business_id)
		var output_commodity := b.output_commodity()
		var rate: float = b.recipe.outputs[output_commodity]
		var planned: float = float(employed) * rate
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
	var employed := _business_employed_worker_count(b.id)
	var output_commodity := b.output_commodity()
	var harvested := 0.0
	for f in b.fields:
		var share: float = float(employed) * (f.area / b.land_area_acres) if b.land_area_acres > 0.0 else 0.0
		f.labor_applied += share
		f.days_growing += 1
		if f.days_growing < b.growth_days:
			continue
		var labor_required: float = f.area * b.labor_per_area_per_day * b.growth_days
		var efficiency: float = clampf(f.labor_applied / labor_required, 0.0, 1.0) if labor_required > 0.0 else 0.0
		harvested += f.area * b.yield_per_area * efficiency
		f.days_growing = 0
		f.labor_applied = 0.0
	b.add_stock(output_commodity, harvested)
	b.last_planned_units = float(employed)
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

## One person's daily use of `commodity` lives in HENeeds, so a household's
## need and the reference wage's cost of living can never drift apart.
## `commodity` is expressed as if it were the need's only source; goods that
## satisfy no need return 0.
func _daily_need(h: HEHousehold, commodity: Commodity.Type) -> float:
	return float(h.headcount()) * HENeeds.units_per_person_daily(commodity)

## What `_clear_market_for` puts on offer to households today: the local
## seller's stock, paced over its harvest cycle if it has one. Zero when
## nothing local sells `commodity`.
func _household_offer(settlement_id: int, commodity: Commodity.Type) -> float:
	var seller := _business_selling(settlement_id, commodity)
	if seller == null:
		return 0.0
	var stock := seller.stock(commodity)
	if seller.has_long_cycle():
		var days_until: int = maxi(1, seller.days_until_next_harvest())
		return minf(stock, stock / float(days_until) * SELL_PACE_HEADROOM)
	return stock

## What a business buyer can actually get of `commodity` today. A local seller
## shares its paced offer with households pro rata (_b2b_offer, sized by the
## buyer's `claim`); there is no household reserve. With no local seller,
## `allow_import` lets the settlement's Trader supply it from outside out of its
## shared per-day import capacity (initialised lazily into
## `trader_import_capacity`, keyed by trader id).
func _business_offer(settlement_id: int, commodity: Commodity.Type, trader_import_capacity: Dictionary, allow_import: bool, claim: float) -> float:
	var seller := _business_selling(settlement_id, commodity)
	if seller != null:
		return _b2b_offer(seller, settlement_id, commodity, claim)
	var trader := _settlement_trader(settlement_id)
	if not allow_import or trader == null:
		return 0.0
	if not trader_import_capacity.has(trader.id):
		trader_import_capacity[trader.id] = float(_business_employed_worker_count(trader.id)) * TRADER_CAPACITY_PER_WORKER
	return trader_import_capacity[trader.id]

## The satisfiers a buyer can actually draw on today, cheapest per need-unit
## first. `offers` maps a satisfier to how much of it THIS kind of buyer can
## obtain (_household_offer or _business_offer). The baseline is always
## listed, even with nothing on offer, so a shortfall still lands on it; any
## other satisfier is listed only if something can really be bought.
## Near-ties (within a hundredth of a cent) go to the baseline, so a
## settlement with no real alternative behaves exactly as if the baseline
## were the only option. This is the single seam for how buyers choose
## between substitutes.
func _satisfier_cascade(settlement_id: int, need: HENeed, offers: Callable) -> Array[Commodity.Type]:
	var cascade: Array[Commodity.Type] = []
	for c in need.satisfiers():
		if c == need.baseline or offers.call(c) > 0.0001:
			cascade.append(c)
	if cascade.size() > 1:
		var local_market: HEMarket = markets[settlement_id]
		cascade.sort_custom(func(a: Commodity.Type, b: Commodity.Type) -> bool:
			var cost_a: float = local_market.price[a] / need.value_of(a)
			var cost_b: float = local_market.price[b] / need.value_of(b)
			if absf(cost_a - cost_b) > 0.0001:
				return cost_a < cost_b
			if a == need.baseline or b == need.baseline:
				return a == need.baseline
			return need.satisfiers().find(a) < need.satisfiers().find(b))
	return cascade

func _household_cascade(settlement_id: int, need: HENeed) -> Array[Commodity.Type]:
	return _satisfier_cascade(settlement_id, need, func(c: Commodity.Type) -> float: return _household_offer(settlement_id, c))

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
	return order

## How far a household's own judgement of a non-baseline satisfier's price may
## sit from the posted one, as a fraction (+-35%). Households never all agree
## that meat has just become cheaper than grain: without this, every
## household switches on the same day the price crosses parity, and demand for
## the substitute swings from everyone to no one as the price drifts back and
## forth over it. With it, demand shifts gradually across the range.
const HOUSEHOLD_TASTE_SPREAD := 0.35

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
	var best := need.baseline
	var best_cost: float = local_market.price[best] / need.value_of(best)
	for c in cascade:
		if c == need.baseline:
			continue
		var cost: float = local_market.price[c] / need.value_of(c) * (1.0 + taste)
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
func _desired_purchase(h: HEHousehold, commodity: Commodity.Type) -> float:
	var need := HENeeds.for_commodity(commodity)
	if need == null:
		return 0.0
	if need.unit_values.size() > 1:
		# Households clear a need's satisfiers in cascade order (cheapest posted
		# first). Each reaches for its own favourite (see _household_favourite)
		# and anything after it in that order as a fallback; goods that clear
		# BEFORE the favourite are skipped, so a household that finds meat
		# dearer than posted keeps buying grain until meat is clearly cheaper.
		var cascade := _household_cascade(h.settlement_id, need)
		if not cascade.has(commodity):
			return 0.0
		if cascade.find(commodity) < cascade.find(_household_favourite(h, need, cascade)):
			return 0.0
	var target := float(h.headcount()) * need.per_person_daily * TARGET_BUFFER_DAYS
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
	var met_by := {}
	for c in need.satisfiers():
		met_by[Commodity.name_of(c)] = 0.0
	for household_id in s.household_ids:
		var h: HEHousehold = households[household_id]
		var h_required: float = h.last_need_required.get(need.id, 0.0)
		var h_provided: float = h.last_need_provided.get(need.id, 0.0)
		required += h_required
		provided += h_provided
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
	var unmet_history: Array = []
	for record in get_daily_history(days):
		var entry: Dictionary = record["needs"].get(need.id, {})
		for name in met_history.keys():
			met_history[name].append(entry.get("met_by", {}).get(name, 0.0))
		unmet_history.append(maxf(0.0, entry.get("required", 0.0) - entry.get("provided", 0.0)))

	var household_count := met + unmet
	return {
		"id": need.id,
		"label": need.label,
		"drives_lifecycle": need.drives_lifecycle,
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

## One need for one household: spend satisfiers densest-first until the need
## is met. A shortfall is reported against the need's baseline satisfier, in
## that good's units. The household's record is the need's own outcome
## (required and provided, in need units) plus what each satisfier spent.
func _consume_need(h: HEHousehold, need: HENeed, record: Dictionary) -> void:
	var needed := float(h.headcount()) * need.per_person_daily
	var result := need.burn(h, needed)
	var provided: float = result["provided"]
	var burned: Dictionary = result["burned"]
	h.last_need_required[need.id] = needed
	h.last_need_provided[need.id] = provided

	var shortfall_units := (needed - provided) / need.value_of(need.baseline)
	if shortfall_units > 0.0001:
		_accumulate(h.last_unmet_scarcity, need.baseline, shortfall_units)

	var need_record: Dictionary = record["needs"].get_or_add(need.id, {
		"required": 0.0, "provided": 0.0, "met_by": {}, "households_met": 0, "households_unmet": 0})
	need_record["required"] += needed
	need_record["provided"] += provided
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

	var written_off := _write_off_and_remove_households(to_remove)
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
		if h.worker_capacity() <= 0:
			h.employer_business_id = -1
			if h.demographics.dependents > 0:
				orphaned.append(household_id)
			else:
				to_remove.append(household_id)

	for household_id in orphaned:
		if not _adopt_orphaned_dependents(household_id):
			to_remove.append(household_id)

	var written_off := _write_off_and_remove_households(to_remove)
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
	for age in orphan.dependent_ages():
		adopter.add_dependent(age)
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
	return true

## Shared by _evaluate_emigration and _evaluate_old_age: each `household_ids`
## entry has already been confirmed empty (is_empty()) by its caller and has
## nothing left to represent -- write off whatever balance/stock it still
## held (not redistributed, not inherited -- see get_city_summary's
## money_written_off_total) and remove it from settlement/households.
## Returns {"money": float, "goods": Dictionary[Commodity.Type, float]} so
## each caller can fold the totals into ITS OWN daily-record fields under
## its own cause, rather than this helper guessing which one it's for.
func _write_off_and_remove_households(household_ids: Array[int]) -> Dictionary:
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

	_money_written_off_total += money_written_off
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
	for household_id in households.keys():
		var h: HEHousehold = households[household_id]
		var pre_split_headcount := h.headcount()
		var promoted := h.evaluate_aging(rng)
		for i in promoted:
			_log_event("coming_of_age", {"household_id": household_id})
			new_households.append(_split_off_new_household(h, pre_split_headcount - i, h.last_promoted_member_numbers[i]))
		promotions += promoted
		if h.evaluate_birth(rng):
			births += 1
			_log_event("birth", {"household_id": household_id})

	for new_household in new_households:
		households[new_household.id] = new_household
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
func _split_off_new_household(parent: HEHousehold, headcount_before_leaving: int, member_number: int) -> HEHousehold:
	var new_id := _next_household_id
	_next_household_id += 1
	var share: float = 1.0 / float(max(headcount_before_leaving, 1))

	var starting_balance: float = parent.balance * share
	parent.balance -= starting_balance
	var new_household := HEHousehold.new(new_id, 1, 0, starting_balance, parent.settlement_id)

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
## _pay_wages always pays the full reference wage whenever a business can
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
		var reference_wage := _reference_wage_per_worker(b.settlement_id)
		reference_wages[b.settlement_id] = reference_wage
		if b.kind == HEBusiness.Kind.GOVERNMENT or b.kind == HEBusiness.Kind.WAREHOUSE:
			# Staffed by the seed / _ensure_administrator, not by revenue
			# signals -- it has no revenue per worker to judge.
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
		var delta := 0
		var change_reason := ""
		var avg_revenue := b.rolling_average_revenue_per_worker()
		if reference_wage > 0.0:
			var ratio_error := (avg_revenue - reference_wage) / reference_wage
			if absf(ratio_error) > WAGE_PROFIT_MARGIN:
				var clamped_error := clampf(ratio_error, -WAGE_RATIO_CLAMP, WAGE_RATIO_CLAMP)
				delta = roundi(clamped_error * CAPACITY_STEP_MAX_WORKERS)
				change_reason = "low_revenue" if delta < 0 else "high_revenue"
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
				}
	record["reference_wage_by_settlement"] = reference_wages
	if reference_wages.size() == 1:
		record["reference_wage"] = reference_wages.values()[0]

## How often (in days, always a whole multiple of CAPACITY_EVAL_INTERVAL_
## DAYS so it still only ever fires on one of the ticks the calling
## _daily_tick has already gated on that cadence) a business's TARGET
## capacity should actually be re-evaluated. Trader uses three weeks because
## its suppliers release stock in harvest batches. A field-model business
## grows its cadence with its production lag (roughly a sixth of its growth
## cycle) so step changes do not compound before output responds.
func _capacity_eval_interval_days(b: HEBusiness) -> int:
	if b.kind == HEBusiness.Kind.TRADER:
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
	var daily_wage_bill: float = _reference_wage_per_worker(b.settlement_id) * employed
	if daily_wage_bill <= 0.0:
		return INF
	var stock_value := 0.0
	if b.kind == HEBusiness.Kind.PRODUCTION:
		for oc in b.recipe.outputs.keys():
			stock_value += b.stock(oc) * (markets[b.settlement_id] as HEMarket).price[oc]
		if b.processes_livestock:
			# Live animals the Butcher holds are worth what it paid for them.
			for species in BUTCHERY_SPECIES_ORDER:
				stock_value += b.stock(HEBusiness.livestock_commodity(species)) * _butchery_head_price(species)
	elif b.kind == HEBusiness.Kind.HERD:
		# The culled animal itself has no local price (see HERD_EXPORT_PRICE's
		# doc comment) -- value it at what the Trader would actually pay for
		# it, not the undiscounted reference price, so this doesn't overstate
		# what the ranch could really turn it into. Wool, unlike the animal,
		# does clear locally, so it's valued at the real local price like any
		# other PRODUCTION stock above.
		var herd_commodity := b.herd_commodity()
		stock_value = b.stock(herd_commodity) * HERD_EXPORT_PRICE[b.species] * TRADER_BUY_PRICE_FRACTION
		if b.species == HEBusiness.Species.SHEEP:
			stock_value += b.stock(Commodity.Type.WOOL) * (markets[b.settlement_id] as HEMarket).price[Commodity.Type.WOOL]
	return (b.balance + stock_value) / daily_wage_bill

## Weekly self-tuning step 2: lay off whole households (highest household ID
## first, an arbitrary but deterministic tie-break) from any business now
## over its (possibly just-reduced) capacity, then let every under-capacity
## business hire from the resulting pool of unemployed households (lowest
## household ID first). Businesses are processed in a fixed ID order for
## hiring, so a lower-ID business gets first pick of the pool when two are
## expanding into the same freed labor at once -- a deterministic but real
## bias, same spirit as the pooled model's documented edge-order bias in
## _run_trade.
func _reconcile_employment(record: Dictionary = {}) -> void:
	var business_ids := businesses.keys()
	business_ids.sort()

	for business_id in business_ids:
		var b: HEBusiness = businesses[business_id]
		if b.kind == HEBusiness.Kind.GOVERNMENT or b.kind == HEBusiness.Kind.WAREHOUSE:
			continue # never laid off by the capacity loop; see _ensure_administrator
		var employed_ids: Array[int] = []
		for household_id in households.keys():
			if (households[household_id] as HEHousehold).employer_business_id == business_id:
				employed_ids.append(household_id)
		employed_ids.sort()
		var employed_workers := _business_employed_worker_count(business_id)
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
				"reference_wage_per_worker": capacity_change.get("reference_wage_per_worker", _reference_wage_per_worker(b.settlement_id)),
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
		var pool_index := 0
		var local_business_ids := (settlements[settlement_id] as HESettlement).business_ids.duplicate()
		local_business_ids.sort()
		for business_id in local_business_ids:
			var b: HEBusiness = businesses[business_id]
			if b.kind == HEBusiness.Kind.GOVERNMENT:
				continue # TODO(builders): hire builder_slots households here once modeled
			var employed_workers := _business_employed_worker_count(business_id)
			while employed_workers < b.capacity and pool_index < available.size():
				var household_id: int = available[pool_index]
				pool_index += 1
				var h: HEHousehold = households[household_id]
				if h.worker_capacity() <= 0:
					continue
				h.employer_business_id = business_id
				employed_workers += h.worker_capacity()
				_log_event("job", {"household_id": household_id, "business_id": business_id, "settlement_id": settlement_id, "workers": h.worker_capacity()})

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
		var days_until: int = maxi(1, seller.days_until_next_harvest())
		return minf(stock, stock / float(days_until) * SELL_PACE_HEADROOM)
	return stock

## Cash-funded household demand for `commodity` right now -- what households
## would ask for in today's market, used only to size a business buyer's
## fair share of the seller's offer before households have cleared.
func _household_funded_demand(settlement_id: int, commodity: Commodity.Type) -> float:
	var price: float = (markets[settlement_id] as HEMarket).price[commodity]
	if price <= 0.0:
		return 0.0
	var total := 0.0
	for household_id in (settlements[settlement_id] as HESettlement).household_ids:
		var h: HEHousehold = households[household_id]
		total += minf(_desired_purchase(h, commodity), maxf(0.0, h.balance / price))
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
	var total_offer := _household_offer(settlement_id, commodity)
	# Today's input purchases (_run_input_purchasing) already took their
	# pro-rata share of this seller's paced offer; households clear against
	# what's left of it, and the price signal below sees both sides' demand.
	var b2b: Dictionary = _b2b_today.get(settlement_id, {}).get(commodity, {})
	var b2b_sold: float = b2b.get("sold", 0.0)
	if seller != null and not b2b.is_empty():
		total_offer = minf(seller.stock(commodity), maxf(0.0, b2b["offer"] - b2b_sold))

	# A satisfier that is not last in its need's cascade passes whatever it
	# could not supply on to the next one, so that shortfall is not yet a
	# household going without -- only the last satisfier records it as unmet.
	var need := HENeeds.for_commodity(commodity)
	var defers_shortfall := false
	if need != null and need.unit_values.size() > 1:
		var cascade := _household_cascade(settlement_id, need)
		defers_shortfall = cascade.has(commodity) and cascade.back() != commodity

	var requests_funded: Dictionary = {}
	var total_funded_request := 0.0
	var total_wanted := 0.0

	for household_id in (settlements[settlement_id] as HESettlement).household_ids:
		var h: HEHousehold = households[household_id]
		var desired_qty: float = _desired_purchase(h, commodity)
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

		if seller != null:
			seller.consume(commodity, quantity_traded)
			seller.add_flow(HEBusiness.FLOW_SOLD, commodity, quantity_traded)
			var revenue := quantity_traded * price
			revenue -= _collect_sales_tax(settlement_id, revenue)
			seller.balance += revenue
			# += , not = -- _pay_wages already zeroed this at the top of the
			# tick, and _run_input_purchasing may have already added this
			# same seller's business-to-business sales today (e.g. Woodlot
			# selling wood to the Bloomery before households ever got a
			# chance to buy any).
			seller.last_revenue += revenue
			seller.last_cash_change += revenue

	# Records only the household pass; the business-to-business sales were
	# already merged in _run_input_purchasing. The PRICE signal below sees both.
	local_market.merge_clearing(commodity, total_offer, total_funded_request, quantity_traded, price)
	local_market.record_household_demand(commodity, total_wanted, total_funded_request, maxf(0.0, quantity_traded))
	record["traded_quantity"][name] = record["traded_quantity"].get(name, 0.0) + quantity_traded

	# Feeds the day's single price signal (see _apply_price_signals); household
	# and business passes both add to it, nothing adjusts the price here.
	var signal_today := _price_signal_entry(settlement_id, commodity)
	signal_today["offer"] = maxf(signal_today["offer"], total_offer + b2b_sold)
	signal_today["funded_household"] = total_funded_request
	signal_today["wanted_household"] = total_wanted
	signal_today["unfunded_household"] = maxf(0.0, total_wanted - total_funded_request)

## Today's accumulating inputs to each good's price signal, by settlement then
## commodity. Reset when input purchasing starts the day; consumed (and cleared)
## by _apply_price_signals once every local pass has run.
var _price_signal_today: Dictionary = {}

func _price_signal_entry(settlement_id: int, commodity: Commodity.Type) -> Dictionary:
	var by_commodity: Dictionary = _price_signal_today.get_or_add(settlement_id, {})
	return by_commodity.get_or_add(commodity, {
		"offer": 0.0, "funded_household": 0.0, "funded_business": 0.0,
		"business_buffer_request": 0.0, "import_capacity": 0.0,
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
			var unsold := maxf(0.0, offer - funded)
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
				"business_buffer_request": s["business_buffer_request"], "import_capacity": s["import_capacity"],
				"shortage": shortage, "unsold": unsold,
				"wanted_household": s["wanted_household"], "unfunded_household": s["unfunded_household"],
				"pressure": pressure, "reason": reason, "bound": bound,
			}
	_price_signal_today = {}

## Runs after _run_market, so a Trader only ever sees stock local
## households already had first crack at buying that same day -- it never
## competes with a household for a good it needs, by construction. Each
## Kind.TRADER business independently draws down every PRODUCTION
## business's surplus above its reserve for every enabled EXPORT_PRIORITY good,
## capped by the trader's own labor-derived handling capacity, and pays a
## deliberately low price (TRADER_BUY_PRICE_FRACTION of the going market
## rate) for what it takes -- see the constants' doc comment above for why.
## A good with no household demand at all (iron) has a reserve of zero (see
## _seller_surplus_above_reserve/_settlement_daily_demand), so it exports
## freely rather than needing a special case. A second pass right after
## does the same for each Kind.HERD business's culled animal stock, sharing
## the same capacity_limit/remaining_capacity -- see HERD_EXPORT_PRICE's
## doc comment for why that pass has no local reserve and uses a flat price
## instead of a live one.
func _run_trade(record: Dictionary) -> void:
	var trader_ids: Array[int] = []
	for business_id in businesses.keys():
		if (businesses[business_id] as HEBusiness).kind == HEBusiness.Kind.TRADER:
			trader_ids.append(business_id)
	trader_ids.sort()

	for trader_id in trader_ids:
		var trader: HEBusiness = businesses[trader_id]
		trader.last_exported = {}
		var capacity_limit: float = float(_business_employed_worker_count(trader_id)) * TRADER_CAPACITY_PER_WORKER
		var remaining_capacity := capacity_limit
		var trader_margin_today := 0.0
		var total_exported := 0.0

		for commodity in EXPORT_PRIORITY:
			if remaining_capacity <= 0.0001:
				break
			if not _trader_export_enabled[trader_id].get(commodity, false):
				continue
			var seller := _business_selling(trader.settlement_id, commodity)
			if seller == null:
				continue
			var surplus := _exportable_surplus(seller, trader.settlement_id, commodity)
			var quantity: float = min(surplus, remaining_capacity)
			var local_market: HEMarket = markets[trader.settlement_id]
			# Appetite is recorded even on a day nothing ships, so the market
			# chart can show demand the seller's stock didn't cover.
			local_market.record_export(commodity, remaining_capacity,
				quantity if not SUBSISTENCE_COMMODITIES.has(commodity) and quantity > 0.0001 else 0.0)
			if quantity <= 0.0001:
				continue

			var local_price: float = local_market.price[commodity]
			var pay_price: float = local_price * TRADER_BUY_PRICE_FRACTION
			seller.consume(commodity, quantity)
			seller.add_flow(HEBusiness.FLOW_SOLD, commodity, quantity)
			# Adds to whatever seller.last_revenue this same tick's earlier
			# steps (_run_input_purchasing, local market clearing) already
			# contributed -- tomorrow's wage for THIS business is funded by
			# every channel it sold through today together, exactly like a
			# real producer benefiting from export demand on top of
			# domestic demand.
			seller.balance += quantity * pay_price
			seller.last_revenue += quantity * pay_price

			var margin: float = quantity * (local_price - pay_price)
			trader.balance += margin
			trader_margin_today += margin
			total_exported += quantity
			remaining_capacity -= quantity

			trader.last_exported[commodity] = quantity
			var name := Commodity.name_of(commodity)
			record["exported"][name] = record["exported"].get(name, 0.0) + quantity
			record["trader_transactions"].append({
				"day": day + 1,
				"business_id": trader.id,
				"direction": "export",
				"commodity": name,
				"quantity": quantity,
				"unit_price": local_price,
				"local_value": quantity * local_price,
			})
			# New money entering the closed system, valued at market price
			# -- see _export_revenue_total's doc comment.
			var revenue: float = quantity * local_price
			record["export_revenue"] += revenue
			_export_revenue_total += revenue

			# SUBSISTENCE_COMMODITIES already get a full last_clearing entry
			# from _clear_market_for's household-facing pass; a good like
			# iron that households never buy has no other clearing source,
			# so this is the only place its market grid row gets real
			# offered/traded numbers and price drift.
			if not SUBSISTENCE_COMMODITIES.has(commodity):
				local_market.merge_clearing(commodity, surplus, quantity, quantity, local_price)

		trader.last_revenue += trader_margin_today

		# Herd export: a second, independent pass over Kind.HERD businesses,
		# sharing capacity_limit/remaining_capacity with the pass above but
		# accumulating its own margin total in a separate variable so the
		# flush above is never double-counted. herd.last_revenue doesn't need
		# resetting here -- _pay_wages' single per-day reset already covers
		# every business, herds included.
		var herd_margin_today := 0.0
		for herd_id in _herd_business_ids(trader.settlement_id):
			if remaining_capacity <= 0.0001:
				break
			var herd: HEBusiness = businesses[herd_id]
			var herd_commodity := herd.herd_commodity()
			# A staffed Butcher gets first call on the cull (see
			# _run_livestock_purchasing); only what it won't stock is exported.
			var exportable_head: float = maxf(0.0, herd.stock(herd_commodity) - _butchery_reserved_head(herd.settlement_id, herd.species))
			var herd_quantity: float = min(exportable_head, remaining_capacity)
			if herd_quantity <= 0.0001:
				continue

			var reference_price: float = HERD_EXPORT_PRICE[herd.species]
			var herd_pay_price: float = reference_price * TRADER_BUY_PRICE_FRACTION
			herd.consume(herd_commodity, herd_quantity)
			herd.balance += herd_quantity * herd_pay_price
			herd.last_revenue += herd_quantity * herd_pay_price

			var herd_margin: float = herd_quantity * (reference_price - herd_pay_price)
			trader.balance += herd_margin
			herd_margin_today += herd_margin
			total_exported += herd_quantity
			remaining_capacity -= herd_quantity

			_accumulate(trader.last_exported, herd_commodity, herd_quantity)
			var herd_name := Commodity.name_of(herd_commodity)
			_accumulate(record["exported"], herd_name, herd_quantity)
			var herd_revenue: float = herd_quantity * reference_price
			record["export_revenue"] += herd_revenue
			_export_revenue_total += herd_revenue

		trader.last_revenue += herd_margin_today
		trader.last_planned_units = capacity_limit
		trader.last_actual_units = total_exported

## The herd size `b` culls back down to each review: its own player-set
## cull_target, or the species default if none was ever set.
func herd_cull_target(b: HEBusiness) -> float:
	return b.cull_target if b.cull_target > 0.0 else HERD_CULL_TARGET[b.species]

## The range a ranch's cull target may be set to: never below the hardship
## butchering floor (selling down to it would otherwise fight the cull), and
## never above what the whole shared pasture could hold for this species.
func herd_cull_target_range(b: HEBusiness) -> Vector2:
	var land_per_head: float = CATTLE_LAND_PER_HEAD if b.species == HEBusiness.Species.CATTLE else SHEEP_LAND_PER_HEAD
	var lowest: float = HARDSHIP_BUTCHER_MIN_HERD[b.species]
	var highest: float = maxf(lowest, floorf(SETTLEMENT_GRAZING_LAND / land_per_head))
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
## convention as _run_trade's edge order) so each one's land claim is
## resolved against what settlements earlier in the order already took,
## rather than all racing for the same pasture at once.
func _run_herds(record: Dictionary) -> void:
	var land_claimed: Dictionary = {} # settlement_id -> float
	var herd_ids: Array[int] = []
	for business_id in businesses.keys():
		if (businesses[business_id] as HEBusiness).kind == HEBusiness.Kind.HERD:
			herd_ids.append(business_id)
	herd_ids.sort()

	for business_id in herd_ids:
		var b: HEBusiness = businesses[business_id]
		var land_per_head: float = CATTLE_LAND_PER_HEAD if b.species == HEBusiness.Species.CATTLE else SHEEP_LAND_PER_HEAD
		var claimed_by_others: float = land_claimed.get(b.settlement_id, 0.0)
		var available_land: float = max(0.0, SETTLEMENT_GRAZING_LAND - claimed_by_others)
		var max_herd_by_land: float = (available_land / land_per_head) if land_per_head > 0.0 else b.herd_size

		# Fed if the herd already fits the land available to it; a herd that
		# has outgrown its share is neglected -- no grain is bought to make
		# up the gap (see SETTLEMENT_GRAZING_LAND's doc comment).
		var fed := b.herd_size <= max_herd_by_land
		var herd_before: float = b.herd_size

		# Care: the staffed share of the worker-days this herd needs for full
		# care over the interval. 0 = nobody employed (free-range baseline),
		# 1 = fully staffed. Drives the upsides in HERD_STAFFED_*.
		var care_required: float = herd_before * HERD_LABOR_PER_HEAD_PER_DAY[b.species] * HERD_EVAL_INTERVAL_DAYS
		var care: float = clampf(b.care_worker_days / care_required, 0.0, 1.0) if care_required > 0.0 else 1.0
		b.care_worker_days = 0.0
		b.last_care_fraction = care

		var loss_rate: float = (HERD_LOSS_RATE_FED[b.species] if fed else HERD_LOSS_RATE_NEGLECTED[b.species]) * (1.0 - HERD_STAFFED_MORTALITY_CUT * care)
		var born: float = herd_before * HERD_GROWTH_RATE[b.species] * HERD_GROWTH_RATE_MULTIPLIER * (1.0 + HERD_STAFFED_REPRODUCTION_BONUS * care)
		var died: float = herd_before * loss_rate
		b.herd_size = clampf(herd_before + born - died, 0.0, max_herd_by_land)
		_log_herd_event(b, "herd_birth", {"born": born, "died": died, "fed": fed, "care": care, "herd_after": b.herd_size})

		b.last_wool_produced = 0.0
		if b.species == HEBusiness.Species.SHEEP:
			var wool: float = b.herd_size * WOOL_PER_HEAD_PER_INTERVAL * (1.0 + HERD_STAFFED_WOOL_BONUS * care)
			b.add_stock(Commodity.Type.WOOL, wool)
			b.last_wool_produced = wool
			_accumulate(record["produced"], Commodity.name_of(Commodity.Type.WOOL), wool)

		b.last_culled = {}
		b.last_actual_units = 0.0
		var target: float = herd_cull_target(b)
		if b.herd_size > target:
			var excess: float = b.herd_size - target
			b.herd_size = target
			var commodity := b.herd_commodity()
			b.add_stock(commodity, excess)
			b.last_culled[commodity] = excess
			b.last_actual_units = excess
			_accumulate(record["produced"], Commodity.name_of(commodity), excess)
			_log_herd_event(b, "herd_cull", {"head": excess, "herd_after": b.herd_size})

		land_claimed[b.settlement_id] = claimed_by_others + b.herd_size * land_per_head

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
## business whose recipe outputs it, or (WOOL only) whichever Sheep Farm holds
## it. Cattle Ranches/Sheep Farms' herd_commodity() (the animal itself) is
## deliberately NOT resolved here: no household buys a live animal, so it
## never joins the local market. Ranches sell it to a Butcher directly (see
## _run_livestock_purchasing) or to the Trader (see HERD_EXPORT_PRICE).
func _business_selling(settlement_id: int, commodity: Commodity.Type) -> HEBusiness:
	for business_id in businesses.keys():
		var b: HEBusiness = businesses[business_id]
		if b.settlement_id != settlement_id:
			continue
		if b.sells(commodity):
			return b
		if b.kind == HEBusiness.Kind.HERD and b.species == HEBusiness.Species.SHEEP and commodity == Commodity.Type.WOOL:
			return b
	return null

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

## The stock a PRODUCTION business can sell to a buyer OUTSIDE the settlement
## right now (_run_trade's export step), above the reserve that protects local
## subsistence demand -- so an exporting Trader can never outbid a household
## for a good it needs to survive, by construction. Local businesses buying
## inputs do NOT use this: they compete with households in the market itself
## (see _b2b_offer). A
## field-model (or herd -- see HEBusiness.has_long_cycle()) seller's own
## next harvest is a known, dated relief -- the reserve only needs to cover
## local demand until THEN, not a flat buffer that ignores how close (or
## far) that day actually is. A legacy/non-cyclical seller has no such
## date, so it keeps a flat TRADER_RESERVE_BUFFER_DAYS.
func _seller_surplus_above_reserve(seller: HEBusiness, settlement_id: int, commodity: Commodity.Type) -> float:
	var reserve_days: float = float(seller.days_until_next_harvest()) if seller.has_long_cycle() else TRADER_RESERVE_BUFFER_DAYS
	var reserve: float = _settlement_daily_demand(settlement_id, commodity) * reserve_days
	return max(0.0, seller.stock(commodity) - reserve)

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
	var household_demand := _household_funded_demand(settlement_id, commodity)
	if claim <= 0.0001 or claim + household_demand <= 0.0001:
		return remaining
	return minf(remaining, seller.stock(commodity)) * claim / (claim + household_demand)

## Export happens after local input purchases and production. Leave enough
## at the seller for staffed local businesses to buy their next day's input
## before the next production pass. This matters when ore exports are enabled:
## without it the Trader could take every ore mined today before the
## Bloomery gets its first chance to buy that newly produced ore tomorrow.
func _exportable_surplus(seller: HEBusiness, settlement_id: int, commodity: Commodity.Type) -> float:
	var surplus := _seller_surplus_above_reserve(seller, settlement_id, commodity)
	var next_day_input_need := 0.0
	for business_id in businesses.keys():
		var buyer: HEBusiness = businesses[business_id]
		if buyer.settlement_id != settlement_id or buyer.kind != HEBusiness.Kind.PRODUCTION or not buyer.recipe.inputs.has(commodity):
			continue
		var planned: float = float(_business_employed_worker_count(business_id)) * buyer.recipe.outputs[buyer.output_commodity()]
		next_day_input_need += maxf(0.0, planned * buyer.recipe.inputs[commodity] - buyer.stock(commodity))
	return maxf(0.0, surplus - next_day_input_need)

## Runs first thing in the tick (right after _pay_wages, before
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
## importing it from outside on the spot at TRADER_BUY_PRICE_FRACTION of
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
		if (businesses[business_id] as HEBusiness).kind == HEBusiness.Kind.TRADER:
			(businesses[business_id] as HEBusiness).last_imported = {}

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

		var trader := _settlement_trader(buyer.settlement_id)
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
			var bought: float = requested * purchase_ratio
			var price: float = local_market.price[commodity]
			var cost: float = bought * price
			buyer.balance -= cost
			buyer.last_cash_change -= cost
			buyer.add_stock(commodity, bought)
			buyer.add_flow(HEBusiness.FLOW_BOUGHT, commodity, bought)
			var name := Commodity.name_of(commodity)
			record["traded_quantity"][name] = record["traded_quantity"].get(name, 0.0) + bought

			var seller := _business_selling(buyer.settlement_id, commodity)
			if seller != null:
				var b2b: Dictionary = _b2b_entry(buyer.settlement_id, commodity, seller)
				b2b["sold"] += bought
				b2b["requested"] += requested * affordable_ratio
				seller.consume(commodity, bought)
				seller.add_flow(HEBusiness.FLOW_SOLD, commodity, bought)
				var net_cost := cost - _collect_sales_tax(buyer.settlement_id, cost)
				seller.balance += net_cost
				seller.last_revenue += net_cost
				seller.last_cash_change += net_cost
				# Business-to-business sale (e.g. Iron Mine -> Bloomery): no
				# household or Trader pass records it, so without this the
				# good's market shows 0 supplied / 0 requested.
				var offer_before_sale: float = b2b["offer"]
				local_market.merge_clearing(commodity, offer_before_sale, requested, bought, price)
			elif trader != null:
				var offer_before: float = trader_import_capacity[trader.id]
				trader_import_capacity[trader.id] -= bought
				var import_cost: float = cost * TRADER_BUY_PRICE_FRACTION
				# The sale to the local buyer is taxed; the Trader, as seller,
				# bears it out of its import margin (never out of import_cost,
				# which leaves the closed system).
				var margin: float = cost - import_cost - _collect_sales_tax(buyer.settlement_id, cost)
				trader.balance += margin
				trader.last_revenue += margin
				trader.last_cash_change += margin
				trader.last_imported[commodity] = trader.last_imported.get(commodity, 0.0) + bought
				record["imported"][name] = record["imported"].get(name, 0.0) + bought
				record["trader_transactions"].append({
					"day": day + 1,
					"business_id": trader.id,
					"direction": "import",
					"commodity": name,
					"quantity": bought,
					"unit_price": price,
					"local_value": cost,
				})
				record["import_cost"] += import_cost
				_import_cost_total += import_cost

				local_market.merge_clearing(commodity, offer_before, requested, bought, price)

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
	var wage_floor := -WAGE_NEGATIVE_BALANCE_FLOOR_DAYS * _reference_wage_per_worker(buyer.settlement_id) * employed
	var headroom := maxf(0.0, buyer.balance - wage_floor)
	return maxf(buyer.balance, 0.0) + minf(headroom, INPUT_CREDIT_DAYS * daily_input_cost)

## What the Butcher pays a ranch for one head of `species`.
func _butchery_head_price(species: HEBusiness.Species) -> float:
	return HERD_EXPORT_PRICE[species] * BUTCHERY_PURCHASE_PRICE_FRACTION

## Worker-days of processing the livestock `b` holds represents.
func _butchery_held_worker_days(b: HEBusiness) -> float:
	var total := 0.0
	for species in BUTCHERY_SPECIES_ORDER:
		total += b.stock(HEBusiness.livestock_commodity(species)) * BUTCHERY_WORKER_DAYS_PER_HEAD[species]
	return total

## Runs right after _run_input_purchasing: each staffed Butcher tops its
## livestock up to BUTCHERY_INPUT_BUFFER_DAYS of work from the settlement's
## ranches, cattle first, paying each ranch _butchery_head_price. This is a plain
## business-to-business transfer -- no money or animals enter or leave the
## system -- and it happens before _run_trade's herd export, so the Butcher
## always gets first call on a cull.
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
		for species in BUTCHERY_SPECIES_ORDER:
			if wanted_worker_days <= 0.0001:
				break
			var commodity := HEBusiness.livestock_commodity(species)
			var price: float = _butchery_head_price(species)
			var worker_days_per_head: float = BUTCHERY_WORKER_DAYS_PER_HEAD[species]
			for herd_id in _herd_business_ids(butcher.settlement_id):
				var herd: HEBusiness = businesses[herd_id]
				if herd.species != species:
					continue
				var affordable: float = maxf(0.0, butcher.balance + BUTCHERY_CREDIT_LIMIT) / price
				var head: float = minf(minf(herd.stock(commodity), wanted_worker_days / worker_days_per_head), affordable)
				if head <= 0.0001:
					continue
				var cost: float = head * price
				herd.consume(commodity, head)
				herd.add_flow(HEBusiness.FLOW_SOLD, commodity, head)
				var net_cost := cost - _collect_sales_tax(butcher.settlement_id, cost)
				herd.balance += net_cost
				herd.last_revenue += net_cost
				herd.last_cash_change += net_cost
				butcher.balance -= cost
				butcher.last_cash_change -= cost
				butcher.add_stock(commodity, head)
				butcher.add_flow(HEBusiness.FLOW_BOUGHT, commodity, head)
				var name := Commodity.name_of(commodity)
				record["traded_quantity"][name] = record["traded_quantity"].get(name, 0.0) + head
				wanted_worker_days -= head * worker_days_per_head

## Livestock the Trader must leave in `settlement_id`'s ranches for staffed
## Butchers to buy tomorrow: what their crews would still stock up on, cattle
## first. An unstaffed Butcher reserves nothing, so a settlement whose Butcher
## has not been hired yet exports its cull raw exactly as before.
func _butchery_reserved_head(settlement_id: int, species: HEBusiness.Species) -> float:
	var reserved := 0.0
	var business_ids := businesses.keys()
	business_ids.sort()
	for business_id in business_ids:
		var butcher: HEBusiness = businesses[business_id]
		if not butcher.processes_livestock or butcher.settlement_id != settlement_id:
			continue
		var workers := _business_employed_worker_count(business_id)
		if workers <= 0:
			continue
		var wanted_worker_days: float = float(workers) * BUTCHERY_INPUT_BUFFER_DAYS - _butchery_held_worker_days(butcher)
		for candidate in BUTCHERY_SPECIES_ORDER:
			if wanted_worker_days <= 0.0001:
				break
			var available: float = 0.0
			for herd_id in _herd_business_ids(settlement_id):
				var herd: HEBusiness = businesses[herd_id]
				if herd.species == candidate:
					available += herd.stock(HEBusiness.livestock_commodity(candidate))
			var worker_days_per_head: float = BUTCHERY_WORKER_DAYS_PER_HEAD[candidate]
			var taken_worker_days: float = minf(wanted_worker_days, available * worker_days_per_head)
			if candidate == species:
				reserved += taken_worker_days / worker_days_per_head
			wanted_worker_days -= taken_worker_days
	return reserved

## One day of butchery: the crew's worker-days go to the livestock the Butcher
## holds, cattle first, and each head becomes meat and leather at once. The
## animals are booked as a cost at what the Butcher paid for them (the same
## way a recipe input is costed when consumed), so capacity tuning sees the
## net revenue the work really earns.
func _run_butchery(b: HEBusiness, record: Dictionary) -> void:
	var workers := _business_employed_worker_count(b.id)
	var worker_days_left := float(workers)
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
		b.last_revenue -= head * _butchery_head_price(species)
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
	for household_id in households.keys():
		if (households[household_id] as HEHousehold).employer_business_id == gov.id:
			admin_ids.append(household_id)
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
## basis for the Trader's reserve (TRADER_RESERVE_BUFFER_DAYS worth of
## this), so the reserve tracks the settlement's actual size/composition
## rather than being a fixed number that a shrinking or growing population
## would drift away from.
##
## For a good several satisfiers can supply, this is the whole need expressed
## in that good: each good's reserve guards what households COULD draw of it,
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
		total += _daily_need(h, commodity)
	return total

func _business_employed_worker_count(business_id: int) -> int:
	var total := 0
	for household_id in households.keys():
		var h: HEHousehold = households[household_id]
		if h.employer_business_id == business_id:
			total += h.worker_capacity()
	return total

func _business_employed_household_count(business_id: int) -> int:
	var total := 0
	for household_id in households.keys():
		if (households[household_id] as HEHousehold).employer_business_id == business_id:
			total += 1
	return total

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

## The going rate a worker's wage needs to clear for that worker's WHOLE
## household to afford subsistence: (population / total workers) people
## depend on each worker's wage, on average, and each of those people needs
## every HENeed's per-person daily amount, bought as the cheapest satisfier
## per need-unit on offer, priced at each commodity's trailing average
## (_average_price_history) in THIS settlement's market rather than today's
## live spot price. A
## business's rolling_average_wage() is already smoothed over
## HEBusiness.WAGE_ROLLING_WINDOW_DAYS; comparing that against a live price
## would pit a slow-moving average against a fast one that the SAME
## business's own output directly moves (selling more grain pushes
## grain_price down, which lowers both sides of the comparison through the
## same channel) -- a timescale mismatch that reads as a profitability
## signal when it's really same-day noise. Smoothing both sides over the
## same window fixes that without hiding a genuine, sustained price
## trend -- it just takes as long to show up here as it does in the wage
## average it's being judged against.
##
## This is the number _evaluate_business_capacity compares each business's
## actual wage against -- a business paying above it is generating more
## value per worker than that worker's household needs to survive
## (profitable, should grow); below it, it structurally can't sustain the
## households working there (unprofitable, should shrink), regardless of
## what its production recipe's rate happens to be.
func _reference_wage_per_worker(settlement_id: int) -> float:
	var total_workers := 0
	var total_population := 0
	for household_id in (settlements[settlement_id] as HESettlement).household_ids:
		var h: HEHousehold = households[household_id]
		total_workers += h.worker_capacity()
		total_population += h.headcount()
	if total_workers <= 0:
		return 0.0
	var dependency_ratio := float(total_population) / float(total_workers)
	var per_person_cost := 0.0
	for need in HENeeds.all():
		var cheapest_unit_cost := INF
		for c in _household_cascade(settlement_id, need):
			cheapest_unit_cost = minf(cheapest_unit_cost, _average_price_history(settlement_id, c) / need.value_of(c))
		per_person_cost += cheapest_unit_cost * need.per_person_daily
	return dependency_ratio * per_person_cost

## BASE_PRICE.keys(), not just SUBSISTENCE_COMMODITIES -- every commodity
## that can actually sit in SOMEONE's inventory (a business's, in iron's
## case; iron ore never does, see _run_input_purchasing, but costs nothing
## to include). Deliberately UNFILTERED, unlike get_market_summary()'s
## active-commodity filter -- conservation accounting must still count
## stock of a good that just went inactive (e.g. a Bloomery whose capacity
## self-tuned to zero but still has unsold iron sitting in inventory).
func _total_stock_snapshot(settlement_id: int = -1) -> Dictionary:
	# BASE_PRICE.keys() covers every commodity that can sit in a HOUSEHOLD's
	# inventory (grain/timber/wool) or a PRODUCTION business's (iron_ore,
	# iron); HERD_COMMODITIES (the culled animal itself) is appended
	# separately since it never joins BASE_PRICE at all -- see
	# HERD_EXPORT_PRICE's doc comment for why.
	var commodities: Array[Commodity.Type] = BASE_PRICE.keys()
	commodities.append_array(HERD_COMMODITIES)
	var snap := {}
	for c in commodities:
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
