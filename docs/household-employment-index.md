# Household employment index

How `HESimulation` (`scripts/sim/household_economy/he_simulation.gd`) answers "who works for business X?" without scanning every household per business.

## Model

- **Authoritative state** is each household's `employer_business_id` (`-1` = unemployed) and its demographics. Nothing else is a source of truth.
- **Derived index** `_employment_members`: business ID -> `Array[int]` of employee household IDs, in `households` iteration order. Built by `_employment_index()` in one household pass.
- **Membership only.** Worker totals are not cached: `_workers_in(member_ids)` sums each member's current `worker_capacity()` at query time, so aging, deaths, emigration, and orphan adoption can never leave a count stale. Household counts are the member array size.
- **Settlement scoping.** Business IDs are unique per simulation instance, and a household is only ever employed by a business in its own settlement, so one index serves multi-settlement instances without labor leaking between settlements. Separate `HESimulation` instances (one per town) each own their own index.

## Invalidation

The index is lazy: anything that can change membership sets `_employment_dirty`, and the next read rebuilds. Rebuilds replace the dictionary rather than mutating it, so a reference taken earlier remains a valid snapshot.

| Trigger | Mechanism |
|---|---|
| Any employer change (hire, layoff, business failure, administrator/warehouse reassignment, settlement-reassignment cleanup, harness fixture writes) | `HEHousehold.employer_business_id` setter calls `employment_changed`, which the sim installs on each household during rebuild |
| Household removed (emigration, last member gone, orphan adoption) | `_invalidate_employment()` after `households.erase` |
| Household added (split-off) | `_invalidate_employment()` after insertion |
| World load / replacement | `_invalidate_employment()` where `households` is assigned |

Rules for new code:
- Change employers by assigning `employer_business_id`; the setter does the rest. Never edit the index arrays.
- Adding or removing entries in `households` must call `_invalidate_employment()`.
- Changing `worker_capacity()` needs no invalidation; it is read live.
- Do not call an index read inside a loop that mutates employers for the same pool unless you want a rebuild per iteration. Take one snapshot (`var snapshot := _employment_index()`) instead.

## Consumers

- `_business_employed_worker_count`, `_business_employed_household_count`: production, purchasing, capacity decisions, reports.
- `_pay_wages`: distributes wages over the business's actual employees, in the same order as the old scan, so floating-point accumulation is unchanged.
- `_fail_business`: releases employees from the index (copied first, since releasing mutates it).
- `_reconcile_employment`: the layoff pass uses one snapshot (a layoff changes only its own business, and each business is visited once); hiring takes one snapshot per settlement after `_ensure_administrator` / `_ensure_warehouse_staff` and tracks working counts locally while assigning. Layoffs and hires still iterate sorted IDs, so deterministic order is preserved.
- `get_government_summary`: administrator IDs.

`_ensure_administrator` and `_ensure_warehouse_staff` read counts through the index and may steal households from other employers, which dirties it; the hiring snapshot is taken after them.

## Verification

- `HESimulation.employment_index_matches_scan()` compares the index against an independent full scan of `households`. It is a debug oracle, not used on production paths.
- `run_household_economy.gd` -> `_check_employment_index_matches_scan` runs it every day for 400 days in the three-business and lopsided scenarios, and after a direct `employer_business_id` write.
- `_employment_rebuild_count` exposes how often the index rebuilt, for spotting batching regressions.
- Behavior is meant to be identical to the scan implementation: city, business, household, and employment-event output is unchanged for the same seed.

## Performance characteristics

- Counts and wage distribution cost O(employees of that business) after a rebuild; a rebuild is O(households). Per-tick rebuilds are bounded by the number of mutation boundaries, not the number of businesses.
- Measured on the replacement scans only: the all-business count sweep at 1,500 households dropped from about 4.8 ms to 0.8 ms. Employment lookup is under 1% of a simulated day at those sizes, so there was no measurable end-to-end tick gain; other phases dominate. Do not attribute tick latency to employment lookup without profiling.
- Sorting on reconciliation days remains legitimate work and is not removed.

## Boundaries

- Indexes hold stable IDs, not scene nodes, so they port cleanly to a typed-vector core.
- Not covered: reference-wage caching (depends on demographics, served needs, seller availability, and price history, so an employment index cannot establish its freshness), dashboard refresh scheduling (see `household-dashboard-performance-plan.md`), supplier indexes, and threading.
- Incremental maintenance (updating member lists inside the setter instead of a lazy rebuild) is a possible later change behind the same interface; it would need to preserve member order, and the scan oracle should stay as the check.
