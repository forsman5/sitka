# Household economy wage model

## Current state (PR 106)

`HEWages` (`scripts/sim/household_economy/he_wages.gd`) owns payroll, the derived reference wage, its three roles, and business wages. Ordinary businesses pay `max(reference wage, labour_share x trailing net return per worker)`; government and warehouse crews receive the reference wage. The default labour share is 0.6. Productivity pay is the sole wage path, with no model flag or Settings control. The reference wage remains the floor and the fallback when a business lacks enough history.

Phases 0 and 1 are implemented. The tables below record the earlier A/B runs that informed the 0.6 default; they are measurements of those presets and seeds, not full validation of the always-on path. Reservation-based migration, wage-aware hiring, and a broader basket of needs remain design work.

## Problem

Before this change, the derived reference wage was `(people / workers) x per-person subsistence cost` and served as the wage every business paid. That reference-only path had these problems:

- Income tracks cost of living by construction. Households sit at income ~ cost; productivity gains make goods cheaper and wages fall with them, so no real slack appears (see `measure_household_slack.gd`: zero two-worker households sustain one wage).
- One number did three jobs: the wage paid, the benchmark used by the capacity loop, and the scale for liquidity floors and reserves. `HEWages` now gives those roles separate entry points. Capacity and liquidity still use the reference wage; ordinary business pay can rise with net return.
- It is only as stable as the price history it reads: per-head cost swings 10-17x between snapshots.

## What a margin tells us (experiment, not a design)

`HEWages.reference_wage_margin` (default 0) multiplies the derived wage. These historical reference-only results came from `measure_wage_margin.gd`, 2 presets, 720 days, one seed. The script now runs with productivity pay, so rerunning it will produce different values:

| Margin | Small village: failed / employed / income:cost | Large village: failed / employed / income:cost |
|---|---|---|
| 0% | 0 / 85% / 0.90 | 0 / 95% / 0.99 |
| +10% | 0 / 83% / 0.98 | 1 / 92% / 1.08 |
| +25% | 0 / 79% / 1.05 | 1 / 91% / 1.21 |
| +50% | 1 / 69% / 1.06 | 3 / 82% / 1.35 |

Even +10% produces a failure in the large preset; higher margins reduce employment, and at +50% the small village's gain in income:cost flattens. A fixed markup is a stopgap: it raises wages without raising what a worker produces, so it spends the same pool of value differently.

## Target

The longer-term design goal is for wages to reflect what workers produce and what households need:

1. **Business wage:** a share of trailing net return per worker, with the current settlement-wide reference wage as a floor. Payroll is limited by cash plus the existing wage overdraft; a private business fails if it cannot meet its full wage bill. A separate funded cap on the productivity premium has not been built.
2. **Household reservation:** eventually account for each household's own subsistence cost. The current floor is settlement-wide and does not change migration decisions.
3. **Competition:** eventually let households respond to wages when seeking jobs. Weekly hiring currently fills vacancies from the unemployed pool; it does not compare offers.
4. **Real surplus:** add useful goods and services, such as cooking and housing needs, so additional income can buy more than the current basket.

## Phases

0. **Done: split the three roles.** `HEWages.wage_paid_per_worker`, `capacity_benchmark_wage`, and `liquidity_scale` were separated. `HEWages` also owns payroll and its collateral-backed overdraft helpers. At that checkpoint, before productivity pay became the sole path, the recorded `run_household_economy.gd` and `measure_money_flows.gd` output remained byte-identical.
1. **Done: productivity pay is always on.** Ordinary businesses pay `max(reference, labour_share x trailing net return per worker)`, with a default labour share of 0.6. The model switch and reference-only branch were removed. `measure_wage_model.gd` now sweeps labour shares; the earlier A/B results below support 0.6 in the measured presets. The full household harness, longer and varied scenarios, and the dashboard and town view still need checking against the always-on path.
2. **Remaining: household reservation and migration.** Decide how to calculate a household-specific floor and how unemployment or pay below that floor affects migration. Existing emigration responds to starvation and homelessness, not to a reservation-wage comparison.
3. **Remaining: wage-aware hiring.** Decide how households compare offers and change employers without destabilizing staffing. Geographic hiring order, where available, is separate from wage competition.
4. **Remaining: useful surplus.** Expand needs and jobs, then measure whether higher pay creates lasting improvements rather than only larger balances. The money audit below explains why moving some business returns into wages is useful, but phase 1 is only one distribution mechanism.

## Phase 1 historical A/B results

Net return per worker is sales less consumed inputs and taxes over the staffing window (the quantity `_staffing_decision` already judges), not gross revenue: a trader's gross revenue is mostly goods it resells at cost. The reference wage is the floor, so a business with no qualifying history, a government, and a warehouse pay that rate. `HEWages.pay_wages` limits actual payroll to available cash plus the existing overdraft and fails a private business that cannot pay its full bill. The subsistence rows below were recorded before removal of the reference-only branch; the current `measure_wage_model.gd` sweeps productivity shares only.

720 days, mean of 3 seeds, margin 0. Values other than failures and final business count are averages of samples from day 120 through day 720. "Hold" is the sampled share of all money in households.

| Preset / model | Failed | Employed | Income:cost | Households covered | Hold | Wage vs ref |
|---|---|---|---|---|---|---|
| Small, subsistence | 0 | 86% | 0.91 | 41% | 7% | 1.0x |
| Small, share 0.6 | 0 | 82% | 1.54 | 57% | 15% | 1.8x |
| Small, share 0.8 | 0 | 74% | 1.50 | 54% | 22% | 2.2x |
| Mining, subsistence | 0 | 94% | 0.98 | 65% | 8% | 1.0x |
| Mining, share 0.6 | 0 | 93% | 4.13 | 80% | 44% | 4.1x |
| Mining, share 0.8 | 0 | 94% | 4.75 | 82% | 62% | 5.0x |
| Large, subsistence | 0 | 94% | 0.99 | 69% | 9% | 1.0x |
| Large, share 0.6 | 0 | 94% | 4.08 | 77% | 44% | 3.9x |
| Large, share 0.8 | 0 | 81% | 6.11 | 66% | 68% | 7.3x |

- **Measured gate met at 0.4 and 0.6**: no business failures in these runs, employment within 4 points in the worst case, and a larger average share of town money in households. These samples do not establish end-of-run balances or behavior in other scenarios.
- **0.8 over-pays in two presets**: employment drops 12-13 points in the small and large villages (businesses shrink crews). 0.6 is the selected default share.
- **Inequality**: average income:cost is 4x in the mining village but only 80% of households are covered. Wages differ by employer in this experiment, so households at high-return businesses (trader, bloomery) are rich and those at farms and woodlots stay near the reference. Household-specific reservation and wage-aware job choice remain open.
- **Remaining validation**: `run_household_economy.gd`'s assertions were tuned for the old reference-only model; this plan does not record a run against always-on productivity pay or an inspection in the town view and dashboard.

## Money audit (measure_money_flows.gd)

Historical reference-only run: seeded presets, 720 days, margin 0. The identity `change = exports + startup cash - imports - construction - written off` closes to 0 in these runs, so the measured money flows reconcile. A current run of `measure_money_flows.gd` uses productivity pay and will produce different values.

| Preset | Money day 0 -> 720 | Exports in | Written off | Held by households at 720 |
|---|---|---|---|---|
| Small | 11k -> 14k | 3.5k | 0.4k | 0.8k (6%) |
| Mining | 12k -> 117k | 109k | 3.7k | 6.0k (5%) |
| Large | 21k -> 355k | 344k | 9.6k | 16k (5%) |

- **Not a leak, and not the trade gap.** Trade is a net *source*: export revenue is new money (no imports in these presets). The 9.6k "written off" is the savings of households that vanish: 8.2k emigration, 1.4k old age, 0 business failures at margin 0. It is under 3% of what exports bring in.
- **The real issue is pooling.** Money supply grows ~17x, but ~95% of it sits in businesses: in the large village the trader holds 170k (48%), the bloomery 99k, farms and woodlots 44k. Households hold 16k (~280 each). The same wage formula that pegs pay to subsistence means revenue above the wage is retained as business profit, with no owners, dividends, profit share or tax recirculation.
- That is why a margin only partly works: the cash is concentrated in exporters (trader, bloomery) while the businesses that fail at +50% (e.g. ranches, which sit negative) are not the ones holding it.
- **Implication**: productivity pay moves part of the return from businesses to their workers in the measured runs. Whether that produces broadly shared wealth over longer play remains to be checked.

## Open questions

- Labour share: fixed (e.g. 0.6) or per recipe?
- Does the reservation wage include dependents' cost fully, or only a floor to survive?
- Should the government (treasury) set a minimum wage, as a player lever?
- Price smoothing: how much before it hides real shocks?

## Field producer staffing

Farm and Woodlot capacity is now managed by a forward stock plan (`HEProducerPlan`) rather than the trailing return and sales-volume tuner. The planner projects each field's next harvests using its current growing days, labor applied, candidate crew, tool productivity and the season the crop lands in. It selects the smallest crew that keeps projected stock above 14 days of forecast local use, with a 360-day maximum horizon, and changes capacity by at most four workers per evaluation. This keeps the reference-wage return available as report information, while the cash-runway guard still takes precedence when payroll is at risk. Herds, Traders, extractors and non-field workshops retain their existing staffing rules.

The steward offer follows funded household and business use, includes recent exports in the use forecast, releases stock above 90 days of cover over 30 days, and makes a bounded price nudge around measured cost per unit. The same offer feeds households, business input buyers and the market report. Storage remains unlimited and the policy does not optimise profit; acreage planning and rival sellers remain future work. Checks live in `check_producer_plan.gd` and `check_producer_offers.gd`.
- What acceptance runs and town-view checks should guide further tuning of the always-on productivity wage?
