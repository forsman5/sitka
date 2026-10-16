# Household economy: house maintenance

## What it is

Every house needs upkeep, paid by the town government in timber from the Government Warehouse. Neglected homes cost their households morale. Wells and river intakes have their own yearly servicing (`household-water.md`); this covers dwellings.

## Sim

- **Cost.** A house takes 0.2 timber a year. A tenement takes 0.8 timber and 0.8 stone (`HEHouse.upkeep_timber()` / `upkeep_stone()`).
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
