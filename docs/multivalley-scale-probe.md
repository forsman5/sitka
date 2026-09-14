# Headless multi-valley scale probe

This is a parallel engineering experiment, not a replacement for the authored
five-settlement slice or a new requirement to render 100 settlements. Use five
settlements to prove player decisions; use generated worlds to find scale,
connectivity, scarcity, and local-trade assumptions before polishing the display.

## Generate only (Python standard library)

From the repository root, on native Windows:

```powershell
py tools/generate_multivalley.py --settlements 100 --valleys 10 --seed 42 --out multivalley.json
```

The JSON contains stable settlement/edge IDs, valley membership, economic
archetypes, household counts, river corridors, feeder roads, and sparse mountain
passes. River travel is directional; capacity is shared. This is abstract authored
graph structure with randomized parameters, not terrain or hydrology generation.
Each valley has a river spine and inland specialist settlements; inter-valley
passes connect the valley network. No global trade planner is introduced.

Use `--links isolated`, `--links sparse` (default), or `--links redundant`.
For identical size/seed, these preserve settlement data and local edges; only
inter-valley connections change. Sparse uses a chain of passes, so closures can
partition regions. Redundant adds a second link where distinct endpoints exist.
Singleton valleys cannot have two distinct links to another singleton valley.

## Run the existing simulation (Godot 4.6)

```powershell
godot --headless --path . --script scripts/sim/harness/run_multivalley.gd -- --graph=multivalley.json --days=360 --out=multivalley-run.jsonl
```

Replace `godot` with your executable path if necessary; PowerShell uses
`& "C:/path/to/Godot_console.exe"` for a quoted executable. Pass arguments with
`=` as shown. Output parents must exist. Keep generated JSON/JSONL local unless
intentionally committing a small reproducible fixture.

The runner plugs a seed builder into the unchanged production Simulation. It
reuses the five existing economic archetypes and recipes, scales production
targets and initial stocks by household count, and adds a finite 90-day food
buffer. Trade centers retain the current four-worker target. There are no player
holdings, so individual collapse is reported without stopping the world.

**Generated does not mean balanced.** Expect shortages, losses, inventory growth,
and possibly regions that fail. No ongoing food injection, automatic balancing,
new demand model, or global routing is supplied. These results help evaluate
Milestone 3A rather than bypassing it. Inter-valley links need not carry useful
trade simply because they exist, particularly with the current stock-based prices.

Monthly JSONL samples retain every settlement summary and active shipments,
population, cumulative starvation deaths, collapsed settlement count, and completed
deliveries. A SHA-256 fingerprint covers each economic sample, excluding timing;
compare fingerprints from repeated runs with the same graph, code and Godot
version. This is observable-state reproducibility, not a full internal-state proof.
The last record reports total simulation time, reporting time, and mean tick time
separately. Initialization is excluded. Sampled inventories are checked for finite,
nonnegative values; this probe does not replace existing conservation tests.

## Suggested experiments

1. Generate 5/1, 25/3, and 100/10 settlements/valleys with the same seed. Measure
   time per tick; household count matters alongside settlement count.
2. Run 100/10 twice for 360 days and compare sample fingerprints.
3. Compare isolated, sparse, and redundant connectivity for 1,800 days, including
   starvation, not just surviving population's food fulfillment.
4. Inspect whether longer runs slow down after histories reach their 360-day cap.
   The runner streams monthly output rather than retaining years of snapshots.

Current trade planning scans all edges for each center, so this is also a probe
for the eventual need for an adjacency index. Measure before optimizing or
moving to Rust. Keep exact graph/seed, engine version, and code revision alongside
benchmark output. No performance threshold or equilibrium claim is established yet.

## Verification

```powershell
py -m unittest discover -s tools -p test_generate_multivalley.py
```

Generator tests cover connected/disconnected cases, uneven valley sizes,
singletons, reproducibility, invalid configurations, and preservation of the local
world between connectivity experiments. The Godot runner still needs execution
in a Godot 4.6 environment; the authoring environment did not have Godot installed.
