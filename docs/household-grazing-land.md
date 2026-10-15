# Grazing land per head, and how land shapes the town

Research behind `CATTLE_LAND_PER_HEAD`, `SHEEP_LAND_PER_HEAD`,
`HERD_STOCKING_UTILIZATION` and `DEFAULT_RANCH_LAND_ACRES` in
`scripts/sim/household_economy/he_simulation.gd`.

## What the sources say

- **Animal unit (AU):** one 1,000 lb cow with a calf. Stocking rate is acres
  per AU (or AUMs per acre); capacity = acres / acres-per-AU / months grazed.
  ([NDSU](https://ndsu.edu/agriculture/sites/default/files/2022-10/Generalized_Average_Stocking_Rates.pdf),
  [Wyoming Extension B-1320](https://www.wyoextension.org/agpubs/pubs/B-1320_AUMs-for-web.pdf))
- **Cattle:** about 1.2 acres per AU-year on good improved pasture
  (orchardgrass/white clover, Penn State via
  [Lancaster Farming](https://www.lancasterfarming.com/farming-news/livestock/is-your-livestock-stocking-rate-right-for-your-farm/article_d6a76929-5bff-53a9-89c7-00741a9902b3.html));
  1.5-2 acres per pair is the usual commercial rule of thumb
  ([Farmbrite](https://farmbrite.com/post/how-many-cows-can-i-keep-per-acre));
  range and drought years need several times that, and a drought year should
  cut capacity 20-30%.
- **Sheep:** a mature sheep is about 0.2 AU (five per cow); an ewe with a lamb
  about 0.27 ([Colorado State](https://sites.warnercnr.colostate.edu/larryr/carrying-capacity-stocking-rate-feedback)).
- **Medieval/early-modern:** no clean acres-per-animal figure turned up.
  Manor accounts give head counts (e.g. 12-18 cows and 130-510 sheep on one
  demesne) and later stints (12 cattle or 40 sheep per yardland, Aston and
  Cote), which are not pasture-area figures, so they were not used.

## What the sim uses

| | acres / head | default land | carries | cull target (80%) |
|---|---|---|---|---|
| Cattle ranch | 3.0 | 600 | 200 | 150 |
| Sheep farm | 0.6 | 160 | 266 | 200 |

- 3.0 acres per cow is the thin end of the 1.2-3 range: unimproved pasture, no
  fertiliser, with the ranch's own hay meadow, rest rotation and yards counted
  in. 0.6 per sheep keeps the 1:5 cow:sheep ratio (a ewe with lamb is ~0.27 AU).
- Cull target = round(land / acres-per-head x 0.75). The 75% leaves room to grow
  between reviews and a margin for a bad year.
- The defaults land on the earlier 150 / 200 targets, so the economy's
  timings (~900 days to first cull) are unchanged, and sheep winter fodder
  (0.6 grain per head) is the same.
- Each ranch owns its land; the old shared 300-acre settlement pool is gone.

## Farm and woodlot

The sim's farm and woodlot are abstract: a 40-acre farm used to feed ~200
people (0.2 acres each against ~1-2 historically), a 50-acre woodlot ~490
(0.1 against ~2). Rather than re-balance, acreage is scaled 8x
(farm 320, woodlot 400 -- about 1.5 acres of grain and 2 of wood per person for
the large preset's ~190 people) and labor and yield per acre divided by 8, so
every total (staffing ceiling 50, 1800 grain per field-cycle) is unchanged.
One size for every preset for now; scaling acres by town size is future work.

## Town view scale

Plots are drawn at a compressed scale, `UNITS2_PER_ACRE = 12` world units^2 per
acre (true scale is ~4,000), 1.4:1 wide: the 320-acre farm is about 73 x 52,
the 400-acre woodlot 83 x 59, a 600-acre cattle ranch 101 x 72. The farm shows
one block of furrows per field (4); a woodlot's trees are one per 70 u^2 of
plot. `HALF_EXTENT` is 160 and field/pasture candidates are tried outermost
first, so land spreads to the rim; a plot far from any road gets a lane
("track") grown to its edge.

## Next (not done)

- Per-acre forage state, so herds move to growing grass.
- Scale acres to town size per preset (and from population in a save).
