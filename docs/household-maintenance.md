# Household economy: house maintenance

## What it is

Every lived-in house needs upkeep, and the **households living there pay for it, on the market**. Government staff do the repair work. Neglected homes cost their households morale. Wells and river intakes have their own yearly servicing (`household-water.md`), paid by the government because they are public; this covers dwellings.

Why households and not the government: stone houses (#116) and wages that differ by employer (`household-wage-model-plan.md`) mean households have very different means. Measured numbers are in `household-housing-choice-plan.md`: median surplus 650-1,050 g/yr. With the government paying, a house's upkeep was about 1 g/yr (0.1% of that) and stone had no household buyer at all, only the Trader's exports.

## Sim

- **Cost** (yearly goods, `HEHouse`): plain house 1 timber; stone house 4 timber + 10 stone (about 56 g at 4 g a unit, roughly 9% of the large village's median surplus); tenement 4 timber + 4 stone, split between its households. A household's share is `HEHousehold.home_upkeep_timber` / `home_upkeep_stone`, set by `_reconcile_housing`.
- **Households buy the goods.** `_desired_purchase` asks for one slice (`HEHouse.UPKEEP_SLICE_YEARS`, a quarter year) of the household's share on top of whatever else it buys the good for, so timber is bought alongside heat fuel and stone appears in the household clearing order (`_market_clearing_order`) once any household has a stone bill. It is a normal market request: limited by the household's balance, shown in the market's household demand and traded quantity, and moving the price. Sellers keep stock back for it (`_settlement_daily_demand`). A town with no stone house leaves the stone market to business and export, as before.
- **Staff do the repair.** `_run_house_maintenance` runs daily after the water pass. Each government worker household (government or warehouse) can serve `HOUSE_VISITS_PER_STAFF` (4) houses a day. A house is visited once a slice is owed (`HOUSE_VISIT_YEARS`, a quarter year), round robin from just after the last one served (`_house_cursor`), and only if every household living there holds its slice. The goods are taken from the households' stock and booked as consumed in the daily record, so stock conservation holds. The warehouse is not involved.
- **Backlog.** `HEHouse.neglect_years` grows 1/365 a day while the house is lived in (an empty house owes nothing until someone moves in). First visits are staggered by dwelling id.
- **Shortage.** If a household cannot afford or cannot find the goods (poor, or no stone for sale), the visit is skipped and the backlog grows. Staff are not the limit unless there are none.
- **Morale.** `HEHousehold.home_overdue_years` is the backlog beyond one visit interval. It costs 4 points of morale per year (`MORALE_DISREPAIR_PER_YEAR`), capped at 20, shown as "Home in disrepair", and while it is above zero a stone house's +8% "Stone house" bonus is lost. A healthy town carries neither.
- **Daily record.** `record["maintenance"][settlement_id]` = `{visits, timber_used, stone_used, overdue_houses, backlog_years, households_overdue, stone_bonus_lost}`, which the Housing tab's upkeep charts read (`household-housing.md`).
- **Reports.** `get_house_maintenance_summary(settlement_id)`; `get_housing_report` adds `maintenance_deliveries` (dwelling ids served today); `get_dwelling_reports` adds `neglect_years`.
- **Why not a `HENeed`.** `HENeeds.for_commodity` maps a good to one need, and timber is already heat's; a stone house needs timber AND stone together. So upkeep is a reserve added to the purchase target, like the heat buffer.
- **Also fixed here:** water servicing (#113) and house repairs now book the goods they use as consumed, which the stock-conservation check needs.

## Town view

Government and warehouse workers whose house deliveries fall on a day leave their workplace, walk to each house they were assigned (deliveries are dealt out round robin over the staff by household id), stand at the door `DELIVER_HOURS` (0.25), and walk back. Houses that do not fit in the working day are skipped. The person window shows "Carrying timber to a house" / "Repairing a house". `HEVillagerSchedule._push_errands`, `HEVillagers.sync(..., errand_sites)`.

## Checks and open items

- `scripts/sim/harness/check_house_maintenance.gd`: costs and shares, penalty size and cap, the stone bonus lost in arrears, a healthy town buying timber without touching the warehouse, six stone houses putting stone on the market, a stone house with no stone to buy falling behind and recovering, every lived-in house being visited, and the errand round in the schedule.
- Open: the costs are a first guess (tune with a 3-seed sweep, see the plan doc); who gets the stone houses (`household-housing-choice-plan.md`); a dashboard line for the backlog; a visible marker on houses in disrepair; paying the crew a wage for the work; upkeep for non-house buildings.
