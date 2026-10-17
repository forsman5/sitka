# Household economy: spending decisions and comfort goods

## Direction

Households today meet fixed per-person needs (food, heat, clothing, tools) with the cheapest satisfier per need-unit, nudged by a fixed per-household "taste" of +-35% on non-baseline prices. Once the needs are met, extra income only piles up as balance. After the wage model change (`docs/household-wage-model-plan.md`) towns do accumulate surplus (balance Gini 0.5-0.6, top income quintile ~3x master), but it has nowhere to go, so higher pay does not improve anyone's life and creates no new demand or jobs.

The aim is a household that decides what to buy with its means: comfort goods (meat first) that better-off households choose, that lift morale and so output, and that give businesses demand beyond subsistence.

## Measured starting point

On the merged wage model, day 365, mean of 3 seeds (`measure_stratification.gd`): meat is 0-1% of food in every preset. Two reasons:

- **Price**: meat costs about 3.2x grain per food-unit most of the year (grain sits at its 0.25 floor; meat 1.6 for 2 food-units). A cost-minimiser never buys it. In the lean season (last month of the year) grain spikes to 3-4 and meat becomes cheaper, but then there is none.
- **Supply**: meat is on offer 1-5 days a year because very little is made: a year-1 run produces 98 meat in the small village, 0 in mining and 24 in large (a household of four wants ~290 a year if it ate only meat). The cattle ranch runs one worker, and the Butcher only grows from measured output (it cannot grow from unmet demand it never sees). Export is not the cause: meat export is off by default and the Trader allocates capacity by margin per unit, not by `EXPORT_PINNED_FIRST` (that list only orders the settings page and breaks ties).

## Built (this branch)

- `HENeed.comfort`: satisfier -> morale gained when it supplies the whole need, scaled by the share it supplies. Food's comfort is meat (`HENeeds.FOOD_MEAT_MORALE`, 0.08). Generic, so charcoal for heat or leather/cloth for clothing are one-line additions.
- **Affluence** (`HESimulation._household_affluence`): 0..1 from the household's balance in days of a basic basket priced at `BASE_PRICE` (so it does not swing with the market), smoothstep from `AFFLUENCE_MIN_DAYS` 60 to `AFFLUENCE_FULL_DAYS` 240.
- **Preference** (`_household_favourite`): comfort satisfiers are judged `AFFLUENCE_PRICE_TOLERANCE` (0.75) cheaper at full affluence, on top of the existing taste. Poor households are unchanged.
- **Clearing order**: households clear comfort goods first (`_satisfier_cascade(..., comfort_first)`), so a household that prefers meat asks for it first and falls back to grain for what it could not get. Business cascades are unchanged.
- **Morale**: `HEHousehold.morale_bonuses` adds the comfort bonus ("Food: Meat"). Morale above 100% already raises output (cap 125%), so a better table pays back.
- `check_household_spending.gd`: at posted prices (grain 0.25, meat 1.6), 17 of 18 affluent households favour meat and 0 of 27 near-subsistence ones do; the bonus scales with meat share. `measure_stratification.gd`: the gate (Gini, quintiles, meat share).

Effect today: none in the full sim, by design of the problem above. The demand side works; meat is not on the shelf.

## The next piece is supply

1. **Let demand reach the producers.** A comfort good nobody can currently buy is left out of the household cascade, so unmet preference never shows up as `unmet_demand` for the Butcher or the ranches. Record a preferred-but-unavailable comfort request as unmet scarcity.
2. **Butcher and ranch staffing from demand.** The Butcher grows only when it has measured output; the herd model decides ranch size. Both need a path from sustained local meat demand to more herd and more crew.
3. **Keep export profit-driven.** Sellers already offer only stock above their forecast of local use, and the Trader ranks offers by margin per unit of capacity. If meat export is ever switched on, the sellers' local-use forecast (`_known_daily_local_use`) must include comfort demand, or exports will drain the shelf affluent households want.
4. **Seasonal fallback.** Meat (and stored grain) as the answer to the lean-season grain spike is a separate, larger supply problem; do not design around it yet.

Gate for each step: `measure_stratification.gd` (meat share rising with income quintile), solvency held, employment held, ranches not collapsing, meat price stable.

## Thoughts: a morale-optimising household

A literal optimiser (each household maximises morale subject to a budget) is the wrong first move: it is expensive per household per day, and a hard maximum makes everyone jump to the same bundle the day prices cross, which the existing taste spread was added to avoid. Keep the shape, make the inputs richer:

- **Utility per cost, not a hard switch.** Each satisfier has a comfort value; a household weighs `comfort x marginal value of comfort` against `price premium x marginal value of money`. The marginal value of money falls with savings, which is what affluence already approximates. This is the current rule, so it can grow into a proper curve (diminishing returns per need, a savings target) without new machinery.
- **A stored standard of living.** A household that has been eating meat does not drop to grain on the first dear day: a slow-moving "accustomed tier" (a state with hysteresis) smooths consumption, gives persistent stratification, and makes a fall in income visible as a morale cost. This is the likeliest next addition.
- **Income, not just savings.** Affluence is balance-based. A high earner with little saved, or a retiree with a large nest egg, behave differently. A permanent-income blend (balance plus a multiple of recent income) is the natural refinement once the above works.
- **Budget the choice between goods.** Heat, clothing and food comfort compete for the same discretionary money. Per-need affluence thresholds (food first, then heat, then clothing) are enough to order them without a solver.
- **Morale as the goal, productivity as the payoff.** Morale already feeds output, so every comfort good is a real productivity lever, not just a number. That, not utility theory, is what makes the loop worth having: spending lifts output, output funds wages.

Later, the same decision frame covers whether a parent takes a job: a household compares the wage against the comfort tier it wants to sustain and the child care it values (`docs/household-wage-model-plan.md`, "Remaining").

## Risks

- Meat is lumpy (herd cycles) and ranches already run negative in these runs; a demand shock could sink them before supply responds.
- Price volatility is still high (grain 0.25-4.0), so comfort preference can flip with the season.
- A more even-handed preference could reduce grain demand and so farm hiring (the farm is already demand-limited; see the small-village unemployment note).
