# Household economy: seasons

Seasons are a property of the household economy (H1) itself, not of any one scenario or the pooled valley. They are a pure function of the day, so a run is exactly as deterministic as before.

## Calendar

- Four 90-day seasons make a 360-day year: **Spring, Summer, Autumn, Winter** (`HESimulation.Season`, `DAYS_PER_SEASON`, `DAYS_PER_YEAR`). Day 0 is the first day of spring.
- `HESimulation.season_of_day(day)` / `season_name_of_day(day)` are static. `get_clock_summary()` returns `day`, `season`, `season_name`, `day_of_season` (0-based) and `year` (0-based).
- `HERD_EVAL_INTERVAL_DAYS` already equals 90, so **each herd review closes exactly one season**: the review on day `d` (when `(d + 1) % 90 == 0`) belongs to `season_of_day(d)`.
- The dashboard shows `Season · Year N, Day M` in the top bar (tooltip: season number and day of season). Its day formatter now uses the 360-day year; it used 365 before, which disagreed with every simulation interval.

## Seasonal heat demand

Heating is the one need that follows the season (`HENeed.seasonal_curve`, `HENeeds.HEAT_SEASONAL_CURVE`). The shape is spring 1.0, summer 0.4, autumn 1.0, winter 1.8, interpolated through the season midpoints so demand glides instead of stepping at a boundary (winter needs 4.5x summer), and normalised so a year averages exactly 1.0: the yearly requirement and the cost-of-living basket are unchanged.

- `HENeed.seasonal_scale(day)` is the multiplier; `HESimulation._need_scale(household, need)` multiplies it by the home's effect (a stone house saves 25%). It is applied to the purchase target, the daily-use forecast, consumption and the household and person pages.
- The heat Needs detail shows the season's factor ("Winter: demand is x1.71 the yearly average"), and the chart follows it.
- Status: see the PR for the harness results; the scenario fixtures that run for years are sensitive to winter timber demand.

## Seasonal output

`SEASONAL_OUTPUT_MODIFIER` carries the pooled valley's curves (`valley_seed.gd`), spring/summer/autumn/winter:

| Good | Curve | Applied to |
|------|-------|------------|
| Grain | 0.8 / 1.0 / 1.6 / 0.1 | Farm field harvests |
| Timber | 1.0 / 1.0 / 1.0 / 0.6 | Woodlot field harvests |
| Wool | 1.5 / 1.5 / 0.5 / 0.2 | Sheep Farm review clip |

- **The season is the one the harvest or review lands in.** Fields are staggered, so every season still sees harvests; a winter harvest is just small.
- **The curve sets the shape, not the total.** H1's field yields and wool rate are calibrated to a yearly target, and the valley's curves average 0.875 (grain) and 0.925 (wool). The multiplier applied is `seasonal_yield_scale` = curve / its own yearly mean, so four seasons average exactly 1.0 and a year's output matches the pre-season model. Without this the town runs ~12% short of grain, grain's price climbs, wages indexed to it follow, and the Sheep Farm fails in its first autumn.
- Only the amount added to the business's inventory changes. Each unit is still produced once, recorded in the day's `produced`, held by one business, and then sold, consumed or exported through the usual market and ledger paths.
- Fields keep their own labor/efficiency maths; the modifier multiplies the finished harvest, after `efficiency`.
- Heat need supports an optional normalized seasonal curve (spring/summer/autumn/winter: 1.0 / 0.4 / 1.0 / 1.8). `_settlement_daily_demand(..., at_day)` evaluates it at the requested future day, so field producer planning sees the winter peak and summer trough when a scenario supplies a curve. The producer stability harness sets the curve for seasonal runs and uses `[1, 1, 1, 1]` for flat runs.
- Household consumption and purchase targets use the heat curve for the current day. Producer forecasts use the curve for each future day, alongside the season when each field harvest lands.

## Carrying the harvest through winter

A seller reserves its routine local use until its next harvest and exports the rest (`_seller_trade_offer`). With a winter harvest of ~0.1x that would ship an autumn glut out at the floor price and leave the town hungry, so for a seasonal good the reserve also includes `seasonal_carry_days(commodity, day)`: the days of ordinary use the lean days in the next `SEASONAL_CARRY_LOOKAHEAD_DAYS` (180) leave unsupplied, from each day's shortfall below the curve's own mean. For grain that is ~80 days through autumn, tapering through winter, and ~0 in spring and summer, so spring/summer exports are untouched and only the autumn glut is held. It only withholds **export**; local sales are unchanged.

Measured (`build_three_business_economy`, seed 4242, grain households could not buy, per 360-day year): 4.6k / 7.4k / 0.05k / 0.3k with the carry (the second year is the one-time build-up of the first winter store), against 2.4k / 10.2k / 8.5k / 4.9k without it and 7.2k / 0.9k / 0.2k / 0.2k on master before seasons. Population settles at the same ~95.


## Herds and winter fodder

- A winter review (the one closing Winter) makes each ranch eat grain **from its own inventory**: `herd_size * FODDER_PER_HEAD_PER_WINTER[species]`. It eats as much as it holds. The grain leaves the world as ordinary consumption (`record["consumed"]`, the ranch's `FLOW_CONSUMED`), so stock reconciliation needs no special case.
- **Fodder need per head:** cattle 3.0 (the valley's `FODDER_PER_HEAD_PER_SEASON`); sheep 0.45, which is 3.0 scaled by the forage ratio H1 already uses for grazing land (`SHEEP_LAND_PER_HEAD / CATTLE_LAND_PER_HEAD`). A sheep is worth ~1/20 of a cow here, so the valley's flat 3.0 would cost more than the animal and bankrupts the Sheep Farm.
- **Mortality follows cover.** Fodder cover (`eaten / needed`, 0..1) interpolates the review's loss rate from `HERD_LOSS_RATE_FED` (full cover) to `HERD_LOSS_RATE_NEGLECTED` (none). Overgrazing still takes the harsher of the two. Staffed care cuts the result as before.
- **Births are unchanged**: a flat per-review rate, winter included. The pooled valley stops births in winter, but bunching a year's births into three reviews made every cull about a third bigger and skipped winter's, so the Butcher could not absorb the lumps and more head left raw. Winter differs through fodder and mortality only.
- Wool is the review's `herd * WOOL_PER_HEAD_PER_INTERVAL * care bonus * seasonal_yield_scale`.

### Buying fodder

`_run_fodder_purchasing` runs at the end of `_run_input_purchasing`, so it shares that day's Trader import capacity. From the first day of autumn until the winter review, each ranch buys `(herd * need - grain held) / days left in the buying window` per day (autumn: days until winter starts; winter: days until the review).

- It is an ordinary business purchase through `_settle_purchase`: the local seller's stock (the Farm) first, else a Trader import; posted price, sales tax, the ranch's `input_local` / `input_import` ledger line and the seller's sale are all booked as for a recipe input. Nothing mutates stock or cash outside that path.
- **Budget:** the ranch's cash plus half of its wage overdraft (`_fodder_budget`; a ranch's overdraft is backed by its herd, see `_herd_collateral`). Fodder can never spend the credit its crew is paid from. A ranch that cannot afford the full need goes into winter underfed and its herd pays for it at the review.
- It feeds the grain price signal like any funded business request.

## Reports and dashboard

- Business report, field businesses: `next_harvest_expected_units` is now scaled by the season the harvest lands in; `next_harvest_season_modifier` gives the factor. The row status adds `Autumn ×1.8` style text when it is not 1.
- Business report, ranches: `fodder_stock`, `fodder_target`, `fodder_cover`, `last_review_season(_name)`, `last_fodder_needed`, `last_fodder_eaten`, `wool_season_modifier`. The detail view's Productivity tab shows a "Winter fodder" row and the row status shows fodder cover.
- `herd_birth` events carry `season`, `fodder_needed` and `fodder_eaten`; the blotter line reads e.g. `(Winter review, fodder 450 of 450 grain)`.

## Checks

`run_household_economy.gd` gains four checks: calendar boundaries and the valley curves, harvest/wool by season against a fully-labored field, winter fodder and fed/half-fed/unfed herd outcomes (plus grain leaving the world), and a 5-year run for stock and money reconciliation and survival.

## Not in this change

Town specialization and inter-town shipment tuning are untouched; the pooled valley (`simulation.gd`) is unchanged. Both can build on this model.

## Town view snow

The Town view shows winter. `HETownView.snow_cover_for_day(day)` gives 0..1: full through winter, settling over the last 12 days of autumn and melting over the first 12 of spring. The dashboard sets it every header refresh (`set_snow_cover`).

`shaders/town_snow.gdshader` does both layers from one shader: a cool, part see-through plane just above the ground (over roads, plazas, fields) and a shared overlay on every building mesh that whitens only up-facing faces, so roofs get a cap and walls stay clear; woodlot trees use the same shader with a much lower settle threshold, since a conifer cone is steep. Rendering only; no simulation state is read or changed.
