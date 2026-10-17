# PR #19 handoff: neighbor Trader relay

Implement this on `feat/valley-household-integration` for PR #19. The Single Valley owns one `HESimulation` per town in `scripts/valley/valley_economy.gd`. Keep standalone Household Economy behavior intact. Large Valleys still uses the pooled model; do not migrate it as part of this cut.

## User intent

This is an 880s relationship trade network. Traders know neighboring Traders, pass bids and offers through those relationships, hold goods while arranging onward sales, and take a margin for their risk and work. The graph is small enough (eventually roughly 10–50 towns) that simple route evaluation is fine internally, but towns should not behave as if they can see an electronic valley-wide clearing house.

The immediate objective is to make charcoal flow from Oakmere to households outside Oakmere, especially towns without local fuel. Stone from Ironbank should be able to fill small construction reserves in other towns before Staithe's Port takes residual surplus. Measure the change instead of merely adding routes.

## Current failure, measured at HEAD `01ed885`

- At day 360, only 50 of 798 households burned charcoal, all in Oakmere. At day 180, 61 households burned it, also only in Oakmere. Aldford imported 70.3 charcoal and Ironbank 76.2 during days 1–30; neither imported more during the rest of the year. High Fell and Staithe received none.
- At day 180, Oakmere charcoal trade quote was 0.95, Aldford 0.95, Ironbank 1.43, High Fell and Staithe 3.80. Oakmere has direct edges only to Aldford and Ironbank. The best direct gap, Ironbank, was about `1.43 - 0.95 - 0.10 = 0.38`, below `MIN_PRICE_GAP = 0.5`; Aldford's gap was negative.
- `_satisfier_cascade` in `he_simulation.gd` excludes charcoal when its local offer is zero. Households still need heat, but cannot express a charcoal-specific funded bid when no charcoal is on offer. Timber is the baseline heat good. A counterfactual charcoal bid must account for its fourfold heat value, timber substitution, household budgets, and expected price; do not blindly turn all heat need into demand for both goods.
- `get_valley_trade_offer` requires a local seller. A Trader holding imported charcoal cannot offer it onward. `ValleyEconomy._dispatch_shipments` compares only endpoints of one edge and never propagates a downstream buyer's bid to an upstream neighbor.
- Ironbank's Quarry currently sends stone to Staithe's Port; the year-long run dispatched 165 stone shipments totaling about 1,468 units, but other towns have no routine local stone demand. The Port is a useful residual buyer, not the first destination for a town's needed construction stock.
- Baseline year-long check: 427 shipments delivered, 10 in transit, 864 Trader transactions. High Fell's Woodlot closes around day 250; that predates this task.

## Requested implementation

1. Give towns a truthful import interest for goods with no current local offer. For charcoal, derive willingness to buy from funded household heat demand at the proposed delivered price and the available timber alternative. Demand should be bounded by likely use and on-hand plus inbound stock. Stone may use a small explicit construction reserve target, ideally tied to a tenement build/upgrade quantity, because households do not consume stone daily.
2. Pass bounded buy interest and resale offers across **neighbor** Trader relationships. A Trader may relay a downstream bid upstream, subtracting edge travel/toll/risk and its own required margin. Keep information local and allow a small quote lag or expiry; avoid instant valley-wide knowledge in the economic state. An implementation can use a graph algorithm under the hood to update neighbor quotes, provided each Trader's action follows received neighboring quotes.
3. Let a Trader offer imported stock onward and account for its purchase, sale, and held inventory. Prevent double spending and duplicate shipments by counting stock already held, committed, or in transit. Carry shipments edge by edge or as an itinerary with an explicit intermediate Trader handoff; intermediate Traders must get their negotiated margin and the good must not teleport.
4. Retune or remove the fixed `MIN_PRICE_GAP = 0.5` only after the bid/relay path exists. Compare expected net profit on a practical shipment, including edge costs, instead of applying one absolute per-unit cutoff to every good. Avoid flooding the graph with tiny repeated shipments; use a stock target, reorder point, or sensible lot threshold for charcoal and stone.
5. Preserve current grain, timber, ore, iron, Quarry, and Port behavior, town detail navigation, pause/timer behavior, and the standalone Household Economy trade mode. Keep the valley state headless and UI-independent.

## Verification and report

- Extend `scripts/valley/harness/check_valley_economy.gd` and/or `measure_trade_timeline.gd` with deterministic measurements: charcoal shipments by leg and destination, charcoal consumed by households by town, Trader balances/failures, stone inventory and shipments by town, and total deliveries.
- Show a clear increase over the baseline: charcoal shipments continue after day 30 and at least one non-Oakmere town has meaningful household charcoal use by day 180 and day 360. Aim for High Fell or Staithe, which require a relay. Explain if route or economics block either. If stone is stocked outside Staithe, show it is a bounded reserve rather than unlimited accumulation.
- Run the headless valley economy, town detail, Household Economy dashboard, and Quarry checks. Do not accept widespread Trader or Quarry closures, money/stock creation, or a collapse of established grain/ore routes as the cost of more charcoal.
- Push the completed branch to PR #19 and report concrete before/after counts, failures, and remaining limits. Godot executable: `C:/Users/jrfor/OneDrive/Desktop/gamedev/Godot_v4.6.2-stable_win64_console.exe`.

## Implemented in this cut

- Household heat demand now gives a bounded charcoal import interest even with no charcoal in town. It considers timber's price and whether timber is actually available. Trader-held and incoming goods reduce the requested quantity.
- A Trader passes a neighboring buyer's quote to an adjacent Trader, buys the lot, holds it as earmarked stock, and forwards it after arrival. The onward quote includes the purchase cost and the next edge's cost, so the middle Trader cannot resell below its cost. Earmarked stock is unavailable to households, workshops, and the Port. Source and destination ledgers record each leg.
- Stone has a 20-unit repair stock target in towns without a Quarry. This is deliberately smaller than a tenement's 100-unit construction order; the current valley towns have no regular stone consumer or Government Warehouse order. The Quarry town does not bid for its own output.
- The fixed 0.5-per-unit gap is replaced by a 0.04-per-unit Trader margin after modeled edge costs, plus a two-unit minimum lot for charcoal and stone. The valley Trader keeps seven days of wages as a cash reserve while buying short-lived contracts. These are interim economic values, not a cargo weight model.
- Staithe's Port can bid above its usual half-price quote for a local producer when the producer's cost floor rises, up to a price that leaves the Port at least 10% of its outside quote. This prevents the integrated charcoal/timber flow from stranding the Bloomery's iron stock and closing the Bloomery.

The current quote pass reaches one intermediary (two shipment legs). It does not yet carry a bid across an arbitrary-length 10–50-town chain or model individual Trader relationships, quote aging, and credit contracts. Those are the next scale cut. High Fell's pre-existing Woodlot failure remains a separate town-configuration/economics issue.

## Measured result

The 360-day valley check now reports 544 delivered shipments, 11 in transit, and 1,099 Trader transactions, compared with 427, 10, and 864 before this change. By day 360, households had consumed 92.6 charcoal in High Fell, 260.4 in Staithe, and 149.3 in Ironbank; the baseline had no sustained use outside Oakmere. The relay carried 126.6 charcoal from Oakmere to Aldford and forwarded 92.6 to High Fell. Ironbank forwarded 258.5 charcoal to Staithe. Ironbank shipped 1,468 stone to Staithe, which forwarded 20 to Aldford's bounded reserve. All five Traders and the Staithe Bloomery and Ironbank Quarry remained operating in this run. Aldford's households still did not use charcoal; its Trader acted as a relay.
