extends SceneTree

## Town layout acceptance check (no scene needed). Run with:
##   godot --headless --script res://scripts/sim/harness/check_town_layout.gd

const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
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
	_check_full_roster_fits()
	_check_no_overlap_and_bounds_under_load()
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
	return Callable(HEScenarioSeeds, "build_three_business_economy")

func _layout_for(builder: Callable) -> Array:
	var reports := _reports(builder)
	var layout := HETownLayout.new(HETownLayout.scenario_key_for(builder), HEScenarioSeeds.SETTLEMENT_ID, reports)
	return [layout, reports]

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
	var builder := Callable(HEScenarioSeeds, "build_custom").bind([HEScenarioSeeds.WOODLOT_BUSINESS_ID, HEScenarioSeeds.CATTLE_RANCH_BUSINESS_ID])
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
	var b := _positions(_layout_for(Callable(HEScenarioSeeds, "build_economy_with_charcoal_burner"))[0])
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
	layout.reconcile(reports)
	_assert(layout.unplaced_business_ids().is_empty(), "A full roster of %d businesses should all be placed" % reports.size())

func _check_no_overlap_and_bounds_under_load() -> void:
	var built := _layout_for(_default_builder())
	var layout = built[0]
	var reports: Array = built[1].duplicate()
	for i in 80:
		var kinds := ["farm", "cattle_ranch", "butcher", "sheep_farm", "woodlot"]
		reports.append(_live_report(200 + i, kinds[i % kinds.size()], "Extra %d" % i))
	layout.reconcile(reports)
	var sites: Array = layout.get_sites()
	var limit := Rect2(Vector2.ONE * -HETownLayout.HALF_EXTENT, Vector2.ONE * HETownLayout.HALF_EXTENT * 2.0)
	for i in sites.size():
		var rect: Rect2 = layout.site_rect(sites[i])
		_assert(limit.encloses(rect), "Site %d lies outside the town bounds" % i)
		for j in range(i + 1, sites.size()):
			_assert(not rect.grow(HETownLayout.SITE_SPACING - 0.01).intersects(layout.site_rect(sites[j])), "Sites %d and %d overlap or crowd" % [i, j])
	var occupied := 0
	for site in sites:
		if site["business_id"] != HETownLayout.NO_BUSINESS:
			occupied += 1
	_assert(occupied + layout.unplaced_business_ids().size() == reports.size(), "Every business is either seated or reported unplaced")
	print("  load: %d sites, %d unplaced of %d businesses" % [sites.size(), layout.unplaced_business_ids().size(), reports.size()])

func _check_scenario_key_identity() -> void:
	var a := Callable(HEScenarioSeeds, "build_custom").bind([3, 1, 2])
	var b := Callable(HEScenarioSeeds, "build_custom").bind([1, 2, 3])
	var c := Callable(HEScenarioSeeds, "build_custom").bind([1, 2])
	_assert(HETownLayout.scenario_key_for(a) == HETownLayout.scenario_key_for(b), "Roster order must not change scenario identity")
	_assert(HETownLayout.scenario_key_for(a) != HETownLayout.scenario_key_for(c), "Different rosters must have different identity")
	_assert(HETownLayout.scenario_key_for(_default_builder()) != HETownLayout.scenario_key_for(a), "Presets and custom rosters must differ")
