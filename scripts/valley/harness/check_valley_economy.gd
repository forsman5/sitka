extends SceneTree

const ValleyEconomy = preload("res://scripts/valley/valley_economy.gd")
const ValleySeed = preload("res://scripts/sim/data/valley_seed.gd")
const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")
const HENeed = preload("res://scripts/sim/household_economy/records/he_need.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var valley := ValleyEconomy.new()
	if valley.towns.size() != 5:
		push_error("Expected five household economies")
		quit(1)
		return
	for town_id in ValleySeed.HOUSEHOLDS_PER_SETTLEMENT:
		if valley.towns[town_id].get_city_summary()["household_count"] != ValleySeed.HOUSEHOLDS_PER_SETTLEMENT[town_id]:
			push_error("Town %d did not receive its authored household count" % town_id)
			quit(1)
			return
		var housing: Dictionary = valley.towns[town_id].get_housing_report(HEScenarioSeeds.SETTLEMENT_ID)
		if not housing["modeled"] or housing["capacity"] < ValleySeed.HOUSEHOLDS_PER_SETTLEMENT[town_id]:
			push_error("Town %d was not housed for its authored household count" % town_id)
			quit(1)
			return
		for commodity in HESimulation.EXPORT_PRIORITY:
			if valley.towns[town_id].get_valley_trade_price(commodity) <= 0.0:
				push_error("Town %d has no price for export good %d" % [town_id, commodity])
				quit(1)
				return
	var aldford = valley.towns[ValleySeed.ALDFORD]
	var staithe = valley.towns[ValleySeed.STAITHE]
	if not staithe.businesses.has(HEScenarioSeeds.PORT_BUSINESS_ID):
		push_error("Staithe has no outside-market Port business")
		quit(1)
		return
	for town_id in valley.towns:
		var has_quarry: bool = valley.towns[town_id].businesses.has(HEScenarioSeeds.QUARRY_BUSINESS_ID)
		if has_quarry != (town_id == ValleySeed.IRONBANK):
			push_error("Ironbank should be the valley's only Quarry town")
			quit(1)
			return
	if not valley.towns[ValleySeed.OAKMERE].businesses.has(HEScenarioSeeds.CHARCOAL_BURNER_BUSINESS_ID) or not valley.towns[ValleySeed.STAITHE].businesses.has(HEScenarioSeeds.TOOLSMITH_BUSINESS_ID):
		push_error("The valley is missing Oakmere's Charcoal Burner or Staithe's Toolsmith")
		quit(1)
		return
	# Aldford's standalone excess-clearing bid is below its Farm's floor early
	# on. Valley trade must still buy that reserved surplus at a viable price.
	for _i in 30:
		valley.advance_ticks(1)
	var early_grain_exports := 0
	for transaction in aldford.get_trader_transactions(HEScenarioSeeds.TRADER_BUSINESS_ID, 30):
		if transaction.get("direction") == "export" and transaction.get("commodity") == "Grain" and transaction.get("route") == "High Fell":
			early_grain_exports += 1
	if early_grain_exports == 0:
		push_error("No early Aldford grain exports to High Fell; valley trade may be using the standalone Trader bid")
		quit(1)
		return
	var charcoal_use := {}
	for _i in 150:
		valley.advance_ticks(1)
	for town_id in valley.towns:
		charcoal_use[town_id] = _charcoal_consumed(valley.towns[town_id], 180)
	print("DAY 180 charcoal_consumed=%s" % [charcoal_use])
	if charcoal_use[ValleySeed.IRONBANK] + charcoal_use[ValleySeed.STAITHE] + charcoal_use[ValleySeed.ALDFORD] + charcoal_use[ValleySeed.HIGH_FELL] < 25.0:
		push_error("Charcoal still has no household buyers outside Oakmere by day 180")
		quit(1)
		return
	_print_trade_metrics(valley, 180)
	for _i in 180:
		valley.advance_ticks(1)
	for town_id in valley.towns:
		charcoal_use[town_id] = _charcoal_consumed(valley.towns[town_id], 360)
	print("DAY 360 charcoal_consumed=%s" % [charcoal_use])
	if charcoal_use[ValleySeed.HIGH_FELL] < 20.0:
		push_error("The Oakmere-Aldford-High Fell Trader relay failed to deliver household charcoal")
		quit(1)
		return
	_print_trade_metrics(valley, 360)
	if valley.day != 360 or aldford.day != 360:
		push_error("Town clock diverged from valley clock")
		quit(1)
		return
	if valley.delivered_total + valley.shipments.size() == 0:
		push_error("No intertown shipment was dispatched")
		quit(1)
		return
	var port = staithe.businesses.get(HEScenarioSeeds.PORT_BUSINESS_ID)
	if port == null or port.ledger_good_average("export", Commodity.Type.IRON, 360) * 360.0 < 100.0:
		push_error("The Port did not buy a meaningful quantity of iron for the outside market")
		quit(1)
		return
	var recorded_trades := 0
	for town_id in valley.towns:
		var town: HESimulation = valley.towns[town_id]
		if not town.businesses.has(HEScenarioSeeds.TRADER_BUSINESS_ID):
			for event in town.get_event_log_days(360):
				if event.get("type") == "business_failed":
					print(event)
			push_error("Town %d lost its Trader within the first year" % town_id)
			quit(1)
			return
		recorded_trades += town.get_trader_transactions(HEScenarioSeeds.TRADER_BUSINESS_ID, 360).size()
	if not valley.towns[ValleySeed.OAKMERE].businesses.has(HEScenarioSeeds.CHARCOAL_BURNER_BUSINESS_ID) or not staithe.businesses.has(HEScenarioSeeds.TOOLSMITH_BUSINESS_ID) or not staithe.businesses.has(HEScenarioSeeds.BLOOMERY_BUSINESS_ID):
		for town_id in valley.towns:
			var failures := []
			for event in valley.towns[town_id].get_event_log_days(360):
				if event.get("type") == "business_failed":
					failures.append(event)
			print("FAILURES %s: %s" % [valley.TOWN_NAMES[town_id], failures])
		push_error("A valley Charcoal Burner, Toolsmith, or Staithe Bloomery closed within the first year")
		quit(1)
		return
	if recorded_trades < valley.delivered_total * 2:
		push_error("Shipment dispatches and arrivals are missing from Trader history")
		quit(1)
		return
	var ironbank = valley.towns[ValleySeed.IRONBANK]
	var quarry = ironbank.businesses.get(HEScenarioSeeds.QUARRY_BUSINESS_ID)
	if quarry == null or port.ledger_good_average("export", Commodity.Type.STONE, 360) * 360.0 < 1000.0:
		push_error("Ironbank's Quarry must survive and ship substantial stone to Staithe's Port")
		quit(1)
		return
	var ore_imports := 0
	var stone_imports_to_aldford := 0.0
	for transaction in staithe.get_trader_transactions(HEScenarioSeeds.TRADER_BUSINESS_ID, 360):
		if transaction.get("direction") == "import" and transaction.get("commodity") == "Iron Ore":
			ore_imports += 1
	for transaction in aldford.get_trader_transactions(HEScenarioSeeds.TRADER_BUSINESS_ID, 360):
		if transaction.get("direction") == "import" and transaction.get("commodity") == "Stone":
			stone_imports_to_aldford += float(transaction.get("quantity", 0.0))
	var aldford_retail_stone: float = aldford.businesses[HEScenarioSeeds.TRADER_BUSINESS_ID].stock(Commodity.Type.STONE) - aldford.get_valley_relay_reserved_stock(Commodity.Type.STONE)
	if stone_imports_to_aldford < 15.0 or aldford_retail_stone > 21.0:
		push_error("Aldford did not hold a bounded construction stone reserve")
		quit(1)
		return
	for transaction in ironbank.get_trader_transactions(HEScenarioSeeds.TRADER_BUSINESS_ID, 360):
		if transaction.get("direction") == "import" and transaction.get("commodity") == "Stone":
			push_error("Ironbank bought back the stone produced by its own Quarry")
			quit(1)
			return
	if ore_imports == 0 or not ironbank.businesses.has(HEScenarioSeeds.IRON_MINE_BUSINESS_ID) or ironbank.businesses.has(HEScenarioSeeds.BLOOMERY_BUSINESS_ID):
		push_error("Ironbank must keep its mine and ship ore to Staithe without a local Bloomery")
		quit(1)
		return
	for town_id in [ValleySeed.ALDFORD, ValleySeed.IRONBANK]:
		for transaction in valley.towns[town_id].get_trader_transactions(HEScenarioSeeds.TRADER_BUSINESS_ID, 360):
			if transaction.get("direction") == "import" and transaction.get("commodity") == "Iron":
				push_error("Town %d imported iron without a workshop or Port buyer" % town_id)
				quit(1)
				return
	print("Valley economy OK: %d delivered, %d in transit, %d Trader transactions" % [valley.delivered_total, valley.shipments.size(), recorded_trades])
	quit()

func _charcoal_consumed(town, days: int) -> float:
	var total := 0.0
	for row in town.get_daily_history(days):
		var heat: Dictionary = row.get("needs", {}).get(HENeed.Id.HEAT, {})
		total += float(heat.get("met_by", {}).get("Charcoal", 0.0)) / 4.0
	return total

func _print_trade_metrics(valley, checkpoint: int) -> void:
	var charcoal_legs := {}
	var stone_legs := {}
	var trader_balances := {}
	var stone_stock := {}
	for town_id in valley.towns:
		var town = valley.towns[town_id]
		var trader = town.businesses.get(HEScenarioSeeds.TRADER_BUSINESS_ID)
		trader_balances[valley.TOWN_NAMES[town_id]] = trader.balance if trader != null else -1.0
		stone_stock[valley.TOWN_NAMES[town_id]] = trader.stock(Commodity.Type.STONE) if trader != null else 0.0
		for transaction in town.get_trader_transactions(HEScenarioSeeds.TRADER_BUSINESS_ID, checkpoint):
			if transaction.get("direction") != "export":
				continue
			var commodity: String = transaction.get("commodity", "")
			var key := "%s>%s" % [valley.TOWN_NAMES[town_id], transaction.get("route", "?")]
			if commodity == "Charcoal":
				charcoal_legs[key] = charcoal_legs.get(key, 0.0) + float(transaction.get("quantity", 0.0))
			elif commodity == "Stone":
				stone_legs[key] = stone_legs.get(key, 0.0) + float(transaction.get("quantity", 0.0))
	print("DAY %d charcoal_legs=%s stone_legs=%s stone_trader_stock=%s trader_balances=%s delivered=%d in_transit=%d" % [
		checkpoint, charcoal_legs, stone_legs, stone_stock, trader_balances,
		valley.delivered_total, valley.shipments.size()])
