extends RefCounted

## Stable site layout for one household-economy town. Pure data: no nodes, no
## economy rules. The dashboard owns one instance for the life of a run and
## feeds it business reports; renderers (the household town view today, the
## valley later) only read it.
##
## Coordinates are local to the town: a flat X/Y plane in world units centred
## on the civic anchor (0, 0), bounded by +/-HALF_EXTENT. A consumer maps
## (x, y) to its own ground (x, height(x, y), y) with whatever transform and
## terrain sampling it needs; `footprint` is the unrotated size in the same
## units and `rotation` a yaw in radians. Businesses sit at multiples of
## PI/2; houses face the lane they front and take any yaw. site_rect() is the
## axis-aligned bounds of the rotated footprint, site_contains() the exact test.
##
## Rules:
## - The starting layout is a pure function of the scenario key, settlement id
##   and sorted starting business ids (see scenario_key_for). No global RNG,
##   no dependence on report order.
## - A site never moves or disappears. A failed business vacates its site (the
##   building stays); the next new business takes the lowest-numbered vacant
##   non-civic site, and only when none is vacant is a new site allocated.
## - Allocation walks a fixed, seeded candidate list per zone and takes the
##   first candidate that clears every existing footprint by SITE_SPACING, so
##   later additions never rearrange earlier ones.
## - Site 0 is the civic anchor, reserved for the government.
## - Roads are data too: a seeded graph (spokes from the civic anchor, lanes
##   branching off them) built at construction. It only ever grows: when no
##   house lot is left, new lanes are added (seeded, never through an existing
##   site), and no road is moved or removed. Businesses keep to their zone
##   candidates but must clear the roads; houses take lots along the road
##   frontage, nearest the civic anchor first, facing the road. Roads store no
##   occupancy; a frontage site records its `road_id` and `access`, the point
##   on that road's centreline its front door walks to (Vector2.INF when the
##   site is not on a road).
## - Occupants come in two kinds with separate id spaces: a business
##   (`business_id`, from get_business_reports) or a house (`dwelling_id`, from
##   get_dwelling_reports). A site holds at most one; key an occupant by
##   (type_key, id). Houses never fail, so a house site is never vacated or
##   reused, and houses are allocated only in the residential zone (road
##   frontage).

const CIVIC_SITE_ID := 0
const NO_BUSINESS := -1

const ZONE_CIVIC := "civic"
const ZONE_TOWN := "town"
const ZONE_FIELD := "field"
const ZONE_PASTURE := "pasture"
const ZONE_HOUSING := "housing"

const GOVERNMENT_TYPE_KEY := "government"
const HOUSE_TYPE_KEY := "house"
const DENSE_HOUSE_TYPE_KEY := "tenement"
## House count at which the static road network is nearly full (it caps near
## 54); past it, prefers_densify() says to upgrade houses rather than grow out.
const DENSIFY_HOUSE_COUNT := 48
## Half the side of the square town footprint; sites are kept fully inside it.
const HALF_EXTENT := 80.0
## Minimum clear gap between two site footprints.
const SITE_SPACING := 3.0
## Roads and house rows reject a share of a zone's candidates, so there are
## enough of them that a business still finds a clear spot in its own zone.
const CANDIDATES_PER_ZONE := 384
const COORD_SNAP := 0.5

## footprint: site size; radius: band of distances from the civic anchor in
## which candidate centres are generated.
const ZONE_SPECS := {
	ZONE_CIVIC: {"footprint": Vector2(14.0, 14.0), "radius": Vector2(0.0, 0.0)},
	ZONE_TOWN: {"footprint": Vector2(10.0, 10.0), "radius": Vector2(13.0, 26.0)},
	ZONE_FIELD: {"footprint": Vector2(30.0, 22.0), "radius": Vector2(30.0, 72.0)},
	ZONE_PASTURE: {"footprint": Vector2(32.0, 24.0), "radius": Vector2(58.0, 100.0)},
	# Lots along the road frontage (see _make_frontage_candidates); no radius band.
	ZONE_HOUSING: {"footprint": Vector2(6.0, 6.0)},
}

## Road network. Spokes leave the civic anchor at seeded angles; lanes branch
## off each spoke at the arc distances in LANE_JUNCTIONS (`sides`: which sides
## of the spoke get a lane; `alternate`: one side, flipping per spoke).
const ROAD_SPOKE_COUNT := 5
const ROAD_SPOKE_START := 6.0
const ROAD_STEP := 7.0
const ROAD_MAX_POINTS := 14
const MAIN_ROAD_WIDTH := 5.0
const LANE_WIDTH := 3.5
const LANE_STEP := 6.0
const LANE_JUNCTIONS := [
	{"at": 66.0, "sides": [1, -1], "length": 30.0},
]
## A lane is cut to half the chord between neighbouring spokes at its junction,
## less this, so lanes from adjacent spokes never run into each other.
const LANE_SPOKE_GAP := 9.0
## Shorter lanes are skipped: a stub too short to front a house just reads as a nub.
const LANE_MIN_LENGTH := 12.0
## Roads stay this far inside the town square.
const ROAD_EDGE_MARGIN := 4.0
## Clear gap a business keeps from a road ribbon; houses front it directly.
const BUSINESS_ROAD_CLEARANCE := 1.5
const HOUSE_SETBACK := 1.0
## Spacing of candidate lots along a road. Finer than a house plus SITE_SPACING
## on purpose: first-fit then slides past a blocked lot and packs the frontage.
const HOUSE_LOT_PITCH := 5.0
## Town businesses front the spokes out to this radius (the "main street"),
## and houses start beyond it so the two never compete for the same frontage.
const MAIN_STREET_RADIUS := 42.0
const HOUSE_MIN_RADIUS := 42.0
## Growth: lanes added per step when house lots run out, tries per step, and
## steps tried for one house before it is reported unplaced.
const GROWTH_LANES_PER_STEP := 3
const GROWTH_ATTEMPTS := 40
const GROWTH_STEPS_PER_HOUSE := 4
const GROWTH_LANE_LENGTH := Vector2(16.0, 26.0)
## A new lane keeps this far from any existing site.
const GROWTH_SITE_CLEARANCE := 1.0
## Chance a growth lane continues its parent past the end instead of branching.
const GROWTH_EXTEND_CHANCE := 0.3
## Where a zone's allocation spills when its own candidates run out.
const FALLBACK_ORDER := {
	ZONE_TOWN: [ZONE_TOWN, ZONE_FIELD, ZONE_PASTURE],
	ZONE_FIELD: [ZONE_FIELD, ZONE_PASTURE, ZONE_TOWN],
	ZONE_PASTURE: [ZONE_PASTURE, ZONE_FIELD, ZONE_TOWN],
}
## Zone a business kind prefers; anything not listed goes in the town ring.
const TYPE_ZONES := {
	"farm": ZONE_FIELD,
	"woodlot": ZONE_FIELD,
	"cattle_ranch": ZONE_PASTURE,
	"sheep_farm": ZONE_PASTURE,
}

const _GOLDEN_ANGLE := 2.399963229728653
const _RADIAL_STEP := 0.7548776662466927

## Bumped on every change, so a renderer can skip work when nothing moved.
var revision: int = 0
var scenario_key: String = ""
var settlement_id: int = -1

var _sites: Array[Dictionary] = []
var _roads: Array[Dictionary] = [] # {"road_id", "class", "width", "points": PackedVector2Array, "parent"}
var _road_segments: Array[Dictionary] = [] # {"center", "half", "rotation", "road_id"}: oriented ribbon rects
var _seed_text: String = ""
var _growth_steps: int = 0
var _candidates: Dictionary = {} # zone -> Array of {"position": Vector2, "rotation": float}
var _unplaced: Array[int] = []
var _unplaced_dwellings: Array[int] = []

## `scenario_key` distinguishes presets and custom rosters (see
## scenario_key_for); `starting_reports` is get_business_reports() at start.
func _init(p_scenario_key: String, p_settlement_id: int, starting_reports: Array, starting_dwellings: Array = []) -> void:
	scenario_key = p_scenario_key
	settlement_id = p_settlement_id
	var starting_ids: Array = []
	for report in starting_reports:
		if int(report["settlement_id"]) == settlement_id:
			starting_ids.append(int(report["business_id"]))
	starting_ids.sort()
	var seed_text := "%s|%d|%s" % [scenario_key, settlement_id, ",".join(starting_ids.map(str))]
	for zone in [ZONE_TOWN, ZONE_FIELD, ZONE_PASTURE]:
		_candidates[zone] = _make_candidates(zone, seed_text)
	_seed_text = seed_text
	_roads = _make_roads(seed_text)
	_road_segments = _segments_of(_roads)
	# Town businesses front the spokes first (the spiral spots stay as overflow),
	# so civic and trade buildings sit on the main streets instead of in the
	# narrow wedges between them.
	var town_lots := _make_frontage_candidates(ZONE_TOWN, seed_text, _roads, 0.0, MAIN_STREET_RADIUS)
	town_lots.append_array(_candidates[ZONE_TOWN])
	_candidates[ZONE_TOWN] = town_lots
	_candidates[ZONE_HOUSING] = _make_frontage_candidates(ZONE_HOUSING, seed_text, _roads, HOUSE_MIN_RADIUS, INF)
	_sites.append({
		"site_id": CIVIC_SITE_ID,
		"settlement_id": settlement_id,
		"position": Vector2.ZERO,
		"rotation": 0.0,
		"footprint": ZONE_SPECS[ZONE_CIVIC]["footprint"],
		"zone": ZONE_CIVIC,
		"road_id": -1,
		"access": Vector2.INF,
		"business_id": NO_BUSINESS,
		"dwelling_id": NO_BUSINESS,
		"type_key": "",
		"label": "",
		"built": false,
		"under_construction": false,
	})
	reconcile(starting_reports, starting_dwellings)

## A durable identity for the scenario a builder Callable creates: the
## method name plus its bound arguments, so "build_custom" with different
## rosters (order-insensitive) are different scenarios.
static func scenario_key_for(builder: Callable) -> String:
	if not builder.is_valid():
		return "default"
	var bound: Array = builder.get_bound_arguments().duplicate(true)
	for i in bound.size():
		if bound[i] is Array:
			(bound[i] as Array).sort()
	return "%s%s" % [builder.get_method(), str(bound)]

## Brings the layout in line with the live businesses. Vacates sites whose
## business is gone, then seats unseated businesses (government first, then
## ascending id), then seats new houses in the residential zone. `dwellings`
## is get_dwelling_reports(), `constructions` get_construction_reports(): a
## build still under construction takes the site its finished building will
## keep (same id), flagged `under_construction` until it opens. Returns
## whether anything changed.
func reconcile(reports: Array, dwellings: Array = [], constructions: Array = []) -> bool:
	var live: Dictionary = {} # business_id -> report
	for report in reports:
		if int(report["settlement_id"]) == settlement_id:
			live[int(report["business_id"])] = report
	var building_businesses: Dictionary = {} # business_id -> true
	var building_dwellings: Dictionary = {} # dwelling_id -> construction report
	for construction in constructions:
		if int(construction["settlement_id"]) != settlement_id:
			continue
		if int(construction["business_id"]) != NO_BUSINESS:
			live[int(construction["business_id"])] = construction
			building_businesses[int(construction["business_id"])] = true
		elif int(construction["dwelling_id"]) != NO_BUSINESS:
			building_dwellings[int(construction["dwelling_id"])] = construction
	if not building_dwellings.is_empty():
		dwellings = dwellings + building_dwellings.values()
	var changed := false
	for site in _sites:
		var occupant: int = site["business_id"]
		if occupant != NO_BUSINESS and not live.has(occupant):
			site["business_id"] = NO_BUSINESS
			changed = true
	var seated: Dictionary = {}
	for site in _sites:
		if site["business_id"] != NO_BUSINESS:
			seated[site["business_id"]] = true
	var pending: Array[int] = []
	for business_id in live.keys():
		if not seated.has(business_id):
			pending.append(business_id)
	pending.sort_custom(func(a: int, b: int) -> bool:
		var a_gov := _type_key_of(live[a]) == GOVERNMENT_TYPE_KEY
		var b_gov := _type_key_of(live[b]) == GOVERNMENT_TYPE_KEY
		if a_gov != b_gov:
			return a_gov
		return a < b)
	_unplaced.clear()
	for business_id in pending:
		var report: Dictionary = live[business_id]
		var type_key := _type_key_of(report)
		var site_index := _vacant_site_index(type_key)
		if site_index == -1:
			site_index = _allocate_site(type_key)
		if site_index == -1:
			_unplaced.append(business_id)
			continue
		var site: Dictionary = _sites[site_index]
		site["business_id"] = business_id
		site["type_key"] = type_key
		site["label"] = str(report.get("name", ""))
		site["built"] = true
		changed = true
	var seated_houses: Dictionary = {}
	for site in _sites:
		if site["dwelling_id"] != NO_BUSINESS:
			seated_houses[site["dwelling_id"]] = true
	var new_houses: Array[int] = []
	var house_reports: Dictionary = {}
	for dwelling in dwellings:
		if int(dwelling["settlement_id"]) != settlement_id:
			continue
		var dwelling_id := int(dwelling["dwelling_id"])
		house_reports[dwelling_id] = dwelling
		if not seated_houses.has(dwelling_id):
			new_houses.append(dwelling_id)
	new_houses.sort()
	# A seated house may have been upgraded in place: same site, new kind.
	for site in _sites:
		var seated_id: int = site["dwelling_id"]
		if seated_id != NO_BUSINESS and house_reports.has(seated_id):
			var seated_type := str(house_reports[seated_id].get("type_key", HOUSE_TYPE_KEY))
			if site["type_key"] != seated_type:
				site["type_key"] = seated_type
				site["label"] = str(house_reports[seated_id].get("name", site["label"]))
				changed = true
	_unplaced_dwellings.clear()
	for dwelling_id in new_houses:
		var site_index := _allocate_from([ZONE_HOUSING])
		var growth := 0
		while site_index == -1 and growth < GROWTH_STEPS_PER_HOUSE and _grow_roads():
			growth += 1
			site_index = _allocate_from([ZONE_HOUSING])
		if site_index == -1:
			_unplaced_dwellings.append(dwelling_id)
			continue
		var house_site: Dictionary = _sites[site_index]
		house_site["dwelling_id"] = dwelling_id
		house_site["type_key"] = str(house_reports[dwelling_id].get("type_key", HOUSE_TYPE_KEY))
		house_site["label"] = str(house_reports[dwelling_id].get("name", "House"))
		house_site["built"] = true
		changed = true
	for site in _sites:
		var under: bool = building_businesses.has(site["business_id"]) or building_dwellings.has(site["dwelling_id"])
		if site["under_construction"] != under:
			site["under_construction"] = under
			changed = true
	if changed:
		revision += 1
	return changed

func get_sites() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for site in _sites:
		out.append(site.duplicate())
	return out

func get_site(site_id: int) -> Dictionary:
	for site in _sites:
		if site["site_id"] == site_id:
			return site.duplicate()
	return {}

## The site `business_id` occupies, or {} if it has none.
func site_of_business(business_id: int) -> Dictionary:
	for site in _sites:
		if site["business_id"] == business_id:
			return site.duplicate()
	return {}

## Businesses that found no room (every candidate in every zone taken).
func unplaced_business_ids() -> Array[int]:
	return _unplaced.duplicate()

## Houses that found no room in the residential zone.
func unplaced_dwelling_ids() -> Array[int]:
	return _unplaced_dwellings.duplicate()

static func is_housing_type(type_key: String) -> bool:
	return type_key == HOUSE_TYPE_KEY or type_key == DENSE_HOUSE_TYPE_KEY

## Whether more housing should come from upgrading an existing house rather
## than a new lot: the road network had to grow, a house found no room, or the
## static network is nearly full.
func prefers_densify() -> bool:
	if _growth_steps > 0 or not _unplaced_dwellings.is_empty():
		return true
	var houses := 0
	for site in _sites:
		if site["dwelling_id"] != NO_BUSINESS:
			houses += 1
	return houses >= DENSIFY_HOUSE_COUNT

## The site a house occupies, or {} if it has none.
func site_of_dwelling(dwelling_id: int) -> Dictionary:
	for site in _sites:
		if site["dwelling_id"] == dwelling_id:
			return site.duplicate()
	return {}

## Axis-aligned bounds of the site's rotated footprint, in town coordinates.
func site_rect(site: Dictionary) -> Rect2:
	return _rect_for(site["position"], site["footprint"], site["rotation"])

## Whether `later`'s footprint grown by `margin` (in its own frame, as
## placement checks it) overlaps `earlier`'s. A later site has the higher id.
static func sites_crowd(later: Dictionary, earlier: Dictionary, margin: float) -> bool:
	return _obb_overlap(
		later["position"], (later["footprint"] as Vector2) * 0.5 + Vector2.ONE * margin, later["rotation"],
		earlier["position"], (earlier["footprint"] as Vector2) * 0.5, earlier["rotation"])

## Whether `point` lies inside the site's rotated footprint.
func site_contains(site: Dictionary, point: Vector2) -> bool:
	var local: Vector2 = (point - site["position"]).rotated(-float(site["rotation"]))
	var half: Vector2 = (site["footprint"] as Vector2) * 0.5
	return absf(local.x) <= half.x and absf(local.y) <= half.y

func road_count() -> int:
	return _roads.size()

## The road network: {road_id, class ("main"/"lane"), width, points, parent}.
func get_roads() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for road in _roads:
		out.append(road.duplicate())
	return out

# ---------------------------------------------------------------------------

static func _type_key_of(report: Dictionary) -> String:
	return str(report.get("type_key", ""))

func _vacant_site_index(type_key: String) -> int:
	if type_key == GOVERNMENT_TYPE_KEY and _sites[0]["business_id"] == NO_BUSINESS:
		return 0
	for i in range(1, _sites.size()):
		if _sites[i]["business_id"] == NO_BUSINESS and _sites[i]["dwelling_id"] == NO_BUSINESS:
			return i
	return -1

func _allocate_site(type_key: String) -> int:
	var zone: String = TYPE_ZONES.get(type_key, ZONE_TOWN)
	return _allocate_from(FALLBACK_ORDER[zone])

## First free candidate in `zones` (tried in order) becomes a new, empty site.
func _allocate_from(zones: Array) -> int:
	for candidate_zone in zones:
		var footprint: Vector2 = ZONE_SPECS[candidate_zone]["footprint"]
		for candidate in _candidates[candidate_zone]:
			var clearance := 0.0 if candidate.get("frontage", false) else BUSINESS_ROAD_CLEARANCE
			if not _fits(candidate["position"], footprint, candidate["rotation"], clearance):
				continue
			_sites.append({
				"site_id": _sites.size(),
				"settlement_id": settlement_id,
				"position": candidate["position"],
				"rotation": candidate["rotation"],
				"footprint": footprint,
				"zone": candidate_zone,
				"road_id": int(candidate.get("road_id", -1)),
				"access": candidate.get("access", Vector2.INF),
				"business_id": NO_BUSINESS,
				"dwelling_id": NO_BUSINESS,
				"type_key": "",
				"label": "",
				"built": false,
				"under_construction": false,
			})
			return _sites.size() - 1
	return -1

## Whether a footprint at `center` yawed by `rotation` is inside the town,
## SITE_SPACING clear of every site and `road_clearance` clear of every road.
func _fits(center: Vector2, footprint: Vector2, rotation: float, road_clearance: float) -> bool:
	var limit := Rect2(Vector2.ONE * -HALF_EXTENT, Vector2.ONE * HALF_EXTENT * 2.0)
	if not limit.encloses(_rect_for(center, footprint, rotation)):
		return false
	var half := footprint * 0.5
	var spaced := half + Vector2.ONE * SITE_SPACING
	for site in _sites:
		if _obb_overlap(center, spaced, rotation, site["position"], (site["footprint"] as Vector2) * 0.5, site["rotation"]):
			return false
	var cleared := half + Vector2.ONE * road_clearance
	for segment in _road_segments:
		if _obb_overlap(center, cleared, rotation, segment["center"], segment["half"], segment["rotation"]):
			return false
	return true

## Axis-aligned bounds of a footprint rotated by `rotation`.
static func _rect_for(center: Vector2, footprint: Vector2, rotation: float) -> Rect2:
	var half := footprint * 0.5
	var c := absf(cos(rotation))
	var s := absf(sin(rotation))
	var extent := Vector2(c * half.x + s * half.y, s * half.x + c * half.y)
	return Rect2(center - extent, extent * 2.0)

## Separating-axis test for two oriented rects given as centre, half extents
## and yaw. Touching edges do not overlap.
static func _obb_overlap(c1: Vector2, h1: Vector2, r1: float, c2: Vector2, h2: Vector2, r2: float) -> bool:
	var u1 := Vector2.from_angle(r1)
	var v1 := Vector2(-u1.y, u1.x)
	var u2 := Vector2.from_angle(r2)
	var v2 := Vector2(-u2.y, u2.x)
	var delta := c2 - c1
	for axis in [u1, v1, u2, v2]:
		var reach: float = h1.x * absf(u1.dot(axis)) + h1.y * absf(v1.dot(axis)) \
			+ h2.x * absf(u2.dot(axis)) + h2.y * absf(v2.dot(axis))
		if absf(delta.dot(axis)) >= reach:
			return false
	return true

# --- Roads ------------------------------------------------------------------

## Spokes from the civic anchor with lanes branching off. A pure function of
## the seed text; roads are never edited after this.
static func _make_roads(seed_text: String) -> Array[Dictionary]:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%s|roads" % seed_text)
	var roads: Array[Dictionary] = []
	var base_angle := rng.randf() * TAU
	for k in ROAD_SPOKE_COUNT:
		var angle := base_angle + float(k) * TAU / float(ROAD_SPOKE_COUNT) + rng.randf_range(-0.35, 0.35)
		roads.append({
			"road_id": roads.size(),
			"class": "main",
			"width": MAIN_ROAD_WIDTH,
			"points": _wander(Vector2.from_angle(angle) * ROAD_SPOKE_START, angle, ROAD_STEP, INF, 0.14, rng),
			"parent": -1,
		})
	for k in ROAD_SPOKE_COUNT:
		var spoke: Dictionary = roads[k]
		for junction in LANE_JUNCTIONS:
			var sides: Array = junction.get("sides", [])
			if junction.get("alternate", false):
				sides = [1 if k % 2 == 0 else -1]
			for side in sides:
				var sample := _polyline_sample(spoke["points"], float(junction["at"]) + rng.randf_range(-2.0, 2.0))
				var heading := (sample[1] as Vector2).angle() + float(side) * PI * 0.5 + rng.randf_range(-0.25, 0.25)
				var chord := 2.0 * float(junction["at"]) * sin(PI / float(ROAD_SPOKE_COUNT))
				var length := minf(float(junction["length"]), chord * 0.5 - LANE_SPOKE_GAP)
				if length < LANE_MIN_LENGTH:
					continue
				var points := _wander(sample[0], heading, LANE_STEP, length, 0.15, rng)
				if points.size() < 2:
					continue
				roads.append({
					"road_id": roads.size(),
					"class": "lane",
					"width": LANE_WIDTH,
					"points": points,
					"parent": spoke["road_id"],
				})
	return roads

## A gently wandering polyline from `start`, pulled back toward `heading`, up
## to `length` along it (INF: until it nears the town edge or the point cap).
static func _wander(start: Vector2, heading: float, step: float, length: float, wobble: float, rng: RandomNumberGenerator) -> PackedVector2Array:
	var points := PackedVector2Array([start])
	var current := heading
	var position := start
	var travelled := 0.0
	var limit := HALF_EXTENT - ROAD_EDGE_MARGIN
	while points.size() < ROAD_MAX_POINTS and travelled < length:
		current = lerp_angle(current, heading, 0.3) + rng.randf_range(-wobble, wobble)
		var advance := step if is_inf(length) else minf(step, length - travelled)
		position += Vector2.from_angle(current) * advance
		if absf(position.x) > limit or absf(position.y) > limit:
			break
		points.append(position)
		travelled += advance
	return points

## [position, unit tangent] at arc distance `s` along `points` (clamped).
static func _polyline_sample(points: PackedVector2Array, s: float) -> Array:
	var remaining := maxf(s, 0.0)
	for i in range(points.size() - 1):
		var segment := points[i + 1] - points[i]
		var length := segment.length()
		if remaining <= length or i == points.size() - 2:
			var t := clampf(remaining / maxf(length, 0.0001), 0.0, 1.0)
			return [points[i] + segment * t, segment.normalized()]
		remaining -= length
	return [points[0], Vector2.RIGHT]

static func _segments_of(roads: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for road in roads:
		var points: PackedVector2Array = road["points"]
		for i in range(points.size() - 1):
			var delta := points[i + 1] - points[i]
			out.append({
				"center": (points[i] + points[i + 1]) * 0.5,
				"half": Vector2(delta.length() * 0.5, float(road["width"]) * 0.5),
				"rotation": delta.angle(),
				"road_id": road["road_id"],
			})
	return out

## Adds up to GROWTH_LANES_PER_STEP lanes branching off random existing roads,
## seeded by the growth step so a given history always grows the same town.
## A lane may not cross another road or come near an existing site. Returns
## whether any lane was added; its house lots join the candidate list.
func _grow_roads() -> bool:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%s|grow|%d" % [_seed_text, _growth_steps])
	_growth_steps += 1
	var added: Array[Dictionary] = []
	var attempts := 0
	while added.size() < GROWTH_LANES_PER_STEP and attempts < GROWTH_ATTEMPTS:
		attempts += 1
		var parent: Dictionary = _roads[rng.randi() % _roads.size()]
		var parent_points: PackedVector2Array = parent["points"]
		var total := 0.0
		for i in range(parent_points.size() - 1):
			total += parent_points[i].distance_to(parent_points[i + 1])
		var extend := rng.randf() < GROWTH_EXTEND_CHANCE
		var sample := _polyline_sample(parent_points, total if extend else rng.randf_range(total * 0.1, total))
		var side := 1 if rng.randf() < 0.5 else -1
		var turn := 0.0 if extend else float(side) * PI * 0.5
		var heading := (sample[1] as Vector2).angle() + turn + rng.randf_range(-0.3, 0.3)
		var length := rng.randf_range(GROWTH_LANE_LENGTH.x, GROWTH_LANE_LENGTH.y)
		var points := _wander(sample[0], heading, LANE_STEP, length, 0.15, rng)
		if points.size() < 3 or (sample[0] as Vector2).length() < HOUSE_MIN_RADIUS:
			continue
		var lane := {
			"road_id": _roads.size() + added.size(),
			"class": "lane",
			"width": LANE_WIDTH,
			"points": points,
			"parent": parent["road_id"],
		}
		if _lane_is_clear(lane, added):
			added.append(lane)
	if added.is_empty():
		return false
	_roads.append_array(added)
	_road_segments.append_array(_segments_of(added))
	var lots := _make_frontage_candidates(ZONE_HOUSING, "%s|grow%d" % [_seed_text, _growth_steps], added, HOUSE_MIN_RADIUS, INF)
	(_candidates[ZONE_HOUSING] as Array).append_array(lots)
	return true

## Whether `lane` stays clear of existing sites and of every road but its
## parent (and the lanes already added this step).
func _lane_is_clear(lane: Dictionary, added: Array[Dictionary]) -> bool:
	var segments := _segments_of([lane] as Array[Dictionary])
	for segment in segments:
		var ribbon: Vector2 = segment["half"]
		for site in _sites:
			var reach: Vector2 = (site["footprint"] as Vector2) * 0.5 + Vector2.ONE * GROWTH_SITE_CLEARANCE
			if _obb_overlap(segment["center"], ribbon, segment["rotation"], site["position"], reach, site["rotation"]):
				return false
		for other in _road_segments:
			if other["road_id"] == lane["parent"]:
				continue
			if _obb_overlap(segment["center"], ribbon + Vector2.ONE * 2.0, segment["rotation"], other["center"], other["half"], other["rotation"]):
				return false
		for other_lane in added:
			for other in _segments_of([other_lane] as Array[Dictionary]):
				if _obb_overlap(segment["center"], ribbon + Vector2.ONE * 2.0, segment["rotation"], other["center"], other["half"], other["rotation"]):
					return false
	return true

## Lots for `zone` along both sides of every road, between `min_radius` and
## `max_radius` of the civic anchor, nearest it first. Each faces the road
## (local +Z toward it), with a little seeded setback, slide and yaw jitter so
## the rows read as built, not stamped. Candidates are flagged `frontage`, so
## placement lets them sit directly against the road ribbon.
static func _make_frontage_candidates(zone: String, seed_text: String, roads: Array[Dictionary], min_radius: float, max_radius: float) -> Array:
	var footprint: Vector2 = ZONE_SPECS[zone]["footprint"]
	var half := footprint.x * 0.5
	var depth := footprint.y * 0.5
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%s|%s|frontage" % [seed_text, zone])
	var out: Array = []
	for road in roads:
		var points: PackedVector2Array = road["points"]
		var total := 0.0
		for i in range(points.size() - 1):
			total += points[i].distance_to(points[i + 1])
		var s := HOUSE_LOT_PITCH * 0.5
		while s < total - half:
			var sample := _polyline_sample(points, s)
			var tangent: Vector2 = sample[1]
			var left := Vector2(-tangent.y, tangent.x)
			for side in [1, -1]:
				var setback: float = float(road["width"]) * 0.5 + HOUSE_SETBACK + depth + rng.randf_range(0.0, 1.2)
				var center: Vector2 = sample[0] + left * float(side) * setback + tangent * rng.randf_range(-0.7, 0.7)
				var rotation := tangent.angle() + (PI if side > 0 else 0.0) + rng.randf_range(-0.05, 0.05)
				var distance := center.length()
				if distance < min_radius or distance > max_radius:
					continue
				out.append({"position": center, "rotation": rotation, "road_id": road["road_id"], "order": distance, "frontage": true, "access": sample[0]})
			s += HOUSE_LOT_PITCH
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["order"] != b["order"]:
			return a["order"] < b["order"]
		if a["position"].x != b["position"].x:
			return a["position"].x < b["position"].x
		return a["position"].y < b["position"].y)
	return out

## Seeded candidate centres for one zone: a low-discrepancy spiral through the
## zone's radius band, jittered by a local RNG so different scenarios differ.
static func _make_candidates(zone: String, seed_text: String) -> Array:
	var spec: Dictionary = ZONE_SPECS[zone]
	var band: Vector2 = spec["radius"]
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%s|%s" % [seed_text, zone])
	var base_angle := rng.randf() * TAU
	var base_radial := rng.randf()
	var out: Array = []
	for k in CANDIDATES_PER_ZONE:
		var angle := base_angle + float(k) * _GOLDEN_ANGLE + rng.randf_range(-0.12, 0.12)
		var t := fposmod(base_radial + float(k) * _RADIAL_STEP, 1.0)
		var radius := lerpf(band.x, band.y, t) + rng.randf_range(-1.0, 1.0)
		var position := Vector2.from_angle(angle) * radius
		position = Vector2(snappedf(position.x, COORD_SNAP), snappedf(position.y, COORD_SNAP))
		var turns := rng.randi() % 2
		out.append({"position": position, "rotation": float(turns) * PI * 0.5})
	return out
