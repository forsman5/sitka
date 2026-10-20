# Valley migration (experiment)

Whole households move between connected valley towns. `ValleyEconomy._run_migration` runs every 30 days: each town gets a smoothed attractiveness (fed, employed, free homes); across each edge, a household leaves the worse town for the better one if the gap beats `MIGRATION_MIN_ADVANTAGE`, the destination has a free home and the origin keeps more than `MIGRATION_ORIGIN_FLOOR` households. The household carries its people, money and goods (`HESimulation.extract_migrant` / `accept_migrant`); nothing is written off. Unemployed or food-stressed households leave first. Toggle with `ValleyEconomy.migration_enabled`.

## Measuring

```powershell
..\Godot_v4.6.2-stable_win64_console.exe --headless --path . --script res://scripts/valley/harness/measure_valley_migration.gd -- 3
```

Runs migration off, then on, for N years (about 5 minutes per simulated year pair; first run needs `--import`). Per quarter it prints population per town, moves, and the attractiveness spread. It declares **EQUILIBRIUM** when, over the last 12 months, spread < 0.35, each town's population range < 16% of its mean, net flow per town < 0.5 households/month, and moves are still happening (a frozen valley is stuck, not balanced).

## First result (3 years)

- 51 moves (17/year). Mechanism works; no equilibrium declared.
- The baseline is not stable: with migration off total population falls from about 2,000 to about 1,100 (Staithe 735 to 316), so there is no steady state to settle into.
- The attractiveness spread grows (0.8 to 1.5) because at most one household per edge moves per month, far too slow to close gaps; it also saturates on the unemployment term.

Next: stabilise the no-migration baseline (trade capacity / livelihood pass from #19's known gap), then tune hazard, cap and utility weights.
