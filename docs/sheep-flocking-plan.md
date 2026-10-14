# Sheep movement: flocking plan

Source: Jadhav et al., "Collective responses of flocking sheep (Ovis aries) to a
herding dog (border collie)", *Communications Biology* 7:1543 (2024),
doi:10.1038/s42003-024-07245-8. 14 merino sheep + 1 border collie, UWB-tracked
over 80 m x 50 m, plus an agent-based model that reproduces the data.

## Status

| Phase | State |
|---|---|
| 1. `on_foot_sheep.gd` tuning deltas + harness | **Implemented in this PR, awaiting sign-off** |
| 2. Shared `FlockSteering` module, port island `Sheep` | Not started |
| 3. Herding dog brain (drive/collect) | **Out of scope for now** (approved deferral) |

Phase 1 results (`check_flock_steering.gd`, 14 sheep, scripted dog trailing 5 m,
60 s after 10 s warm-up, fixed seed):

| | Paper | Before | After |
|---|---|---|---|
| Cohesion C (mean radius) | 1.21 m | 6.00 m | 1.54 m |
| Polarization P | 0.85 | 0.35 | 0.90 |
| Median elongation E | ~0.8 | 1.16 | 0.81 |
| Max straggle from barycentre | n/a | 13.6 m | 4.7 m |
| Distance driven in 60 s | n/a | 19 m | 116 m |

Phase 1 checklist (section 4 items):

- [x] 1. Attraction + alignment while fleeing (`w_dog 1.0, w_rep 2.0, w_att 1.5, w_ali 1.3`, paper weights)
- [x] 2. Nearest-k neighbours for wander cohesion instead of the global centroid
- [x] 3. One per-physics-frame snapshot of the flock; drops per-sheep `get_nodes_in_group` scans
- [x] 4. Heading inertia term (`w_inertia`)
- [x] 5. Noise + neighbour subset re-rolled ~1 Hz, staggered per sheep
- [x] 6. Flee-speed ratio reviewed, **left unchanged** (see section 4)
- [x] Acceptance harness `scripts/sim/harness/check_flock_steering.gd`
- [ ] Sign-off (user)

Not changed: `_react_step` bark hop, `_avoid_water`, penning, animation.
Known limits: neighbour scan is still O(N) per sheep once per second (fine for
tens of sheep, grid is phase 2); harness runs without terrain, so it does not
exercise `_avoid_water`; not yet eyeballed in the real On Foot scene.

## 1. Where we are

There are two unrelated sheep implementations:

| | `scripts/entities/sheep.gd` | `scripts/on_foot/on_foot_sheep.gd` |
|---|---|---|
| Used by | Island / sim scenes | On Foot plane (dog + pen) |
| Movement | NavigationAgent3D, pick random point 3-12 m away, pause 2-6 s | Steering: graze/wander toggle, flee from player |
| Flock awareness | None (an explicit `TODO` stub) | Weak: wander dir biased to flock centre; separation only while fleeing |
| Threat response | None | Flee `away + edge + separation`, bark startle hop |
| Sleep / health | Not ported | n/a |

`on_foot_sheep.gd` is already a decent single-sheep reactor but it is **not a
flock**. Concretely, while fleeing every sheep steers `normalize(away_from_player
+ edge_push + separation)`:

- No attraction and no alignment term, so a spooked group *fans out radially*
  from the player instead of moving off as a cohesive, polarized mob. This is the
  single biggest gap versus the paper.
- Calm/grazing sheep don't align with anyone; the only cohesion is a re-roll of
  the wander direction every 2-5 s, biased to the global flock centroid (O(N)
  `get_nodes_in_group` per re-roll, and O(N) per frame per fleeing sheep for
  separation, so O(N^2)).
- "Flock centre" is the centroid of *all* sheep in the group, so two separated
  clumps both pull toward an empty midpoint.
- Nothing in the game plays the *dog* role except the human player, so there is
  no reusable herding behavior (drive/collect) for NPC dogs or shepherd persons.

## 2. What the paper says (the useful parts)

**Model (Methods, eqs 1-4, Fig. 7).** Discrete 1 s steps. Each sheep's new heading
is the normalized weighted sum of:

```
heading_next = e_prev                       (inertia, weight 1)
             + noise                        (eta = 0.5)
             + w_dog * repel_from_dog       (only if dog within R_D = 12 m)
             + w_rep * repel_from_neighbors (only those within d_rep = 2 m)
             + w_att * mean_dir_to(n_att random of k nearest)
             + w_ali * mean_heading(n_ali random of those n_att)
```

with `k = 10, n_att = 5, n_ali = 1, w_dog = 1, w_rep = 2, w_att = 1.5,
w_ali = 1.3, v_sheep = 1 m/s, v_dog = 1.5 m/s`.

Design points worth stealing:

1. **Linear, distance-independent forces.** Every term is a unit vector times a
   constant weight. No falloff curves to tune.
2. **Topological, not metric, neighbours, and only a few of them.** Perceive the
   k=10 nearest; attract to 5 *random* ones; align to 1 *random* one of those. The
   random subsampling (re-rolled each step) is what gives realistic, non-rigid,
   non-oscillating group motion and keeps cost O(k) per sheep.
3. **Threat gates motion.** Sheep only move when the dog is within R_D; otherwise
   they graze in place. (We already do something like this.)
4. **Inertia term.** Heading is blended with the previous heading, so turns are
   smooth and information propagates through the group over seconds.
5. **Hard minimum spacing** `d_rep`, independent of the soft repulsion weight.
6. **Dog rule (drive/collect).** Dog moves straight at constant speed to
   `P_drive`, a point `l_drive` behind the flock barycentre such that
   dog -> barycentre -> target are collinear (so repulsion pushes the flock to
   the target). If any sheep strays more than `l_sep` from the barycentre, the dog
   instead targets a point behind *that sheep* relative to the barycentre
   ("collect"), then resumes driving. Slows to 0.05 v_D if within l_a of a sheep.

**Measured targets (Results, Fig. 2), useful as acceptance numbers.**

| Observable | Value |
|---|---|
| Cohesion C (mean radius) | 1.21 +/- 0.34 m (~1 body length) |
| Polarization P | 0.85 +/- 0.17, always > 0.6 |
| Elongation E (length/width along motion) | mode 0.8, i.e. *wider* than long |
| Sheep speed under pressure | ~1.3 m/s |
| Dog speed | ~1.5 m/s mean (peaks 2 m/s) = only ~1.15x the flock |
| Dog position | 1-4 m behind rear sheep, zig-zagging +/-2-6 m laterally |

**Qualitative findings that matter for feel:**

- Directional information flows **front -> back** even though the dog is behind.
  Front sheep (most reactive) initiate turns; others follow. No fixed leader is
  required; the model produces this from the rules above.
- Elongation < 1 comes from attraction weight > alignment weight. Raise
  `w_ali` relative to `w_att` for a longer, column-like mob; lower for a wide
  line.
- The *constant presence* of the pressure source is what creates the front->back
  hierarchy; without it you just get a diffusing cloud.
- Caveat from the authors: single flock, single dog; and they only studied the
  driven phase, not grazing -> threat onset. Don't over-fit the grazing side to
  this paper.

## 3. Recommendation: extract a pure flocking module, don't patch each sheep

Both sheep scripts should share one brain. Proposal:

```
scripts/flock/
  flock_params.gd      # Resource: k, n_att, n_ali, weights, radii, speeds
  flock_steering.gd    # static, no nodes: steer(...) -> desired heading
  flock_grid.gd        # uniform-grid spatial hash, rebuilt once per physics tick
  herding_dog_brain.gd # drive/collect target selection (paper's dog rule)
```

### `FlockSteering.steer(me, neighbors, threats, params, rng) -> Vector3`

Pure function over plain data (positions, headings), so it is unit-testable with
the existing headless harness pattern (`scripts/sim/harness/check_*.gd`) and
independent of `CharacterBody3D` vs `NavigationAgent3D`.

- Inputs: self pos + previous heading, the `k` nearest neighbour snapshots
  (from the grid), a list of threats (player/dog positions with their scare
  radius), terrain/edge hazards as extra additive vectors.
- Output: desired horizontal heading + a `speed_scale` (0 = graze, wander
  speed, flee speed).
- Sampling of `n_att`/`n_ali` neighbours is re-rolled on a **timer (~0.5-1 s
  per sheep, staggered)**, not every physics frame, otherwise 60 Hz noise
  becomes jitter. Between re-rolls reuse the chosen indices.

### Grid

One `FlockGrid` node (or autoload-lite on the world) rebuilds a hash of sheep
positions each physics tick; `OnFootSheep` asks it for k nearest. Removes the
per-sheep `get_nodes_in_group` scans. Cell size ~ `d_rep * 2`.

### Dog brain (out of scope for now)

`HerdingDogBrain.next_target(dog_pos, flock_positions, goal) -> Vector3` returns
`P_drive` or the collect point. Today only the player plays the dog, so this is
**optional phase 3**, but it directly enables: an NPC shepherd/dog that
penning sheep for the town sim, an auto-herd upgrade, or a "sheepdog" building
unit.

### Hooking into existing code

- `OnFootSheep._physics_process`: replace the `desired`/`_pick_wander_dir`/
  `_flee_direction`/`_separation` block with one `FlockSteering.steer` call.
  Keep `_react_step` (bark hop), `_avoid_water`, `penned` handling, and
  `_face_and_animate` untouched; they're orthogonal.
- `Sheep` (`entities/sheep.gd`): keep NavigationAgent3D for *pathing*, but pick
  its target as `global_position + steer(...) * lookahead` each re-plan instead
  of a random 3-12 m point. That lets the island sheep graze as a loose flock and
  still respect the navmesh. Resolve its remaining TODOs (night sleep, forest
  avoidance) as separate threat/hazard vectors fed to the same function rather
  than new bespoke code paths.
- Bark: already a threat event; model as a temporary `w_dog` boost +
  `R_D` extension instead of its own `_startled_left` branch.

## 4. Concrete tuning deltas for `on_foot_sheep.gd`

Even before the refactor, these are cheap and map directly to the paper:

1. While fleeing, add attraction to the mean of ~5 nearest mates and alignment
   to one nearest mate's velocity: `desired = away*1.0 + sep*2.0 + att*1.5 +
   ali*1.3`, normalized. Expect immediate polarization.
2. Use *nearest-k*, not global centroid, for wander cohesion (kills the
   "empty midpoint" artifact).
3. Cache neighbour list once per tick; drop the O(N^2) separation scan.
4. Add a velocity-heading inertia term (blend with previous heading ~0.5)
   before the `accel` clamp.
5. Add small heading noise (eta ~0.5 on unit vectors) re-rolled at ~1 Hz.
6. Match the paper's speed ratio. **Reviewed, no change:** the player's walk
   speeds are 3.5 / 5.0 and sprint 8.0 / 8.5 (`on_foot_player.gd`), and
   `flee_speed` is 5.5. So walking never catches a fleeing flock, but sprinting
   gains ~2.5-3 m/s, which reads as "run to herd, walk to keep pressure".
   That is a deliberate-feeling gap rather than the paper's 1.15x, so leave it
   as a tuning knob.

## 5. Acceptance harness

Add `scripts/sim/harness/check_flock_steering.gd` (headless, fixed seed):
place 14 sheep + scripted dog driving a straight line over 60 s of sim time and
assert, with tolerances:

- mean C in 0.8-1.8 m
- mean P >= 0.7 (paper 0.85; our rendering/accel will cost some)
- median E < 1
- no sheep further than `l_sep` from barycentre for > 5 s once the collect rule
  is on
- 1 sheep vs 14 vs 60 sheep per-tick cost stays flat-ish (grid works)

These are the paper's own observables, so regressions are measurable instead of
"looks off".

## 6. Phasing

1. **Phase 1 (this PR, done pending sign-off):** section 4 deltas inside `on_foot_sheep.gd` + the
   harness check. Biggest visible win, low risk.
2. **Phase 2:** extract `FlockSteering`/`FlockGrid`/`FlockParams`; port
   `OnFootSheep` onto it; port `Sheep` (island) with navmesh target picking.
3. **Phase 3:** `HerdingDogBrain` for NPC dogs/shepherds; tie into sheep_pen
   (sheepfold) and household sim.

## 7. Open questions

- Is the island `Sheep` expected to ever be *driven* by a dog, or only graze
  and sleep? Determines whether it needs the threat path at all in phase 2.
- Do we want one tunable `FlockParams` resource per species (cow/pig later) so
  this becomes a general herd-animal module?
- Player "dog" speed/scare radius numbers: need a pass against the 1.15x
  dog:sheep ratio before tuning weights.
