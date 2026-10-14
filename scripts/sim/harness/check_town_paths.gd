extends SceneTree

## Town road-path acceptance check (no scene needed). Run with:
##   godot --headless --script res://scripts/sim/harness/check_town_paths.gd

const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HETownLayout = preload("res://scripts/sim/household_economy/he_town_layout.gd")
const HETownPaths = preload("res://scripts/sim/household_economy/he_town_paths.gd")

const SEED := 4242
const RIBBON_EPSILON := 0.05
## A frontage door leg: setback plus jitter plus half a ribbon.
const MAX_DOOR_LEG := 8.0
const MAX_OFFROAD_LEG := 40.0

var _ok := true

func _init() -> void:
	for preset in ["small_village", "large_village"]:
		_check_reachability_and_shape(preset)
		_check_determinism(preset)
		_check_symmetry(preset)
		_check_stability_under_growth(preset)
	_check_unknown_sites()
	print("TOWN PATHS %s" % ("OK" if _ok else "FAILED"))
	quit(0 if _ok else 1)

func _assert(condition: bool, message: String) -> void:
	if not condition:
		_ok = false
		push_error("FAIL: " + message)

## [layout, business reports, dwelling reports]
func _layout_for(preset: String) -> Array:
	var builder := Callable(HEScenarioSeeds, "build_preset").bind(preset)
	var sim := HESimulation.new(SEED, builder)
	var reports := sim.get_business_reports()
	var dwellings := sim.get_dwelling_reports()
	var layout := HETownLayout.new(HETownLayout.scenario_key_for(builder), HEScenarioSeeds.SETTLEMENT_ID, reports, dwellings)
	return [layout, reports, dwellings]

func _dwelling_report(dwelling_id: int) -> Dictionary:
	return {"dwelling_id": dwelling_id, "settlement_id": HEScenarioSeeds.SETTLEMENT_ID, "type_key": "house", "name": "House"}

func _live_report(business_id: int, type_key: String) -> Dictionary:
	return {"business_id": business_id, "settlement_id": HEScenarioSeeds.SETTLEMENT_ID, "type_key": type_key, "name": type_key}

func _built_sites(layout) -> Array:
	return layout.get_sites().filter(func(s: Dictionary) -> bool: return s["built"])

func _first_house(layout) -> Dictionary:
	for site in _built_sites(layout):
		if site["zone"] == HETownLayout.ZONE_HOUSING:
			return site
	return {}

func _ribbon_gap(point: Vector2, roads: Array) -> float:
	var best := INF
	for road in roads:
		var points: PackedVector2Array = road["points"]
		for i in range(points.size() - 1):
			var d := point.distance_to(Geometry2D.get_closest_point_to_segment(point, points[i], points[i + 1]))
			best = minf(best, d - float(road["width"]) * 0.5)
	return best

func _check_reachability_and_shape(preset: String) -> void:
	var built := _layout_for(preset)
	var layout = built[0]
	var paths := HETownPaths.new(layout)
	var roads: Array = layout.get_roads()
	var house := _first_house(layout)
	_assert(not house.is_empty(), "%s: needs a house" % preset)
	var count := 0
	var longest_offroad := 0.0
	for site in _built_sites(layout):
		var id: int = site["site_id"]
		count += 1
		var from_civic := paths.path(HETownLayout.CIVIC_SITE_ID, id)
		var from_house := paths.path(house["site_id"], id)
		_assert(not from_civic.is_empty(), "%s: site %d unreachable from civic" % [preset, id])
		_assert(not from_house.is_empty(), "%s: site %d unreachable from a house" % [preset, id])
		if from_house.size() < 2:
			continue
		# Every vertex between the two door ends lies on a road ribbon.
		for i in range(1, from_house.size() - 1):
			if from_house[i] == Vector2.ZERO:
				continue # the civic anchor is the plaza, not a ribbon
			_assert(_ribbon_gap(from_house[i], roads) <= RIBBON_EPSILON, "%s: path vertex %s to site %d is off the roads" % [preset, from_house[i], id])
		var leg := from_house[from_house.size() - 1].distance_to(from_house[from_house.size() - 2])
		if (site["access"] as Vector2).is_finite():
			_assert(leg <= MAX_DOOR_LEG, "%s: door leg of site %d is %.1f long" % [preset, id, leg])
		elif id != HETownLayout.CIVIC_SITE_ID:
			longest_offroad = maxf(longest_offroad, leg)
	print("  %s: %d built sites reachable; longest off-road leg %.1f" % [preset, count, longest_offroad])
	_assert(longest_offroad <= MAX_OFFROAD_LEG, "%s: an off-road leg is %.1f long" % [preset, longest_offroad])

func _signature(layout) -> Dictionary:
	var paths := HETownPaths.new(layout)
	var out := {}
	var house := _first_house(layout)
	for site in _built_sites(layout):
		out[Vector2i(HETownLayout.CIVIC_SITE_ID, site["site_id"])] = paths.path(HETownLayout.CIVIC_SITE_ID, site["site_id"])
		out[Vector2i(house["site_id"], site["site_id"])] = paths.path(house["site_id"], site["site_id"])
	return out

func _check_determinism(preset: String) -> void:
	_assert(_signature(_layout_for(preset)[0]) == _signature(_layout_for(preset)[0]), "%s: two identical layouts must give identical paths" % preset)

func _check_symmetry(preset: String) -> void:
	var layout = _layout_for(preset)[0]
	var paths := HETownPaths.new(layout)
	var sites := _built_sites(layout)
	var step := maxi(1, sites.size() / 12)
	for i in range(0, sites.size(), step):
		for j in range(0, sites.size(), step):
			var a: int = sites[i]["site_id"]
			var b: int = sites[j]["site_id"]
			var reversed := PackedVector2Array(paths.path(a, b))
			reversed.reverse()
			_assert(reversed == paths.path(b, a), "%s: path %d->%d is not the reverse of %d->%d" % [preset, a, b, b, a])

func _check_stability_under_growth(preset: String) -> void:
	var built := _layout_for(preset)
	var layout = built[0]
	var paths := HETownPaths.new(layout)
	var before := {}
	var house := _first_house(layout)
	for site in _built_sites(layout):
		before[site["site_id"]] = paths.path(house["site_id"], site["site_id"])
	var roads_before: int = layout.road_count()
	var reports: Array = built[1].duplicate()
	var dwellings: Array = built[2].duplicate()
	reports.append(_live_report(900, "butcher"))
	reports.append(_live_report(901, "woodlot"))
	dwellings.append(_dwelling_report(9000))
	layout.reconcile(reports, dwellings)
	_assert(_unchanged(paths, house, before), "%s: paths changed after adding sites" % preset)
	for i in 120:
		dwellings.append(_dwelling_report(9100 + i))
	layout.reconcile(reports, dwellings)
	_assert(layout.road_count() > roads_before, "%s: expected road growth" % preset)
	_assert(_unchanged(paths, house, before), "%s: paths changed after road growth" % preset)
	var sites := _built_sites(layout)
	var reachable := 0
	for site in sites:
		if not paths.path(house["site_id"], site["site_id"]).is_empty():
			reachable += 1
	_assert(reachable == sites.size(), "%s: %d of %d sites reachable after growth" % [preset, reachable, sites.size()])
	print("  %s: stable across growth (%d -> %d roads, %d sites)" % [preset, roads_before, layout.road_count(), reachable])

func _unchanged(paths, house: Dictionary, before: Dictionary) -> bool:
	for id in before:
		if paths.path(house["site_id"], id) != before[id]:
			return false
	return true

func _check_unknown_sites() -> void:
	var paths := HETownPaths.new(_layout_for("small_village")[0])
	_assert(paths.path(0, 99999).is_empty(), "Unknown destination must give an empty path")
	_assert(paths.path(-5, 0).is_empty(), "Unknown origin must give an empty path")
	_assert(HETownPaths.path_length(PackedVector2Array([Vector2.ZERO, Vector2(3, 4)])) == 5.0, "path_length")
