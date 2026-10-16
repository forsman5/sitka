extends RefCounted

## The villagers' daily timetable, as pure data (no nodes, no stored state).
##
## `plan(...)` turns one villager's situation for one sim day (key, role, home
## and work site, route graph) into an ordered list of segments covering the
## day, and `evaluate(plan, time_of_day)` / `segment_at` / `position_of`
## answer where the villager is and what they are doing. Everything comes from
## (key, sim day, time of day, sites), so pausing, speed changes and
## fast-forward cannot make a villager drift.
##
## A sim day runs from DAY_START (05:30, when the simulation ticks and the
## roster may change while everyone is indoors) to DAY_END (the next 05:30).
## Plan hours are on that line: 00:00-05:30 is hours 24-29.5 of the previous
## sim day. Per villager and day, each timetable moment is jittered by up to
## 30 minutes (seeded by key and day).
##
## Timeline (housed villager):
##   indoors until wake (~06:00), then
##   - employed:  walk to the workplace (arrive ~08:00); work 08:00-17:00;
##                walk home (arrival depends on route length)
##   - unemployed adult: walk to the plaza; loiter; walk home
##   - child: plays in the home yard
##   then in the yard by the door until bed (~21:00), then indoors.
## At work: field, pasture and woodlot workers (open sites) wander inside the
## footprint, visible; town-business workers are inside (hidden) apart from two
## short stints standing at the door.
## Homeless villagers have no door: they are at the plaza all night, and
## commute from and back to it.
##
## Walking legs follow HETownPaths routes at WALK_CAP. Morning departures are
## timed to arrive around ARRIVE_WORK, leaving at DAY_START and arriving late
## when a route is too long for that window. Evening commuters leave at
## LEAVE_WORK and arrive home after the route's travel time.
##
## Water: a housed villager who walks out for the day (work or plaza) stops at
## the water source that adds the least walking, stands there FILL_HOURS to fill
## up, and carries on (skipped when no source is within WELL_MAX_DETOUR extra
## walking). The way home is the direct route.
##
## Mill segments (yard, plaza, a field) put the villager on a slow Lissajous
## wander inside an area, a pure function of absolute time (day * 24 + hour), blended in and out of the
## segment's end points so there are no jumps.

const HETownPaths = preload("res://scripts/sim/household_economy/he_town_paths.gd")
const HETownLayout = preload("res://scripts/sim/household_economy/he_town_layout.gd")

const ROLE_EMPLOYED := "employed"
const ROLE_ADULT := "adult" ## unemployed worker, or a grown dependent
const ROLE_CHILD := "child"
const ROLES := [ROLE_CHILD, ROLE_ADULT, ROLE_EMPLOYED]

const DAY_START := 5.5
const DAY_END := 29.5

## Moments, in hours (each jittered by +-JITTER_HOURS per villager per day).
const WAKE := 6.0
const ARRIVE_WORK := 8.0
const LEAVE_WORK := 17.0
const BEDTIME := 21.0
const JITTER_HOURS := 0.5

## Commuting speed, world units per game hour.
const WALK_CAP := 90.0
## Wander pace inside an area, world units per game hour, and blend pace.
const WANDER_SPEED := 3.0
const BLEND_SPEED := 14.0
## Yard: from this far in front of the house's front wall, this deep, and this
## far past each side wall.
const YARD_GAP := 0.4
const YARD_DEPTH := 1.8
const YARD_SIDE_OVERHANG := 1.0
## Personal plaza spot: distance band from the civic anchor, and wander half-size.
const PLAZA_RING := Vector2(8.5, 11.5)
const PLAZA_HALF := 1.5
## Open work sites: wander kept this far inside the footprint edge.
const SITE_INSET := 1.0
## Town workers step out to their door this long (hours), twice a day.
const DOOR_STINT := 0.3
## Water stop: time spent filling up (hours), and the most extra walking (world
## units) a villager will go out of their way for it.
const FILL_HOURS := 0.15
const WELL_MAX_DETOUR := 90.0

## House upkeep: government workers walk out from their workplace to each house
## they were given today, spending DELIVER_HOURS at every door.
const DELIVER_HOURS := 0.25

const OPEN_ZONES := ["field", "pasture"]

# --- Public queries -------------------------------------------------------------

## Convenience: where is the villager at `time_of_day` (0..1)? Builds the plan
## each call; callers that ask repeatedly keep the plan and use evaluate().
## Result: see evaluate().
static func at(key: Vector2i, role: String, day: int, time_of_day: float, home: Dictionary, work: Dictionary, paths) -> Dictionary:
	return evaluate(plan(key, role, day, home, work, paths), time_of_day)

## Where the plan puts the villager at `time_of_day`: {"visible": bool,
## "pos": Vector2 (town coordinates; the door when hidden), "activity": String,
## "site_id": int (destination or workplace, or -1), "segment": Dictionary}.
static func evaluate(villager_plan: Dictionary, time_of_day: float) -> Dictionary:
	var h := hour_of(time_of_day)
	var seg := segment_at(villager_plan, h)
	return {
		"visible": seg["type"] != "inside",
		"pos": position_of(seg, h),
		"activity": seg["act"],
		"site_id": seg["site_id"],
		"segment": seg,
	}

## Time of day (0..1) on the plan's hour line (DAY_START..DAY_END).
static func hour_of(time_of_day: float) -> float:
	var h := fposmod(time_of_day, 1.0) * 24.0
	return h + 24.0 if h < DAY_START else h

static func segment_at(villager_plan: Dictionary, h: float) -> Dictionary:
	var segs: Array = villager_plan["segs"]
	for seg in segs:
		if h < float(seg["t1"]):
			return seg
	return segs[segs.size() - 1]

## Town-coordinate position within `seg` at plan hour `h`.
static func position_of(seg: Dictionary, h: float) -> Vector2:
	match seg["type"]:
		"walk":
			var span: float = float(seg["t1"]) - float(seg["t0"])
			var f := 1.0 if span <= 0.0 else clampf((h - float(seg["t0"])) / span, 0.0, 1.0)
			return _along(seg["pts"], seg["cum"], f * float(seg["total"]))
		"mill":
			var p := wander(seg["area"], seg["phase"], float(seg["base"]) + h)
			var t0: float = seg["t0"]
			var t1: float = seg["t1"]
			var in_dur: float = seg["in_dur"]
			var out_dur: float = seg["out_dur"]
			if in_dur > 0.0 and h < t0 + in_dur:
				p = (seg["in_from"] as Vector2).lerp(p, clampf((h - t0) / in_dur, 0.0, 1.0))
			if out_dur > 0.0 and h > t1 - out_dur:
				p = p.lerp(seg["out_to"], clampf((h - (t1 - out_dur)) / out_dur, 0.0, 1.0))
			return p
	return seg["pos"] # "inside", "door"

## A slow Lissajous wander over `area` ({"center", "rot", "half"}); a pure
## function of the hour, always inside the area.
static func wander(area: Dictionary, phase: Vector2, h: float) -> Vector2:
	var half: Vector2 = area["half"]
	var wx := clampf(WANDER_SPEED / maxf(half.x, 0.5), 0.15, 1.5)
	var wy := clampf(WANDER_SPEED / maxf(half.y, 0.5), 0.15, 1.5) * 1.31
	var local := Vector2(half.x * sin(wx * h + phase.x), half.y * sin(wy * h + phase.y))
	return (area["center"] as Vector2) + local.rotated(float(area["rot"]))

## Where a household member's yard is: the strip between the house's front
## wall and its road.
static func yard_area(home: Dictionary) -> Dictionary:
	var position: Vector2 = home["position"]
	var half: Vector2 = (home["footprint"] as Vector2) * 0.5
	var front := _front_of(home)
	return {
		"center": position + front * (half.y + YARD_GAP + YARD_DEPTH * 0.5),
		"rot": front.orthogonal().angle(),
		"half": Vector2(half.x + YARD_SIDE_OVERHANG, YARD_DEPTH * 0.5),
	}

## A villager's own spot on the plaza ring.
static func plaza_area(key: Vector2i) -> Dictionary:
	var angle := _unit(key, 11) * TAU
	var radius := lerpf(PLAZA_RING.x, PLAZA_RING.y, _unit(key, 12))
	return {"center": Vector2.from_angle(angle) * radius, "rot": 0.0, "half": Vector2.ONE * PLAZA_HALF}

## The inside of an open work site's footprint.
static func site_area(site: Dictionary) -> Dictionary:
	var half: Vector2 = (site["footprint"] as Vector2) * 0.5 - Vector2.ONE * SITE_INSET
	return {"center": site["position"], "rot": float(site["rotation"]), "half": Vector2(maxf(half.x, 0.3), maxf(half.y, 0.3))}

## Open-air work: farms, woodlots and ranches, by what the business is (not
## where it ended up: a farm that spilled into the town ring is still a field).
static func is_open_site(site: Dictionary) -> bool:
	var zone: String = HETownLayout.TYPE_ZONES.get(str(site.get("type_key", "")), str(site.get("zone", "")))
	return OPEN_ZONES.has(zone)

# --- Planning -------------------------------------------------------------------

## The day's segments for one villager. `home` is the house's site dictionary
## ({} = homeless), `work` the workplace's ({} = none), `paths` an HETownPaths
## (or null, which leaves everyone at home), `water_sites` the working water
## sources' site dictionaries. Segment types: "inside" (hidden),
## "door" (standing at the door), "walk", "mill". Every segment has "t0", "t1"
## (plan hours), "act" and "site_id".
static func plan(key: Vector2i, role: String, day: int, home: Dictionary, work: Dictionary, paths, water_sites: Array = [], errands: Array = []) -> Dictionary:
	var segs: Array = []
	## Hour count since sim day 0 started: wanders run on it so they stay
	## continuous across the day boundary.
	var base := float(day) * 24.0
	var homeless := home.is_empty()
	var home_id: int = 0 if homeless else int(home["site_id"])
	var phase := Vector2(_unit(key, 1) * TAU, _unit(key, 2) * TAU)
	var wake := WAKE + JITTER_HOURS * _jit(key, day, 0)
	var arrive_work := ARRIVE_WORK + JITTER_HOURS * _jit(key, day, 1)
	var leave_work := LEAVE_WORK + JITTER_HOURS * _jit(key, day, 2)
	var bed := BEDTIME + JITTER_HOURS * _jit(key, day, 4)

	var plaza := plaza_area(key)
	var yard := {} if homeless else yard_area(home)
	var door := Vector2.INF
	if not homeless:
		var to_civic: PackedVector2Array = paths.path(home_id, 0) if paths != null else PackedVector2Array()
		door = to_civic[0] if not to_civic.is_empty() else home["position"] + _front_of(home) * (home["footprint"] as Vector2).y * 0.5

	# Where to, and by which route.
	var kind := "" # "plaza", "open", "town" or "" (stays home)
	var dest_id := -1
	var route := PackedVector2Array()
	if paths != null:
		if role == ROLE_EMPLOYED and not work.is_empty():
			dest_id = int(work["site_id"])
			kind = "open" if is_open_site(work) else "town"
		elif role == ROLE_ADULT and not homeless:
			dest_id = 0
			kind = "plaza"
		if kind != "":
			route = paths.path(home_id, dest_id)
			if route.is_empty():
				kind = ""
	if kind == "":
		_stay_home(segs, base, homeless, plaza, yard, door, phase, wake, bed)
		return {"segs": segs, "day": day}

	# Walking legs. Homeless villagers start from and return to their plaza spot.
	var out_pts := route
	var back_pts := PackedVector2Array(route)
	back_pts.reverse()
	var length := HETownPaths.path_length(route)
	if homeless:
		length += wander(plaza, phase, base + wake).distance_to(route[0])
	var walk_duration := length / WALK_CAP
	# Water stop on the way out: home -> source -> destination.
	var well := {} if homeless else _best_water_stop(paths, home_id, dest_id, length, water_sites)
	var out_duration := walk_duration if well.is_empty() else (float(well["length"]) / WALK_CAP + FILL_HOURS)
	var s1 := maxf(DAY_START, arrive_work - out_duration)
	if homeless:
		out_pts = PackedVector2Array([wander(plaza, phase, base + s1)]) + route
	var walk_arrival := s1 + out_duration
	arrive_work = walk_arrival
	var s2 := leave_work
	var arrive_home := s2 + walk_duration
	if homeless:
		back_pts = back_pts + PackedVector2Array([wander(plaza, phase, base + arrive_home)])

	if homeless:
		_push(segs, _mill(base, plaza, phase, Vector2.INF, Vector2.INF, "plaza", -1), s1)
	else:
		_push(segs, _inside(door, "indoors", -1), s1)
	var walk_act := "walk_plaza" if kind == "plaza" else "walk_work"
	if well.is_empty():
		_push(segs, _walk(out_pts, walk_act, dest_id), walk_arrival)
	else:
		var to_well: PackedVector2Array = well["to_well"]
		var stand: Vector2 = to_well[to_well.size() - 1]
		var reached := s1 + HETownPaths.path_length(to_well) / WALK_CAP
		_push(segs, _walk(to_well, walk_act, int(well["site_id"])), reached)
		_push(segs, {"type": "door", "pos": stand, "act": "fill_water", "site_id": int(well["site_id"])}, reached + FILL_HOURS)
		_push(segs, _walk(well["from_well"], walk_act, dest_id), walk_arrival)
	var end := route[route.size() - 1]
	match kind:
		"plaza":
			_push(segs, _mill(base, plaza, phase, end, end, "plaza", -1), s2)
		"open":
			_push(segs, _mill(base, site_area(work), phase, end, end, "work", dest_id), s2)
		"town":
			var cursor := arrive_work
			if not errands.is_empty():
				_push_errands(segs, paths, dest_id, end, errands, cursor + 0.3, leave_work - 0.2)
			for slot in (2 if errands.is_empty() else 0):
				var start := lerpf(9.5, 14.0, float(slot) / 1.0) + 1.5 * _jit(key, day, 5 + slot)
				start = maxf(start, cursor + 0.2)
				if start + DOOR_STINT > s2 - 0.2:
					continue
				_push(segs, _inside(end, "work_inside", dest_id), start)
				_push(segs, {"type": "door", "pos": end, "act": "work_door", "site_id": dest_id}, start + DOOR_STINT)
				cursor = start + DOOR_STINT
			_push(segs, _inside(end, "work_inside", dest_id), s2)
	_push(segs, _walk(back_pts, "walk_home", home_id if not homeless else 0), arrive_home)
	if homeless:
		_push(segs, _mill(base, plaza, phase, Vector2.INF, Vector2.INF, "plaza", -1), DAY_END)
	else:
		_push(segs, _mill(base, yard, phase, door, door, "yard", -1), bed)
		_push(segs, _inside(door, "indoors", -1), DAY_END)
	return {"segs": segs, "day": day}

## Appends a worker's house-upkeep round: inside until `start`, then workplace
## -> each house in turn (stand DELIVER_HOURS at its door) -> workplace, leaving
## out any house the round has no time left for before `limit`. The last
## segment ends at the workplace door.
static func _push_errands(segs: Array, paths, work_id: int, work_door: Vector2, errands: Array, start: float, limit: float) -> void:
	_push(segs, _inside(work_door, "work_inside", work_id), start)
	var at_id := work_id
	var t := start
	for house in errands:
		var house_id := int(house["site_id"])
		var out: PackedVector2Array = paths.path(at_id, house_id)
		var back: PackedVector2Array = paths.path(house_id, work_id)
		if out.is_empty() or back.is_empty():
			continue
		var arrive := t + HETownPaths.path_length(out) / WALK_CAP
		var done := arrive + DELIVER_HOURS
		if done + HETownPaths.path_length(back) / WALK_CAP > limit:
			continue
		_push(segs, _walk(out, "walk_errand", house_id), arrive)
		_push(segs, {"type": "door", "pos": out[out.size() - 1], "act": "deliver_upkeep", "site_id": house_id}, done)
		t = done
		at_id = house_id
	if at_id != work_id:
		var home_route: PackedVector2Array = paths.path(at_id, work_id)
		_push(segs, _walk(home_route, "walk_errand", work_id), t + HETownPaths.path_length(home_route) / WALK_CAP)

## The water source that costs the least extra walking between home and
## destination: {"site_id", "to_well", "from_well", "length"} (total walked), or
## {} when none is within WELL_MAX_DETOUR of the direct `direct_length`.
static func _best_water_stop(paths, home_id: int, dest_id: int, direct_length: float, water_sites: Array) -> Dictionary:
	var best := {}
	for water in water_sites:
		var water_id := int(water["site_id"])
		var to_well: PackedVector2Array = paths.path(home_id, water_id)
		var from_well: PackedVector2Array = paths.path(water_id, dest_id)
		if to_well.is_empty() or from_well.is_empty():
			continue
		var length := HETownPaths.path_length(to_well) + HETownPaths.path_length(from_well)
		if length - direct_length > WELL_MAX_DETOUR:
			continue
		if best.is_empty() or length < float(best["length"]) or (length == float(best["length"]) and water_id < int(best["site_id"])):
			best = {"site_id": water_id, "to_well": to_well, "from_well": from_well, "length": length}
	return best

static func _stay_home(segs: Array, base: float, homeless: bool, plaza: Dictionary, yard: Dictionary, door: Vector2, phase: Vector2, wake: float, bed: float) -> void:
	if homeless:
		_push(segs, _mill(base, plaza, phase, Vector2.INF, Vector2.INF, "plaza", -1), DAY_END)
		return
	_push(segs, _inside(door, "indoors", -1), wake)
	_push(segs, _mill(base, yard, phase, door, door, "yard", -1), bed)
	_push(segs, _inside(door, "indoors", -1), DAY_END)

# --- Segment builders -----------------------------------------------------------

static func _inside(pos: Vector2, act: String, site_id: int) -> Dictionary:
	return {"type": "inside", "pos": pos, "act": act, "site_id": site_id}

static func _walk(pts: PackedVector2Array, act: String, site_id: int) -> Dictionary:
	var cum := PackedFloat32Array([0.0])
	var total := 0.0
	for i in range(pts.size() - 1):
		total += pts[i].distance_to(pts[i + 1])
		cum.append(total)
	return {"type": "walk", "pts": pts, "cum": cum, "total": total, "act": act, "site_id": site_id}

## `in_from` / `out_to` (Vector2.INF = none) are the points the villager comes
## from and goes to; the wander is blended with them near the segment's ends.
static func _mill(base: float, area: Dictionary, phase: Vector2, in_from: Vector2, out_to: Vector2, act: String, site_id: int) -> Dictionary:
	return {"type": "mill", "base": base, "area": area, "phase": phase, "in_from": in_from, "out_to": out_to, "in_dur": 0.0, "out_dur": 0.0, "act": act, "site_id": site_id}

## Appends `seg` from the previous segment's end to `t1` (clamped so time never
## runs backwards); resolves a mill's blend durations.
static func _push(segs: Array, seg: Dictionary, t1: float) -> void:
	var t0 := DAY_START if segs.is_empty() else float(segs[segs.size() - 1]["t1"])
	t1 = maxf(t1, t0)
	seg["t0"] = t0
	seg["t1"] = t1
	if seg["type"] == "mill":
		var span := t1 - t0
		var in_from: Vector2 = seg["in_from"]
		var out_to: Vector2 = seg["out_to"]
		if in_from.is_finite():
			seg["in_dur"] = clampf(in_from.distance_to(wander(seg["area"], seg["phase"], float(seg["base"]) + t0 + 0.25)) / BLEND_SPEED, 0.1, span * 0.5)
		if out_to.is_finite():
			seg["out_dur"] = clampf(out_to.distance_to(wander(seg["area"], seg["phase"], float(seg["base"]) + t1 - 0.25)) / BLEND_SPEED, 0.1, span * 0.5)
	segs.append(seg)

# --- Helpers --------------------------------------------------------------------

static func _front_of(home: Dictionary) -> Vector2:
	var position: Vector2 = home["position"]
	var access: Vector2 = home["access"]
	if access.is_finite() and access.distance_to(position) > 0.01:
		return (access - position).normalized()
	return Vector2.from_angle(float(home["rotation"])).orthogonal()

static func _along(pts: PackedVector2Array, cum: PackedFloat32Array, distance: float) -> Vector2:
	if pts.size() < 2:
		return pts[0] if pts.size() == 1 else Vector2.ZERO
	for i in range(1, pts.size()):
		if distance <= cum[i]:
			var span: float = cum[i] - cum[i - 1]
			return pts[i - 1].lerp(pts[i], 1.0 if span <= 0.0 else (distance - cum[i - 1]) / span)
	return pts[pts.size() - 1]

## Seeded value in [-1, 1] per villager, sim day and moment.
static func _jit(key: Vector2i, day: int, salt: int) -> float:
	return float(hash(Vector3i(key.x * 64 + salt, key.y, day)) & 0xFFFF) / 32767.5 - 1.0

## Seeded value in [0, 1) per villager (the same every day).
static func _unit(key: Vector2i, salt: int) -> float:
	return float(hash(Vector3i(key.x, key.y, -1000 - salt)) & 0xFFFF) / 65536.0
