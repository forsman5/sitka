# Sheep flocking

Source: Jadhav et al., "Collective responses of flocking sheep (Ovis aries) to a
herding dog (border collie)", *Communications Biology* 7:1543 (2024),
doi:10.1038/s42003-024-07245-8.

## Status

| Phase | State |
|---|---|
| 1. `on_foot_sheep.gd` flocking + acceptance harness | **Accepted, merged** |
| 2. Shared flocking module, port island `Sheep` | Not started |
| 3. Herding dog brain (drive/collect) | Out of scope for now |

## How it works (phase 1)

`scripts/on_foot/on_foot_sheep.gd` follows the paper's agent model. Each term is a
unit vector times a constant weight; none depend on distance. A fleeing sheep
steers the normalized sum of:

| Term | Weight export | Default |
|---|---|---|
| Away from threat | `w_dog` | 1.0 |
| Repulsion from mates inside `rep_distance` | `w_rep` | 2.0 |
| Attraction to `flock_n_att` random of the `flock_k` nearest mates | `w_att` | 1.5 |
| Alignment to `flock_n_ali` of those | `w_ali` | 1.3 |
| Previous heading (inertia) | `w_inertia` | 1.0 |
| Noise | `noise_strength` | 0.5 |

The neighbour subset and noise are re-rolled about once per `resample_interval`
per sheep (staggered), so 60 Hz noise doesn't turn into jitter. Neighbour data
comes from one per-physics-frame snapshot shared by all sheep. Calm wander
cohesion uses nearby mates rather than the global centroid.

Unchanged by design: bark startle hop, water avoidance, penning, animation.
Flee speed (5.5 at full, eased down toward the scare edge by
`_flee_speed_factor`) sits between player walk (3.5/5.0) and sprint (8.0/8.5):
walking keeps pressure, sprinting catches up. That's a tuning knob, not the
paper's 1.15x. Figures below are with that distance scaling merged.

## Acceptance check

`scripts/sim/harness/check_flock_steering.gd` drives 14 sheep with a scripted dog
for 60 s (fixed seed, headless):

```
godot --headless --path . --script res://scripts/sim/harness/check_flock_steering.gd
```

| | Paper | Before | After | Pass bound |
|---|---|---|---|---|
| Cohesion C (mean radius) | 1.21 m | 6.00 m | 1.34 m | <= 4.0 |
| Polarization P | 0.85 | 0.35 | 0.93 | >= 0.7 |
| Median elongation E | ~0.8 | 1.16 | 0.62 | < 1.0 |
| Distance driven in 60 s | n/a | 19 m | 80 m | > 50 |

Limits: runs without terrain (doesn't exercise `_avoid_water`); neighbour scan is
O(N) per sheep once per second, fine for tens of sheep.

## Remaining work

**Phase 2: shared module.** Extract the steering into a node-free `FlockSteering`
(plus a uniform spatial grid and a params resource) used by both sheep types.
Port the island `Sheep` (`scripts/entities/sheep.gd`, currently a random-wander
stub on NavigationAgent3D) by keeping the agent for pathing and picking its
target from the steering output each re-plan. Its sleep/forest-avoidance TODOs
become extra additive vectors rather than separate code paths. Open questions:
does the island sheep ever get driven by a dog, and do we want per-species params
for other herd animals.

**Phase 3: herding dog brain (deferred).** Paper's dog rule: drive from a point
behind the flock barycentre, collinear with the goal; if a sheep strays beyond
`l_sep`, collect it first. Enables NPC dogs/shepherds feeding the pen and
household sim.
