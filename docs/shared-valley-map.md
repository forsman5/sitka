# Shared valley map

The single-valley view now reads one `ValleyMapDefinition` Resource. The default
is authored in `scripts/valley/river_valley_layout.gd`, in `create_map()`.
The scene's exported `map_definition` accepts a different resource; when unset,
it creates a fresh default. Change the resource before the scene enters the tree.
Edits take effect on scene rebuild, not through live editor regeneration.

## Records

| Collection | Owns |
| --- | --- |
| `settlements` | Actual village sites, roles, accents, districts, optional waterfront anchors |
| `rivers` | Ordered centerline points, channel width, generated node name |
| `roads` | Ordered path points, width, deterministic seed, optional simulation edge ID |
| `crossings` | Kind, road ID, river ID, location, bank-search radius, width, seed |
| `junctions` | Shared river meeting point and water-height blend radii |
| `vegetation` | Region center, ellipse radii, count, seed, central clearance |

Path points may be fixed `Vector3` coordinates or references:

```gdscript
{"settlement": 3} # follows Oakmere's actual site
{"crossing": "oakmere", "offset": Vector3(-8, 0, 10)} # ford approach
{"junction": "aldford"} # shared endpoint of the tributary and main river
{"waterfront": 5} # Staithe's river anchor, independent of its inland houses
```

Move Oakmere by editing `map.settlements[3]["site"]`. Both road endpoints,
village geometry, selection, settlement clearance, and its relative woodland
center follow that value. Interior road control points remain authored; moving
a village does **not** calculate a new route around hills or water.

Move a crossing by editing its `position`. Referencing road points move with it.
One ford builder finds the road's two bank intersections near that location and
fits the gravel surface to the rendered water triangles. Aldford's former
special-case ford now uses the same builder as Oakmere and the upstream ford.
Only `ford` is currently supported; bridges require a new renderer.

Road clipping and vegetation exclusion are generated from the same resolved
paths and widths. Every river participates, including disconnected channels.
The Aldford approach now participates in vegetation clearance as well.

## Validation

`validate()` checks references and basic record requirements.
`validate_geometry()` also checks settlement centers against water, requires
exactly two bank intersections per declared crossing, and rejects road/water
intersections without a matching crossing. The scene runs these checks before
building. Search radii must isolate the intended crossing.

Run the integration harness:

```powershell
& 'C:\Users\jrfor\OneDrive\Desktop\gamedev\Godot_v4.6.2-stable_win64_console.exe' --headless --path . --script scripts/valley/harness/check_map_definition.gd
```

It checks default geometry and simulation links, moves Oakmere, builds the
changed scene, checks generated fords and vegetation clearance, and rejects
broken references and an undeclared crossing.

## Boundaries

The map defines presentation geography. Simulation travel times, capacities,
and connectivity remain owned by `ValleySeed`; an authored visual ford does not
change those mechanics. The existing EXR terrain backend remains in place.
This is the placement foundation for a future Gaea import, not yet a terrain
importer, road pathfinder, hydrology solver, or multi-valley economic adapter.
Validation checks centerlines and village centers; it does not yet prove that
every road shoulder, building footprint, or slope is buildable.
