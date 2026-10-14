# Household dashboard presentation and performance

Keeps the household economy dashboard (`scripts/sim/household_economy/he_dashboard.gd`) responsive as towns grow past roughly 100 households and as simulation speed rises. This is a presentation/query-boundary effort: it does not change economic rules, tick order, deterministic outcomes, or the employment index (`household-employment-index.md`). Moving the simulation to a worker thread is a compatible follow-up, not a prerequisite.

The doc has two parts: what exists now (the structure the work builds on), and what remains.

## Current structure

### Refresh groups
`_refresh()` is an immediate, full refresh that calls named groups in a fixed order:

| Group (`HEPresenter.Group`) | Function | Contents |
|---|---|---|
| `HEADER` | `_refresh_header` | day label, treasury, population summary, extinction check |
| `TOWN` | `_refresh_town_and_housing` | town stats/charts, housing tab, government build menu |
| `MARKET_NEEDS` | `_refresh_market_and_needs` | market grid and detail, needs tab and detail |
| `BUSINESSES` | `_refresh_businesses` | business rows, town map sync, jobs tab, open business detail (all four tabs) |
| `HOUSEHOLDS` | `_refresh_households` | household table |
| `DETAILS` | household and person detail | open household/person detail panels |
| `BLOTTER` | `_refresh_blotter` | event log |

Detail panels are rebuilt from scratch, so they are skipped while a mouse button is down (a swapped-out button would eat the click); the next refresh catches up. All groups currently refresh every time.

### Household table (`he_household_table.gd`, `HEHouseholdTable`)
A pure view of the Households tab. It receives presentation rows through `set_snapshot(rows, business_names)` and reports clicks through `row_selected(household_id)` and `employer_pressed(business_id)`. It owns its row controls and rebuilds them only when the set of household IDs changes. It never reads the simulation. Row shape is documented at the top of the file.

The dashboard builds the rows in `_household_table_rows()` from the rich `get_household_summary()` per household. That is the seam where the lightweight simulation snapshot (below) goes.

### Presenter (`he_presenter.gd`, `HEPresenter`)
Pure bookkeeping for when and what to present; no nodes and no simulation access.

- `note_simulated(days)` raises `revision` and dirties every group.
- `due(delta)` is true when a revision is unpresented and at least `interval_seconds` of wall time has passed, or when `request_immediate()` was called. Skipped revisions are coalesced, never queued.
- `take_dirty()` consumes the dirty groups and records `presented_revision`.
- `request_immediate()` is for pause, player commands, and selection changes. `_refresh()` always calls it, so explicit refreshes are full.

The dashboard's `PRESENT_INTERVAL_SECONDS` is `0.0`, which presents on every simulated step. Raising it is the wall-clock throttle.

### Business detail page
The open business's detail page has identity facts above a four-tab bar (Cash, Stocks, Productivity, Events). Tabs are built once so the selected tab and in-progress spin-box edits survive refreshes. `_refresh_business_detail()` currently fetches full-detail reports, builds the rows for all four tabs, and clears and recreates all four grids on every refresh, whichever tab is open. Detail work is therefore not yet proportional to what is visible; see section 3.

### Checks
`scripts/sim/harness/check_household_dashboard.gd` covers presenter cadence/coalescing/immediate requests, table row count, snapshot parity with rich summaries, no rebuild for an unchanged household set, and click routing. `check_town_view.gd` and `check_town_layout.gd` cover the dashboard scene around it.

## Suspected cost (until timed)

- The household table creates a permanent set of `Control` nodes per household (buttons and labels for identity, employer, housing, demographics, stocks, balance, unmet needs). A `ScrollContainer` clips drawing but does not virtualize them; around 100 households this is more than a thousand retained controls in layout, theme, input, and text updates.
- Every row refresh calls `get_household_summary()`, which builds inventory and unmet-demand dictionaries, need and satisfier arrays, health/morale explanations, and demographic age arrays the table never shows. That query is right for one selected household, not the whole table.
- `_refresh()` updates every view regardless of which tab is visible, and the business detail page does the same for its four tabs: it fetches full-detail reports (balance/ledger histories, herd events) via `get_business_reports()`, scans for the selected business, rebuilds all four grids with `queue_free`, redraws the cash sparkline and goods flow chart, and refreshes the employee list and event logs, even though only one tab shows.
- The employment index measured employment lookup at under 1% of a simulated day with no end-to-end tick gain, so do not attribute interaction latency to the simulation or to the UI without separate measurements.

## Remaining work

### 1. Measurement first
Development-only timing counters around: `advance_ticks(1)`; complete `_refresh()`; household table snapshot construction; row binding/text updates; control creation/rebuild; each refresh group; town chart history extraction.

Test at 30, 100, 300, and 1,000 households while paused, at 1x, and at the highest speed. Capture p50/p95/max frame time, refresh time, tick time, retained `Control` count, and refresh/rebuild counts. Compare the Households tab against a lightweight tab while paused to separate UI-tree cost from simulation cost. Record the visible tab and whether a detail panel was open.

### 2. Lightweight household table snapshot
Add a purpose-built simulation query:

```gdscript
func get_household_table_snapshot(settlement_id: int = -1) -> Array[Dictionary]
```

Each row carries only what the table shows (the shape `HEHouseholdTable` already consumes): stable ID, employer business ID, housing status, workers, dependents, displayed commodity stocks, balance, food stress, unmet scarcity, unmet unaffordable demand. No member-level details, explanations, full need objects, satisfier arrays, or copied histories. One pass over the relevant households, without calling other rich report methods. Employer names are resolved in the dashboard from its business-name map. `get_household_summary()` stays the detail query for the one selected household.

Then `_household_table_rows()` becomes a call to the snapshot.

Acceptance: the table refresh makes no per-row `get_household_summary()` calls; table values match the rich-summary fields in a harness across ordinary and lifecycle days; snapshot generation is measured independently and scales with the requested households.

### 3. Visibility-aware refresh
Retain the top-level and nested `TabContainer` references and connect `tab_changed`. Narrow which groups `_refresh()` takes from the presenter to those whose views are actually visible; an inactive group stays dirty and refreshes once when opened. Candidates: active top-level tab, active nested list tab, selected detail panel only when visible, Town view only when visible, blotter only when expanded.

Do not infer visibility from `Control.visible` alone; ancestor visibility and active tab state matter. Keep the policy in one place (the presenter or a single dashboard function), not scattered through refresh functions.

#### Business detail tabs
Apply the same policy one level down, to the page's Cash / Stocks / Productivity / Events tabs:

- Build rows, charts, and lists only for the selected tab (`_business_detail_tabs.current_tab`). Cash owns the balance sparkline, cash/ledger rows, and the government tax section; Stocks owns the goods flow chart, inventory rows, wool rows, and warehouse orders; Productivity owns morale/tool/land/husbandry rows, field rows, and the employee list; Events owns the employment blotter, herd events, and Trader transactions. Header facts above the tabs always refresh.
- Connect `tab_changed` so an unselected tab refreshes once on open and then follows the normal cadence. Treat a business selection change as dirtying all of that page's tabs.
- Stop rebuilding grids that are not visible. Where a tab's row set is stable, update labels in place rather than `queue_free` and recreate; at minimum, skip the clear-and-rebuild for hidden tabs.
- Fetch one business's detail report instead of calling `get_business_reports()` and scanning. Split cheap fields from history/ledger arrays so the Cash and Events tabs request those only when selected; the household table snapshot (section 2) is the model.
- Keep the existing mouse-down guard (a rebuilt button between mouse-down and mouse-up eats the click) and the controls that must not be reloaded mid-edit: the cull-target box and tax slider load only when the business is first shown.
- Make the presenter group granularity match: split `DETAILS` into business, household, and person detail groups so a hidden panel is never taken.

Acceptance: with the business page open on one tab, per-refresh counters for the other three tabs (rows built, controls created, charts redrawn, histories requested) stay flat as days advance; switching tabs shows current data on the first rendered or next scheduled frame; the selected tab and any in-progress edit survive refreshes; `check_business_tabs.gd` still passes (rows land on the correct tab, no duplication on refresh).

Acceptance: an inactive tab's query and row-update counters do not advance as days pass; opening an inactive tab shows the latest state on its first rendered or next scheduled frame; hidden detail panels do not rebuild controls or request histories; returning from Town view or a detail panel gives a complete current view.

### 4. Wall-clock presentation throttle
Raise `PRESENT_INTERVAL_SECONDS` (start at 10 Hz; 5 Hz is acceptable for dense diagnostic tables; Town view animation may stay at frame rate). Simulation still advances the requested days; the UI presents the latest state and skips intermediates. Pause, player commands, selection changes, and opening a tab/detail request an immediate presentation, without more than one full refresh per frame.

Acceptance: at 100x, refresh count tracks wall time rather than simulated days; the displayed day may jump forward but never backward or mix revisions; pause and commands show promptly; no refresh backlog accumulates; Town lighting/animation stays smooth.

### 5. Virtualize the household rows (inside `HEHouseholdTable`)
Replace one permanent row per household with a bounded pool of reusable rows (visible viewport plus overscan, target 25-40).

- Keep an ordered record array separate from controls; a content spacer represents total height; on scroll, bind the pool to the visible slice.
- Row controls read the household ID they are currently bound to when pressed (already how `HEHouseholdTable` routes clicks), never an ID captured at creation.
- Selection is by stable household ID; the detail panel stays open if the selected household scrolls out of view.
- Births, deaths, splits, migration, and filters change the data array and total height, not the pool. Default order is household ID; sort uses ID as a deterministic tie-breaker; clamp scroll when the list shrinks.
- If variable-height virtualization is disproportionate, ship pagination (about 50 per page) behind the same `set_snapshot` API; never create every page's controls at once.

Acceptance: retained row controls stay bounded as population grows; scrolling never shows a stale ID or sends a click to the previously bound household; selection, employer links, detail navigation, sorting/filtering, births, splits, and removals stay correct; keyboard/controller focus does not jump to a recycled off-screen record.

### Sequence
1. Timing counters and a baseline.
2. Lightweight snapshot with parity checks.
3. Visibility-aware groups.
3a. Business detail tab gating (can land with or right after step 3; it reuses the same visibility policy).
4. Wall-clock throttle (verify skipped presentations never skip simulation ticks).
5. Row virtualization (pagination is an acceptable intermediate).
6. Re-run the timing matrix, document which costs moved, and test a production export as well as editor/headless.

The snapshot may land before virtualization. Do not add a background thread in the same change: first make the UI consume coherent snapshots and prove it no longer assumes synchronous access to live records.

### Validation
Run `run_household_economy.gd` to prove economic output is unchanged, and extend `check_household_dashboard.gd` with: lightweight/rich field parity; bounded row-pool size across populations and viewports; row reuse, click targets, selection, and focus after scrolling; births, deaths, splits, migration, filtering, and sort changes; inactive tabs doing no expensive work; dirty tabs catching up when selected; refresh coalescing at high speed; immediate refresh on pause and commands; standalone and embedded dashboards; Town view transitions and resized windows.

Report baseline and post-change tick time separately from snapshot, refresh, layout/frame, and interaction measurements. A faster dashboard is not evidence of a faster simulation, and a faster tick is not evidence of smoother interaction.

## Follow-up: simulation/UI separation
Once the dashboard consumes snapshots rather than live state, a single-owner simulation runner is worth adding if profiling still shows tick work stalling frames. Commands cross into the runner at tick boundaries; immutable snapshots cross back atomically; Godot UI nodes stay on the main thread. Independent town economies are a natural scheduling unit, but intertown shipments must still resolve in deterministic shared-clock order. Every API and UI optimization above carries over, and the runner can host either the GDScript simulation or a Rust core.
