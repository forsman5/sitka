# Sitka: Five-Settlement River Valley Vertical Slice

**Status:** Directional prototype specification  
**Scope:** Design and architecture only; no Godot implementation in this pass  
**Setting:** Northern Britain, approximately AD 600–800 for the prototype  
**Primary question:** Can a physically grounded transport economy make settlement growth and regional specialization feel legible, consequential, and fun?

## 1. Product direction

Sitka is a management city builder about growing a clan's holdings in early medieval northern Britain. Its intended scale sits between the intimate settlement building of *Manor Lords* and the regional logistics of *Hegemony*. The player does not control individual villagers as in *RimWorld*, nor an entire national economy as in *Victoria 3*. The player develops a small network of holdings whose geography, production, transport links, households, and political importance change over time.

The core fantasy is:

> Begin with one modest holding, reshape the economic geography of a river valley, and watch a durable clan domain emerge from the movement of households, herds, and goods.

The game should make macro outcomes traceable to physical causes. A town becomes wealthy because grain and wool move through its landing, roads connect it to productive land, households find work there, and traders can reach it—not because the player filled an abstract progress bar. At the same time, physical detail is representational rather than literal: a rendered flock may stand for hundreds of sheep, and a few visible barges may visualize a larger transport flow.

### Design pillars

1. **Geography is economic structure.** Rivers, crossings, roads, pasture, woodland, and deposits determine what can prosper where.
2. **Goods move through the world.** Settlements do not share a global inventory. Transport time, capacity, and cost create meaningful local scarcity.
3. **Households are the atomic social unit.** The simulation tracks families or household groups, not individual hunger meters and daily walking schedules.
4. **Growth is an outcome, not a placement puzzle alone.** Infrastructure and opportunity attract households and production; the player creates conditions for settlement growth.
5. **One world, multiple lenses.** Close and regional views describe the same underlying economy. Zoom changes presentation and available tools, not simulation truth.
6. **History accumulates.** Early choices remain visible: an old hall, road, ford, or landing can become the center—or neglected edge—of a later town.

### Inspiration and what to borrow

| Reference | Relevant lesson |
| --- | --- |
| *Manor Lords* | A settlement should feel physically credible, inhabited, and shaped by terrain. |
| *Hegemony Gold / III* | Tactical geography and regional logistics can share one continuous map and camera. |
| *Anno* | Production chains are readable, satisfying, and capable of driving specialization. |
| *Victoria 3* | Prices, labor, and political power can emerge from connected economic conditions. |
| *Factorio* / *Timberborn* | Infrastructure should visibly transform throughput and make optimization pleasurable. |
| *Songs of Syx* | The player's responsibilities can change as scale increases without abandoning the underlying settlement. |
| *Against the Storm* | A scenario needs a sharp test and an ending before its economy becomes solved and tedious. |

Sitka should not initially attempt the population storytelling of *RimWorld*, the factory density of *Factorio*, the national scope of *Victoria 3*, or detailed tactical battles. Those are useful boundaries, not missing features.

## 2. The river-valley test

The vertical slice is one authored river valley containing five settlements and roughly 500 households. It should be small enough to understand at a glance but large enough for trade, specialization, bottlenecks, and settlement hierarchy to emerge.

The prototype begins with the player's clan controlling one inland settlement. The other settlements are neutral or AI-operated economic actors with stable, simple behavior. The player can improve production and transport infrastructure in controlled territory, negotiate or pay for access where required, and observe valley-wide consequences.

### The five settlements

Names are placeholders chosen for clarity rather than final historical authenticity.

| Settlement | Geography | Initial role | Structural constraint |
| --- | --- | --- | --- |
| **Aldford** | Player holding at a ford and poor landing | Mixed subsistence farming; clan hall | Central location but weak transport capacity |
| **High Fell** | Upland pasture connected by a rough track | Sheep, cattle, wool | Slow overland movement; severe winter penalty |
| **Oakmere** | Woodland on a tributary | Timber and charcoal | No direct navigable-river access |
| **Ironbank** | Small ore deposit downstream of Oakmere | Bloomery iron | Fuel-hungry and labor-poor |
| **Staithe** | Established downstream river port | Trade, milling, imported grain | Collects tolls and begins as the valley's market center |

The authored geography should make Aldford look unpromising but strategically positioned. It is where an overland route from High Fell and Oakmere meets the main river. Initially, shallow banks and poor facilities mean most long-distance trade flows downstream through Staithe.

### Starting state

- Approximately 500 households valley-wide; 70–100 belong to Aldford.
- Eight commodities: grain, cattle, sheep, wool, timber, charcoal, iron, and tools.
- Four transport modes: foot/pack, cart, cattle drive, and river barge.
- Infrastructure: rough track, improved road, ford, bridge, landing, and port.
- Production sites: farm, pasture, woodland camp, charcoal burner, bloomery, smithy, mill, storehouse, and market.
- One annual seasonal cycle, with planting, harvest, winter fodder pressure, and river/road modifiers.
- No tactical warfare, dynasty simulation, religion, raiding, detailed construction labor, or national politics.

The player should immediately be able to inspect:

- what each settlement produces and consumes;
- current inventories and local prices;
- active or planned shipments;
- route travel time, capacity, toll, and seasonal risk;
- why a good is scarce or expensive;
- which households are arriving, leaving, or changing work.

### Intended scenario arc

**Phase 1: Read the valley.** Aldford survives but does not prosper. Wool and cattle from High Fell move slowly toward Staithe. Oakmere sends some charcoal toward Ironbank, but the route is unreliable. Tools are expensive everywhere upstream. The player learns that production alone is not the main problem; transport is.

**Phase 2: Make a bet.** The player chooses among competing investments: improve the upland road, build a proper landing, replace the ford with a bridge, add storage, or expand local food production. Funds and labor are insufficient to do everything. Each option helps, but the landing plus one feeder route should create the strongest network effect.

**Phase 3: Redirect flows.** Barges begin loading at Aldford. Wool, charcoal, and food move more cheaply. Traders prefer Aldford for some transactions. Local tool production becomes viable because charcoal and iron can arrive predictably. Visible carts, herds, and barges make the change tangible.

**Phase 4: Growth creates pressure.** Better access attracts households and workshops. Grain and housing become constrained; wages or household prosperity diverge; congestion or storage capacity begins to matter. The successful strategy creates a new management problem instead of merely increasing every number.

**Phase 5: Demonstrate transformation.** Aldford becomes the valley's principal upstream market or specialized production center. Staithe remains relevant because it still connects the valley to outside trade. The goal is not to erase another settlement but to alter the hierarchy and relationships among all five.

### Success condition

The scenario succeeds when the player makes Aldford a sustainable regional center for at least two consecutive years. The exact thresholds can change during tuning, but should combine:

- sustained household growth without chronic food shortage;
- a meaningful share of valley trade passing through Aldford;
- at least one locally viable multi-settlement production chain;
- positive clan surplus after infrastructure upkeep;
- no settlement driven into irreversible collapse.

The last condition matters: the intended fantasy is building a functioning domain, not exploiting an economic model until all activity concentrates in one tile.

### Failure and soft failure

There need not be an immediate game-over state. Poor decisions should produce recoverable consequences:

- winter food shortage;
- unused infrastructure and clan debt;
- household out-migration;
- livestock losses from insufficient fodder;
- an ironworks idled by missing charcoal;
- trade continuing to bypass Aldford.

The prototype should allow fast restart and comparison of strategies. A complete playthrough should target 60–120 minutes, with accelerated simulation available for tuning.

## 3. Simulation and interaction specification

### Simulation units

A **household** represents a family or dependent group with members summarized by worker capacity and dependents. It owns or accesses a home, an occupation, modest inventory, livestock where relevant, wealth, and clan/settlement affiliation. Individual people may be rendered, but they are not authoritative simulation objects.

A **workplace** converts inputs, land, labor, and time into outputs. A **settlement** supplies a local market, storage, labor pool, and service capacity. A **shipment** reserves a quantity of goods and moves it along a route between inventories. A **transport edge** connects nodes and specifies mode, capacity, travel time, seasonal modifier, toll, and risk.

The first economic model should favor legibility over realism:

- Settlements clear simple local markets on a regular discrete tick.
- Households supply labor and consume food and basic goods.
- Workplaces choose production from recent expected input and output prices.
- Traders or a simple planner create shipments when price differences exceed transport cost and risk.
- Household movement responds slowly to food security, work, housing, kin ties, and relative prosperity.
- Herds are inventories with seasonal reproduction, fodder needs, and self-propelled transport along eligible routes.

Prices must be explainable. The UI should be able to answer “Why are tools expensive in High Fell?” with a short causal chain such as: low stock → Ironbank output reduced → charcoal shipment delayed → Oakmere road saturated.

### Time model

The simulation is deterministic and advances in fixed discrete ticks. Rendering remains continuous.

| Cadence | Systems |
| --- | --- |
| Hourly or event-based | Shipment departures/arrivals; construction progress where visible |
| Daily | Consumption, production, market clearing, local inventory updates |
| Weekly | Trade planning, employment changes, route-capacity decisions |
| Seasonal | Planting, harvest, pasture/fodder, road and river conditions |
| Yearly | Household formation, births/deaths as aggregates, migration review |

This schedule is directional. The implementation should use the coarsest cadence that preserves visible causality.

### Player actions

For the vertical slice, the player can:

- place or upgrade a limited set of workplaces and storage;
- build or improve roads, a bridge, a landing, and a port;
- prioritize or subsidize selected construction and trade;
- inspect settlements, households in aggregate, inventories, prices, workplaces, and routes;
- change time speed and pause;
- view transport and economic overlays.

The player cannot directly order a household to move a sack, select individual workers, manually schedule every shipment, redesign river channels, command armies, or govern settlements outside the clan's authority.

### Camera and presentation

Use two practical lenses with a continuous transition:

- **Settlement lens:** buildings, fields, paths, landing activity, representative people, carts, livestock, and barges.
- **Valley lens:** five settlements, productive land, route capacities, trade flows, clan control, and economic summaries.

Close decorative detail and a continent-scale campaign map are outside scope. Zoom controls what is rendered and which overlay is useful; it must not change economic outcomes.

Representative motion should be derived from simulation events. A shipment with a departure time, arrival time, and route can render as an interpolated cart or barge without simulating its physics every tick.

### Required feedback

The prototype is not successful if the underlying simulation works but the player cannot perceive it. Minimum UI feedback includes:

- a timeline and speed controls;
- settlement summary with population, food security, jobs, and prosperity;
- commodity stock and local price history;
- route overlays for capacity, cost, traffic, and bottlenecks;
- visible shipment movement;
- before/after comparison for infrastructure projects;
- short causal explanations for shortages, idle production, migration, and price changes.

## 4. Technical direction

Build the first playable version in Godot/GDScript, but preserve a deliberate simulation boundary so the core can move to Rust if profiling or project maturity justifies it.

The existing Sitka prototype is reference material, not a constraint. Useful camera, terrain, building, or visual experiments may be reused selectively. Existing node-per-person behaviors, global mutable state, and frame-driven economy code should not define the new simulation model.

Four architectural rules apply from the first implementation:

1. **Simulation records are plain data, not scene nodes.**
2. **Simulation advances through explicit discrete ticks, never per-object `_process(delta)`.**
3. **Player intent enters through commands; UI and scenes do not directly mutate economic truth.**
4. **Views consume summaries or render snapshots; they do not own authoritative state.**

A conceptual boundary:

```text
Commands -> Simulation -> Events / Snapshots -> Godot views and UI
```

The initial GDScript implementation should expose a small interface such as:

```gdscript
simulation.issue_command(command)
simulation.advance_ticks(count)
simulation.get_settlement_summary(settlement_id)
simulation.get_market_history(settlement_id, commodity_id)
simulation.get_visible_transports(bounds)
```

Stable integer IDs should connect households, workplaces, settlements, inventories, and routes. Avoid object-reference graphs that would complicate serialization and a later Rust migration.

Start single-threaded. Do not introduce ECS, Tokio, Rayon, custom job systems, or zoom-dependent simulation fidelity during the vertical slice. Determinism, fast headless tests, and profiling are more valuable than speculative concurrency.

### When to introduce Rust

Consider porting the simulation core only after all three are true:

1. The economic model has survived substantial design iteration and is worth preserving.
2. A headless benchmark or profiler identifies GDScript simulation cost as a material constraint.
3. The Godot/simulation command-and-snapshot boundary is stable enough to reproduce through GDExtension.

Rust remains the likely long-term home for a large deterministic simulation, batch scenario testing, save validation, and performance-sensitive routing or market logic. It is not a prerequisite for proving the game.

## 5. Milestones and acceptance criteria

### Milestone 0: Paper model and data skeleton

Define the authored valley, initial stocks, production recipes, household aggregates, transport graph, and a simple balance spreadsheet or headless test harness.

**Accept when:** one simulated year can run deterministically and inventories remain bounded under the starting configuration.

### Milestone 0.5: Simulation dashboard

Add a live, speed-controllable dashboard over the headless simulation so stocks, shortages, population, season, and year can be observed without building the world view.

**Accept when:** the simulation can be paused and accelerated, every settlement can be inspected, and the dashboard reads simulation snapshots rather than owning economic rules.

### Milestone 0.75: Diagnostic simulation contract

Make economic outcomes explainable before adding additional mechanics. Expose settlement IDs and clock state through query methods; distinguish current or rolling shortage from lifetime totals; record daily production and consumption flows; and report each workplace's planned output, actual output, utilization, and limiting input.

**Accept when:** the dashboard can explain a stopped production chain—such as Ironbank's bloomery idling for lack of charcoal—and automated tests verify those explanations rather than only checking that inventories remain nonnegative.

### Milestone 0.76: Isolated-settlement equilibrium and collapse

Before enabling inter-settlement transport, enforce the consequences of local depletion. Households consume food from their settlement, accumulate food-security stress when demand is unmet, recover when fed, and emigrate after sustained hardship. Agricultural settlements with viable land and labor should converge toward a bounded population and inventory cycle; structurally deficient settlements should contract rather than survive indefinitely on zero stock.

Use settlement food security as the first causal chain:

```text
production and starting stock -> consumption shortfall -> household stress
-> emigration and/or mortality -> lower labor and demand -> new equilibrium or collapse
```

For this milestone, emigration may remove households from the isolated test world rather than relocate them to another settlement. Starvation mortality should occur only after prolonged severe shortage and should be slower than emigration; neither consequence should fire from a single bad day. Population changes must feed back into labor capacity, production, and consumption. Define game over as the player's holding losing every viable household or falling below a small recoverable-population threshold for a sustained period.

Tune and test at least three authored cases:

- a viable farming settlement reaches a repeatable seasonal equilibrium;
- an overpopulated farming settlement contracts and then stabilizes;
- a settlement with no food production or imports depletes its stock, experiences emigration and starvation, and eventually collapses.

**Accept when:** multi-year headless tests deterministically distinguish equilibrium, contraction, and collapse; no settlement persists indefinitely without food; viable farms do not grow or stockpile without bound; and the dashboard explains population losses through recent food-security history.

This is deliberately a baseline survival model, not the full Milestone 4 household economy. Housing, prosperity-driven immigration, occupational choice, and movement between connected settlements remain deferred.

### Milestone 1: Static readable valley

Render the five settlements, river, tributary, crossings, roads, terrain/resource regions, and two camera lenses. Expose seeded settlement summaries.

**Accept when:** a player can identify each settlement's likely economic role without reading this document.

### Milestone 2: Goods and routes

Implement inventories, workplaces, shipments, route costs/capacities, representative carts/barges/herds, and basic market prices.

**Accept when:** blocking one edge or reducing its capacity produces a visible, explainable shortage elsewhere.

### Milestone 3: Player infrastructure

Allow road, bridge, landing, port, storage, and selected workplace projects. Apply construction cost and upkeep.

**Accept when:** two materially different infrastructure strategies lead to different trade patterns rather than simple linear bonuses.

### Milestone 4: Households and growth

Add labor allocation, consumption, housing capacity, prosperity, and slow migration.

**Accept when:** successful trade attracts households but can also generate food, housing, or labor pressure.

### Milestone 5: Complete river-valley scenario

Add the success condition, soft failures, onboarding, economic explanations, balance passes, restart, and save/load if needed for playtesting.

**Accept when:** a new player can complete or meaningfully fail the scenario, explain why Aldford changed, and express a desire to try a different network strategy.

## 6. Explicit non-goals and open questions

### Non-goals for this slice

- Tactical combat, raids, levies, or army movement
- Dynasty, succession, marriage, or named-character simulation
- Religion, monasteries as institutions, or conversion
- Detailed political factions or kingdom diplomacy
- Procedural world generation
- Full construction logistics and individual builders
- Weather beyond simple seasonal route/harvest modifiers
- Individually authoritative people, animals, carts, or boats
- A continent-scale campaign
- Rust/GDExtension integration

### Questions the prototype must answer

1. Is changing transport geography fun enough to be the primary loop?
2. Are explicit shipments more legible and enjoyable than abstract inter-settlement flows?
3. Does the household abstraction create convincing growth without individual simulation?
4. How much control should the player have over trade versus creating incentives?
5. Can local prices remain understandable without becoming trivially exploitable?
6. Does the settlement-to-valley zoom feel like two views of one world?
7. Which existing Sitka assets and systems are worth carrying forward, and which should be discarded?

The strongest outcome is not a technically complete city builder. It is a small scenario that produces one memorable realization:

> “I built the landing and improved the road; now I can watch the wool and charcoal converge here, the smithy can finally operate, and this village is becoming the center of the valley.”
