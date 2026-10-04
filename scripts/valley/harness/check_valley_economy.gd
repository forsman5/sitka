extends SceneTree

const ValleyEconomy = preload("res://scripts/valley/valley_economy.gd")
const ValleySeed = preload("res://scripts/sim/data/valley_seed.gd")

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
	var aldford = valley.towns[ValleySeed.ALDFORD]
	for _i in 120:
		valley.advance_ticks(1)
	if valley.day != 120 or aldford.day != 120:
		push_error("Town clock diverged from valley clock")
		quit(1)
		return
	if valley.delivered_total + valley.shipments.size() == 0:
		push_error("No intertown shipment was dispatched")
		quit(1)
		return
	var recorded_trades := 0
	for town in valley.towns.values():
		recorded_trades += town.get_trader_transactions(3, 120).size()
	if recorded_trades < valley.delivered_total * 2:
		push_error("Shipment dispatches and arrivals are missing from Trader history")
		quit(1)
		return
	print("Valley economy OK: %d delivered, %d in transit, %d Trader transactions" % [valley.delivered_total, valley.shipments.size(), recorded_trades])
	quit()
