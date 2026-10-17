class_name ValleyEconomy
extends RefCounted

## Owns the five persistent town economies and the shipments between them.
const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const ValleySeed = preload("res://scripts/sim/data/valley_seed.gd")
const TransportEdge = preload("res://scripts/sim/records/transport_edge.gd")
const Shipment = preload("res://scripts/sim/records/shipment.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")

const TRADE_INTERVAL_DAYS := 2
const TRADER_MIN_MARGIN := 0.04
## Wait for a useful lot while cargo weight and cart loading are unmodeled.
const MIN_BATCH_UNITS := {Commodity.Type.CHARCOAL: 2.0, Commodity.Type.STONE: 2.0}
const TOWN_NAMES := {
	ValleySeed.ALDFORD: "Aldford",
	ValleySeed.HIGH_FELL: "High Fell",
	ValleySeed.OAKMERE: "Oakmere",
	ValleySeed.IRONBANK: "Ironbank",
	ValleySeed.STAITHE: "Staithe",
}

var towns: Dictionary[int, HESimulation] = {}
var edges: Dictionary[int, TransportEdge] = {}
var shipments: Dictionary[int, Shipment] = {}
var shipment_prices: Dictionary[int, float] = {}
var shipment_relay_targets: Dictionary[int, int] = {}
var day := 0
var _next_shipment_id := 1
var delivered_total := 0

## Public snapshots used by the single valley graph. The graph never owns a
## second economy; these read the same towns its detail view opens.
func get_settlement_ids() -> Array[int]:
	var ids: Array[int] = []
	ids.assign(towns.keys())
	ids.sort()
	return ids

func get_clock_summary() -> Dictionary:
	var season_names := ["Spring", "Summer", "Autumn", "Winter"]
	return {"day": day, "year": day / 360, "season_name": season_names[(day / 90) % 4]}

func get_modeled_commodities() -> Array[Commodity.Type]:
	var result: Array[Commodity.Type] = []
	result.assign(HESimulation.BASE_PRICE.keys())
	return result

func get_settlement_summary(town_id: int) -> Dictionary:
	var summary: Dictionary = towns[town_id].get_city_summary()
	var count: int = summary["household_count"]
	var short: int = summary["households_short_of_goods"]
	return {"id": town_id, "name": summary["name"], "population": summary["population"],
		"status": "food_insecure" if short > 0 else "stable",
		"household_count": count, "households_short_of_goods": short,
		"unemployed_household_count": summary["unemployed_household_count"],
		"avg_food_stress": summary["avg_food_stress"],
		"total_money": summary["total_money"], "inventory": summary["total_stock"],
		"grain_fulfillment_rolling_30d": 1.0 - float(short) / float(maxi(1, count)),
		"migration_pressure_count": 0}

func get_settlement_prices(town_id: int) -> Dictionary:
	return towns[town_id].get_valley_market_prices()

func get_transport_edge_ids() -> Array[int]:
	var ids: Array[int] = []
	ids.assign(edges.keys())
	ids.sort()
	return ids

func get_transport_edge_summary(edge_id: int) -> Dictionary:
	var edge: TransportEdge = edges[edge_id]
	return {"id": edge.id, "settlement_a_id": edge.settlement_a_id,
		"settlement_b_id": edge.settlement_b_id,
		"settlement_a_name": TOWN_NAMES[edge.settlement_a_id],
		"settlement_b_name": TOWN_NAMES[edge.settlement_b_id],
		"mode": edge.mode, "capacity": edge.capacity,
		"travel_time_days_a_to_b": edge.travel_time_days_a_to_b,
		"travel_time_days_b_to_a": edge.travel_time_days_b_to_a}

func get_active_shipments() -> Array:
	var result: Array = []
	for shipment in shipments.values():
		result.append({"id": shipment.id, "commodity": shipment.commodity,
			"quantity": shipment.quantity, "edge_id": shipment.edge_id,
			"origin_settlement_id": shipment.origin_settlement_id,
			"destination_settlement_id": shipment.destination_settlement_id,
			"origin_name": TOWN_NAMES[shipment.origin_settlement_id],
			"destination_name": TOWN_NAMES[shipment.destination_settlement_id],
			"origin_trade_center_workplace_id": shipment.origin_trade_center_workplace_id,
			"departure_day": shipment.departure_day, "arrival_day": shipment.arrival_day,
			"days_remaining": maxi(0, shipment.arrival_day - day),
			"progress_fraction": shipment.progress_fraction(day)})
	return result

func get_game_over_info() -> Dictionary:
	return {}

func _init() -> void:
	for town_id in TOWN_NAMES:
		var economy := HESimulation.new(4242 + town_id * 101, Callable(self, "_build_town").bind(town_id))
		economy.external_trade_enabled = false
		if town_id == ValleySeed.STAITHE:
			economy.set_trader_export_enabled(HEScenarioSeeds.TRADER_BUSINESS_ID, Commodity.Type.TOOLS, true)
		if town_id == ValleySeed.IRONBANK:
			economy.set_trader_export_enabled(HEScenarioSeeds.TRADER_BUSINESS_ID, Commodity.Type.IRON_ORE, true)
		towns[town_id] = economy
	edges = ValleySeed._build_transport_edges()

func _build_town(rng: RandomNumberGenerator, town_id: int) -> Dictionary:
	var world: Dictionary = HEScenarioSeeds.build_valley_town(rng, town_id)
	var settlement = world["settlements"][HEScenarioSeeds.SETTLEMENT_ID]
	settlement.name = TOWN_NAMES[town_id]
	# Give neighboring towns different opening buffers so the connected
	# markets have useful trade opportunities while production settles in.
	var businesses: Dictionary = world["businesses"]
	if town_id == ValleySeed.HIGH_FELL:
		businesses[HEScenarioSeeds.FARM_BUSINESS_ID].inventory[Commodity.Type.GRAIN] *= 0.25
	if town_id == ValleySeed.OAKMERE:
		businesses[HEScenarioSeeds.WOODLOT_BUSINESS_ID].inventory[Commodity.Type.TIMBER] *= 2.0
	if town_id == ValleySeed.IRONBANK:
		businesses[HEScenarioSeeds.WOODLOT_BUSINESS_ID].inventory[Commodity.Type.TIMBER] *= 0.3
	return world

func advance_ticks(days: int) -> void:
	for _i in days:
		_deliver_arrivals()
		var town_ids := towns.keys()
		town_ids.sort()
		for town_id in town_ids:
			towns[town_id].advance_ticks(1)
		day += 1
		if day % TRADE_INTERVAL_DAYS == 0:
			_dispatch_shipments()

func _deliver_arrivals() -> void:
	var arrived: Array[int] = []
	for shipment_id in shipments:
		var shipment: Shipment = shipments[shipment_id]
		if shipment.arrival_day > day:
			continue
		var relay_target: int = shipment_relay_targets.get(shipment_id, -1)
		towns[shipment.destination_settlement_id].receive_valley_shipment(shipment.commodity, shipment.quantity, relay_target, shipment_prices[shipment_id])
		var origin_name: String = TOWN_NAMES[shipment.origin_settlement_id]
		towns[shipment.destination_settlement_id].record_valley_transaction("import", shipment.commodity,
			shipment.quantity, shipment_prices[shipment_id], origin_name, true)
		arrived.append(shipment_id)
		delivered_total += 1
	for shipment_id in arrived:
		shipments.erase(shipment_id)
		shipment_prices.erase(shipment_id)
		shipment_relay_targets.erase(shipment_id)

func _dispatch_shipments() -> void:
	var opportunities: Array[Dictionary] = []
	var edge_ids := edges.keys()
	edge_ids.sort()
	for edge_id in edge_ids:
		var edge: TransportEdge = edges[edge_id]
		for source_id in [edge.settlement_a_id, edge.settlement_b_id]:
			var destination_id: int = edge.other_end(source_id)
			var source: HESimulation = towns[source_id]
			var destination: HESimulation = towns[destination_id]
			for commodity in HESimulation.EXPORT_PRIORITY:
				var committed_destination: int = source.get_valley_relay_destination(commodity)
				if committed_destination >= 0 and committed_destination != destination_id:
					continue
				var offer := source.get_valley_trade_offer(commodity)
				if offer["quantity"] <= 0.0001:
					continue
				var source_price := source.get_valley_trade_price(commodity)
				var destination_price := destination.get_valley_trade_price(commodity)
				var port_bid := destination.get_valley_port_buy_price(commodity)
				if port_bid > 0.0:
					destination_price = port_bid
				var local_destination_price := destination_price
				# A posted quote without a buyer is not an import bid. Let an
				# actual downstream household or workshop bid take precedence.
				if commodity in [Commodity.Type.CHARCOAL, Commodity.Type.STONE] and port_bid <= 0.0 and destination.get_valley_import_interest(commodity, local_destination_price) <= 0.0001:
					local_destination_price = 0.0
				# A neighbor can pass a bounded buyer quote through this Trader.
				# The imported lot is physically handed to the middle Trader first;
				# later dispatches can only use the stock it actually holds.
				var relay_buyer := -1
				var relay_price := 0.0
				for next_edge_id in edge_ids:
					var next_edge: TransportEdge = edges[next_edge_id]
					if not next_edge.connects(destination_id):
						continue
					var next_id := next_edge.other_end(destination_id)
					if next_id == source_id:
						continue
					var next_town: HESimulation = towns[next_id]
					var next_port_bid := next_town.get_valley_port_buy_price(commodity)
					var downstream_bid := next_port_bid if next_port_bid > 0.0 else next_town.get_valley_trade_price(commodity)
					var next_cost: float = next_edge.toll + next_edge.risk * 2.0 + TRADER_MIN_MARGIN
					var delivered_bid: float = downstream_bid - next_cost
					if next_town.get_valley_import_interest(commodity, downstream_bid) <= 0.0 and next_port_bid <= 0.0:
						continue
					if delivered_bid > relay_price:
						relay_price = delivered_bid
						relay_buyer = next_id
				if relay_buyer >= 0 and relay_price > local_destination_price:
					destination_price = relay_price
				var is_relay: bool = relay_buyer >= 0 and relay_price > local_destination_price
				# The Port is a standing outside buyer. An origin's local retail
				# quote can stay high when nobody there uses the good (stone is
				# one case), so negotiate from the producer's floor instead.
				var seller_price: float = offer["min_price"] if port_bid > 0.0 or float(offer.get("held", 0.0)) > 0.0 else maxf(source_price, offer["min_price"])
				var route_cost: float = edge.toll + edge.risk * 2.0
				var gap: float = destination_price - seller_price - route_cost
				if gap < TRADER_MIN_MARGIN:
					continue
				# Split the price room between the origin and destination Traders.
				# Transport cost is a hurdle in the route decision, as elsewhere here.
				var unit_price: float = seller_price + route_cost + maxf(TRADER_MIN_MARGIN, gap * 0.5)
				var destination_interest: float = destination.get_valley_import_interest(commodity, unit_price)
				opportunities.append({"source": source_id, "destination": destination_id, "edge": edge_id,
					"commodity": commodity, "gap": gap, "price": unit_price, "seller_price": seller_price,
					"relay_buyer": relay_buyer,
					"is_relay": is_relay,
					"construction_reserve": commodity == Commodity.Type.STONE and destination_interest > 0.0})
	opportunities.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["commodity"] == Commodity.Type.GRAIN and b["commodity"] != Commodity.Type.GRAIN:
			return true
		if b["commodity"] == Commodity.Type.GRAIN and a["commodity"] != Commodity.Type.GRAIN:
			return false
		var a_critical: bool = a["commodity"] in [Commodity.Type.IRON_ORE, Commodity.Type.IRON]
		var b_critical: bool = b["commodity"] in [Commodity.Type.IRON_ORE, Commodity.Type.IRON]
		if a_critical != b_critical:
			return a_critical
		if a["construction_reserve"] != b["construction_reserve"]:
			return bool(a["construction_reserve"])
		return a["gap"] > b["gap"]
	)
	var remaining_edges := {}
	for edge_id in edge_ids:
		remaining_edges[edge_id] = edges[edge_id].capacity
	var remaining_traders := {}
	for town_id in towns:
		remaining_traders[town_id] = towns[town_id].get_valley_trader_capacity()
	for opportunity in opportunities:
		var source_id: int = opportunity["source"]
		var destination_id: int = opportunity["destination"]
		var edge_id: int = opportunity["edge"]
		var commodity: Commodity.Type = opportunity["commodity"]
		var source: HESimulation = towns[source_id]
		var committed_destination: int = source.get_valley_relay_destination(commodity)
		if committed_destination >= 0 and committed_destination != destination_id:
			continue
		if opportunity["is_relay"] and _has_conflicting_relay(destination_id, commodity, int(opportunity["relay_buyer"])):
			continue
		var destination: HESimulation = towns[destination_id]
		if opportunity["is_relay"] and destination.get_valley_relay_destination(commodity) not in [-1, int(opportunity["relay_buyer"])]:
			continue
		var current_offer := source.get_valley_trade_offer(commodity)
		var quantity: float = minf(current_offer["quantity"],
			minf(remaining_edges[edge_id], minf(remaining_traders[source_id], remaining_traders[destination_id])))
		var inbound := 0.0
		for shipment in shipments.values():
			if shipment.destination_settlement_id == destination_id and shipment.commodity == commodity:
				inbound += shipment.quantity
		var local_interest: float = destination.get_valley_import_interest(commodity, opportunity["price"], inbound)
		if opportunity["is_relay"]:
			var buyer: HESimulation = towns[int(opportunity["relay_buyer"])]
			var downstream_inbound := 0.0
			for shipment in shipments.values():
				if shipment.destination_settlement_id == int(opportunity["relay_buyer"]) and shipment.commodity == commodity:
					downstream_inbound += shipment.quantity
			var committed_at_relay := destination.get_valley_relay_reserved_stock(commodity) if destination.get_valley_relay_destination(commodity) == int(opportunity["relay_buyer"]) else 0.0
			for shipment_id in shipment_relay_targets:
				var incoming: Shipment = shipments[shipment_id]
				if incoming.destination_settlement_id == destination_id and incoming.commodity == commodity and shipment_relay_targets[shipment_id] == int(opportunity["relay_buyer"]):
					committed_at_relay += incoming.quantity
			var downstream_need := buyer.get_valley_import_interest(commodity, buyer.get_valley_trade_price(commodity), downstream_inbound)
			quantity = minf(quantity, maxf(0.0, downstream_need - committed_at_relay))
		elif commodity in [Commodity.Type.CHARCOAL, Commodity.Type.STONE] and destination.get_valley_port_buy_price(commodity) <= 0.0:
			quantity = minf(quantity, local_interest)
		if commodity in [Commodity.Type.IRON, Commodity.Type.IRON_ORE] and destination.get_valley_port_buy_price(commodity) <= 0.0:
			quantity = minf(quantity, destination.get_valley_workshop_import_need(commodity, inbound))
		quantity = minf(quantity, destination.get_valley_trader_purchase_capacity(opportunity["price"]))
		if quantity < float(MIN_BATCH_UNITS.get(commodity, 0.0001)):
			continue
		var unit_price: float = opportunity["price"]
		var route_cost: float = edges[edge_id].toll + edges[edge_id].risk * 2.0
		quantity = source.dispatch_valley_shipment(commodity, quantity, unit_price, opportunity["seller_price"], route_cost)
		if quantity <= 0.0001:
			continue
		towns[destination_id].pay_for_valley_shipment(commodity, quantity, unit_price)
		source.record_valley_transaction("export", commodity, quantity, unit_price, TOWN_NAMES[destination_id])
		var edge: TransportEdge = edges[edge_id]
		var arrival := day + ceili(edge.travel_time_days(source_id))
		var shipment := Shipment.new(_next_shipment_id, commodity, quantity, source_id,
			destination_id, HEScenarioSeeds.TRADER_BUSINESS_ID, edge_id, day, arrival)
		shipments[shipment.id] = shipment
		shipment_prices[shipment.id] = unit_price
		if opportunity["is_relay"]:
			shipment_relay_targets[shipment.id] = int(opportunity["relay_buyer"])
		_next_shipment_id += 1
		remaining_edges[edge_id] -= quantity
		remaining_traders[source_id] -= quantity
		remaining_traders[destination_id] -= quantity

func _has_conflicting_relay(destination_id: int, commodity: Commodity.Type, target_id: int) -> bool:
	for shipment_id in shipment_relay_targets:
		var shipment: Shipment = shipments.get(shipment_id)
		if shipment != null and shipment.destination_settlement_id == destination_id and shipment.commodity == commodity:
			if shipment_relay_targets[shipment_id] != target_id:
				return true
	return false
