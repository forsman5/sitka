extends SceneTree

## Town layout acceptance check (no scene needed). Run with:
##   godot --headless --script res://scripts/sim/harness/check_town_layout.gd

const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HEFixtures = preload("res://scripts/sim/harness/he_fixtures.gd")
const HETownLayout = preload("res://scripts/sim/household_economy/he_town_layout.gd")

const SEED := 4242

var _ok := true

func _init() -> void:
	_check_default_scenario_sites()
	_check_custom_scenario_shows_only_its_businesses()
	_check_regeneration_is_deterministic()
	_check_scenarios_differ()
	_check_incremental_allocation_keeps_sites()
	_check_failure_vacates_and_reuse_fills_it()
	_check_houses_fill_the_residential_zone()
	_check_tenement_upgrade_in_place()
	_check_full_roster_fits()
	_check_no_overlap_and_bounds_under_load()
	_check_roads_and_frontage()
	_check_scenario_key_identity()
	print("TOWN LAYOUT %s" % ("OK" if _ok else "FAILED"))
	quit(0 if _ok else 1)

func _assert(condition: bool, message: String) -> void:
	if not condition:
		_ok = false
		push_error("FAIL: " + message)

func _reports(builder: Callable) -> Array:
	return HESimulation.new(SEED, builder).get_business_reports()

func _default_builder() -> Callable:
	return Callable(HEFixtures, "build_three_business_economy")

## [layout, business reports, dwelling reports]
func _layout_for(builder: Callable) -> Array:
	var sim := HESimulation.new(SEED, builder)
	var reports := sim.get_business_reports()
	var dwellings := sim.get_dwelling_reports()
	var layout := HETownLayout.new(HETownLayout.scenario_key_for(builder), HEScenarioSeeds.SETTLEMENT_ID, reports, dwellings)
	return [layout, reports, dwellings]

func _positions(layout) -> Dictionary:
	var out := {}
	for site in layout.get_sites():
		out[site["site_id"]] = site["position"]
	return out

func _site_types(layout) -> Dictionary:
	var out := {}
	for site in layout.get_sites():
		if site["business_id"] != HETownLayout.NO_BUSINESS:
			out[site["type_key"]] = site
	return out

func _check_default_scenario_sites() -> void:
	var built := _layout_for(_default_builder())
	var layout = built[0]
	var types := _site_types(layout)
	for key in ["government", "farm", "cattle_ranch", "sheep_farm"]:
		_assert(types.has(key), "Default scenario should place a %s" % key)
	_assert(types["government"]["site_id"] == HETownLayout.CIVIC_SITE_ID, "Government belongs on the civic anchor")
	_assert(types["government"]["position"] == Vector2.ZERO, "Civic anchor sits at the town origin")
	var seen := {}
	for site in layout.get_sites():
		if site["business_id"] != HETownLayout.NO_BUSINESS:
			_assert(not seen.has(site["position"]), "Occupied sites must be at distinct positions")
			seen[site["position"]] = true
	_assert(layout.unplaced_business_ids().is_empty(), "Every starting business should be placed")
	_assert(types["farm"]["zone"] == HETownLayout.ZONE_FIELD, "Farm should land in the field zone")
	_assert(types["cattle_ranch"]["zone"] == HETownLayout.ZONE_PASTURE, "Ranch should land in the pasture zone")

func _check_custom_scenario_shows_only_its_businesses() -> void:
	var builder := Callable(HEFixtures, "build_custom").bind([HEScenarioSeeds.WOODLOT_BUSINESS_ID, HEScenarioSeeds.CATTLE_RANCH_BUSINESS_ID])
	var built := _layout_for(builder)
	var layout = built[0]
	var reports: Array = built[1]
	var occupied := 0
	for site in layout.get_sites():
		if site["business_id"] != HETownLayout.NO_BUSINESS:
			occupied += 1
	_assert(occupied == reports.size(), "Custom scenario: one occupied site per live business (%d vs %d)" % [occupied, reports.size()])
	_assert(not _site_types(layout).has("farm"), "A custom roster without a farm must not show one")

func _check_regeneration_is_deterministic() -> void:
	var first := _positions(_layout_for(_default_builder())[0])
	var second := _positions(_layout_for(_default_builder())[0])
	_assert(first == second, "The same scenario must regenerate the same layout")

func _check_scenarios_differ() -> void:
	var a := _positions(_layout_for(_default_builder())[0])
	var b := _positions(_layout_for(Callable(HEFixtures, "build_economy_with_charcoal_burner"))[0])
	_assert(a != b, "A different scenario should produce its own layout")

func _live_report(business_id: int, type_key: String, name: String) -> Dictionary:
	return {"business_id": business_id, "settlement_id": HEScenarioSeeds.SETTLEMENT_ID, "type_key": type_key, "name": name}

func _check_incremental_allocation_keeps_sites() -> void:
	var built := _layout_for(_default_builder())
	var layout = built[0]
	var reports: Array = built[1].duplicate()
	var before := _positions(layout)
	var revision_before: int = layout.revision
	_assert(not layout.reconcile(reports), "Reconciling an unchanged roster must not change anything")
	_assert(layout.revision == revision_before, "Unchanged reconcile must not bump the revision")
	reports.append(_live_report(100, "woodlot", "Woodlot"))
	_assert(layout.reconcile(reports), "A new business should change the layout")
	var after := _positions(layout)
	for site_id in before:
		_assert(after[site_id] == before[site_id], "Site %d moved when a business was added" % site_id)
	_assert(after.size() == before.size() + 1, "A new business with no vacancy should add exactly one site")
	_assert(layout.site_of_business(100)["zone"] == HETownLayout.ZONE_FIELD, "A woodlot should be allocated in the field zone")

func _check_failure_vacates_and_reuse_fills_it() -> void:
	var built := _layout_for(_default_builder())
	var layout = built[0]
	var reports: Array = built[1].duplicate()
	var victim: Dictionary = {}
	for report in reports:
		if report["type_key"] == "farm":
			victim = report
	var victim_site: Dictionary = layout.site_of_business(victim["business_id"])
	var before := _positions(layout)
	var survivors := reports.filter(func(r: Dictionary) -> bool: return r["business_id"] != victim["business_id"])
	layout.reconcile(survivors)
	var vacated: Dictionary = layout.get_site(victim_site["site_id"])
	_assert(vacated["business_id"] == HETownLayout.NO_BUSINESS, "A failed business should vacate its site")
	_assert(vacated["built"], "The vacated building should remain")
	_assert(_positions(layout) == before, "A failure must not move any site")
	survivors.append(_live_report(101, "butcher", "Butcher"))
	layout.reconcile(survivors)
	_assert(layout.site_of_business(101).get("site_id", -2) == victim_site["site_id"], "The next business should reuse the vacant site regardless of type")
	_assert(_positions(layout) == before, "Reuse must not add or move sites")

func _dwelling_report(dwelling_id: int) -> Dictionary:
	return {"dwelling_id": dwelling_id, "settlement_id": HEScenarioSeeds.SETTLEMENT_ID, "type_key": "house", "name": "House"}

func _check_houses_fill_the_residential_zone() -> void:
	var built := _layout_for(_default_builder())
	var layout = built[0]
	var dwellings: Array = built[2].duplicate()
	_assert(dwellings.size() == 41, "Seeded town should start with 41 houses (got %d)" % dwellings.size())
	var house_sites := 0
	for site in layout.get_sites():
		if site["dwelling_id"] != HETownLayout.NO_BUSINESS:
			house_sites += 1
			_assert(site["zone"] == HETownLayout.ZONE_HOUSING, "A house belongs in the residential zone")
			_assert(site["business_id"] == HETownLayout.NO_BUSINESS and site["type_key"] == "house", "A house site holds only a house")
			_assert(site["site_id"] != HETownLayout.CIVIC_SITE_ID, "Houses stay off the civic anchor")
	_assert(house_sites == 41 and layout.unplaced_dwelling_ids().is_empty(), "All 41 houses should be placed (got %d, %d unplaced)" % [house_sites, layout.unplaced_dwelling_ids().size()])
	# A new house adds one site and moves nothing.
	var before := _positions(layout)
	dwellings.append(_dwelling_report(9999))
	_assert(layout.reconcile(built[1], dwellings), "A new house should change the layout")
	var after := _positions(layout)
	for site_id in before:
		_assert(after[site_id] == before[site_id], "Site %d moved when a house was added" % site_id)
	_assert(after.size() == before.size() + 1, "A new house should add exactly one site")
	_assert(layout.site_of_dwelling(9999).get("zone", "") == HETownLayout.ZONE_HOUSING, "The new house should land in the residential zone")
	# Houses never vacate and are never reused by a business.
	layout.reconcile(built[1], [])
	_assert(not layout.site_of_dwelling(9999).is_empty(), "A house site must never be vacated")
	var reports: Array = built[1].duplicate()
	reports.append(_live_report(500, "butcher", "Butcher 2"))
	for report in built[1]:
		if report["type_key"] == "farm":
			reports.erase(report)
	layout.reconcile(reports, dwellings)
	_assert(layout.site_of_business(500).get("zone", HETownLayout.ZONE_HOUSING) != HETownLayout.ZONE_HOUSING, "A business must not move into a house")
	_assert(layout.site_of_dwelling(9999).get("business_id", 0) == HETownLayout.NO_BUSINESS, "A house site stays a house site")

func _check_tenement_upgrade_in_place() -> void:
	var built := _layout_for(_default_builder())
	var layout = built[0]
	var dwellings: Array = built[2].duplicate(true)
	_assert(not layout.prefers_densify(), "A default town has room: no pressure to densify")
	var before := _positions(layout)
	var first: Dictionary = dwellings[0]
	var site_before: Dictionary = layout.site_of_dwelling(int(first["dwelling_id"]))
	first["type_key"] = "tenement"
	first["name"] = "Tenement"
	_assert(layout.reconcile(built[1], dwellings), "Upgrading a house should change the layout")
	var site_after: Dictionary = layout.site_of_dwelling(int(first["dwelling_id"]))
	_assert(site_after["site_id"] == site_before["site_id"] and site_after["position"] == site_before["position"], "An upgrade keeps the site")
	_assert(site_after["type_key"] == "tenement", "The site takes the tenement kind")
	_assert(_positions(layout) == before, "An upgrade moves and adds nothing")
	# Packing past the static network's capacity flips the densify preference.
	for i in range(60):
		dwellings.append(_dwelling_report(5000 + i))
	layout.reconcile(built[1], dwellings)
	_assert(layout.prefers_densify(), "A crowded town should prefer densifying")

func _check_full_roster_fits() -> void:
	# Every unique business type plus the government and its warehouse: the
	# most one town can hold, so none may be left unplaced.
	var built := _layout_for(_default_builder())
	var layout = built[0]
	var reports: Array = built[1].duplicate()
	var have := {}
	for report in reports:
		have[report["type_key"]] = true
	var next_id := 300
	for option in HEScenarioSeeds.business_types() + [{"type_key": "warehouse", "label": "Government Warehouse"}]:
		if not have.has(option["type_key"]):
			reports.append(_live_report(next_id, option["type_key"], option["label"]))
			next_id += 1
	layout.reconcile(reports, built[2])
	_assert(layout.unplaced_business_ids().is_empty(), "A full roster of %d businesses should all be placed" % reports.size())
	_assert(layout.unplaced_dwelling_ids().is_empty(), "Every house should still have a plot beside a full roster")

func _check_no_overlap_and_bounds_under_load() -> void:
	var built := _layout_for(_default_builder())
	var layout = built[0]
	var reports: Array = built[1].duplicate()
	for i in 80:
		var kinds := ["farm", "cattle_ranch", "butcher", "sheep_farm", "woodlot"]
		reports.append(_live_report(200 + i, kinds[i % kinds.size()], "Extra %d" % i))
	layout.reconcile(reports, built[2])
	var sites: Array = layout.get_sites()
	var limit := Rect2(Vector2.ONE * -HETownLayout.HALF_EXTENT, Vector2.ONE * HETownLayout.HALF_EXTENT * 2.0)
	for i in sites.size():
		var rect: Rect2 = layout.site_rect(sites[i])
		_assert(limit.encloses(rect), "Site %d lies outside the town bounds" % i)
		for j in range(i + 1, sites.size()):
			_assert(not HETownLayout.sites_crowd(sites[j], sites[i], HETownLayout.SITE_SPACING - 0.01), "Sites %d and %d overlap or crowd" % [i, j])
	var occupied := 0
	for site in sites:
		if site["business_id"] != HETownLayout.NO_BUSINESS:
			occupied += 1
	_assert(occupied + layout.unplaced_business_ids().size() == reports.size(), "Every business is either seated or reported unplaced")
	print("  load: %d sites, %d unplaced of %d businesses" % [sites.size(), layout.unplaced_business_ids().size(), reports.size()])

## Distance from `point` to the nearest point of a polyline.
func _distance_to_polyline(point: Vector2, points: PackedVector2Array) -> float:
	var best := INF
	for i in range(points.size() - 1):
		best = minf(best, point.distance_to(Geometry2D.get_closest_point_to_segment(point, points[i], points[i + 1])))
	return best

func _check_roads_and_frontage() -> void:
	var built := _layout_for(_default_builder())
	var layout = built[0]
	var roads: Array = layout.get_roads()
	_assert(roads.size() >= HETownLayout.ROAD_SPOKE_COUNT, "The town should start with its spokes (got %d roads)" % roads.size())
	# Every placed site keeps its centre clear of every road ribbon (a footprint
	# always contains the disc of its smaller half-extent).
	for site in layout.get_sites():
		if site["site_id"] == HETownLayout.CIVIC_SITE_ID:
			continue
		var inradius: float = minf(site["footprint"].x, site["footprint"].y) * 0.5
		for road in roads:
			var gap := _distance_to_polyline(site["position"], road["points"]) - float(road["width"]) * 0.5
			_assert(gap >= inradius - 0.01, "Site %d (%s) sits on road %d" % [site["site_id"], site["type_key"], road["road_id"]])
		if site["zone"] == HETownLayout.ZONE_HOUSING:
			_assert(site["road_id"] >= 0 and site["road_id"] < roads.size(), "House site %d should record the road it fronts" % site["site_id"])
			var access: Vector2 = site["access"]
			_assert(access.is_finite(), "House site %d should have a door access point" % site["site_id"])
			if access.is_finite():
				var road: Dictionary = roads[site["road_id"]]
				_assert(_distance_to_polyline(access, road["points"]) < 0.01, "Site %d's access point should lie on its road" % site["site_id"])
				# Door to road: at most the setback jitter plus half a ribbon, a short walk.
				_assert(site["position"].distance_to(access) <= 3.0 + 1.0 + 1.2 + float(road["width"]) * 0.5 + 1.5, "Site %d is too far from its road" % site["site_id"])
	# Roads are deterministic and only ever grow.
	var again = _layout_for(_default_builder())[0]
	_assert(again.get_roads().size() == roads.size(), "Road network must be a pure function of the scenario")
	var dwellings: Array = built[2].duplicate()
	for i in 80:
		dwellings.append(_dwelling_report(5000 + i))
	var site_positions := _positions(layout)
	layout.reconcile(built[1], dwellings)
	var grown: Array = layout.get_roads()
	_assert(grown.size() > roads.size(), "Running out of house lots should grow new lanes")
	for i in roads.size():
		_assert(grown[i]["points"] == roads[i]["points"], "Road %d moved when the town grew" % i)
	var after := _positions(layout)
	for site_id in site_positions:
		_assert(after[site_id] == site_positions[site_id], "Site %d moved when roads grew" % site_id)
	print("  roads: %d at start, %d after +80 houses (%d unplaced)" % [roads.size(), grown.size(), layout.unplaced_dwelling_ids().size()])

func _check_scenario_key_identity() -> void:
	var a := Callable(HEFixtures, "build_custom").bind([3, 1, 2])
	var b := Callable(HEFixtures, "build_custom").bind([1, 2, 3])
	var c := Callable(HEFixtures, "build_custom").bind([1, 2])
	_assert(HETownLayout.scenario_key_for(a) == HETownLayout.scenario_key_for(b), "Roster order must not change scenario identity")
	_assert(HETownLayout.scenario_key_for(a) != HETownLayout.scenario_key_for(c), "Different rosters must have different identity")
	_assert(HETownLayout.scenario_key_for(_default_builder()) != HETownLayout.scenario_key_for(a), "Presets and custom rosters must differ")
