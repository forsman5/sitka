# Household economy: moving off the derived reference wage

## Problem

`HESimulation._reference_wage_per_worker` is `(people / workers) x per-person subsistence cost`. It is meant as a benchmark, but it is also the wage every business pays, so:

- Income tracks cost of living by construction. Households sit at income ~ cost; productivity gains make goods cheaper and wages fall with them, so no real slack appears (see `measure_household_slack.gd`: zero two-worker households sustain one wage).
- One number does three jobs: the wage paid (`_pay_wages`), the benchmark the capacity loop compares revenue-per-worker against (`_evaluate_business_capacity`), and the scale for liquidity floors and reserves (`WAGE_NEGATIVE_BALANCE_FLOOR_DAYS`, warehouse reserve, trader spread floor, input-purchasing floors).
- It is only as stable as the price history it reads: per-head cost swings 10-17x between snapshots.

## What a margin tells us (experiment, not a design)

`reference_wage_margin` (default 0) multiplies the derived wage. `measure_wage_margin.gd`, 2 presets, 720 days, one seed:

| Margin | Small village: failed / employed / income:cost | Large village: failed / employed / income:cost |
|---|---|---|
| 0% | 0 / 85% / 0.90 | 0 / 95% / 0.99 |
| +10% | 0 / 83% / 0.98 | 1 / 92% / 1.08 |
| +25% | 0 / 79% / 1.05 | 1 / 91% / 1.21 |
| +50% | 1 / 69% / 1.06 | 3 / 82% / 1.35 |

Businesses can carry roughly +10-25% before failures start; +50% costs jobs (capacity shrinks) and the gain in income:cost flattens. A fixed markup is a stopgap: it raises wages without raising what a worker produces, so it spends the same pool of value differently.

## Target

Wages as an outcome, not a formula:

1. **Business wage** = a share of what a worker actually earns it (rolling revenue per worker x labour share), never below the household reservation wage, capped by what the business can fund.
2. **Reservation wage** per household = its subsistence cost (the current derived number, demoted to a floor). Below it a household emigrates or looks elsewhere.
3. **Competition**: the weekly hiring pool already moves households between employers; let it follow wages so productive businesses pull labour and the rest tune capacity.
4. **Real surplus**: value-adding steps (cooking), tools/morale, trade margin. Only these make the wealth real.

## Phases

0. **Split the three roles** of the reference wage into separate functions (wage paid, capacity benchmark, liquidity scale) with identical values. No behaviour change; harness outputs byte-identical.
1. **Pay from productivity**: business wage = clamp(labour share x revenue per worker, reservation, funded cap). Keep the old formula behind a flag for A/B. Gate on `measure_wage_margin` style runs: no rise in failures, employment held.
2. **Reservation and migration**: unemployed or sub-reservation households leave or shrink the town; check against population and `run_household_economy.gd`.
3. **Grow the basket**: housing/cooking/market services as real needs and jobs, so spendable income has somewhere to go.
4. **Money pools in businesses**: see "Money audit" below. Profit above the wage never reaches households, so phase 1 is also the distribution fix.

## Money audit (measure_money_flows.gd)

Seeded presets, 720 days, margin 0. The identity `change = exports + startup cash - imports - construction - written off` closes to 0, so every flow is accounted for.

| Preset | Money day 0 -> 720 | Exports in | Written off | Held by households at 720 |
|---|---|---|---|---|
| Small | 11k -> 14k | 3.5k | 0.4k | 0.8k (6%) |
| Mining | 12k -> 117k | 109k | 3.7k | 6.0k (5%) |
| Large | 21k -> 355k | 344k | 9.6k | 16k (5%) |

- **Not a leak, and not the trade gap.** Trade is a net *source*: export revenue is new money (no imports in these presets). The 9.6k "written off" is the savings of households that vanish: 8.2k emigration, 1.4k old age, 0 business failures at margin 0. It is under 3% of what exports bring in.
- **The real issue is pooling.** Money supply grows ~17x, but ~95% of it sits in businesses: in the large village the trader holds 170k (48%), the bloomery 99k, farms and woodlots 44k. Households hold 16k (~280 each). The same wage formula that pegs pay to subsistence means revenue above the wage is retained as business profit, with no owners, dividends, profit share or tax recirculation.
- That is why a margin only partly works: the cash is concentrated in exporters (trader, bloomery) while the businesses that fail at +50% (e.g. ranches, which sit negative) are not the ones holding it.
- **Implication**: a productivity/revenue-share wage (phase 1) would move money from where it is earned to the households working there, and reaching a genuine "wealthy town" is a distribution problem more than a supply one.

## Open questions

- Labour share: fixed (e.g. 0.6) or per recipe?
- Does the reservation wage include dependents' cost fully, or only a floor to survive?
- Should the government (treasury) set a minimum wage, as a player lever?
- Price smoothing: how much before it hides real shocks?
