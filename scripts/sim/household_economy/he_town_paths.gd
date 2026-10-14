extends RefCounted

## Walking routes through the town, as pure data (no nodes). Built from an
## HETownLayout: the road polylines become an undirected weighted graph, and
## `path(from_site, to_site)` answers with the vertices a villager walks.
##
## Graph rules:
## - Nodes are road polyline points, plus inserted junction and access nodes.
## - The civic anchor (0, 0) joins the first point of every spoke
##   (`parent == -1`).
## - A lane's first point lies on its parent road; that point is inserted into
##   the parent segment nearest it, so the lane joins the parent mid-segment.
## - Each built site's `access` is projected onto its road (`road_id`) and
##   inserted as a node, splitting that segment.
## - Off-road sites (`access` not finite: fields, pastures) attach to the
##   nearest point on any road by a straight leg. That attach point is
##   remembered per site, so a later, nearer lane never reroutes it.
## - The civic site (id 0) is the anchor node itself.
##
## Every lane has exactly one connection (to its parent) and spokes meet only
## at the anchor, so the graph is a tree: the route between two sites is unique.
## Shortest-path search (Dijkstra, ties broken by lowest node id) is still used
## so the class stays correct if roads ever form loops.
##
## Path shape: door -> graph nodes (access first and last for frontage sites)
## -> door. The door is the point on the footprint edge facing the access (or,
## for off-road sites, nearest the road).
##
## Rebuilding: roads only grow and sites never move, so a route between two
## existing sites stays valid when only sites or lanes are added (a new lane
## is a dead-end branch and cannot shorten an existing route). `refresh()`
## rebuilds the graph and clears the cache when `layout.revision` changed;
## `path()` calls it first, so callers normally never need to.

const HETownLayout = preload("res://scripts/sim/household_economy/he_town_layout.gd")

const _KEY_SCALE := 1000.0
## A route vertex closer than this to the line through its neighbours is dropped.
const COLLINEAR_EPSILON := 0.001

var _layout: HETownLayout
var _built_revision: int = -1
var _nodes: PackedVector2Array = PackedVector2Array()
var _adjacency: Array[Dictionary] = [] # node id -> {neighbour id: length}
var _node_of_key: Dictionary = {} # Vector2i -> node id
var _site_node: Dictionary = {} # site id -> node id
var _site_door: Dictionary = {} # site id -> Vector2
var _offroad_attach: Dictionary = {} # site id -> road point (kept across rebuilds)
var _cache: Dictionary = {} # Vector2i(from, to) -> PackedVector2Array

func _init(layout: HETownLayout) -> void:
	_layout = layout
	refresh()

## Rebuilds the graph and clears the cache if the layout changed. Returns
## whether it rebuilt.
func refresh() -> bool:
	if _layout.revision == _built_revision:
		return false
	_built_revision = _layout.revision
	_cache.clear()
	_build()
	return true

## Door -> road graph -> door for two built sites; empty if either is unknown
## or they are not connected. Cached per (from, to) pair.
func path(from_site_id: int, to_site_id: int) -> PackedVector2Array:
	refresh()
	var key := Vector2i(from_site_id, to_site_id)
	if _cache.has(key):
		return _cache[key]
	var result: PackedVector2Array
	if from_site_id > to_site_id:
		# Computed once in canonical order, so a route and its return trip are
		# exact reverses (vertex simplification is direction-dependent).
		result = PackedVector2Array(path(to_site_id, from_site_id))
		result.reverse()
	else:
		result = _compute(from_site_id, to_site_id)
	_cache[key] = result
	return result

## Total walking length of a path.
static func path_length(points: PackedVector2Array) -> float:
	var total := 0.0
	for i in range(points.size() - 1):
		total += points[i].distance_to(points[i + 1])
	return total

# --- Queries ------------------------------------------------------------------

func _compute(from_id: int, to_id: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	if not _site_node.has(from_id) or not _site_node.has(to_id):
		return out
	var route := _shortest(int(_site_node[from_id]), int(_site_node[to_id]))
	if route.is_empty():
		return out
	_push(out, _site_door[from_id])
	for node in route:
		_push(out, _nodes[node])
	_push(out, _site_door[to_id])
	return _simplified(out)

## Drops vertices that lie on the straight line between their neighbours.
## Inserting an access or junction node into a road segment adds such a vertex
## to routes that already used the segment; dropping it keeps a route's
## vertices identical before and after unrelated sites are added.
static func _simplified(points: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in points:
		while out.size() >= 2:
			var a := out[out.size() - 2]
			var b := out[out.size() - 1]
			var closest := Geometry2D.get_closest_point_to_segment(b, a, p)
			if b.distance_to(closest) > COLLINEAR_EPSILON:
				break
			out.remove_at(out.size() - 1)
		out.append(p)
	return out

static func _push(points: PackedVector2Array, p: Vector2) -> void:
	if points.is_empty() or not points[points.size() - 1].is_equal_approx(p):
		points.append(p)

## Node ids from `start` to `goal`, or empty if unreachable.
func _shortest(start: int, goal: int) -> PackedInt32Array:
	var count := _nodes.size()
	var dist := PackedFloat64Array()
	dist.resize(count)
	dist.fill(INF)
	var previous := PackedInt32Array()
	previous.resize(count)
	previous.fill(-1)
	var done := PackedByteArray()
	done.resize(count)
	dist[start] = 0.0
	while true:
		var best := -1
		var best_dist := INF
		for i in count:
			if done[i] == 0 and dist[i] < best_dist:
				best = i
				best_dist = dist[i]
		if best < 0 or best == goal:
			break
		done[best] = 1
		var neighbours: Dictionary = _adjacency[best]
		for n in neighbours:
			var candidate: float = best_dist + float(neighbours[n])
			if candidate < dist[n]:
				dist[n] = candidate
				previous[n] = best
	var route := PackedInt32Array()
	if is_inf(dist[goal]):
		return route
	var node := goal
	while node != -1:
		route.append(node)
		node = previous[node]
	route.reverse()
	return route

# --- Graph construction -----------------------------------------------------------

func _build() -> void:
	_nodes = PackedVector2Array()
	_adjacency.clear()
	_node_of_key.clear()
	_site_node.clear()
	_site_door.clear()
	var roads: Array[Dictionary] = _layout.get_roads()
	# Points to insert into each road: {seg, t, pos}.
	var inserts: Array = []
	for road in roads:
		inserts.append([])
	var anchor := _node_for(Vector2.ZERO)
	# Lane junctions on their parents.
	for road in roads:
		var parent: int = road["parent"]
		var points: PackedVector2Array = road["points"]
		if parent >= 0 and parent < roads.size() and not points.is_empty():
			_queue_insert(inserts, roads, parent, points[0], false)
	# Site attachment points: frontage access projected on its road, or the
	# nearest road point for off-road sites.
	var targets: Dictionary = {} # site id -> Vector2 on a road
	for site in _layout.get_sites():
		if not site["built"]:
			continue
		var site_id: int = site["site_id"]
		var access: Vector2 = site["access"]
		var road_id: int = site["road_id"]
		if site_id == HETownLayout.CIVIC_SITE_ID:
			_site_node[site_id] = anchor
			_site_door[site_id] = Vector2.ZERO
		elif access.is_finite() and road_id >= 0 and road_id < roads.size():
			var hit := _project(roads[road_id]["points"], access)
			_queue_insert(inserts, roads, road_id, access, true)
			targets[site_id] = hit[2]
			_site_door[site_id] = _edge_point_toward(site, access)
		elif not roads.is_empty():
			if not _offroad_attach.has(site_id):
				_offroad_attach[site_id] = _nearest_road_point(roads, site["position"])
			var attach: Vector2 = _offroad_attach[site_id]
			_queue_insert(inserts, roads, _nearest_road(roads, attach), attach, false)
			targets[site_id] = attach
			_site_door[site_id] = _edge_point_toward(site, attach)
	# Road edges, with the inserted nodes in order along each segment.
	for road in roads:
		var points: PackedVector2Array = road["points"]
		if points.is_empty():
			continue
		var here: Array = inserts[int(road["road_id"])]
		here.sort_custom(_insert_less)
		var previous := _node_for(points[0])
		var cursor := 0
		for seg in range(points.size() - 1):
			while cursor < here.size() and int(here[cursor]["seg"]) == seg:
				var inserted := _node_for(here[cursor]["pos"])
				_connect(previous, inserted)
				previous = inserted
				cursor += 1
			var next := _node_for(points[seg + 1])
			_connect(previous, next)
			previous = next
		if int(road["parent"]) < 0:
			_connect(anchor, _node_for(points[0]))
	for site_id in targets:
		var key := _key(targets[site_id])
		if _node_of_key.has(key):
			_site_node[site_id] = _node_of_key[key]
		else:
			_site_door.erase(site_id)

static func _insert_less(a: Dictionary, b: Dictionary) -> bool:
	if a["seg"] != b["seg"]:
		return a["seg"] < b["seg"]
	if not is_equal_approx(a["t"], b["t"]):
		return a["t"] < b["t"]
	var pa: Vector2 = a["pos"]
	var pb: Vector2 = b["pos"]
	return pa.x < pb.x or (pa.x == pb.x and pa.y < pb.y)

func _node_for(p: Vector2) -> int:
	var key := _key(p)
	if _node_of_key.has(key):
		return _node_of_key[key]
	var id := _nodes.size()
	_nodes.append(p)
	_adjacency.append({})
	_node_of_key[key] = id
	return id

static func _key(p: Vector2) -> Vector2i:
	return Vector2i(roundi(p.x * _KEY_SCALE), roundi(p.y * _KEY_SCALE))

func _connect(a: int, b: int) -> void:
	if a == b:
		return
	var length := _nodes[a].distance_to(_nodes[b])
	_adjacency[a][b] = length
	_adjacency[b][a] = length

## Queues `p` for insertion into a road (at its projection when `snap`).
func _queue_insert(inserts: Array, roads: Array[Dictionary], road_id: int, p: Vector2, snap: bool) -> void:
	var hit := _project(roads[road_id]["points"], p)
	var pos: Vector2 = hit[2] if snap else p
	(inserts[road_id] as Array).append({"seg": hit[0], "t": hit[1], "pos": pos})

## [segment index, t along it, closest point] of `p` on a polyline.
static func _project(points: PackedVector2Array, p: Vector2) -> Array:
	var best_seg := 0
	var best_t := 0.0
	var best_point := points[0]
	var best_dist := INF
	for i in range(points.size() - 1):
		var closest := Geometry2D.get_closest_point_to_segment(p, points[i], points[i + 1])
		var d := p.distance_squared_to(closest)
		if d < best_dist - 0.000001:
			best_dist = d
			best_seg = i
			best_point = closest
			var span := points[i + 1] - points[i]
			best_t = (closest - points[i]).dot(span) / maxf(span.length_squared(), 0.000001)
	return [best_seg, best_t, best_point]

static func _nearest_road_point(roads: Array[Dictionary], p: Vector2) -> Vector2:
	var best := Vector2.INF
	var best_dist := INF
	for road in roads:
		if (road["points"] as PackedVector2Array).size() < 2:
			continue
		var hit := _project(road["points"], p)
		var d := p.distance_squared_to(hit[2])
		if d < best_dist - 0.000001:
			best_dist = d
			best = hit[2]
	return best

static func _nearest_road(roads: Array[Dictionary], p: Vector2) -> int:
	var best := 0
	var best_dist := INF
	for road in roads:
		if (road["points"] as PackedVector2Array).size() < 2:
			continue
		var d := p.distance_squared_to(_project(road["points"], p)[2])
		if d < best_dist - 0.000001:
			best_dist = d
			best = int(road["road_id"])
	return best

## The point on the site's footprint edge facing `target`. If `target` is
## inside the footprint, `target` itself.
static func _edge_point_toward(site: Dictionary, target: Vector2) -> Vector2:
	var rotation: float = site["rotation"]
	var origin: Vector2 = site["position"]
	var half: Vector2 = (site["footprint"] as Vector2) * 0.5
	var local: Vector2 = (target - origin).rotated(-rotation)
	var scale := maxf(absf(local.x) / maxf(half.x, 0.0001), absf(local.y) / maxf(half.y, 0.0001))
	if scale <= 1.0:
		return target
	return origin + (local / scale).rotated(rotation)
