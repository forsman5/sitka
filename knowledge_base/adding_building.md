# Adding a New Building

## Files to create (4 total)

### Script: `scripts/entities/building/<name>_building.gd`
```gdscript
extends "res://scripts/entities/building/building.gd"

func _ready() -> void:
    super._ready()
    building_name = "Display Name"
    building_type = "SaveKey"       # must match BUILDING_SCENES key in save_load.gd
    town_radius_contribution = 3.0  # affects town shader radius
    # add_to_group("sleep_point")   # persons sleep here
    # add_to_group("cow_sleep_point") # cows sleep here

# Optional overrides:
# func get_bed_count() -> int: return 4
# func get_cow_bed_count() -> int: return 4
# func get_available_upgrades() -> Array: return [{id, label, cost_wood}]
# func _on_upgrade_applied(id): pass
# func shows_spawn_button() -> bool: return false
# func shows_spawn_ship_button() -> bool: return false
```

### Scene: `scenes/entities/building/<name>.tscn`
- Root: `StaticBody3D` with the building script
- `MeshInstance3D` at `position = Vector3(0, h/2, 0)` — needed by `building.gd` for selection highlight
- `CollisionShape3D` at same offset
- `ClickArea` (Area3D) + `CollisionShape3D` — needed for click-selection raycasting

### Foundation script: `scripts/entities/building/<name>_foundation.gd`
Copy `forest_hut_foundation.gd` verbatim, change:
- `foundation_name = "Name Foundation"` — must match FOUNDATION_SCENES key
- `build_required` (ticks) and `build_tick_time` (seconds/tick, scaled by game_speed)
- `const BuildScene = preload("res://scenes/entities/building/<name>.tscn")`

### Foundation scene: `scenes/entities/building/<name>_foundation.tscn`
- Root: `Node3D` with foundation script
- `MeshInstance3D` — flat BoxMesh matching building footprint (height ~0.2)
- `Area3D` + `CollisionShape3D` (taller, ~1.0 height) — for click-selection

## Files to update (4 total)

### `scripts/global/save_load.gd`
```gdscript
const BUILDING_SCENES := { ..., "SaveKey": "res://scenes/entities/building/<name>.tscn" }
const FOUNDATION_SCENES := { ..., "Name Foundation": "res://scenes/entities/building/<name>_foundation.tscn" }
```

### `scripts/global/game_state.gd`
```gdscript
@export var <name>_cost: int = 60
```

### `scripts/ui/hud.gd`
```gdscript
const <Name>FoundationScene = preload("res://scenes/entities/building/<name>_foundation.tscn")
@onready var _build_<name>_btn: Button = $Root/BuildMenu/VBox/Build<Name>Button

# in _process():
_build_<name>_btn.disabled = GameState.player_wood < GameState.<name>_cost

func _on_build_<name>_pressed() -> void:
    _build_menu.visible = false
    if GameState.player_wood < GameState.<name>_cost: return
    var placement = get_tree().get_first_node_in_group("building_placement")
    if placement:
        placement.arm(<Name>FoundationScene, GameState.<name>_cost)
```

### `scenes/ui/hud.tscn`
- Add `Button` node inside `Root/BuildMenu/VBox`, text `"Name (60w)"`
- Wire `pressed` → `_on_build_<name>_pressed`
- If adding a 4th+ button, increase `BuildMenu` panel height (`offset_top` more negative)

## Key patterns
- `building_type` string is the save/load key — keep consistent with BUILDING_SCENES dict
- `_complete()` in foundation instantiates the building under `NavigationRegion3D` and calls `bake_navigation_mesh()`
- Buildings under NavigationRegion3D are baked into the nav mesh (persons route around them automatically)
- Resource nodes are NOT under NavigationRegion3D — they use NavigationObstacle3D for avoidance instead
