extends RefCounted

## Stages 1 and 3: pick the roster, then score candidate spots for each role and
## grade a pad under each chosen site.

const Terrain = preload("res://scripts/valley/gen/valley_gen_terrain.gd")

const ROLES := {
	"town": {"pad": 28.0, "district": "fields", "accent": Color("d6b45c"), "text": "Market town, mixed farms, and the hall"},
	"port": {"pad": 22.0, "district": "port", "accent": Color("739fc1"), "text": "Downstream port, milling, and outside trade"},
	"ore": {"pad": 14.0, "district": "ore", "accent": Color("a66a4a"), "text": "Ore bank and small bloomery"},
	"woodland": {"pad": 14.0, "district": "woodland", "accent": Color("547a45"), "text": "Tributary woodland for timber and charcoal"},
	"pasture": {"pad": 14.0, "district": "pasture", "accent": Color("a7c884"), "text": "Upland pasture for sheep, cattle, and wool"},
	"farm": {"pad": 14.0, "district": "fields", "accent": Color("c9b458"), "text": "Riverside farming hamlet"},
}

const NAMES := ["Aldmere", "Brindle", "Corrow", "Dunholt", "Eastwick", "Fennick", "Garrow", "Hollin", "Ironby", "Kestle", "Linden", "Marrow", "Norbeck", "Oxley", "Penrith", "Quarn", "Rowan", "Stanmoor", "Thornby", "Ulvey", "Wyke", "Yarrow"]

const SITE_MARGIN := Vector2(30.0, 30.0)
const MIN_GAP := 14.0

## Returns {sites: Array[Dictionary], failures: PackedStringArray}. A site is
## {id, role, name, pos: Vector2, pad, height, district, accent, text, waterfront}.
static func pick(terrain: Terrain, rng: RandomNumberGenerator) -> Dictionary:
	var roles: Array[String] = ["town", "port", "ore", "woodland", "pasture"]
	if rng.randf() < 0.6:
		roles.append("farm")
	var names := NAMES.duplicate()
	for i in range(names.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var swap: String = names[i]
		names[i] = names[j]
		names[j] = swap

	var elevation := terrain.elevation_range()
	var candidates: Array[Vector2] = []
	var half := Terrain.SIZE * 0.5 - SITE_MARGIN
	for x in range(int(-half.x), int(half.x) + 1, 8):
		for z in range(int(-half.y), int(half.y) + 1, 8):
			candidates.append(Vector2(x + rng.randf_range(-2.0, 2.0), z + rng.randf_range(-2.0, 2.0)))

	var sites: Array[Dictionary] = []
	var failures := PackedStringArray()
	var junction := Vector2(terrain.junction.x, terrain.junction.z)
	for role in roles:
		var spec: Dictionary = ROLES[role]
		var pad: float = spec["pad"]
		var best := Vector2.INF
		var best_score := -INF
		for relaxed in [false, true]:
			for c in candidates:
				if not _clear_of(sites, c, pad):
					continue
				var score := _score(terrain, role, c, pad, elevation, junction, relaxed, rng)
				if score > best_score:
					best_score = score
					best = c
			if best != Vector2.INF:
				break
		if best == Vector2.INF:
			if role == "farm":
				continue
			failures.append("No site found for %s" % role)
			continue
		var site := {
			"id": sites.size() + 1,
			"role": role,
			"name": names[sites.size()],
			"pos": best,
			"pad": pad,
			"height": terrain.land_height(best.x, best.y),
			"district": spec["district"],
			"accent": spec["accent"],
			"text": spec["text"],
			"waterfront": null,
		}
		if role == "port":
			var bank := terrain.nearest_river_point("main", best)
			site["waterfront"] = Vector3(bank.x, 0.0, bank.y)
		sites.append(site)
	return {"sites": sites, "failures": failures}

static func _clear_of(sites: Array[Dictionary], c: Vector2, pad: float) -> bool:
	for s in sites:
		if c.distance_to(s["pos"]) < pad + float(s["pad"]) + MIN_GAP:
			return false
	return true

static func _score(terrain: Terrain, role: String, c: Vector2, pad: float, elevation: Vector2, junction: Vector2, relaxed: bool, rng: RandomNumberGenerator) -> float:
	var slope := terrain.slope_at(c.x, c.y, true)
	for k in 4:
		var a := float(k) * TAU / 4.0
		slope += terrain.slope_at(c.x + cos(a) * pad * 0.5, c.y + sin(a) * pad * 0.5, true)
	slope /= 5.0
	var loose := 1.5 if relaxed else 1.0
	var bank := terrain.bank_at(c.x, c.y)
	var trib_bank := terrain.dist_to_river("tributary", c)
	var elev := (terrain.land_height(c.x, c.y) - elevation.x) / maxf(elevation.y - elevation.x, 0.001)
	var tx := terrain.downstream_t(c.x)
	var jitter := rng.randf() * 0.3
	# Keep the whole pad out of the carved banks; the port may sit on the water.
	var min_bank := pad * 0.5 + 2.0 if role == "port" else pad * 0.8 + Terrain.BANK + 2.0
	if bank < min_bank or trib_bank < min_bank:
		return -INF
	match role:
		"town":
			if slope > 0.22 * loose or bank > 60.0 * loose or elev > 0.6 * loose:
				return -INF
			return -slope * 6.0 - elev * 3.0 - absf(tx - 0.5) * 3.0 - c.length() / 150.0 - c.distance_to(junction) / 120.0 + jitter
		"port":
			if tx < 0.7 / loose or slope > 0.2 * loose or bank > 40.0 * loose:
				return -INF
			return tx * 4.0 - slope * 6.0 - bank / 30.0 + jitter
		"pasture":
			if elev < 0.4 / loose or bank < 30.0 or slope > 0.3 * loose:
				return -INF
			return elev * 3.0 - absf(slope - 0.1) * 5.0 + jitter
		"woodland":
			if trib_bank > 70.0 * loose or elev > 0.85:
				return -INF
			return -absf(trib_bank - 35.0) / 30.0 - slope * 3.0 + jitter
		"ore":
			if elev < 0.35 / loose or bank < 35.0 or slope < 0.06 or slope > 0.32 * loose:
				return -INF
			return elev * 2.0 + slope * 3.0 + jitter
		"farm":
			if slope > 0.14 * loose or bank > 50.0 * loose:
				return -INF
			return -slope * 5.0 - bank / 40.0 - elev + jitter
	return -INF
