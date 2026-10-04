# Valley household economy experiment

Open `scenes/valley/river_valley.tscn` or choose **Single Valley Simulation** from the main menu for the graph. Both screens use the same five-town model within each run. The five authored sites each own a persistent `HESimulation`. Their household counts come from `ValleySeed.HOUSEHOLDS_PER_SETTLEMENT`; H1 acreage, opening stock and staffing scale with that count. The town profiles use different opening buffers and industry mixes to create local price differences.

The valley owns the clock. It advances every town once per day and resolves arrivals before that day's local market. Every three days, `ValleyEconomy` looks at the existing road and river edges. A staffed Trader can dispatch available production above the H1 seller reserve when the destination's blended current and recent price exceeds the source price plus edge costs. Edge and Trader capacity limit shipments. The buyer Trader pays at dispatch; the origin Trader pays the producer and earns the spread. At arrival, goods enter the destination Trader's inventory and can sell through its household market or supply a local business. Exports and imports appear in Trader transaction history with the other town's name.

Click a town, then **View household economy** to inspect its live H1 dashboard. **Valley** returns to the map. The valley clock and shipments continue while details are open; opening the town again shows the same economy. The map panel reports current stock and shipment counts. Pause, 1x, 10x and 100x controls sit below it.

In the single valley graph, click a node or choose a town from the picker, then press **View household economy** in the Valley tab. Its prices, shipment markers and town panel read the same live household economies. The large valleys graph remains on the older pooled simulation.

The household detail shows Pause, 1x, 10x and 100x buttons. When opened from a valley, they control the shared valley clock; the direct standalone household economy button controls its own clock.

The route chooser and price spread are deliberately simple. The five town economies retain H1 business rules and generated household composition; they do not reuse the older pooled `Simulation` inventory or workplace records. The standalone H1 dashboard still uses its original external Trader market.

Checks:

```powershell
..\Godot_v4.6.2-stable_win64_console.exe --headless --path . --script res://scripts/valley/harness/check_valley_economy.gd
..\Godot_v4.6.2-stable_win64_console.exe --headless --path . --script res://scripts/valley/harness/check_valley_detail.gd
..\Godot_v4.6.2-stable_win64_console.exe --headless --path . --script res://scripts/sim/harness/check_graph_view.gd
```
