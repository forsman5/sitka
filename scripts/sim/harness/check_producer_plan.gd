extends SceneTree

const Plan = preload("res://scripts/sim/household_economy/he_producer_plan.gd")
const Sim = preload("res://scripts/sim/household_economy/he_simulation.gd")
const Seeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")

func _init() -> void:
	var base := {"stock": 0.0, "fields": [{"area": 10.0, "days_growing": 0, "labor_applied": 0.0}],
		"demand": [0.0, 0.0, 0.0, 0.0], "yield_scales": [1.0, 1.0, 1.0, 1.0],
		"horizon": 4, "growth_days": 2, "land_area": 10.0, "labor_per_area_per_day": 0.1,
		"yield_per_area": 2.0, "productivity": 1.0, "min_capacity": 0, "max_capacity": 10,
		"current_capacity": 2, "average_demand": 0.0}
	var low := Plan.project_stock(base, 1)
	var high := Plan.project_stock(base, 2)
	assert(float(high["stock_end"]) >= float(low["stock_end"]), "projected output must be monotone in crew")
	var winter := base.duplicate(true)
	winter["fields"] = [{"area": 10.0, "days_growing": 1, "labor_applied": 1.0}]
	winter["growth_days"] = 2
	winter["demand"] = [0.0]
	winter["yield_scales"] = [0.1]
	winter["horizon"] = 1
	var winter_projection: Dictionary = Plan.project_stock(winter, 1)
	var normal_yield := winter.duplicate(true)
	var normal_scale: Array[float] = [1.0]
	normal_yield["yield_scales"] = normal_scale
	assert(float(winter_projection["stock_end"]) < float(Plan.project_stock(normal_yield, 1)["stock_end"]), "lean-season harvests should be scaled down")
	var delayed := base.duplicate(true)
	delayed["stock"] = 500.0
	delayed["demand"] = [1.0, 1.0, 1.0, 1.0]
	delayed["average_demand"] = 1.0
	delayed["cover_min_days"] = 14.0
	delayed["cover_max_days"] = 90.0
	var plan: Dictionary = Plan.target_crew(delayed)
	assert(int(plan["target"]) == 0, "large starting stock should delay hiring")
	var near_harvest := base.duplicate(true)
	near_harvest["stock"] = 0.0
	near_harvest["fields"] = [{"area": 100.0, "days_growing": 0, "labor_applied": 10.0}]
	near_harvest["demand"] = [0.0]
	near_harvest["yield_scales"] = [1.0]
	near_harvest["horizon"] = 1
	near_harvest["growth_days"] = 1
	near_harvest["land_area"] = 100.0
	near_harvest["labor_per_area_per_day"] = 0.1
	near_harvest["yield_per_area"] = 1.0
	near_harvest["average_demand"] = 1.0
	near_harvest["cover_min_days"] = 14.0
	assert(float(Plan.project_stock(near_harvest, 0)["min_stock"]) >= 14.0, "imminent harvest should satisfy the projected safety stock")
	var wide_capacity := near_harvest.duplicate(true)
	wide_capacity["fields"] = [{"area": 100.0, "days_growing": 0, "labor_applied": 0.0}]
	wide_capacity["demand"] = [50.0]
	wide_capacity["average_demand"] = 50.0
	wide_capacity["cover_min_days"] = 1.0
	wide_capacity["max_capacity"] = 100
	var wide_plan: Dictionary = Plan.target_crew(wide_capacity)
	assert(int(wide_plan["target"]) == 10, "crew search should converge above the old six-round bound")
	var impossible := base.duplicate(true)
	impossible["demand"] = [100.0, 100.0, 100.0, 100.0]
	impossible["average_demand"] = 100.0
	impossible["cover_min_days"] = 14.0
	var impossible_plan: Dictionary = Plan.target_crew(impossible)
	assert(int(impossible_plan["target"]) == 10 and bool(impossible_plan["max_capacity_insufficient"]), "impossible demand should return max capacity")
	assert(is_equal_approx(Plan.cost_per_unit({"wages": 12.0, "input_cost": 3.0, "units_produced": 5.0}), 3.0), "unit cost should include wages and inputs")
	var sim := Sim.new(4242, Callable(Seeds, "build_preset").bind("small_village"))
	var farm = null
	for b in sim.businesses.values():
		if b.type_key == "farm":
			farm = b
	assert(farm != null)
	sim.advance_ticks(1)
	for field in farm.fields:
		field.days_growing = farm.growth_days - 1
		field.labor_applied = field.area * farm.labor_per_area_per_day * (farm.growth_days - 1) * 0.6
	var crew: int = sim._business_effective_worker_count(farm.id)
	var inputs := {"stock": farm.stock(farm.output_commodity()), "fields": [], "demand": [0.0],
		"yield_scales": [Sim.seasonal_yield_scale(farm.output_commodity(), sim.day)], "horizon": 1,
		"growth_days": farm.growth_days, "land_area": farm.land_area_acres,
		"labor_per_area_per_day": farm.labor_per_area_per_day, "yield_per_area": farm.yield_per_area,
		"productivity": sim._tool_productivity(farm)}
	for field in farm.fields:
		inputs["fields"].append({"area": field.area, "days_growing": field.days_growing, "labor_applied": field.labor_applied})
	var projected: Dictionary = Plan.project_stock(inputs, crew)
	var before: float = farm.stock(farm.output_commodity())
	sim._run_field_growth(farm, {"produced": {}})
	assert(is_equal_approx(float(projected["stock_end"]) - before, farm.last_actual_units), "projection harvest should match field-growth harvest")
	print("Producer plan checks passed")
	quit()
