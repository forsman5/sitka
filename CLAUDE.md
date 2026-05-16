# Sitka

Orthographic top-down RTS city builder prototype in Godot 4.6.2. Persons gather resources, deposit at buildings, sleep at night, and the player expands by building forest huts and purchasing upgrades.

**NO COMMITTING BEFORE VERIFICATION** — always wait for the user to confirm a change works in-engine before committing.

---

## Project Config

- **Engine:** Godot 4.6.2, Forward Plus, Jolt Physics, D3D12
- **Main scene:** `res://scenes/ui/main_menu.tscn`
- **Autoload:** `GameState` (`scripts/global/game_state.gd`)

---

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
