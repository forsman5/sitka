# Household economy: Goat Farm

Opt-in herd (`type_key "goat_farm"`, `HEBusiness.Species.GOAT`, good `Commodity.Type.GOAT`). Towns get one via the Create menu, the Custom roster, or a spec's `"herds": ["goat_farm"]`; no preset has one by default.

## Numbers (sheep is the anchor)

| | Goat | Sheep | Basis |
|---|---|---|---|
| Land per head (acres) | 0.5 | 0.6 | extension rule: ~6 goats per cow unit vs 5 sheep |
| Default farm (acres) / cull target | 120 / 180 | 160 / 200 | capacity 240 head, 0.75 utilization |
| Growth / 90 days | 0.11 | 0.10 | twinning, more kids per doe |
| Loss fed / neglected | 0.035 / 0.17 | 0.03 / 0.20 | kids fragile, goats cope on poor browse |
| Labor per head per day | 1/110 | 1/120 | fencing, kidding, hooves |
| Winter fodder (grain/head) | 0.5 | 0.6 | same land-ratio rule as sheep |
| Butcher: worker-days / meat / leather | 0.4 / 10 / 0.8 | 0.5 / 12 / 1.0 | smaller, leaner carcass |
| Export price per head | 8.0 | 3.0 | see below |

Research caveat: only the stocking rate and dressing percentage were source-confirmed; kidding rate, mortality and hardiness comparisons are general husbandry knowledge. Butcher yields are placeholders like the other species'.

## Why 8.0, not sheep's 3.0

Sheep earn mostly from wool. A goat herd has no fibre or milk in the sim, so its only income is culled head. At ~2.7 the farm could not cover a wage; at 8.0 a farm in the Mining village reaches its cull target by day ~360, culls ~37 head per 90 days, and its balance turns positive. Revisit if goats gain a byproduct.

## Visuals

The Quaternius Farm Animals pack has no goat, so the town view uses its Llama scaled to goat length (`he_livestock.gd`). Swap the `"Goat"` entry's model when a real one turns up.

## Follow-ups

- Milk and cheese (the natural goat-only product), or mohair/cashmere as a small passive yield.
- A Hunter (wild deer herd): same herd loop with huge acreage, no fodder, and crew meaning kills rather than husbandry.
