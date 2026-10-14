extends SceneTree

const ValleyEconomy = preload("res://scripts/valley/valley_economy.gd")
const ValleySeed = preload("res://scripts/sim/data/valley_seed.gd")
const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")

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
	if not valley.towns[ValleySeed.OAKMERE].businesses.has(HEScenarioSeeds.CHARCOAL_BURNER_BUSINESS_ID) or not valley.towns[ValleySeed.STAITHE].businesses.has(HEScenarioSeeds.TOOLSMITH_BUSINESS_ID):
		push_error("The valley is missing Oakmere's Charcoal Burner or Staithe's Toolsmith")
		quit(1)
		return
	for _i in 360:
		valley.advance_ticks(1)
	if valley.day != 360 or aldford.day != 360:
		push_error("Town clock diverged from valley clock")
		quit(1)
		return
	if valley.delivered_total + valley.shipments.size() == 0:
		push_error("No intertown shipment was dispatched")
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
	if not valley.towns[ValleySeed.OAKMERE].businesses.has(HEScenarioSeeds.CHARCOAL_BURNER_BUSINESS_ID) or not valley.towns[ValleySeed.STAITHE].businesses.has(HEScenarioSeeds.TOOLSMITH_BUSINESS_ID):
		push_error("A valley Charcoal Burner or Toolsmith closed within the first year")
		quit(1)
		return
	if recorded_trades < valley.delivered_total * 2:
		push_error("Shipment dispatches and arrivals are missing from Trader history")
		quit(1)
		return
	print("Valley economy OK: %d delivered, %d in transit, %d Trader transactions" % [valley.delivered_total, valley.shipments.size(), recorded_trades])
	quit()
