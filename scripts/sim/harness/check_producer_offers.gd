extends SceneTree

const Sim = preload("res://scripts/sim/household_economy/he_simulation.gd")
const Fixtures = preload("res://scripts/sim/harness/he_fixtures.gd")
const Commodity = preload("res://scripts/sim/records/commodity.gd")
const Needs = preload("res://scripts/sim/household_economy/data/he_needs.gd")

func _init() -> void:
	var sim := Sim.new(4242, Callable(Fixtures, "build_economy_with_charcoal_burner"))
	var woodlot = null
	for b in sim.businesses.values():
		if b.type_key == "woodlot":
			woodlot = b
	assert(woodlot != null)
	var good := Commodity.Type.TIMBER
	var heat = Needs.for_commodity(good)
	var settlement_id: int = woodlot.settlement_id
	var flat_curve: Array[float] = [1.0, 1.0, 1.0, 1.0]
	heat.seasonal_curve = flat_curve
	var flat_summer: float = sim._settlement_daily_demand(settlement_id, good, 100)
	var flat_winter: float = sim._settlement_daily_demand(settlement_id, good, 300)
	assert(is_equal_approx(flat_summer, flat_winter), "flat heat forecast should be day independent")
	var seasonal_curve: Array[float] = [1.0, 0.4, 1.0, 1.8]
	heat.seasonal_curve = seasonal_curve
	var seasonal_summer: float = sim._settlement_daily_demand(settlement_id, good, 135)
	var seasonal_winter: float = sim._settlement_daily_demand(settlement_id, good, 315)
	assert(seasonal_winter > seasonal_summer * 4.4, "heat forecast should reflect the seasonal curve")
	var need := sim._known_daily_local_use(woodlot, good)
	var funded_need: float = sim._household_funded_demand(settlement_id, good) + sim._business_input_daily_use(settlement_id, good, woodlot)
	var expected_need := maxf(need, funded_need)
	var market = sim.markets[woodlot.settlement_id]
	woodlot.inventory[good] = need * 100.0
	market.price[good] = Sim.BASE_PRICE[good] * Sim.PRICE_MULTIPLIER_MIN
	var low_price_offer: float = sim._seller_offer(woodlot, good)
	assert(low_price_offer >= expected_need * 0.9 - 0.0001, "low prices may withhold at most ten percent of funded need")
	assert(low_price_offer <= expected_need * 0.9 + (woodlot.stock(good) - Sim.COVER_MAX_DAYS * need) / Sim.SURPLUS_RELEASE_DAYS + 0.0001, "low-price nudge should be bounded")
	market.price[good] = Sim.BASE_PRICE[good] * Sim.PRICE_MULTIPLIER_MAX
	var high_price_offer: float = sim._seller_offer(woodlot, good)
	assert(high_price_offer >= expected_need * 1.1 - 0.0001, "high prices should release a small surplus")
	assert(high_price_offer <= woodlot.stock(good), "offer cannot exceed stock")
	assert(is_equal_approx(sim._paced_offer(woodlot, good), high_price_offer), "report and business buyers should share the steward offer")
	woodlot.inventory[good] = need * 7.0
	market.price[good] = Sim.BASE_PRICE[good] * Sim.PRICE_MULTIPLIER_MIN
	assert(sim._seller_offer(woodlot, good) >= minf(woodlot.stock(good), need) - 0.0001, "minimum-cover stock must not be withheld below daily need")
	print("Steward offer checks passed (demand %.3f, low %.3f, high %.3f)" % [need, low_price_offer, high_price_offer])
	quit()
