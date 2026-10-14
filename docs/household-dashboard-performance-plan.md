# Household dashboard performance plan

## Outcome and scope

Keep the household economy responsive as towns grow past roughly 100
households and as simulation speed increases. This plan separates four related
UI concerns:

1. virtualize the household table so its control count is bounded;
2. expose a lightweight table snapshot instead of building full household
   detail summaries for every row;
3. refresh only visible dashboard sections and selected detail panels;
4. throttle presentation refreshes by wall-clock time, independently of the
   number of simulation days advanced.

This is a dashboard/query-boundary change. It does not alter economic rules,
tick order, deterministic outcomes, or PR #78's employment index. Moving the
simulation onto a worker thread is a compatible follow-up, not a prerequisite.

## Current behavior and suspected cost

`he_dashboard.gd::_refresh()` is a broad synchronous refresh after simulated
days advance. It updates town, housing, government construction, market,
needs, business, jobs, household, event, and detail views regardless of which
tab the player can currently see.

The household table creates a permanent set of Godot `Control` nodes for every
household. Each row includes buttons and labels for identity, employer,
housing, demographics, inventories, balance, and unmet needs. A
`ScrollContainer` clips drawing but does not virtualize those controls. Around
100 households this can mean more than one thousand retained controls taking
part in layout, theme, input, and text updates.

Every household-row refresh also calls `get_household_summary()`. That method
constructs inventory and unmet-demand dictionaries, need arrays and satisfier
arrays, health/morale explanations, demographic age arrays, and detail fields
that the table does not display. The same rich query is appropriate for one
selected household, not for the whole table.

These are source-based suspects until timed. PR #78 measured employment lookup
as less than one percent of a simulated day and found no end-to-end tick gain;
do not attribute interaction latency to either simulation or UI without
separate measurements.

## Measurement first

Add development-only timing counters around:

- `advance_ticks(1)`;
- complete `_refresh()`;
- household table snapshot construction;
- household row binding/text updates;
- control creation/rebuild;
- each top-level and nested-tab refresh group;
- town chart history extraction and series construction.

Test at 30, 100, 300, and 1,000 households while paused, at 1x, and at the
highest available speed. Capture p50/p95/max frame time, refresh time, tick
time, retained `Control` count, and refresh/rebuild counts. Compare the
Households tab with a lightweight tab while paused; this distinguishes UI-tree
cost from simulation cost. Record the visible tab and whether a detail panel
was open for every sample.

Use the measurements to validate ordering, but keep the four changes together:
they establish the presentation boundary needed by a future background runner
or Rust core.

## 1. Virtualize the household table

Replace one permanent row per household with a bounded pool of reusable row
controls. Prefer virtualization over fixed pagination so sorting/filtering and
mouse-wheel browsing still feel like one list.

### Proposed structure

- Keep an ordered array of household table records separate from controls.
- Create enough row controls for the visible viewport plus a small overscan
  buffer (target 25-40 rows under ordinary window sizes).
- Represent total list height with a spacer/content container.
- On scroll, compute the first visible data index and bind the row pool to that
  slice. Reposition or pad the pool so the scrollbar continues to represent
  the full population.
- Store the currently bound household ID on each reusable row. Button callbacks
  read that bound ID rather than capturing an ID when the control was created.
- Preserve selection by stable household ID, not row index. If the selected
  household leaves the current viewport, its detail panel remains open.
- Rebind only rows whose data index or displayed values changed.

If correct variable-height virtualization proves disproportionate, ship
pagination first (for example, 50 households per page) behind the same table
snapshot API. Avoid creating all pages' controls at once.

### Population and ordering changes

Births, deaths, splits, migration, and filters update the data array and total
height; they should not destroy and recreate the row pool. Define a stable
default order matching today's household-ID order. Sorting must use stable IDs
as a deterministic tie-breaker. Clamp the scroll position when the list
shrinks.

### Acceptance criteria

- Retained household row controls remain bounded as population grows.
- At 1,000 households, increasing population does not proportionally increase
  the household table's `Control` count.
- Scrolling never displays stale IDs or sends a click to the household that was
  previously bound to that row.
- Selection, employer links, detail navigation, sorting/filtering, births,
  splits, and removals remain correct.
- Keyboard/controller focus does not jump to a recycled off-screen record.

## 2. Add a lightweight household table snapshot

Add a purpose-built simulation query whose output contains exactly the fields
needed by the table. A suggested shape is:

```gdscript
func get_household_table_snapshot(settlement_id: int = -1) -> Array[Dictionary]
```

Each row should contain stable ID, employer business ID, housing status,
workers, dependents or compact dependent text, displayed commodity stocks,
balance, food stress, unmet scarcity, and unmet unaffordable demand. Do not
include member-level details, health/morale factor explanations, full need
objects, satisfier arrays, or copied histories.

Resolve employer names in the dashboard from its existing business-name map,
or include a compact name only if that materially reduces repeated lookups.
Keep `get_household_summary()` as the detail query for the one selected
household.

Snapshot construction should be one pass over the relevant households. Avoid
calling other rich public report methods from inside it. Returning dictionaries
is acceptable initially; measurements can justify typed records or packed
arrays later. Treat returned data as immutable presentation data.

### Acceptance criteria

- The full table refresh makes no per-row `get_household_summary()` calls.
- The selected household detail still uses the rich summary and shows the same
  information as before.
- Table values match the corresponding fields from rich summaries in a harness
  across ordinary days and lifecycle changes.
- Snapshot generation is measured independently and scales approximately with
  the number of requested households.

## 3. Refresh according to visibility

Retain references to the top-level and nested `TabContainer` instances and
connect `tab_changed`. Split `_refresh()` into small refresh groups with dirty
flags or revision tracking:

- always-visible header: clock, treasury, and extinction state;
- active top-level tab: Town, Housing, Needs, and the tab containing the
  business/household/market lists;
- active nested list tab only;
- selected detail panel only when it is visible;
- Town view only when Town view is visible;
- event/blotter content only when expanded and visible.

When a simulation snapshot arrives, mark affected groups dirty. Refresh the
visible group immediately at the next presentation opportunity. An inactive
group remains dirty and refreshes once when opened. UI actions that change
authoritative state may explicitly invalidate the relevant visible groups.

Do not infer visibility solely from `Control.visible`; ancestor visibility and
active tab state matter. Centralize this policy instead of scattering checks
through every refresh function.

### Acceptance criteria

- An inactive tab's expensive query and row-update counters do not increase as
  days advance.
- Opening an inactive tab shows data from the latest published state on its
  first rendered frame or the next scheduled presentation frame.
- Hidden detail panels do not rebuild controls or request histories.
- Returning from Town view or a detail panel produces a complete current view,
  not a partially stale mixture.

## 4. Throttle UI presentation by wall time

Simulation speed and presentation frequency are separate concepts. Continue to
advance the requested number of deterministic days, but coalesce dashboard
updates and present at a target wall-clock cadence. Begin with 10 Hz and make
the constant easy to tune; 5 Hz is acceptable for dense diagnostic tables,
while Town view animation may continue at frame rate using interpolated visual
time.

Maintain:

- a simulation/day revision that changes after authoritative state advances;
- a last-presented revision;
- a wall-clock accumulator or monotonic deadline;
- dirty flags for visible presentation groups.

At the presentation deadline, query one coherent current snapshot and update
the visible UI. If several days advanced since the last presentation, skip
intermediate UI states rather than queueing refreshes. Pause, direct player
commands, selection changes, and opening a tab/detail may request an immediate
refresh, subject to preventing multiple full refreshes in the same frame.

This throttling does not move simulation work off the main thread. It reduces
query, allocation, control update, and layout work. A later worker runner can
publish immutable snapshots through the same cadence without redesigning the
dashboard.

### Acceptance criteria

- At 100x, dashboard refresh count tracks wall time rather than simulated days.
- The displayed day may jump forward but never moves backward or mixes records
  from different simulation revisions.
- Pause and player commands become visible promptly.
- No unbounded backlog of pending UI refreshes accumulates.
- Town lighting/animation remains smooth even when economic labels update at a
  lower frequency.

## Implementation sequence

1. Add timings and counters without changing behavior; capture a baseline.
2. Add the lightweight table snapshot and parity tests.
3. Split `_refresh()` into named groups, retain tab references, and introduce
   visibility-aware dirty flags.
4. Add wall-clock presentation throttling and verify that skipped presentation
   frames never skip simulation ticks.
5. Virtualize the household rows using the lightweight snapshot. Pagination is
   an acceptable intermediate release if virtualization delays the rest.
6. Re-run the timing matrix and document which costs moved. Test a production
   export as well as editor/headless builds.

The snapshot API may land before virtualization. Do not add a background thread
in the same change: first make the UI consume coherent snapshots and prove that
it no longer assumes synchronous access to live records.

## Validation

Run the existing household economy acceptance harness to prove economic output
is unchanged. Add dashboard-focused checks for:

- lightweight/rich-summary field parity;
- bounded row-pool size at multiple populations and viewport sizes;
- correct row reuse, click targets, selection, and focus after scrolling;
- births, deaths, splits, migration, filtering, and sort-order changes;
- inactive tabs performing no expensive refresh work;
- dirty tabs catching up when selected;
- refresh coalescing at high simulation speed;
- pause/command immediate refresh behavior;
- standalone and externally hosted/embedded dashboards;
- Town view transitions and resized windows.

Report baseline and post-change tick time separately from UI snapshot,
refresh, layout/frame, and interaction measurements. A faster dashboard is not
evidence of a faster simulation, and a faster tick is not evidence of smoother
interaction.

## Follow-up: simulation/UI execution separation

Once the dashboard consumes snapshots rather than live state, introduce a
single-owner simulation runner if profiling still shows tick work causing frame
stalls. Commands cross into the runner at tick boundaries; immutable snapshots
cross back atomically. Godot UI nodes remain on the main thread. Independent
town economies are a natural unit of scheduling, but intertown shipments must
still resolve in deterministic shared-clock order.

That follow-up can retain every API and UI optimization in this plan and can
later host either the GDScript simulation or a Rust core.
