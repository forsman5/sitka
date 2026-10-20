extends RefCounted

## Water routes: boat lanes over open sea between settlements. On an island map
## they are the only link between islands, so they connect whichever land road
## networks are still separate. On a coast they chain the harbours (port and
## fishing villages) along the shore.

const Terrain = preload("res://scripts/valley/gen/valley_gen_terrain.gd")
const Roads = preload("res://scripts/valley/gen/valley_gen_roads.gd")

const CELL := 5.0
const SIMPLIFY := 1.5
const ROUTE_WIDTH := 1.6
const HARBOURS := ["port", "fishing"]
## Boats keep off the beach: cells this close to shore cost extra.
const BEACH_MARGIN := 8.0

## Returns Array of {id, a, b, length, points}. Also sets `waterfront` on every
## site a route lands at. `roads` supply the land components.
static func build(terrain: Terrain, sites: Array[Dictionary], roads: Array[Dictionary]) -> Array[Dictionary]:
	var routes: Array[Dictionary] = []
	if not terrain.has_sea or sites.size() < 2:
		return routes
	var gw := int(Terrain.SIZE.x / CELL) + 1
	var gh := int(Terrain.SIZE.y / CELL) + 1
	var grid := AStarGrid2D.new()
	grid.region = Rect2i(0, 0, gw, gh)
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ALWAYS
	grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_EUCLIDEAN
	grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_EUCLIDEAN
	grid.update()
	for gz in gh:
		for gx in gw:
			var p := _world(Vector2i(gx, gz))
			if not terrain.is_sea(p.x, p.y):
				grid.set_point_solid(Vector2i(gx, gz), true)
			elif terrain.shore_at(p.x, p.y) < BEACH_MARGIN:
				grid.set_point_weight_scale(Vector2i(gx, gz), 4.0)

	var landing: Array[Vector2] = []
	for site in sites:
		var anchor := terrain.waterfront_for(site["pos"])
		landing.append(Vector2(anchor.x, anchor.z))

	# Land components from the road network (islands), or one set per harbour (coast).
	var parent: Array[int] = []
	for i in sites.size():
		parent.append(i)
	if terrain.landscape == "island":
		for road in roads:
			_union(parent, int(road["a"]) - 1, int(road["b"]) - 1)

	var nodes := _route_nodes(terrain, sites, landing, parent)
	var edges: Array[Dictionary] = []
	for x in nodes.size():
		for y in range(x + 1, nodes.size()):
			var line := _sea_line(grid, landing[nodes[x]], landing[nodes[y]], gw, gh)
			if line.size() >= 2:
				edges.append({"a": nodes[x], "b": nodes[y], "line": line, "length": _length(line)})
	edges.sort_custom(func(p: Dictionary, q: Dictionary) -> bool: return p["length"] < q["length"])
	for edge in edges:
		var root_a := _find(parent, edge["a"])
		var root_b := _find(parent, edge["b"])
		if root_a == root_b:
			continue
		parent[root_a] = root_b
		var site_a: Dictionary = sites[edge["a"]]
		var site_b: Dictionary = sites[edge["b"]]
		var line: PackedVector2Array = edge["line"]
		var points: Array = [{"waterfront": site_a["id"]}]
		for k in range(1, line.size() - 1):
			points.append(Vector3(line[k].x, 0.0, line[k].y))
		points.append({"waterfront": site_b["id"]})
		for site in [site_a, site_b]:
			var anchor := landing[sites.find(site)]
			site["waterfront"] = Vector3(anchor.x, 0.0, anchor.y)
		routes.append({"id": "sea_%d_%d" % [site_a["id"], site_b["id"]], "a": site_a["id"], "b": site_b["id"], "length": edge["length"], "points": points})
	return routes

## Harbours, plus (on islands) the shoreward-most site of any land network that
## has none, so every island can be linked.
static func _route_nodes(terrain: Terrain, sites: Array[Dictionary], landing: Array[Vector2], parent: Array[int]) -> Array[int]:
	var nodes: Array[int] = []
	for i in sites.size():
		if HARBOURS.has(sites[i]["role"]):
			nodes.append(i)
	if terrain.landscape != "island":
		return nodes
	var covered := {}
	for i in nodes:
		covered[_find(parent, i)] = true
	var nearest := {}
	for i in sites.size():
		var root := _find(parent, i)
		if covered.has(root):
			continue
		var d: float = sites[i]["pos"].distance_to(landing[i])
		if not nearest.has(root) or d < nearest[root][1]:
			nearest[root] = [i, d]
	for root in nearest:
		nodes.append(nearest[root][0])
	return nodes

static func _sea_line(grid: AStarGrid2D, from: Vector2, to: Vector2, gw: int, gh: int) -> PackedVector2Array:
	var start := _sea_cell(grid, from, gw, gh)
	var goal := _sea_cell(grid, to, gw, gh)
	if start.x < 0 or goal.x < 0:
		return PackedVector2Array()
	var path: Array[Vector2i] = grid.get_id_path(start, goal)
	if path.is_empty():
		return PackedVector2Array()
	var line := PackedVector2Array([from])
	for cell in path:
		line.append(_world(cell))
	line.append(to)
	return Roads._simplify(line, SIMPLIFY)

## The nearest open-water cell to `p` (landings sit on the shore, where the
## cell centre may still be land).
static func _sea_cell(grid: AStarGrid2D, p: Vector2, gw: int, gh: int) -> Vector2i:
	var base := Vector2i(clampi(roundi((p.x + Terrain.SIZE.x * 0.5) / CELL), 0, gw - 1), clampi(roundi((p.y + Terrain.SIZE.y * 0.5) / CELL), 0, gh - 1))
	var best := Vector2i(-1, -1)
	var best_distance := INF
	for dz in range(-4, 5):
		for dx in range(-4, 5):
			var cell := base + Vector2i(dx, dz)
			if cell.x < 0 or cell.y < 0 or cell.x >= gw or cell.y >= gh or grid.is_point_solid(cell):
				continue
			var d := _world(cell).distance_to(p)
			if d < best_distance:
				best_distance = d
				best = cell
	return best

static func _length(line: PackedVector2Array) -> float:
	var total := 0.0
	for i in range(1, line.size()):
		total += line[i].distance_to(line[i - 1])
	return total

static func _world(cell: Vector2i) -> Vector2:
	return Vector2(cell.x * CELL - Terrain.SIZE.x * 0.5, cell.y * CELL - Terrain.SIZE.y * 0.5)

static func _find(parent: Array[int], i: int) -> int:
	while parent[i] != i:
		parent[i] = parent[parent[i]]
		i = parent[i]
	return i

static func _union(parent: Array[int], a: int, b: int) -> void:
	var root_a := _find(parent, a)
	var root_b := _find(parent, b)
	if root_a != root_b:
		parent[root_a] = root_b
