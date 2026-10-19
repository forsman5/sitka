class_name HEProducerPlan
extends RefCounted

## Pure helpers for projecting field-model production. Input dictionaries use
## plain field snapshots and a per-day demand array indexed from the next day.
static func project_stock(inputs: Dictionary, crew: int) -> Dictionary:
	var stock := float(inputs.get("stock", 0.0))
	var demand: Array = inputs.get("demand", [])
	var fields: Array = inputs.get("fields", [])
	var field_states: Array = []
	for source in fields:
		field_states.append((source as Dictionary).duplicate())
	var harvests: Array = []
	var horizon: int = mini(int(inputs.get("horizon", demand.size())), demand.size())
	var growth_days: int = int(inputs.get("growth_days", 1))
	var land_area := float(inputs.get("land_area", 0.0))
	var labor_rate := float(inputs.get("labor_per_area_per_day", 0.0))
	var yield_per_area := float(inputs.get("yield_per_area", 0.0))
	var productivity := float(inputs.get("productivity", 1.0))
	var curve: Array = inputs.get("yield_scales", [])
	var min_stock := stock
	var cumulative_demand := 0.0
	for offset in range(1, horizon + 1):
		var daily_harvest := 0.0
		for field_value in field_states:
			var f: Dictionary = field_value
			var area := float(f.get("area", 0.0))
			var days_growing := int(f.get("days_growing", 0))
			var labor := float(f.get("labor_applied", 0.0))
			var share := float(crew) * productivity * area / land_area if land_area > 0.0 else 0.0
			days_growing += 1
			labor += share
			if days_growing >= growth_days:
				var required := area * labor_rate * growth_days
				var efficiency := clampf(labor / required, 0.0, 1.0) if required > 0.0 else 0.0
				var scale := float(curve[offset - 1]) if offset - 1 < curve.size() else 1.0
				daily_harvest += area * yield_per_area * efficiency * scale
				days_growing = 0
				labor = 0.0
			f["days_growing"] = days_growing
			f["labor_applied"] = labor
		stock += daily_harvest
		cumulative_demand += float(demand[offset - 1])
		stock -= float(demand[offset - 1])
		min_stock = minf(min_stock, stock)
		if daily_harvest > 0.0:
			harvests.append({"offset": offset, "units": daily_harvest})
	return {"stock_end": stock, "min_stock": min_stock, "harvests": harvests,
		"cumulative_demand": cumulative_demand}

## Smallest crew satisfying the safety stock path. A surplus above maximum
## cover at the current crew releases the target toward a lower crew gradually.
static func target_crew(inputs: Dictionary) -> Dictionary:
	var low := int(inputs.get("min_capacity", 0))
	var high := int(inputs.get("max_capacity", low))
	var current := int(inputs.get("current_capacity", low))
	var min_cover := float(inputs.get("cover_min_days", 14.0)) * float(inputs.get("average_demand", 0.0))
	var max_cover := float(inputs.get("cover_max_days", 90.0)) * float(inputs.get("average_demand", 0.0))
	var current_projection := project_stock(inputs, current)
	if float(current_projection["stock_end"]) > max_cover and float(current_projection["min_stock"]) >= min_cover:
		high = mini(high, current)
	var max_projection := project_stock(inputs, high)
	if float(max_projection["min_stock"]) < min_cover:
		return {"target": high, "reason": "plan_short", "max_capacity_insufficient": true,
			"projection": max_projection}
	var left := low
	var right := high
	for _i in range(6):
		if left >= right:
			break
		var mid := (left + right) / 2
		var projection := project_stock(inputs, mid)
		if float(projection["min_stock"]) >= min_cover:
			right = mid
		else:
			left = mid + 1
	var target := left
	var projected := project_stock(inputs, target)
	var reason := "plan_hold"
	if target > current:
		reason = "plan_short"
	elif target < current:
		reason = "plan_surplus"
	return {"target": target, "reason": reason, "max_capacity_insufficient": false,
		"projection": projected, "current_projection": current_projection}

static func cost_per_unit(summary: Dictionary) -> float:
	var produced := float(summary.get("units_produced", 0.0))
	var employed := maxf(1.0, float(summary.get("employed", 0.0)))
	if produced <= 0.0001:
		return float(summary.get("fallback_cost_per_unit", 0.0))
	return (float(summary.get("wages", 0.0)) + float(summary.get("input_cost", 0.0))) / produced
