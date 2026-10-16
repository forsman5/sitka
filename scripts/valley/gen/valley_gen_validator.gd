extends RefCounted

## Stage 7: cheap structural checks plus an economy *proxy*. The proxy only asks
## whether every settlement's inputs have a producer within road range; running
## the real household economy on a generated valley needs the valley-economy
## integration from #19.

const Terrain = preload("res://scripts/valley/gen/valley_gen_terrain.gd")

const MAX_PAD_SLOPE := 0.14
const MAX_ROAD_GRADE := 0.65
const MAX_DETOUR := 3.5
const MAX_SUPPLY_DISTANCE := 800.0

## role -> {makes, needs}
const TRADE := {
	"town": {"makes": ["grain", "cloth"], "needs": ["iron", "timber"]},
	## A port stands in for outside trade, so it can supply any import.
	"port": {"makes": ["*"], "needs": ["grain"]},
	"pasture": {"makes": ["wool", "meat"], "needs": ["grain", "iron"]},
	"woodland": {"makes": ["timber", "charcoal"], "needs": ["grain"]},
	"ore": {"makes": ["iron"], "needs": ["charcoal", "grain"]},
	"farm": {"makes": ["grain"], "needs": ["iron"]},
	"fishing": {"makes": ["fish"], "needs": ["grain", "timber"]},
}

## Returns {ok, checks: [{name, ok, detail}]}.
static func run(result: Dictionary) -> Dictionary:
	var terrain: Terrain = result["terrain"]
	var sites: Array[Dictionary] = result["sites"]
	var map: ValleyMapDefinition = result["map"]
	var roads: Array[Dictionary] = result["roads"]
	var checks: Array[Dictionary] = []

	var failures: PackedStringArray = result["failures"]
	checks.append(_check("roster", failures.is_empty(), "%d sites" % sites.size() if failures.is_empty() else ", ".join(failures)))

	if terrain.has_sea:
		var sea := terrain.sea_fraction()
		var lo := 0.1
		var hi := 0.6 if terrain.landscape == "coast" else 0.88
		checks.append(_check("sea share", sea >= lo and sea <= hi, "%d%% of the map is sea (want %d-%d%%)" % [roundi(sea * 100.0), roundi(lo * 100.0), roundi(hi * 100.0)]))

	var errors := map.validate_geometry()
	checks.append(_check("map geometry", errors.is_empty(), "valid; %d fords" % map.crossings.size() if errors.is_empty() else "%d errors, e.g. %s" % [errors.size(), errors[0]]))

	var wet := PackedStringArray()
	var steep := PackedStringArray()
	for s in sites:
		var p: Vector2 = s["pos"]
		if terrain.is_water(p.x, p.y):
			wet.append(s["name"])
		var worst := 0.0
		for k in 8:
			var a := float(k) * TAU / 8.0
			var r: float = s["pad"] * 0.7
			var q := p + Vector2(cos(a), sin(a)) * r
			# Banks and beaches are not buildable, so they are not judged.
			var margin := 10.0 if terrain.has_sea else Terrain.BANK
			if terrain.bank_at(q.x, q.y) > margin:
				worst = maxf(worst, terrain.slope_at(q.x, q.y))
		if worst > MAX_PAD_SLOPE:
			steep.append("%s(%s) %.2f" % [s["name"], s["role"], worst])
	checks.append(_check("sites dry", wet.is_empty(), "ok" if wet.is_empty() else ", ".join(wet)))
	checks.append(_check("pad slope", steep.is_empty(), "all <= %.2f" % MAX_PAD_SLOPE if steep.is_empty() else ", ".join(steep)))

	var worst_grade := 0.0
	var worst_detour := 0.0
	var lengths := {}
	for road in roads:
		var line := road_line(map, road["id"])
		var length := 0.0
		for i in range(1, line.size()):
			length += line[i].distance_to(line[i - 1])
		# Grade over ~6 unit windows, away from carved banks (fords are flat).
		for i in range(2, line.size()):
			var window := line[i].distance_to(line[i - 2])
			var a := line[i - 2]
			var b := line[i]
			if window > 0.0 and terrain.bank_at(a.x, a.y) > Terrain.BANK + 1.0 and terrain.bank_at(b.x, b.y) > Terrain.BANK + 1.0:
				worst_grade = maxf(worst_grade, absf(terrain.get_height(b.x, b.y) - terrain.get_height(a.x, a.y)) / window)
		var straight := line[0].distance_to(line[line.size() - 1])
		worst_detour = maxf(worst_detour, length / maxf(straight, 1.0))
		lengths[Vector2i(road["a"], road["b"])] = length
	checks.append(_check("road grade", worst_grade <= MAX_ROAD_GRADE, "worst %.2f (limit %.2f)" % [worst_grade, MAX_ROAD_GRADE]))
	checks.append(_check("road detour", worst_detour <= MAX_DETOUR, "worst %.2fx (limit %.1fx)" % [worst_detour, MAX_DETOUR]))

	var water_routes: Array[Dictionary] = result["water_routes"]
	var stray := 0
	var samples_total := 0
	for route in water_routes:
		lengths[Vector2i(route["a"], route["b"])] = route["length"]
		var line := _route_line(map, route["id"])
		for i in line.size():
			# Away from the landings, a boat must be on open water.
			if line[i].distance_to(line[0]) > 12.0 and line[i].distance_to(line[line.size() - 1]) > 12.0:
				samples_total += 1
				if not terrain.is_sea(line[i].x, line[i].y):
					stray += 1
	if terrain.has_sea and (not water_routes.is_empty() or terrain.islands.size() > 1):
		checks.append(_check("sea routes", stray <= samples_total / 30, "%d routes, %d of %d samples off open water" % [water_routes.size(), stray, samples_total]))
	var distance := _all_pairs(sites, lengths)
	var isolated := PackedStringArray()
	var unsupplied := PackedStringArray()
	for s in sites:
		var needs: Array = TRADE[s["role"]]["needs"]
		for need in needs:
			var best := INF
			for other in sites:
				if other["id"] == s["id"]:
					continue
				var makes: Array = TRADE[other["role"]]["makes"]
				if makes.has(need) or makes.has("*"):
					best = minf(best, distance.get(Vector2i(s["id"], other["id"]), INF))
			if best == INF:
				unsupplied.append("%s:%s" % [s["name"], need])
			elif best > MAX_SUPPLY_DISTANCE:
				isolated.append("%s:%s %d" % [s["name"], need, best])
	var cut_off := PackedStringArray()
	for s in sites:
		if sites.size() > 1 and distance.get(Vector2i(sites[0]["id"], s["id"]), INF) == INF:
			cut_off.append(s["name"])
	checks.append(_check("connected", cut_off.is_empty(), "all settlements linked by road" if cut_off.is_empty() else "no road to %s" % ", ".join(cut_off)))
	var supply_ok := unsupplied.is_empty() and isolated.is_empty()
	var detail := "every input within %d units of a producer" % int(MAX_SUPPLY_DISTANCE)
	if not supply_ok:
		detail = "missing %s; far %s" % [", ".join(unsupplied), ", ".join(isolated)]
	checks.append(_check("supply proxy", supply_ok, detail))

	var ok := true
	for c in checks:
		ok = ok and c["ok"]
	return {"ok": ok, "checks": checks}

static func _route_line(map: ValleyMapDefinition, route_id: String) -> PackedVector2Array:
	var line := PackedVector2Array()
	for p in Terrain.Ribbon._sample_catmull_rom(map.water_route_path(route_id), 3.0):
		line.append(Vector2(p.x, p.z))
	return line

static func road_line(map: ValleyMapDefinition, road_id: String) -> PackedVector2Array:
	var line := PackedVector2Array()
	for p in Terrain.Ribbon._sample_catmull_rom(map.road_path(road_id), 3.0):
		line.append(Vector2(p.x, p.z))
	return line

static func _check(name: String, ok: bool, detail: String) -> Dictionary:
	return {"name": name, "ok": ok, "detail": detail}

## Shortest road distance between every site pair (Floyd-Warshall; <= ~6 nodes).
static func _all_pairs(sites: Array[Dictionary], lengths: Dictionary) -> Dictionary:
	var d := {}
	for a in sites:
		for b in sites:
			d[Vector2i(a["id"], b["id"])] = 0.0 if a["id"] == b["id"] else INF
	for edge in lengths:
		var e: Vector2i = edge
		d[e] = lengths[e]
		d[Vector2i(e.y, e.x)] = lengths[e]
	for k in sites:
		for i in sites:
			for j in sites:
				var via: float = d[Vector2i(i["id"], k["id"])] + d[Vector2i(k["id"], j["id"])]
				if via < d[Vector2i(i["id"], j["id"])]:
					d[Vector2i(i["id"], j["id"])] = via
	return d
