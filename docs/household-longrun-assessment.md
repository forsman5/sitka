# Household economy: 20-year assessment of the three presets

Assessment of `origin/master` at 1820d9a (PR #113, water). No sim code changed. Reproduce with
`scripts/sim/harness/run_longrun_assessment.gd` (yearly table), `probe_longrun.gd` (monthly),
`probe_treasury.gd`, and `run_governor_assessment.gd` (prototype governor, harness-side only).
Year = 360 days. Seed 12345 unless noted; seeds 1-6 for the spread.

## Verdict: no preset thrives; none reaches a stable equilibrium in 20 years

| Preset | Start pop | Typical y5 | Typical y10 | Typical y20 | Extinct runs |
|---|---|---|---|---|---|
| Small village (24 houses) | 80 | 56-71 | 35-57 | 21-50 | 0 of 7 |
| Mining village (36 houses) | 120 | 57-75 | 41-62 | 28-56 | 1 of 7 (seed 5, gone by y15) |
| Large village (56 houses) | 192 | 69-99 | 60-105 | 61-82 | 1 of 7 (seed 12345, gone by y8) |

(7 seeds: 12345 and 1-6; y20 range excludes the extinct runs.) Every preset loses 25-50% of its
people in the first 3-5 years, then wanders with boom/bust swings instead of settling. The large
village is the fragile one: it starts at the food ceiling (below).

## Why: four limiters, in the order they bite

1. **Housing is counted in households, and every coming-of-age splits one off.**
   A 20-year-old founds a new 1-person household that needs its own house. Presets ship with only
   1.2 houses per household, so within a year 10-22 households are homeless and each loses a member
   with 30% chance per month (`HOMELESS_EMIGRATION_CHANCE`). Nothing ever builds a house, so
   population settles at roughly *houses x 1.5-2 people*, about half the starting 4 per household.
2. **Grain cobweb.** Starting stock plus a full crew floods the market, grain falls to its 0.25
   floor, the farm self-tunes down to 10-14 of 50 workers, the 90-day crop lag then leaves a
   shortage, price jumps to the 4.0 cap and food stress hits 0.9+ (health 0.1-0.25 for a year).
   Repeats every 2-5 years. At the floor price the tax base is also tiny (small village: about
   0.5 gold/day against a 270 gold start; treasury is 0 from year 2 and stays there).
3. **Land is a hard ceiling.** Farm = 320 acres, max 50 workers, 1.6 grain/worker/day, so
   80 grain/day at best = **~200 people** at 0.4 grain/person/day (a little more with meat).
   Woodlot is 400 acres / 50 workers. The farm is unique per town (`has_business_of_type`,
   TODO(multiple-buildings)). The large preset starts at 192 people, i.e. at the ceiling with no
   margin for the winter harvest (grain seasonal modifier 0.1).
4. **Water upkeep is finite stone.** Each well needs 4 timber + 4 stone a year from the warehouse,
   and nothing restocks stone. Small village has no quarry: 100 stone runs out around year 13,
   water coverage drops to 0, health/morale fall to about 0.75/0.55. Mining village has a quarry
   but no standing stone order, so it fails around year 17.

## Phase 2: prototype housing/water governor (harness-side policy, one seed, so indicative only)

Weekly: build a house if no free slot; build a well if capacity < 1.15 x population; keep standing
warehouse buy orders for stone and timber. Uses only existing API (`request_government_build`,
`set_warehouse_order`).

| Run (seed 12345) | No governor y20 | Governor y10 | Governor y15-20 |
|---|---|---|---|
| Small | 21 | 52 (but 0 gold: built 3-4 houses then broke) | 48-53, water still dies y10 (no stone) |
| Mining | 52 | 158 | 297-356, 222 houses, 15 wells |
| Large | 0 (extinct y8) | 222 | 258 (y15) |

- Housing governor works where the treasury has gold (mining, large). It removes limiter 1.
- It does **not** fix food: with 300+ people the farm is 37-45/50, grain is at 1.98-4.0, food stress
  costs -0.6 health, and 56-106 workers are unemployed because farm and woodlot are maxed.
  That is limiter 3 showing: the town outgrows its land, then famine-cycles instead of equilibrating.
- Treasury piles up unused (40k gold by y20 in mining): no gold sink, builds are timber-limited.
- Small village cannot be rescued by a governor alone: the treasury is empty, and stone is finite.

## Recommended order of work

1. **Granary (phase 2.5).** Governor sets warehouse GRAIN orders: buy near the floor, sell near the
   cap. Dampens the cobweb with existing mechanics, and gives the treasury a purpose.
2. **Governor v1.** Housing + wells + stone/timber standing orders as above; it needs a gold
   reserve rule (never spend below N days of wages) and should lower sales tax when the treasury
   is rich (up to +10 morale points per 3 points).
3. **Raise the land ceiling (phase 3).** Make Farm/Woodlot repeatable or expandable (clear woodlot
   into fields), so a governor can grow to a land budget. Also let the government build a Quarry
   (`government_business_costs` only lists farm and woodlot) so water upkeep is self-sustaining.
4. **Later buildings:** tenements/stone houses (lots cap around 100 houses), a granary building,
   trader grain imports, tool/charcoal capacity, driven by the same need-vs-capacity checks.
5. **Preset retune (independent of governor):** ship enough houses (about 1.5 per household) and a
   quarry or stone stock for small village, and start the large preset below the food ceiling
   (about 160 people), or its start state is non-viable by construction.
