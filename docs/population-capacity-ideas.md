# Population capacity and stickiness: four ideas for review

Status: proposal, nothing implemented. Each idea stands alone; pick, reorder or reject independently.

## What the sim does today

A 3,600-day trace of the default three-business economy (seed 4242, sampled every 180 days):

| Measure | Observed |
|---|---|
| Population | 150 at day 180, then 160-200 for the next ten years |
| Households | 60 to 127, swinging much more than population |
| Births / emigrations | ~660 / ~500 over ten years |
| Job ceiling vs staffed | 129 vs ~100 |

- **Households are a noisy proxy.** Each coming-of-age splits off a one-person household, and emigration dissolves empty ones. Households can swing 90 to 127 while population moves about 10%. Population (or headcount) is the better thing to stabilise and to chart.
- **Population presses against a ceiling and bleeds off it.** Births keep arriving at full rate, the town overshoots what it can feed, food-unmet households climb (up to 42 of ~109), and emigration removes people steadily, roughly one every 7 days. This is a bang-bang controller with a long delay.
- **The ceiling is probably food, not jobs.** Staffed jobs sit about 30 below the 129 ceiling. Population x 0.4 grain/day matches a near-fully staffed farm at 1.6 grain/worker/day. This is inferred, not measured; Idea 1 would measure it.
- **Why the delay causes overshoot.** A birth only counts as population pressure 360 days later, when the child comes of age. Births are gated on a household's own food record (95% fulfilment, low stress for 180 days), not on whether the town has room. Everything is monthly and on 360-day timers, so cohorts move in lockstep.

## Idea 1: Derive a population capacity (the measuring stick)

Add `get_population_capacity()` to the sim and chart it against population on the Town tab. Capacity is the lowest of several ceilings, each one a daily flow divided by per-person need:

- **Food:** (grain + meat the town can produce or import per day) / per-person food need. Production comes from a trailing 180-day average of actual output, plus a "full staffing" figure from `max_capacity`. The gap between them is *unused headroom*.
- **Jobs:** sum of business `max_capacity` x people supported per working household.
- **Heat and clothing:** the same formula once they matter. Both are weak today.

Smooth with a 180-day window so a single harvest doesn't move it. Report which ceiling binds ("food-limited").

*What grows capacity:* acreage per farm, more fields, new businesses (a second farm is the biggest lever, since the Farm is the binding constraint), meat as a second food source, and trade imports.

- **Pros:** answers "what population can we support?" directly. Lets you estimate capacity from buildings, as you wanted. Needed by Ideas 2 and 4.
- **Cons:** a derived number can disagree with what happens; tracking that gap is part of the value.
- **Effort:** small. Mostly reads of existing state.

## Idea 2: Gate births on headroom, not just household prosperity

Replace the hard birth gates with a density-dependent rate:

`birth_chance = base_rate x clamp(1 - (population + pending dependents) / capacity, 0, 1)`

- Count children in the pipeline as population, so the 360-day delay no longer hides pressure.
- Keep the prosperity gate as a floor; headroom is an extra multiplier.
- Near capacity, births taper smoothly; at capacity they stop. The town then stabilises just under the ceiling instead of overshooting and shedding.
- **Tunable:** `base_rate`, and a `headroom_exponent` (1 = linear taper; above 1 = births stay near full until close to the ceiling).
- **Pros:** attacks the cause (overshoot), not the symptom. Gives you a population that is stable *because* births respond to room.
- **Cons:** needs Idea 1. A wrong capacity estimate pins population to a wrong number.
- **Effort:** small, once Idea 1 exists.

## Idea 3: Break the lockstep (jitter and smoothing)

The 360-day aging, 360-day birth cooldown, 180-day eligibility and monthly evaluation all line up, which produces cohort waves.

- Give each household a randomised birth cooldown (e.g. 360 +/- 25%) and make the monthly birth a chance, not a certainty, once eligible.
- Stagger coming-of-age by individual age (already per-person) but stop splitting several members off in the same evaluation.
- Evaluate births per household on its own offset day instead of one monthly sweep.
- Seed the RNG per household so runs stay deterministic.
- **Pros:** low risk, independent of Idea 1, reduces echo and oscillation.
- **Cons:** treats the symptom; without Idea 2 the average still overshoots.
- **Effort:** small.

## Idea 4: Make leaving and arriving sticky (friction both ways)

Today a household emigrates once it has been severely short for 60 consecutive days *and* stress is at least 0.9. That is a cliff.

- **Hazard instead of threshold:** monthly leave chance rises with stress (e.g. 0 below 0.5, 0.15 at 0.9), so exits are gradual.
- **Attachment:** reduce the chance for employed households, long-tenured households, and those holding savings or stock. Newly split-off households with nothing to lose leave first.
- **Grace after a bad month:** a stress decay or "settling" window so one rough harvest does not start the clock.
- **Optional inflow:** if capacity headroom is above X% and wages beat the reference wage, a small trickle of new households arrives. This closes the loop so population tracks capacity from below as well as above, with the same friction factors on arrival.
- **Pros:** softens the downswing, makes losses feel like a town, not a spreadsheet. Pairs with the health and morale work you plan next (morale becomes an input to attachment).
- **Cons:** more tuning knobs. Inflow changes the economy's character and may deserve its own decision.
- **Effort:** medium. Emigration part is small; inflow is larger.

## Suggested order

1. **Idea 1** first. It's cheap and tells us if the food guess is right.
2. **Idea 2** next; it does most of the stabilising.
3. **Idea 3** as cleanup if cohort waves remain visible.
4. **Idea 4** with the health and morale work.

**How to judge success:** rerun the 3,600-day trace and compare population range (today ~160-200, roughly +/-10% of the mean) and emigrations per year (today ~50). Target is a population range under +/-5% and emigrations near zero in steady state.

## Scale direction (note, not a proposal)

You mentioned scaling both down (many small valley towns) and up. Capacity-as-a-formula (Idea 1) helps here: a 50-person town is just a smaller farm and fewer fields, so each valley town can compute its own ceiling from its own businesses instead of sharing tuned constants. Worth keeping in mind so the per-person constants live in data, not in code.
