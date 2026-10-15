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
| Cattle ranch | 2.0 | 375 | 187 | 150 |
| Sheep farm | 0.4 | 100 | 250 | 200 |

- 2.0 acres per cow is the pessimistic end of tame pasture (no fertiliser or
  improved forage); 0.4 per sheep keeps the 1:5 cow:sheep ratio.
- Cull target = floor(land / acres-per-head x 0.8). The 80% leaves room to grow
  between reviews and a margin for a bad year.
- The defaults land on the previous 150 / 200 targets, so the economy's
  timings (~900 days to first cull) are unchanged. Sheep winter fodder scales
  with the same ratio (0.45 -> 0.6 grain per head).
- Each ranch owns its land; the old shared 300-acre settlement pool is gone.

## Town view scale

Plots are drawn at a compressed scale, `UNITS2_PER_ACRE = 16` world units^2 per
acre (true scale is ~4,000), 1.4:1 wide. A 40-acre farm is about 30 x 21, a
375-acre ranch about 92 x 65. `HALF_EXTENT` is 160 and field/pasture
candidates are tried outermost first, so land spreads to the rim; a plot far
from any road gets a lane ("track") grown to its edge.

## Next (not done)

- Per-acre forage state, so herds move to growing grass.
- Scale the drawn herd cap to the pasture (currently 80 sheep / 40 cattle).
