# Household economy: house maintenance

## What it is

Every house needs upkeep. Neglected homes cost their households morale. Wells and river intakes have their own yearly servicing (`household-water.md`), paid by the government because they are public; this covers dwellings.

## Direction (revised): households pay, on the market

**As built below, the government pays**: staff deliver timber (and stone for tenements) out of the Government Warehouse. Two things have changed since:

- **Stone houses merged** (#116, `HEHouse.is_stone`, +8% morale). They are upgrades of plain houses. A stone house now needs stone to keep up (0.2 timber and 0.4 stone a year, `HEHouse.STONE_UPKEEP_*`), so it falls behind when the warehouse has no stone; but at these sizes the cost is negligible, and nothing in the sim makes a family want one or be able to afford one.
- **Wages now differ by employer** (productivity pay, `household-wage-model-plan.md`), so households have very different disposable income. Measured numbers are in `household-housing-choice-plan.md`: median surplus 650-1,050 g/yr, a plain house's upkeep is about 1 g/yr (0.1% of that), and the quarry crew that digs the stone is among the poorest.

So the direction is:

1. **The household buys the upkeep goods itself.** Timber (and stone, for a stone house or its share of a tenement) is bought on the market like any other good and used up when the repair is done. The warehouse stops paying for dwellings, which also frees its timber for construction. Wells and river intakes stay with the government.
2. **Government staff become the labour**, not the supplier: the existing round of visits and town-view errands stays, but a visit only repairs a house whose household holds the goods for that slice (otherwise the backlog grows and, as built, the household loses morale). Paying the crew a wage for the work remains open.
3. **Upkeep gets a real size**, so it is a choice. Starting point (tune with a sweep): plain house 1 timber/yr; stone house 4 timber + 10 stone/yr (about 56 g/yr at 4 g a unit, roughly 9% of the large village's median surplus); tenement split over its households. A stone house carries stone upkeep (as built, 0.4 stone a year), and while it is in arrears its +8% morale bonus is lost (not yet built).
4. **First household demand for stone.** Stone has no household buyer today (the quarry lives on export), so market-paid upkeep is the first.
5. **Why timber upkeep is not a `HENeed`.** `HENeeds.for_commodity` maps a good to one need, and timber is already heat's; a house also needs timber AND stone together, not either. Add an upkeep reserve to `_desired_purchase` (like the heat buffer) instead, valued at base prices so affordability does not flip with the 0.25-4.0 timber price swing.

What to build next, who lives in the stone houses, and what else pulls richer families into them: `household-housing-choice-plan.md`.

## Sim (as built)

- **Cost.** A house takes 0.2 timber a year. A stone house takes 0.2 timber and 0.4 stone. A tenement takes 0.8 timber and 0.8 stone (`HEHouse.upkeep_timber()` / `upkeep_stone()`).
- **Backlog.** `HEHouse.neglect_years` grows 1/365 a day. First visits are staggered by dwelling id.
- **Deliveries.** `HESimulation._run_house_maintenance` runs daily after the water pass. Each government worker household can serve `HOUSE_VISITS_PER_STAFF` (4) houses a day. A house is only visited once a slice (`HOUSE_VISIT_YEARS`, a quarter year) is owed, and each visit pays one slice. Houses are visited round robin from just after the last one served (`_house_cursor`), so a short warehouse spreads its timber over the whole town instead of finishing one house.
- **Shortage.** With no staff, no warehouse or too little stock, nothing is paid and the backlog grows.
- **Morale.** `HEHousehold.home_overdue_years` is the backlog beyond one visit interval. It costs 4 points of morale per year (`MORALE_DISREPAIR_PER_YEAR`), capped at 20, shown as "Home in disrepair". A healthy town carries no penalty. Paying the backlog down eases it.
- **Reports.** `get_house_maintenance_summary(settlement_id)`; `get_housing_report` adds `maintenance_deliveries` (dwelling ids served today); `get_dwelling_reports` adds `neglect_years`.

## Town view

Government and warehouse workers whose house deliveries fall on a day leave their workplace, walk to each house they were assigned (deliveries are dealt out round robin over the staff by household id), stand at the door `DELIVER_HOURS` (0.25), and walk back. Houses that do not fit in the working day are skipped. The person window shows "Carrying timber to a house" / "Repairing a house". `HEVillagerSchedule._push_errands`, `HEVillagers.sync(..., errand_sites)`.

## Checks and open items

- `scripts/sim/harness/check_house_maintenance.gd`: costs, penalty size and cap, a healthy town, round-robin fairness, shortage and recovery, and the errand round in the schedule.
- Open: a dashboard line for the backlog; a visible marker on houses in disrepair; stone and other upkeep for non-house buildings; paying for the work (wages) rather than only materials.
