extends RefCounted

## Stages 1 and 3: take the roster from the spec, score candidate spots for each
## role, and grade a pad under each chosen site.

const Terrain = preload("res://scripts/valley/gen/valley_gen_terrain.gd")

const ROLES := {
	"town": {"pad": 28.0, "district": "fields", "accent": Color("d6b45c"), "text": "Market town, mixed farms, and the hall"},
	"port": {"pad": 22.0, "district": "port", "accent": Color("739fc1"), "text": "Port, milling, and outside trade"},
	"ore": {"pad": 14.0, "district": "ore", "accent": Color("a66a4a"), "text": "Ore bank and small bloomery"},
	"woodland": {"pad": 14.0, "district": "woodland", "accent": Color("547a45"), "text": "Woodland for timber and charcoal"},
	"pasture": {"pad": 14.0, "district": "pasture", "accent": Color("a7c884"), "text": "Upland pasture for sheep, cattle, and wool"},
	"farm": {"pad": 14.0, "district": "fields", "accent": Color("c9b458"), "text": "Farming hamlet"},
	"fishing": {"pad": 12.0, "district": "coast", "accent": Color("5fa8a0"), "text": "Fishing village on the water"},
}

## Scarce, constrained roles are placed first.
const ROLE_ORDER := ["town", "port", "ore", "woodland", "pasture", "fishing", "farm"]
const WATERSIDE := ["port", "fishing"]

const NAMES := ["Aldmere", "Brindle", "Corrow", "Dunholt", "Eastwick", "Fennick", "Garrow", "Hollin", "Ironby", "Kestle", "Linden", "Marrow", "Norbeck", "Oxley", "Penrith", "Quarn", "Rowan", "Stanmoor", "Thornby", "Ulvey", "Wyke", "Yarrow"]

const SITE_MARGIN := Vector2(30.0, 30.0)
const MIN_GAP := 14.0

## Returns {sites: Array[Dictionary], failures: PackedStringArray}. A site is
## {id, role, name, pos: Vector2, pad, height, district, accent, text, waterfront}.
static func pick(terrain: Terrain, rng: RandomNumberGenerator, spec: RefCounted) -> Dictionary:
	var wanted: Array[Dictionary] = spec.roster()
	wanted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return ROLE_ORDER.find(a["role"]) < ROLE_ORDER.find(b["role"]))
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
	var focus := terrain.focus_point()
	for entry in wanted:
		var role: String = entry["role"]
		var spec_role: Dictionary = ROLES[role]
		var pad: float = spec_role["pad"]
		var best := Vector2.INF
		var best_score := -INF
		for relaxed in [false, true]:
			for c in candidates:
				if not _clear_of(sites, c, pad):
					continue
				var score := _score(terrain, role, c, pad, elevation, focus, relaxed, rng)
				if score > best_score:
					best_score = score
					best = c
			if best != Vector2.INF:
				break
		if best == Vector2.INF:
			if not entry["optional"]:
				failures.append("No site found for %s" % role)
			continue
		var site := {
			"id": sites.size() + 1,
			"role": role,
			"name": names[sites.size()],
			"pos": best,
			"pad": pad,
			"height": terrain.land_height(best.x, best.y),
			"district": spec_role["district"],
			"accent": spec_role["accent"],
			"text": spec_role["text"],
			"waterfront": null,
		}
		if role == "port":
			site["waterfront"] = terrain.waterfront_for(best)
		sites.append(site)
	return {"sites": sites, "failures": failures}

static func _clear_of(sites: Array[Dictionary], c: Vector2, pad: float) -> bool:
	for s in sites:
		if c.distance_to(s["pos"]) < pad + float(s["pad"]) + MIN_GAP:
			return false
	return true

static func _score(terrain: Terrain, role: String, c: Vector2, pad: float, elevation: Vector2, focus: Vector2, relaxed: bool, rng: RandomNumberGenerator) -> float:
	var slope := terrain.slope_at(c.x, c.y, true)
	for k in 4:
		var a := float(k) * TAU / 4.0
		slope += terrain.slope_at(c.x + cos(a) * pad * 0.5, c.y + sin(a) * pad * 0.5, true)
	slope /= 5.0
	var loose := 1.5 if relaxed else 1.0
	var bank := terrain.bank_at(c.x, c.y)
	var trib_bank := terrain.tributary_bank(c)
	var sea := terrain.shore_at(c.x, c.y)
	var elev := (terrain.land_height(c.x, c.y) - elevation.x) / maxf(elevation.y - elevation.x, 0.001)
	var tx := terrain.downstream_t(c)
	var valley := terrain.landscape == "river_valley"
	var jitter := rng.randf() * 0.3
	# Keep the whole pad out of the carved banks; waterside roles may sit on the water.
	var min_bank := pad * 0.5 + 2.0 if role in WATERSIDE else pad * 0.8 + Terrain.BANK + 2.0
	if bank < min_bank or trib_bank < min_bank:
		return -INF
	match role:
		"town":
			if slope > 0.22 * loose or bank > 60.0 * loose or elev > 0.6 * loose:
				return -INF
			var downstream := absf(tx - 0.5) * 3.0 if valley else 0.0
			return -slope * 6.0 - elev * 3.0 - downstream - c.length() / 150.0 - c.distance_to(focus) / 120.0 + jitter
		"port":
			if slope > 0.2 * loose:
				return -INF
			if terrain.has_sea:
				if sea > 40.0 * loose:
					return -INF
				return -slope * 6.0 - sea / 30.0 + jitter
			if tx < 0.7 / loose or bank > 40.0 * loose:
				return -INF
			return tx * 4.0 - slope * 6.0 - bank / 30.0 + jitter
		"fishing":
			var water := sea if terrain.has_sea else bank
			if slope > 0.2 * loose or water > 24.0 * loose:
				return -INF
			return -slope * 5.0 - water / 20.0 + jitter
		"pasture":
			if elev < 0.4 / loose or bank < 30.0 / loose or slope > 0.3 * loose:
				return -INF
			return elev * 3.0 - absf(slope - 0.1) * 5.0 + jitter
		"woodland":
			var reference := trib_bank if trib_bank < INF else bank
			if reference > 70.0 * loose or elev > 0.85:
				return -INF
			return -absf(reference - 35.0) / 30.0 - slope * 3.0 + jitter
		"ore":
			if elev < 0.35 / loose or bank < 35.0 / loose or slope < 0.06 or slope > 0.32 * loose:
				return -INF
			return elev * 2.0 + slope * 3.0 + jitter
		"farm":
			if slope > 0.14 * loose or bank > 50.0 * loose:
				return -INF
			return -slope * 5.0 - bank / 40.0 - elev + jitter
	return -INF
