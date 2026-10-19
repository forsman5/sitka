extends SceneTree

const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HEBusiness = preload("res://scripts/sim/household_economy/records/he_business.gd")
const HESettlement = preload("res://scripts/sim/household_economy/records/he_settlement.gd")
const ValleyEconomy = preload("res://scripts/valley/valley_economy.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")

const SID := HEScenarioSeeds.SETTLEMENT_ID

var _ok := true

func _initialize() -> void:
	var sim := HESimulation.new(2027, Callable(HEScenarioSeeds, "build_preset").bind("small_village"))
	for day_index in range(90):
		_assert_all_match_scan(sim, "small village day %d" % day_index)
		sim.advance_ticks(1)
	_assert_all_match_scan(sim, "small village after 90 days")
	_check_production_order_and_catalog_mutations(sim)
	_check_wool_and_live_animal_order(sim)
	_check_meat_fallback(sim)
	_check_two_settlements()
	_check_valley_instances()
	print("SELLER INDEX %s" % ("OK" if _ok else "FAILED"))
	quit(0 if _ok else 1)

func _check_production_order_and_catalog_mutations(sim: HESimulation) -> void:
	for business_id in sim.businesses.keys().duplicate():
		var business: HEBusiness = sim.businesses[business_id]
		if business.sells(Commodity.Type.STONE):
			_remove_business(sim, business_id)
	var first := HEScenarioSeeds.make_extractor(9002, SID, "quarry", "First inserted", Commodity.Type.STONE, 1.0)
	var second := HEScenarioSeeds.make_extractor(9001, SID, "quarry", "Second inserted", Commodity.Type.STONE, 1.0)
	sim.add_business(first)
	_assert(sim._business_selling(SID, Commodity.Type.STONE) == first, "a zero-stock seller remains indexed")
	sim.add_business(second)
	_assert(sim._business_selling(SID, Commodity.Type.STONE) == first, "business insertion order wins over numeric ID")
	_assert_all_match_scan(sim, "after seller additions")
	_remove_business(sim, first.id)
	_assert(sim._business_selling(SID, Commodity.Type.STONE) == second, "removing the first seller promotes the next scan match")
	var third := HEScenarioSeeds.make_extractor(9003, SID, "quarry", "Failure replacement", Commodity.Type.STONE, 1.0)
	sim.add_business(third)
	sim._fail_business(second.id, sim._new_daily_record())
	_assert(sim._business_selling(SID, Commodity.Type.STONE) == third, "business failure invalidates the seller index")
	_assert_all_match_scan(sim, "after catalog mutations")

func _check_wool_and_live_animal_order(sim: HESimulation) -> void:
	for business_id in sim.businesses.keys().duplicate():
		var business: HEBusiness = sim.businesses[business_id]
		if business.sells(Commodity.Type.WOOL) or (business.kind == HEBusiness.Kind.HERD and business.species == HEBusiness.Species.SHEEP):
			_remove_business(sim, business_id)
	var sheep_first := HEScenarioSeeds.make_herd(9102, SID, HEBusiness.Species.SHEEP)
	var wool_producer := HEScenarioSeeds.make_extractor(9101, SID, "iron_mine", "Wool producer", Commodity.Type.WOOL, 1.0)
	sim.add_business(sheep_first)
	sim.add_business(wool_producer)
	_assert(sim._business_selling(SID, Commodity.Type.WOOL) == sheep_first, "the first eligible sheep wool seller wins")
	_remove_business(sim, sheep_first.id)
	var sheep_second := HEScenarioSeeds.make_herd(9100, SID, HEBusiness.Species.SHEEP)
	sim.add_business(sheep_second)
	_assert(sim._business_selling(SID, Commodity.Type.WOOL) == wool_producer, "an earlier wool producer keeps priority over a later sheep herd")
	_assert(sim._business_selling(SID, Commodity.Type.SHEEP) == sheep_second, "sheep herds remain live-animal sellers")
	_assert_all_match_scan(sim, "after wool and herd ordering cases")

func _check_meat_fallback(sim: HESimulation) -> void:
	var butcher: HEBusiness = sim.businesses.get(HEScenarioSeeds.BUTCHER_BUSINESS_ID)
	_assert(butcher != null, "small village includes its multi-output Butcher")
	if butcher == null:
		return
	butcher.add_stock(Commodity.Type.MEAT, 1.0)
	_assert(sim._business_selling(SID, Commodity.Type.MEAT) == butcher, "a stocked Butcher is the primary meat seller")
	_assert(sim._business_selling(SID, Commodity.Type.LEATHER) == butcher, "all Butcher recipe outputs are indexed")
	butcher.consume(Commodity.Type.MEAT, butcher.stock(Commodity.Type.MEAT))
	for business in sim.businesses.values():
		var candidate: HEBusiness = business
		if candidate.kind == HEBusiness.Kind.HERD:
			candidate.inventory[Commodity.Type.MEAT] = 0.0
	var high_id_herd := HEScenarioSeeds.make_herd(9205, SID, HEBusiness.Species.CATTLE)
	var low_id_herd := HEScenarioSeeds.make_herd(9200, SID, HEBusiness.Species.CATTLE)
	sim.add_business(high_id_herd)
	sim.add_business(low_id_herd)
	high_id_herd.add_stock(Commodity.Type.MEAT, 2.0)
	low_id_herd.add_stock(Commodity.Type.MEAT, 1.0)
	_assert(sim._business_selling(SID, Commodity.Type.MEAT) == low_id_herd, "meat fallback chooses the lowest stocked herd ID")
	butcher.add_stock(Commodity.Type.MEAT, 0.5)
	_assert(sim._business_selling(SID, Commodity.Type.MEAT) == butcher, "live stock changes restore the Butcher as primary")
	butcher.consume(Commodity.Type.MEAT, butcher.stock(Commodity.Type.MEAT))
	_assert(sim._business_selling(SID, Commodity.Type.MEAT) == low_id_herd, "live stock changes restore the herd fallback")
	_remove_business(sim, butcher.id)
	_assert(sim._business_selling(SID, Commodity.Type.MEAT) == low_id_herd, "fallback works when no Butcher exists")
	high_id_herd.inventory[Commodity.Type.MEAT] = 0.0
	low_id_herd.inventory[Commodity.Type.MEAT] = 0.0001
	_assert(sim._business_selling(SID, Commodity.Type.MEAT) == null, "meat at the availability threshold is not offered")
	low_id_herd.add_stock(Commodity.Type.MEAT, 0.000001)
	_assert(sim._business_selling(SID, Commodity.Type.MEAT) == low_id_herd, "meat above the availability threshold is offered")
	low_id_herd.inventory[Commodity.Type.MEAT] = 0.0
	high_id_herd.add_stock(Commodity.Type.MEAT, 1.0)
	_assert(sim._business_selling(SID, Commodity.Type.MEAT) == high_id_herd, "next stocked fallback is selected when the lowest ID empties")
	sim.add_business(butcher)
	butcher.add_stock(Commodity.Type.MEAT, 0.5)
	_assert(sim._business_selling(SID, Commodity.Type.MEAT) == butcher, "restocking a Butcher after fallback restores its priority")
	_assert_all_match_scan(sim, "after meat fallback cases")

func _check_two_settlements() -> void:
	var sim := HESimulation.new(2028, Callable(HEScenarioSeeds, "build_two_settlement_economy"))
	_assert_all_match_scan(sim, "two settlements before ticks")
	sim.advance_ticks(5)
	_assert_all_match_scan(sim, "two settlements after ticks")

func _check_valley_instances() -> void:
	var valley := ValleyEconomy.new()
	for town_id in valley.towns:
		_assert_all_match_scan(valley.towns[town_id], "valley town %d before ticks" % town_id)
	valley.advance_ticks(3)
	for town_id in valley.towns:
		_assert_all_match_scan(valley.towns[town_id], "valley town %d after ticks" % town_id)

func _assert_all_match_scan(sim: HESimulation, context: String) -> void:
	for settlement_id in sim.get_settlement_ids():
		for commodity in Commodity.ALL:
			var indexed: HEBusiness = sim._business_selling(settlement_id, commodity)
			var scanned: HEBusiness = _scan_business_selling(sim, settlement_id, commodity)
			_assert(indexed == scanned, "%s: indexed seller differs from scan for settlement %d commodity %s (indexed %s, scanned %s)" % [
				context, settlement_id, Commodity.name_of(commodity),
				str(indexed.id) if indexed != null else "null",
				str(scanned.id) if scanned != null else "null"])

func _scan_business_selling(sim: HESimulation, settlement_id: int, commodity: Commodity.Type) -> HEBusiness:
	for business_id in sim.businesses.keys():
		var business: HEBusiness = sim.businesses[business_id]
		if business.settlement_id != settlement_id:
			continue
		if business.sells(commodity):
			return _scan_home_butchery_seller(sim, settlement_id, commodity, business)
		if business.kind == HEBusiness.Kind.HERD and business.species == HEBusiness.Species.SHEEP and commodity == Commodity.Type.WOOL:
			return business
		if business.kind == HEBusiness.Kind.HERD and sim.is_livestock(commodity) and business.herd_commodity() == commodity:
			return business
	return _scan_home_butchery_seller(sim, settlement_id, commodity, null)

func _scan_home_butchery_seller(sim: HESimulation, settlement_id: int, commodity: Commodity.Type, primary: HEBusiness) -> HEBusiness:
	if commodity != Commodity.Type.MEAT or (primary != null and primary.stock(commodity) > 0.0001):
		return primary
	var herd_ids: Array[int] = []
	for business_id in sim.businesses.keys():
		var business: HEBusiness = sim.businesses[business_id]
		if business.kind == HEBusiness.Kind.HERD and business.settlement_id == settlement_id:
			herd_ids.append(business_id)
	herd_ids.sort()
	for herd_id in herd_ids:
		var herd: HEBusiness = sim.businesses[herd_id]
		if herd.stock(commodity) > 0.0001:
			return herd
	return primary

func _remove_business(sim: HESimulation, business_id: int) -> void:
	var business: HEBusiness = sim.businesses.get(business_id)
	if business == null:
		return
	sim.businesses.erase(business_id)
	(sim.settlements[business.settlement_id] as HESettlement).business_ids.erase(business_id)
	sim.invalidate_seller_index()

func _assert(condition: bool, message: String) -> void:
	if not condition:
		_ok = false
		push_error("FAIL: " + message)
