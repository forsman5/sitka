# Household economy: who lives in which house (proposal)

Status: **proposal and measurements only, nothing built.** Follows `household-maintenance.md` (upkeep paid by households on the market) and the stone houses merged in #116.

## Today

- **Houses are assigned by id, not by choice.** `HESimulation._assign_dwellings`: sticky for life; unhoused households, ascending id, take the lowest-id house with room (innermost first). Nothing considers money, upkeep or distance, so a stone house goes to whoever has the lowest id.
- **Job proximity is on the hiring side.** `_nearest_available_index` (weekly hiring) gives a business the unemployed household that lives nearest to it, using `position_lookup` (the town layout). Houses never move, so this only changes who is hired, not where anyone lives.
- **A stone house is +8% morale** (`HEHouse.STONE_MORALE_BONUS`) and costs 40 g + 50 timber + 120 stone to upgrade. Its upkeep is that of a plain house.

## Measurements

Throwaway script, one seed (7), day 365, income averaged over days 245-365; surplus = wage x workers - basket cost (`basket_cost_per_person()` x headcount). Prices at the time: timber 4.0, stone 4.0.

| Preset | Households | Bottom 10% | Median | Top 10% | Largest (one Trader household) |
|---|---|---|---|---|---|
| Large village | 84 | 138 g/yr | 654 g/yr | 1,815 g/yr | 40,585 g/yr (balance 19k) |
| Mining village | 46 | 581 g/yr | 1,057 g/yr | 1,956 g/yr | 9,722 g/yr (balance 9k) |
| Small village | 34 | -614 g/yr | -234 g/yr | -190 g/yr | -117 g/yr |

Mean surplus a day by employer, large village: bloomery 6.2, charcoal burner 2.6, farm 2.4, woodlot 2.3, toolsmith 1.4, quarry 0.4, butcher -0.1.

What this says:

1. **Disposable income is real but uneven** in the large and mining villages, and it follows the employer. The quarry crew who dig the stone are among the poorest; bloomery families are the richest ordinary ones.
2. **The small village has no slack at all** on this seed (the median household runs a deficit), so no stone houses should appear there until the economy grows. A rule that gates stone on affordability gives that for free.
3. **Today's upkeep cannot bind**: 0.2 timber a year is 0.8 g at timber 4.0, about 0.1% of the large village's median surplus. At 56 g/yr a stone house would be about 9% of the large village's median surplus and 5% of the mining village's, which is a real but affordable choice for the upper half and out of reach for the bottom quarter.
4. **One-household outliers**: the Trader's household earns 10-60x the median and holds a balance of 9-19k against a median of a few hundred. A rule that ranks by balance will put it first every time, which is fine for one stone house, but it shows why rankings should use income as well as savings.

## Proposed direction

### A. Make upkeep matter (in `household-maintenance.md`)

Households buy the upkeep goods on the market; stone houses carry stone upkeep; arrears cost morale and the stone bonus.

### B. A housing review that considers affordability and distance

Every `HOUSING_REVIEW_DAYS` (90) per settlement, in `_reconcile_housing` after the normal pass:

1. **Budget.** Each household's housing budget is a share (10%) of its trailing surplus (a smoothed income minus basket cost; `HEHousehold` needs an income average, it has none today).
2. **Eligible for stone** if budget covers the house's upkeep at base prices AND balance is at least a buffer (60 days of basket plus a year of upkeep).
3. **Match.** Eligible households, richest first (by income, then balance, so the Trader's pile does not dominate), take free stone houses; among equals the household whose workplace is nearest wins (job proximity, via `position_lookup`), then lowest id.
4. **Hysteresis against churn.** Move up only at 1.25x the upkeep; move down only after two consecutive reviews of arrears. At most 2 moves per review per 100 households. Outside a review assignment stays sticky, as today.
5. **Moves happen at the tick**, when everyone is indoors, so the town view replans without a visible jump. Hiring proximity then sees the new home (`dwelling_id` is the only link).
6. **The vacated house** returns to the pool; unhoused households still take the lowest-id free house.

### C. Other pulls towards stone (beyond the morale bonus), best first

1. **Heat.** A stone house keeps heat: say 25% less heating demand for its household. That is a saving in goods that scales with household size and the cold season, about 150 g/yr for four people heating all year at timber 4.0 (about 10 at 0.25). It makes stone worth having for money, not only morale, and is cheap to build (`HENeed` consumption scaled by a house factor).
2. **Households pay for their own upgrade.** A household above a savings threshold petitions the government to upgrade its house and pays the gold plus buys the stone and timber on the market. This turns pooled cash into demand for stone and timber (the quarry crews' wages) instead of treasury spending, and answers the "income has nowhere to go" problem from `household-spending-plan.md`. Larger change: needs a petition queue, and the government stays the builder.
3. **Housing as a comfort good** in the affluence frame (`_household_affluence`), next to meat: the same 0..1 affluence that already drives meat preference decides who tries for a stone house first. Cheap, but morale already tops out at 125%, so the pull is weak for households already near the cap.
4. **Fire** (a wooden house can burn; stone cannot): a real downside for wood that scales with what a household owns. Needs an event system; defer.

### Recommended order

A, then B with C1, then C2. Gate every step with: stone houses held by upper-half incomes, moves per year (churn), households in arrears, stone price and quarry solvency, employment, and the usual `run_household_economy.gd` assertions.

## Risks

- **Timber price swings 0.25-4.0** between presets; value upkeep at base prices (as affluence does) so a cheap-timber month does not flip who is eligible.
- **Stone is thin**: one quarry, export-driven. The first household buyers will move its price; watch quarry solvency (`check_quarry.gd`).
- **Moves interact with hiring**: employers hire the nearest unemployed household, so moving homes reorders who gets jobs. Keep moves rare.
- **Tenements** share one house between four households; each pays a share, and arrears belong to the house.
- **One seed** here. Re-run `measure_stratification.gd`-style sweeps (3 seeds, 3 presets) before fixing any constant.

## Questions for you

1. Should the government crew be paid a wage for the repair work (a treasury cost that sizes the public cost of housing), or stay unpaid labour?
2. Is "richest first" the right priority for stone houses, or should a family with more children or a longer commute outrank a richer one?
3. Do you want C2 (households pay for their own stone upgrade) in the first pass, or after the review exists?
