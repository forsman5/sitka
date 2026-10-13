# Tools as industrial demand

Follow-up to the Toolsmith (PR #27). Today tools are only a household need, so
the Toolsmith's market is the town's 0.005 tools per person per day (about
0.6-0.9 a day). Production businesses neither use nor buy tools. This plan makes
every production business hold tools that wear out and make its workers more
productive, so the Toolsmith has business-to-business demand and tools matter
to output.

Status: phases 1-3 (model, purchasing, bootstrap) are implemented in this PR
and always on, gated only by a tools seller existing in the town. Phases 4-5
(UI, herds) are not built. There is deliberately no on/off setting: it is
tuned as one addition. See "Tuning" below for the measured numbers.

## Where things stand

- `HENeeds` has a TOOLS need (morale-only, `needs_seller`). Households buy tools
  through the normal cascade; `_need_served()` hides the need in towns without a
  seller.
- The Toolsmith (`make_toolsmith`, id 11) converts 0.07 iron into 0.065 tools per
  worker-day at a 9.0 base price. Over four seeds for two years it survives only
  in a narrow output band (0.06-0.065); 0.07+ oversupplies and goes bankrupt.
  The crew averages 7-8 of 12 workers because the unemployed pool is empty, so
  supply sits just under demand.
- No recipe lists tools as an input. `_run_production` (legacy recipes),
  `_run_field_growth` (Farm, Woodlot), `_run_butchery` and the herd care accrual
  in `_run_production` all take labour at face value.

## Model: wear-out stock that drives a productivity multiplier

Per production business (and herd, see scope):

- `tools_per_worker` - tools it wants on hand per employed worker.
- `tool_wear_per_worker_day` - tools worn out per worker-day.
- `coverage = min(1, tool_stock / (employed * tools_per_worker))`
- `productivity = FLOOR + (1 - FLOOR) * coverage`, `FLOOR` = 0.6.

Why this shape: a pure multiplier creates no demand; a hard input (production
halts without a tool) makes one missed delivery a stoppage and turns the
Toolsmith's survival into everyone's. Wear gives ongoing demand; the floor keeps
a tool-starved business alive and visibly poorer rather than deleted.

Gate: a business only needs tools while a settlement seller of tools exists
(same idea as `HENeed.needs_seller` / `_need_served`). Without a Toolsmith
`productivity` is 1.0 and nothing changes, so every existing scenario and
harness baseline stays identical.

### Where productivity applies

| Business | Applies to | Code |
|---|---|---|
| Legacy recipes (Bloomery, Iron Mine, Charcoal Burner, Toolsmith) | planned output | `_run_production`: `planned = employed * rate * productivity` |
| Farm, Woodlot | labour applied to fields | `_run_field_growth`: effective workers = employed * productivity |
| Butcher | worker-days available | `_run_butchery` |
| Herds | husbandry care | `care_worker_days += employed * productivity` |
| Trader, Government | not applied | no production |

### Starting parameters (proposal)

| Business | tools per worker | wear per worker-day | rationale |
|---|---|---|---|
| Farm | 1 | 1/300 | hoes and sickles, heavy use |
| Woodlot | 1 | 1/200 | axes dull fastest |
| Iron Mine | 1 | 1/150 | picks, hardest on tools |
| Bloomery | 1 | 1/400 | tongs and hammers |
| Charcoal Burner | 1 | 1/300 | |
| Butcher | 1 | 1/250 | blades |
| Toolsmith | 1 | 1/400 | uses its own; bootstrap risk, see below |
| Cattle Ranch, Sheep Farm | 0.5 | 1/400 | optional, phase 5 |

At about 60 working households' workers this is roughly 0.2-0.3 tools a day of
industrial demand, i.e. 30-40% on top of household demand. That is the intended
size: enough to matter, not enough to dominate.

## Implementation phases

1. **Data and model.** *(implemented in this PR)*
   - `HEBusiness`: `tools_per_worker`, `tool_wear_per_worker_day`, derived
     `tool_coverage()` and `productivity()`; per-kind values set in the
     `make_*` factories in `he_scenario_seeds.gd`.
   - `HESimulation`: `_tools_in_play(settlement_id)` gate; apply productivity at
     the four production sites above; wear each day in `_run_production`.
   - Wear is booked as consumed tools (`record["consumed"]`, `FLOW_CONSUMED`) and
     charged into `b.last_revenue` at the market price, exactly like a consumed
     input, so capacity tuning sees the cost when the tool is used.
2. **Purchasing.** New `_run_tool_purchasing` right after
   `_run_input_purchasing`. Target stock is
   `employed * tools_per_worker * TOOL_BUFFER_DAYS-ish`; reuse
   `_business_offer` / `_b2b_offer` so the buyer shares the Toolsmith's paced
   offer with households pro rata (no household reserve, like timber). No Trader
   import fallback: no local seller means no tools economy. Tool purchases never
   enter `last_input_fulfillment_ratio` (a missing tool lowers productivity, it
   does not zero production). Sales tax and money flow reuse the existing
   business-to-business path.
3. **Bootstrap.** Seeds give each business an initial stock of
   `workers * tools_per_worker` (like `STARTING_STOCK_HEADROOM` for fields) so
   month one is not on the floor. `startup_cash` gains a tools term
   (`startup_input_cash` analogue) so player-created businesses can afford their
   first tool buffer. Businesses created mid-run when no Toolsmith exists get
   productivity 1.0 and need nothing.
4. **UI.**
   - Business detail: tool stock, coverage, productivity, wear per day.
   - Tools market detail: split demand into household and industrial.
   - Business flow history already includes consumed/bought; confirm tools show.
   - Needs tab is unaffected (businesses have no need entries).
5. **Optional: herds.** Apply to care accrual once the rest is calibrated; herd
   husbandry is already a delicate model (see `HERD_LABOR_PER_HEAD_PER_DAY`).

## Tuning (measured, phases 1-3 as built)

Probe: `build_economy_with_toolsmith`, 720 days, seeds 4242/1/2/3, toolsmith
output rate swept with industrial demand in the books (iron 0.07 per tool,
tools 9.0 base, wear rates as in the table above).

| Toolsmith output / worker-day | Result |
|---|---|
| 0.065 (the household-only setting) | tools short: price averages 31 (ceiling 36), wages inflate, the Trader dies ~day 330 and the Toolsmith ~day 640 |
| 0.08 | both survive, productivity 0.99, price avg 13, wage 0.79 |
| **0.09** | **both survive in all four seeds, productivity 0.99, price avg 11, wage ~0.79 (the middle of the band)** |
| 0.10 | both survive, price avg 9-10 |
| 0.11 and up | oversupply: price to its floor, Toolsmith bankrupt |

Halving wear changed little at 0.065-0.08 and made 0.10 fragile, so the wear
table stands. There is no on/off setting: the model is always on, gated by a
tools seller existing in the town.

## Calibration and verification

- Re-run the Toolsmith survival sweep used for PR #27: seeds 4242, 1, 2, 3, 720
  days, report Toolsmith gone-day, tool price min/avg/max, average reference
  wage, average Toolsmith crew. Add the second dimension: average productivity
  of each business.
- Targets: Toolsmith survives all four seeds; no business is deleted because of
  tool starvation alone; average productivity above ~0.85; tool price average
  within about 1.5x of base; reference wage no more than ~10% above the no-tools
  baseline.
- Expect to widen the Toolsmith output band or crew cap: industrial demand
  raises the required crew from about 10 to about 14, and the unemployed pool is
  the binding limit.

Harness additions (`run_household_economy.gd`):

- Without a Toolsmith: productivity is exactly 1.0 and production flows equal
  the pre-change numbers.
- With a Toolsmith: goods and money reconcile daily with wear and purchases.
- A business with zero tools produces at `FLOOR` of its rate and is not deleted
  by that alone.
- Wear matches `employed * wear_per_worker_day` within epsilon.
- Industrial share of tools demand lands in the 25-45% band at steady state.

## Risks

- **Toolsmith as single point of failure.** If it is deleted every business
  drops to the floor. The floor bounds the damage; the survival fix (Trader and
  staple-price volatility, see the Bloomery/Iron Mine diagnosis) matters more now.
- **Wage creep.** Tools price feeds the reference wage via the household need;
  industrial demand can push the price up. Consider smoothing the price history
  used for the basket.
- **Bootstrap deadlock.** Toolsmith needs tools to produce tools. Seed its stock
  and never gate it below the floor.
- **Control-loop noise.** Productivity changes revenue per worker, which the
  capacity tuner reads; expect a transient until stocks settle.

## Decisions (confirmed)

1. Hybrid wear-out stock plus floored multiplier (not a hard input).
2. `FLOOR` = 0.6.
3. In scope: Farm, Woodlot, Iron Mine, Bloomery, Charcoal Burner, Butcher;
   herds deferred to phase 5; Trader and Government excluded. The Toolsmith is
   excluded for now (see TODOs).
4. No Trader import fallback for tools in this step (see TODOs).
5. Business tool need is independent of household tier; when tiers exist,
   poor households may skip tools, businesses still need them.

## TODOs (deliberately out of scope here)

- **Trader import fallback for tools.** Ore has one (the Trader imports what no
  local business sells). Decide whether tools should too, so a town with no
  Toolsmith can still equip its businesses from outside. It would mean a tools
  economy without a local seller, which the `_tools_in_play` gate currently
  rules out by design, so it needs its own look at pricing, money leaving the
  system, and Trader capacity.
- **Toolsmith's own tools.** Its tools in stock are also its product, so
  "tools in use" and "tools for sale" are the same inventory. Either hold tools
  in use as a separate per-business count (included in the stock snapshot) or
  keep it excluded. Phase 1 excludes it.

## Out of scope

External towns buying tools (exports stay disabled by default), tool quality
tiers, tool repair, and household-owned production.
