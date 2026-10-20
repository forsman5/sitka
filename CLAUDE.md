# Sitka

Godot 4.6.2 prototype repo holding several **experiments** that share one project and one main menu. They are candidate seeds for a final game, not one game; see "Experiments and direction" before assuming any one of them is "the game".

**WORKFLOW** — commit on a branch, push, and open a PR against `master`. The user reviews and verifies changes from the PR previews, so there is no need to wait for in-engine confirmation before committing. Never push directly to `master`.

---

## Experiments and direction

| Experiment | Main menu entry | Code | Status |
|---|---|---|---|
| **Household economy** (town simulator) | "Household Economy Simulation" | `scripts/sim/household_economy/`, `docs/household-*.md` | **Primary work vector.** Most active development. Name is pending a rename — don't bake it into new public names. |
| **Single valley** (river valley, game view + sim) | "Single Valley Simulation", "Single Valley (Game View)" | `scripts/valley/`, `scripts/sim/simulation.gd`, `docs/river-valley-vertical-slice.md`, `docs/shared-valley-map.md` | Next integration target: villages in the valley backed by household-economy simulations. |
| **Large valleys / multivalley** | "Large Valleys Simulation" | `scripts/sim/data/multivalley_seed.gd`, `tools/generate_multivalley.py`, `docs/multivalley-scale-probe.md` | Scale probe, not a content requirement. |
| **On foot** (sheep herding, dog) | "On Foot" | `scripts/on_foot/`, `docs/sheep-flocking-plan.md` | **Secondary.** Flocking accepted and merged; herding-dog brain is out of scope for now. |
| **Valley generator** (sketch) | "Valley Generator (Dev Tool)" | `scripts/valley/gen/`, `docs/valley-generation-sketch.md` | Rough pipeline from a JSON `ValleySpec` to terrain, sites, roads and fords, emitting a `ValleyMapDefinition`. Dev tool also bakes a larger, detailed valley. |
| **RTS city builder** | "Start Game" | `scripts/entities/`, `scripts/world/`, `scenes/world/` | Original prototype; kept playable, least active. Documented in the RTS sections below. |

### Candidate end-games (what the experiments are converging toward)

1. **Overland strategy map (Mount & Blade style):** a single valley (or several) running a live household-economy simulation, with the player moving across the map. Optional tactical layer: on-foot battles or Total War-style strategy battles.
2. **Sheep-herding on foot:** possibly co-op, possibly with a dog companion, possibly the player whistling commands to the dog.
3. **RTS city builder:** the original Sitka concept.

Options 1 and 2 are the live ones; the household economy is the engine behind option 1 and the on-foot work is option 2. Prefer work that moves the household economy forward, and keep it decoupled from rendering (the sim must run headless and be reusable by the dashboard, the town view, and the valley).

### Household economy notes

- `HESimulation` (`scripts/sim/household_economy/he_simulation.gd`) is the authoritative sim; one instance per town. Views (dashboard `he_dashboard.gd`, 3D town view `he_town_view.gd`) read the same live instance and must not change economic rules or tick order.
- Starting towns are JSON-able specs (`scripts/sim/household_economy/data/he_presets.gd`: Small / Mining / Large village + Custom roster) built by `HEScenarioSeeds.build_from_spec`. That spec is the new-game/save format to grow.
- Reference docs in `docs/`: `household-housing.md`, `household-employment-index.md`, `household-dashboard-performance-plan.md`, `household-town-view-plan.md`, `household-water.md`, `tools-industrial-demand-plan.md`, `population-capacity-ideas.md` (proposals only).
- Headless checks live under `scripts/sim/harness/` and `scripts/valley/harness/`; run with `Godot_v4.6.2-stable_win64_console.exe --headless --path . --script <path>`.
- Town view reuses RTS building models as visual-only instances (RTS building scripts must not run there).

### On-foot notes

- `scripts/on_foot/`: player, companion (dog), sheep flocking (`on_foot_sheep.gd`, per Jadhav et al. 2024), pen, and a dusk-challenge day loop in `on_foot_world.gd` (pen the flock before 9pm; stragglers may be lost, penned sheep may breed).
- It reuses the RTS island terrain and forest/bush managers, so RTS terrain changes can affect it.

### Infrastructure

- PR previews are built by CI (`.github/workflows/pr-preview.yml`); docs-only PRs skip the build. `serve.py` is a local no-cache web server for exports, not part of the game.

---

## Project Config

- **Engine:** Godot 4.6.2, Forward Plus, Jolt Physics, D3D12
- **Main scene:** `res://scenes/ui/main_menu.tscn`
- **Autoloads:** `GameState` (`scripts/global/game_state.gd`), `SaveLoad` (`scripts/global/save_load.gd`), `IslandsManager` (`scripts/global/islands_manager.gd`)

---

# RTS City Builder (original prototype)

Everything below documents the orthographic top-down RTS prototype: persons gather resources, deposit at buildings, sleep at night, and the player expands by building forest huts and purchasing upgrades. The `GameState` autoload is RTS-specific.

## GameState (Autoload)

`scripts/global/game_state.gd`

Exports (tunable in inspector on the autoload node):
- `gather_speed: float = 1.3` — multiplier on resource wait_time
- `game_speed: float = 1.0` — scales day/night speed, move speed, and gather timers
- `pause_on_escape: bool = true`
- `settler_cost: int = 30` (gold)
- `forest_hut_cost: int = 50` (wood)

State with signals:
- `player_gold: int` — setter emits `gold_changed(amount)`
- `player_wood: int` — setter emits `wood_changed(amount)`
- `time_of_day: float` — 0.0 = midnight, 0.25 = 6am, 0.5 = noon, 0.75 = 6pm

---

## Scene Structure

```
main_menu.tscn
└── Start → loads world.tscn

world.tscn
├── RTSCamera (rts_camera.gd) + Camera3D (orthographic)
├── WorldEnvironment + DirectionalLight3D
├── DayNightCycle node (day_night_cycle.gd)
├── NavigationRegion3D
│   ├── Terrain (StaticBody3D, grid+biome shader)
│   └── [buildings added here at runtime]
├── Person ×3 (hidden until capital placed)
├── ResourceNode (gold, pos -8,-3)
├── ResourceNodeWood (wood, pos -4,4)
├── PlacementManager (capital placement, one-shot, then queue_free)
├── BuildingPlacement (hut placement, persistent)
├── ForestManager (continuous tree spawning)
├── HUD (CanvasLayer 10)
└── EscapeMenu (CanvasLayer 20)
```

---

## Groups

| Group | Who joins | Used by |
|-------|-----------|---------|
| `persons` | Person | world.gd selection, HUD rows |
| `buildings` | Building (base `_ready`) | world.gd selection, HUD panel |
| `capital` | DepositBuilding `_ready` | Person deposit target |
| `sleep_point` | Capital always; Forest Hut after bunk_beds upgrade | Person sleep target |
| `resource_nodes` | ResourceNode | world.gd selection, Person auto-retarget |
| `building_placement` | BuildingPlacement | HUD calls `arm()` |

---

## Building Class Hierarchy

```
Building (building.gd)                 – base, groups "buildings"
└── DepositBuilding (deposit_building.gd) – groups "capital", has OmniLight3D
    ├── capital_building.gd             – groups "sleep_point", shows spawn/build buttons
    └── forest_hut_building.gd          – bunk_beds upgrade → groups "sleep_point"
```

`building.gd` virtual methods (override in subclasses, never check building_type in HUD):
- `get_available_upgrades() -> Array` — return `[{id, label, cost_wood}]` dicts or `[]`
- `shows_spawn_button() -> bool`
- `shows_build_hut_button() -> bool`
- `_on_upgrade_applied(id: String)` — called after upgrade state is recorded

Upgrade flow: HUD calls `building.apply_upgrade(id)` → sets `upgrades[id] = true` → calls `_on_upgrade_applied`. Buttons only rebuilt when selected building changes (`_last_selected_building` tracking).

---

## Person AI

`scripts/entities/person.gd` — `class_name Person extends CharacterBody3D`

**Exports:** `move_speed: float = 5.0`, `carry_capacity: float = 10.0`

**Task loop priority** (`_run_task_loop`, runs as async while-loop):
1. Explicit player move order (`_move_target != Vector3.INF`) — always finishes before sleeping
2. Night time (`_is_night_time()`) → `_do_sleep()`
3. Inventory full or deposit queued → `_do_deposit()`
4. Objective node valid → `_do_harvest()`
5. Objective freed + last resource type known → auto-retarget same type
6. Idle (await process_frame)

**Sleep:** 21:00–05:30 (`SLEEP_TIME = 21/24`, `WAKE_TIME = 5.5/24`). Walks to nearest `sleep_point`, deposits inventory, `visible = false`, waits until morning, `visible = true`.

**Navigation:** Uses `NavigationAgent3D`. `max_speed` is updated every physics frame to `move_speed * GameState.game_speed` so the RVO layer doesn't clamp scaled velocities. Uses `velocity_computed` signal pattern.

**Harvest loop:** Timer is owned by Person (`get_tree().create_timer`), not the resource node. Resource uses `mine_sync()` (synchronous) — no coroutine on the resource side to avoid hang-on-free bugs.

**`_wait_until_near` exits when:**
- `dist <= reach`
- `_move_target` overridden by player
- `_nav_agent.is_navigation_finished()` AND `dist <= reach * 2.0` (fallback if nav can't fully close)

---

## Navigation

- Buildings are parented under `NavigationRegion3D` when placed (both capital via `placement_manager.gd` and huts via `building_placement.gd`). This means their mesh geometry is included in `bake_navigation_mesh()` called immediately after placement. No RVO obstacle needed on buildings.
- Resource nodes are NOT children of NavigationRegion3D (they're scene-native). They use `NavigationObstacle3D` (avoidance_enabled=true, radius=0.8) for RVO-based steering. Radius kept tight (0.8) to avoid excessive slowdown.
- Person-to-person avoidance is handled by the NavigationAgent3D on each Person via the `velocity_computed` signal.

---

## Day/Night Cycle

`scripts/world/day_night_cycle.gd` — node inside world.tscn

Exports: `seconds_per_day: float = 120.0`, `min_ambient_energy: float = 0.15`, `day_night_enabled: bool = true`

Gets references via `get_parent().get_node(...)` in `_ready` (NodePath exports failed to resolve for this node). Interpolates between 5 keyframes (midnight/dawn/noon/dusk/midnight) driving DirectionalLight3D energy+color, ambient energy+color, and background sky color.

---

## Forest Manager

`scripts/world/forest_manager.gd`

Exports: `mean_spawn_time`, `min_tree_spacing`, `forest_center: Vector2(-60, -3)`, `forest_radius: float = 50`

Spawns wood resource nodes inside a circle. Checks minimum spacing against existing trees AND buildings (to avoid spawning inside placed structures). Rejects positions outside ±49 world bounds.

---

## Terrain Shader

Three biomes blended by distance in a shader on `NavigationRegion3D/Terrain/MeshInstance3D`:
- **Grassland** — default green
- **Forest** — dark green, centered at `(-60, -3)` radius 50
- **Town** — brown, centered at `capital_pos` (shader parameter set on capital placement), radius 6

`placement_manager.gd` writes `capital_pos` via `mat.set_shader_parameter("capital_pos", Vector2(pos.x, pos.z))`.

---

## HUD

`scripts/ui/hud.gd` — CanvasLayer 10

- Top-right: TimeLabel (`HH:MM`), GoldLabel, WoodLabel
- Bottom-left SelectionPanel shows one of three views: person rows, resource info, building info
- Building view shows upgrade buttons dynamically; buttons only rebuilt on selection change to keep them clickable (recreation mid-frame would split mouse-down and mouse-up across different button instances)
- Spawn/build button visibility delegated to `building.shows_spawn_button()` / `shows_build_hut_button()` — never check `building_type` string in HUD

---

## Known Patterns & Pitfalls

**Freed node safety:** Always guard with `is_instance_valid(node)` before accessing properties, especially after any `await`. Never compare `_objective_node == freed_node` — use `not is_instance_valid(_objective_node)`.

**Coroutine lifetime:** If an object owning a coroutine is freed, any caller awaiting it hangs forever. Solution: own all timers in person.gd, use synchronous methods on resource nodes.

**Building scripts use path-based extends** (`extends "res://scripts/entities/building/deposit_building.gd"`) rather than class_name to avoid load-order issues in subdirectories.

**NavigationAgent3D.max_speed must be updated dynamically** when scaling velocity — passing a high velocity to `set_velocity()` without raising `max_speed` first causes the RVO layer to silently clamp the output.
