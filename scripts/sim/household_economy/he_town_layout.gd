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
## units and `rotation` a yaw in radians (always a multiple of PI/2, so a
## footprint is an axis-aligned rect, see site_rect()).
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

const CIVIC_SITE_ID := 0
const NO_BUSINESS := -1

const ZONE_CIVIC := "civic"
const ZONE_TOWN := "town"
const ZONE_FIELD := "field"
const ZONE_PASTURE := "pasture"

const GOVERNMENT_TYPE_KEY := "government"
## Half the side of the square town footprint; sites are kept fully inside it.
const HALF_EXTENT := 80.0
## Minimum clear gap between two site footprints.
const SITE_SPACING := 3.0
const CANDIDATES_PER_ZONE := 128
const COORD_SNAP := 0.5

## footprint: site size; radius: band of distances from the civic anchor in
## which candidate centres are generated.
const ZONE_SPECS := {
	ZONE_CIVIC: {"footprint": Vector2(14.0, 14.0), "radius": Vector2(0.0, 0.0)},
	ZONE_TOWN: {"footprint": Vector2(10.0, 10.0), "radius": Vector2(13.0, 26.0)},
	ZONE_FIELD: {"footprint": Vector2(22.0, 16.0), "radius": Vector2(28.0, 48.0)},
	ZONE_PASTURE: {"footprint": Vector2(26.0, 20.0), "radius": Vector2(46.0, 66.0)},
}
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
var _candidates: Dictionary = {} # zone -> Array of {"position": Vector2, "rotation": float}
var _unplaced: Array[int] = []

## `scenario_key` distinguishes presets and custom rosters (see
## scenario_key_for); `starting_reports` is get_business_reports() at start.
func _init(p_scenario_key: String, p_settlement_id: int, starting_reports: Array) -> void:
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
	_sites.append({
		"site_id": CIVIC_SITE_ID,
		"settlement_id": settlement_id,
		"position": Vector2.ZERO,
		"rotation": 0.0,
		"footprint": ZONE_SPECS[ZONE_CIVIC]["footprint"],
		"zone": ZONE_CIVIC,
		"business_id": NO_BUSINESS,
		"type_key": "",
		"label": "",
		"built": false,
	})
	reconcile(starting_reports)

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
## ascending id). Returns whether anything changed.
func reconcile(reports: Array) -> bool:
	var live: Dictionary = {} # business_id -> report
	for report in reports:
		if int(report["settlement_id"]) == settlement_id:
			live[int(report["business_id"])] = report
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

## Footprint rect in town coordinates, with the 90 degree rotation applied.
func site_rect(site: Dictionary) -> Rect2:
	return _rect_for(site["position"], site["footprint"], site["rotation"])

# ---------------------------------------------------------------------------

static func _type_key_of(report: Dictionary) -> String:
	return str(report.get("type_key", ""))

func _vacant_site_index(type_key: String) -> int:
	if type_key == GOVERNMENT_TYPE_KEY and _sites[0]["business_id"] == NO_BUSINESS:
		return 0
	for i in range(1, _sites.size()):
		if _sites[i]["business_id"] == NO_BUSINESS:
			return i
	return -1

func _allocate_site(type_key: String) -> int:
	var zone: String = TYPE_ZONES.get(type_key, ZONE_TOWN)
	for candidate_zone in FALLBACK_ORDER[zone]:
		var footprint: Vector2 = ZONE_SPECS[candidate_zone]["footprint"]
		for candidate in _candidates[candidate_zone]:
			var rect := _rect_for(candidate["position"], footprint, candidate["rotation"])
			if not _fits(rect):
				continue
			_sites.append({
				"site_id": _sites.size(),
				"settlement_id": settlement_id,
				"position": candidate["position"],
				"rotation": candidate["rotation"],
				"footprint": footprint,
				"zone": candidate_zone,
				"business_id": NO_BUSINESS,
				"type_key": "",
				"label": "",
				"built": false,
			})
			return _sites.size() - 1
	return -1

func _fits(rect: Rect2) -> bool:
	var limit := Rect2(Vector2.ONE * -HALF_EXTENT, Vector2.ONE * HALF_EXTENT * 2.0)
	if not limit.encloses(rect):
		return false
	var padded := rect.grow(SITE_SPACING)
	for site in _sites:
		if padded.intersects(site_rect(site)):
			return false
	return true

static func _rect_for(center: Vector2, footprint: Vector2, rotation: float) -> Rect2:
	var quarter_turns := int(round(rotation / (PI * 0.5)))
	var size := footprint
	if quarter_turns % 2 != 0:
		size = Vector2(footprint.y, footprint.x)
	return Rect2(center - size * 0.5, size)

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
