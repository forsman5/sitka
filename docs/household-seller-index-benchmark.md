# Household seller index benchmark

Measured on Godot 4.6.2 stable, headless debug, Windows, comparing clean `origin/master` (`252e31d`) with the seller-index branch. These measurements are directional; the host was not isolated from other work.

## Lookup and tick probe

`scripts/sim/harness/measure_household_seller_index.gd` performs 20,000 repeated lookups for a commodity with no seller, then measures seven fresh one-day ticks. It starts from the small-village scenario and adds inert warehouses with no stock, staff, or orders. This increases catalog size without adding sellers or changing demand.

| Catalog businesses | Extra warehouses | Master lookup total | Indexed lookup total | Master tick median | Indexed tick median |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 10 | 0 | 166.662 ms (8.3331 us each) | 15.333 ms (0.7667 us each) | 5.696 ms | 3.953 ms |
| 110 | 100 | 1,115.715 ms (55.7858 us each) | 15.622 ms (0.7811 us each) | 17.413 ms | 7.342 ms |
| 510 | 500 | 6,678.094 ms (333.9047 us each) | 15.230 ms (0.7615 us each) | 76.956 ms | 23.335 ms |

At 510 businesses, the no-seller lookup total fell from 6.68 seconds to 15.23 milliseconds. The tick probe also improved, though adding inert businesses still raises the total tick cost because other simulation work iterates the catalog.

## Valley run

`scripts/sim/harness/measure_valley_30_day_perf.gd` creates a fresh five-town ValleyEconomy for each run and measures 30 ticks, with setup excluded. It performs one warmup run and records five runs.

| Revision | Median | Mean | Range | Median per tick |
| --- | ---: | ---: | ---: | ---: |
| Clean master | 3,340.84 ms | 3,585.82 ms | 3,205.02-4,713.61 ms | 111.361 ms |
| Seller index | 3,503.53 ms | 3,572.31 ms | 3,423.30-3,758.42 ms | 116.784 ms |

The medians differ by about 4.9%, while the master sample has a wide range. This run does not show a clear valley-wide speedup; the benefit is concentrated in repeated seller lookups as the business catalog grows.

## Acceptance checks

The focused `check_seller_index.gd` passes. It compares every commodity and settlement against an independent copy of the pre-index scan, across 90 small-village days, seller additions and removals, seller ordering, live meat stock changes, two settlements, and all five ValleyEconomy towns.

The broad `run_household_economy.gd`, `check_valley_economy.gd`, and `check_house_maintenance.gd` fail on both clean master and the seller-index branch. The household harness reports the same existing failures on both revisions: oversupplied Woodlot staffing, life-cycle worker capacity, static herd cull timing, herd collateral, home butchering when there is no outlet, and intermittent meat demand. The valley harness reports the same failure on both revisions: the Oakmere-Aldford-High Fell Trader relay does not deliver household charcoal. The maintenance harness reports the same upkeep and overdue-house failures on both revisions. These failures are recorded here because the harnesses do not currently pass on the comparison baseline.
