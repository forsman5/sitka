extends SceneTree

## Villager daily-schedule acceptance check (pure data, no scene). Run with:
##   godot --headless --path . --script res://scripts/sim/harness/check_villager_schedule.gd

const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
const HETownLayout = preload("res://scripts/sim/household_economy/he_town_layout.gd")
const HETownPaths = preload("res://scripts/sim/household_economy/he_town_paths.gd")
const HEVillagerSchedule = preload("res://scripts/sim/household_economy/he_villager_schedule.gd")

const SEED := 4242
const DAY := 3
## Largest step between one-minute samples that is not a door transition.
const MAX_STEP_PER_MINUTE := 1.2

var _ok := true

func _init() -> void:
	for preset in ["small_village", "large_village"]:
		_check_preset(preset)
	print("VILLAGER SCHEDULE %s" % ("OK" if _ok else "FAILED"))
	quit(0 if _ok else 1)

func _assert(condition: bool, message: String) -> void:
	if not condition:
		_ok = false
		push_error("FAIL: " + message)

## One villager: {"key", "role", "home", "work", "plan"}.
func _villagers_for(preset: String) -> Array:
	var builder := Callable(HEScenarioSeeds, "build_preset").bind(preset)
	var sim := HESimulation.new(SEED, builder)
	sim.advance_ticks(5)
	var layout := HETownLayout.new(HETownLayout.scenario_key_for(builder), HEScenarioSeeds.SETTLEMENT_ID, sim.get_business_reports(), sim.get_dwelling_reports())
	layout.reconcile(sim.get_business_reports(), sim.get_dwelling_reports(), sim.get_construction_reports())
	var paths := HETownPaths.new(layout)
	var out: Array = []
	for report in sim.get_villager_reports(HEScenarioSeeds.SETTLEMENT_ID):
		var dwelling_id := int(report["dwelling_id"])
		var home := layout.site_of_dwelling(dwelling_id) if dwelling_id != -1 else {}
		if not home.is_empty() and not bool(home.get("built", false)):
			home = {}
		var employer := int(report["employer_business_id"])
		var work := layout.site_of_business(employer) if employer != -1 else {}
		var workers: PackedInt32Array = report["worker_ages"]
		var dependents: PackedInt32Array = report["dependent_ages"]
		for i in workers.size() + dependents.size():
			var is_worker := i < workers.size()
			var child := not is_worker and dependents[i - workers.size()] < HEHousehold.AGING_THRESHOLD_DAYS
			var role := HEVillagerSchedule.ROLE_CHILD if child else HEVillagerSchedule.ROLE_ADULT
			var job := {}
			if is_worker and not work.is_empty():
				role = HEVillagerSchedule.ROLE_EMPLOYED
				job = work
			var key := Vector2i(int(report["household_id"]), i + 1)
			out.append({
				"key": key, "role": role, "home": home, "work": job,
				"plan": HEVillagerSchedule.plan(key, role, DAY, home, job, paths),
			})
	return [out, paths, layout]

func _check_preset(preset: String) -> void:
	var built := _villagers_for(preset)
	var villagers: Array = built[0]
	var paths: HETownPaths = built[1]
	var layout: HETownLayout = built[2]
	_assert(villagers.size() > 20, "%s: needs villagers (%d)" % [preset, villagers.size()])
	_check_night(preset, villagers)
	_check_noon(preset, villagers, layout)
	_check_commute(preset, villagers, paths)
	_check_continuity(preset, villagers)
	_check_determinism(preset, villagers, built[1])

func _at(v: Dictionary, hour: float) -> Dictionary:
	return HEVillagerSchedule.evaluate(v["plan"], hour / 24.0)

func _check_night(preset: String, villagers: Array) -> void:
	var housed := 0
	var bad := 0
	var homeless_hidden := 0
	for v in villagers:
		for hour in [0.0, 2.5, 23.5]:
			var at := _at(v, hour)
			if (v["home"] as Dictionary).is_empty():
				if not at["visible"]:
					homeless_hidden += 1
			else:
				housed += 1
				if at["visible"]:
					bad += 1
	_assert(housed > 0, "%s: some villagers are housed" % preset)
	_assert(bad == 0, "%s: housed villagers are indoors at night (%d of %d samples visible)" % [preset, bad, housed])
	_assert(homeless_hidden == 0, "%s: homeless villagers stay visible at night" % preset)

func _check_noon(preset: String, villagers: Array, layout: HETownLayout) -> void:
	var open_workers := 0
	var outside := 0
	var town_workers := 0
	var town_hidden := 0
	var town_visible_not_at_door := 0
	for v in villagers:
		if v["role"] != HEVillagerSchedule.ROLE_EMPLOYED:
			continue
		var work: Dictionary = v["work"]
		var at := _at(v, 12.0)
		if HEVillagerSchedule.is_open_site(work):
			open_workers += 1
			var p: Vector2 = at["pos"]
			if not at["visible"] or not layout.site_contains(work, p):
				outside += 1
		else:
			town_workers += 1
			if not at["visible"]:
				town_hidden += 1
			elif at["activity"] != "work_door":
				town_visible_not_at_door += 1
	print("%s: noon, %d open-site workers, %d town workers" % [preset, open_workers, town_workers])
	_assert(open_workers > 0, "%s: has field/pasture/woodlot workers" % preset)
	_assert(outside == 0, "%s: every open-site worker is inside their footprint at noon (%d outside)" % [preset, outside])
	_assert(town_workers > 0, "%s: has town-business workers" % preset)
	_assert(town_hidden * 10 >= town_workers * 9, "%s: town workers are hidden at noon (%d of %d)" % [preset, town_hidden, town_workers])
	_assert(town_visible_not_at_door == 0, "%s: a visible town worker is only ever at their door" % preset)

func _check_commute(preset: String, villagers: Array, paths: HETownPaths) -> void:
	var commuters := 0
	var walking := 0
	var off_route := 0
	for v in villagers:
		if v["role"] != HEVillagerSchedule.ROLE_EMPLOYED or (v["home"] as Dictionary).is_empty():
			continue
		commuters += 1
		var at := _at(v, 7.0)
		if at["activity"] != "walk_work":
			continue
		walking += 1
		var route := paths.path(int(v["home"]["site_id"]), int(v["work"]["site_id"]))
		var best := INF
		var p: Vector2 = at["pos"]
		for i in range(route.size() - 1):
			best = minf(best, p.distance_to(Geometry2D.get_closest_point_to_segment(p, route[i], route[i + 1])))
		if best > 0.5:
			off_route += 1
	print("%s: 07:00, %d of %d commuters walking" % [preset, walking, commuters])
	_assert(commuters > 0, "%s: has commuters" % preset)
	_assert(walking * 2 >= commuters, "%s: most commuters are on the road at 07:00 (%d of %d)" % [preset, walking, commuters])
	_assert(off_route == 0, "%s: commuters stay on their road route (%d off)" % [preset, off_route])

func _check_continuity(preset: String, villagers: Array) -> void:
	var jumps := 0
	var worst := 0.0
	var minutes := int((HEVillagerSchedule.DAY_END - HEVillagerSchedule.DAY_START) * 60.0)
	for v in villagers:
		var last: Dictionary = {}
		for m in range(minutes + 1):
			var h := HEVillagerSchedule.DAY_START + float(m) / 60.0
			var at := HEVillagerSchedule.evaluate(v["plan"], h / 24.0)
			if not last.is_empty() and last["visible"] and at["visible"]:
				var step := (last["pos"] as Vector2).distance_to(at["pos"])
				worst = maxf(worst, step)
				if step > MAX_STEP_PER_MINUTE:
					jumps += 1
					if jumps <= 5:
						print("  jump %s at %.2f: %.2f (%s -> %s)" % [v["key"], h, step, last["activity"], at["activity"]])
			last = at
		# Indoor <-> outdoor changes happen at the door: the visible end is at a door.
	print("%s: largest one-minute step %.2f" % [preset, worst])
	_assert(jumps == 0, "%s: positions are continuous (%d jumps)" % [preset, jumps])

func _check_determinism(preset: String, villagers: Array, paths: HETownPaths) -> void:
	var differing := 0
	for v in villagers:
		var again := HEVillagerSchedule.plan(v["key"], v["role"], DAY, v["home"], v["work"], paths)
		for hour in [0.5, 6.5, 7.0, 8.2, 12.0, 15.5, 18.0, 20.0, 22.5]:
			var a := HEVillagerSchedule.evaluate(v["plan"], hour / 24.0)
			var b := HEVillagerSchedule.evaluate(again, hour / 24.0)
			if a["pos"] != b["pos"] or a["visible"] != b["visible"] or a["activity"] != b["activity"]:
				differing += 1
	_assert(differing == 0, "%s: same inputs give the same result (%d differ)" % [preset, differing])
	# Another sim day shifts the jitter, so the days are not copies of each other.
	var shifted := 0
	for v in villagers:
		var other := HEVillagerSchedule.plan(v["key"], v["role"], DAY + 1, v["home"], v["work"], paths)
		if float(other["segs"][0]["t1"]) != float((v["plan"] as Dictionary)["segs"][0]["t1"]):
			shifted += 1
	_assert(shifted * 2 > villagers.size(), "%s: timetables jitter from day to day (%d of %d shifted)" % [preset, shifted, villagers.size()])
