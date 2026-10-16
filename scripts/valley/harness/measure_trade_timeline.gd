extends SceneTree

## Thirty-day shipment counts and market snapshots for the deterministic
## Single Valley seed. Run headlessly after trade or starting-town changes.

const ValleyEconomy = preload("res://scripts/valley/valley_economy.gd")
const ValleySeed = preload("res://scripts/sim/data/valley_seed.gd")
const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")
const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var valley := ValleyEconomy.new()
	for block in 12:
		var before := valley.delivered_total + valley.shipments.size()
		valley.advance_ticks(30)
		var counts := {}
		for town_id in valley.towns:
			for trade in valley.towns[town_id].get_trader_transactions(HEScenarioSeeds.TRADER_BUSINESS_ID, 30):
				if trade.get("direction") != "export" or int(trade.get("day", 0)) <= block * 30:
					continue
				var key := "%s %s>%s" % [trade["commodity"], valley.TOWN_NAMES[town_id], trade["route"]]
				counts[key] = counts.get(key, 0) + 1
		var details := []
		for key in counts:
			details.append("%s:%d" % [key, counts[key]])
		details.sort()
		print("DAYS %d-%d: dispatched %d, %s" % [block * 30 + 1, valley.day, valley.delivered_total + valley.shipments.size() - before, ", ".join(details)])
		if block in [1, 5, 9, 11]:
			for good in [Commodity.Type.GRAIN, Commodity.Type.TIMBER, Commodity.Type.CHARCOAL, Commodity.Type.IRON]:
				var rows := []
				for town_id in valley.towns:
					var town = valley.towns[town_id]
					var offer = town.get_valley_trade_offer(good)
					var market_price: float = town.get_valley_market_prices().get(Commodity.name_of(good), 0.0)
					rows.append("%s p%.2f/ref%.2f/of%.1f%s" % [valley.TOWN_NAMES[town_id], market_price, town.get_valley_trade_price(good), offer["quantity"], " CAP" if market_price >= HESimulation.BASE_PRICE.get(good, INF) * HESimulation.PRICE_MULTIPLIER_MAX - 0.001 else ""])
				print("  %s: %s" % [Commodity.name_of(good), ", ".join(rows)])
	for town_id in valley.towns:
		var town = valley.towns[town_id]
		var trader = town.businesses.get(HEScenarioSeeds.TRADER_BUSINESS_ID)
		print("TOWN %s trader_balance=%.1f trader_workers=%d" % [valley.TOWN_NAMES[town_id], trader.balance if trader else -1.0, town.get_valley_trader_capacity() / 16.0])
		for event in town.get_event_log_days(360):
			if event.get("type") == "business_failed":
				print("  FAIL %s" % event)
	quit()
