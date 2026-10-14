# Household economy employment lookup plan

## Outcome and scope

Replace repeated household scans with simulation-owned employment indexes. Preserve the daily economic rules, deterministic hiring and layoff order, wages, lifecycle behavior, and public report shapes.

Target current master (91ec8c4). PR #19's separate HESimulation per town is the intended world architecture: each instance owns its indexes; ValleyEconomy coordinates towns and shipments. This plan also supports multiple settlements inside one HESimulation. No runtime changes are included in this documentation PR.

## Current cost

In scripts/sim/household_economy/he_simulation.gd:
- _business_employed_worker_count and _business_employed_household_count scan every household.
- _pay_wages counts employees, then scans households again for each business to distribute wages.
- _reconcile_employment collects employees by another full scan per business.
- Production, purchasing, capacity decisions, and get_business_reports call the counting helpers.
- _ensure_administrator, _ensure_warehouse_staff, and get_government_summary also discover employees or candidates through scans.

For H households and B businesses, these paths contain O(B * H) work. Separate towns in #19 confine that cost to each town but do not eliminate it. This is a source-based finding, not measured profiler evidence.

## Recommended design

Begin with a lazily rebuilt index and explicit invalidation. Avoid immediately implementing incremental counters at every demographic mutation: a missed worker-count change would silently affect wages and solvency.

Authoritative state remains each household's employer_business_id and demographics. Derived private indexes:
- business ID -> ordered employee household IDs;
- business ID -> employed worker total;
- business ID -> employed household total;
- settlement ID -> unemployed household IDs, where a later query may filter positive worker capacity;
- optionally settlement workforce/population totals in a subsequent measured change.

Rebuild all employment indexes in one household pass after invalidation. Populate employee lists in the existing household iteration order so wage accumulation does not change floating-point results. For hiring and layoffs, explicitly retain the current sorted-ID ordering. Counts are O(1) after rebuilding; wage distribution visits actual employees.

Use a single mutation helper for employer assignment that marks indexes dirty. Mark dirty when worker capacity or household membership changes. Queries ensure freshness before reading. Do not eagerly rebuild inside each mutation; batch changes where the current algorithms already process a group.

## Correctness and mutation audit

Cover these paths before switching any production consumer:
- initialization and seeded assignments, including invalid employer cleanup;
- add_new_business and initialization employment reconciliation;
- hiring and layoffs in _reconcile_employment;
- _ensure_administrator and _ensure_warehouse_staff, including stealing a household from another employer;
- _fail_business: release employees before removing its record;
- emigration, including homelessness-driven member removal;
- old-age deaths, loss of the last worker, orphan adoption, and household deletion;
- aging/promotions, split-off households, and additions/removals from settlement membership;
- future migration and save/load restoration.

Worker totals must reflect current demographics, not the number of employed households. Preserve the existing semantics for zero-worker employed households until the authoritative code changes their employer.

Inspect acceptance harnesses for direct record mutation. Internal indexes cannot observe arbitrary writes to public dictionaries. Convert relevant harness mutations to supported helpers or explicitly invalidate after fixture edits; document this requirement. UI callers must continue to use commands/query methods.

A snapshot built only at the start of a day is insufficient: failures and lifecycle changes occur within a tick, and later phases and reports must see the updated state.

## Implementation sequence

1. Add a headless employment benchmark and phase timing before changing behavior. Exercise H and B independently and compare one multi-settlement instance with #19-style separate town instances. Keep scenarios economically viable and report final population/business counts.
2. Introduce private indexes, dirty-state handling, and an independent debug scan oracle. Initially keep existing production scan helpers while comparing results at initialization and after mutation boundaries.
3. Switch worker/household count helpers and _pay_wages to indexed membership. Preserve pay order, current wage timing, and deletion behavior.
4. Switch reconciliation and government membership/candidate discovery. Reuse sorted candidate pools within a reconciliation pass; update local working counts during assignment instead of causing a rebuild after each hire.
5. Inspect remaining call sites and benchmark rebuild counts. If index rebuilds multiply with businesses during reconciliation, repair batching before declaring the change complete.
6. Only if measurements justify it, replace lazy rebuilds with incremental maintenance behind the same interface. Keep the scan oracle for debug validation.

The target is a bounded number of O(H) rebuilds per tick plus O(H) total wage distribution, rather than O(B * H) employee discovery. Deterministic sorting on reconciliation days remains legitimate work. Do not claim every simulation phase becomes linear.

## Validation and acceptance

Run the existing run_household_economy.gd acceptance harness. Add focused checks for:
- counts and member IDs matching the independent scan oracle after every audited mutation;
- worker death/emigration changing totals without changing employer membership;
- multiple hires, layoffs, and business failures in one day;
- administrator/warehouse reassignment updating both old and new employer totals;
- household creation/deletion and same numeric business IDs in separate town instances;
- multiple settlements never sharing labor;
- cached reads followed by mutations and immediate report queries.

Capture deterministic baseline fixtures before implementation: household summaries, business reports, employment event order, daily wages, stock/money reconciliation, and RNG-dependent outcomes across ordinary and lifecycle days. Compare against those fixtures after the change; two identical optimized runs alone do not prove compatibility with the old implementation.

Benchmark warmed runs and runs beyond the 730-day history boundary. Record simulation-only time, employment phase time, index rebuild count, peak memory, and p50/p95 tick time. Measure dashboard refresh separately. Use structural acceptance (no business-by-global-household discovery loops in migrated paths) and measured results; do not invent a speedup threshold before collecting a baseline.

If #19 is integrated first, also run its valley economy and embedded-detail checks. Its PR body reports earlier household acceptance failures, so distinguish pre-existing failures from regressions using a same-revision baseline.

## Medium-term boundary

Indexes remain owned by HESimulation and contain stable IDs rather than scene nodes. A future Rust core can preserve the same employment API with typed vectors/maps. Independent towns provide a potential parallel execution boundary, but this change introduces no threading.

Reference-wage caching is a separate follow-up: wages depend on demographics, served needs, seller availability, and price history, so an employment cache alone cannot establish freshness. Likewise dashboard scheduling, history storage, supplier indexes, and Rust extraction are outside this plan.

## Implementation status

Stages 2-4 are implemented in this PR as a membership-only index (business ID -> ordered employee household IDs), lazily rebuilt in one household pass:
- Invalidation: `HEHousehold.employer_business_id` has a setter that notifies the owning `HESimulation`, so direct harness/fixture writes are observed; household add/remove and world load also invalidate.
- Worker totals are summed from member households' current `worker_capacity()` at query time rather than cached, so aging, death, and emigration cannot leave them stale.
- Migrated: worker/household counts, `_pay_wages` distribution, `_fail_business`, `_reconcile_employment` (layoff pass and per-settlement hiring each take one index snapshot instead of rebuilding per hire), and `get_government_summary`.
- Oracle: `HESimulation.employment_index_matches_scan()` is checked daily for 400 days in two scenarios, plus after a direct employer write, in `run_household_economy.gd`.
- Compatibility: city/business/household/event-log fingerprints over 800 days match master for the three-business, toolsmith, and lopsided scenarios.

Not done: benchmark harness and phase timings (stage 1), incremental maintenance (stage 6).
