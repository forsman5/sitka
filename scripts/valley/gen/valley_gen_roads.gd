extends RefCounted

## Stage 4: least-cost roads between sites (minimum spanning tree plus the
## town-port trade road), then explicit ford records wherever a road meets water.

const Terrain = preload("res://scripts/valley/gen/valley_gen_terrain.gd")
const Ribbon = preload("res://scripts/valley/terrain_ribbon_builder.gd")

const CELL := 5.0
const SIMPLIFY := 2.0
const WATER_WEIGHT := 12.0
const ROAD_WIDTH := 2.1

## Returns Array of {id, a, b, cost, points: Array} where points start and end
## with settlement references and the interior are fixed Vector3s.
static func build(terrain: Terrain, sites: Array[Dictionary]) -> Array[Dictionary]:
	var gw := int(Terrain.SIZE.x / CELL) + 1
	var gh := int(Terrain.SIZE.y / CELL) + 1
	var grid := AStarGrid2D.new()
	grid.region = Rect2i(0, 0, gw, gh)
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ALWAYS
	grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_EUCLIDEAN
	grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_EUCLIDEAN
	grid.update()
	var weights := PackedFloat32Array()
	weights.resize(gw * gh)
	for gz in gh:
		for gx in gw:
			var p := _world(Vector2i(gx, gz))
			var slope := terrain.slope_at(p.x, p.y)
			var w := 1.0 + 120.0 * slope * slope
			if terrain.is_sea(p.x, p.y):
				grid.set_point_solid(Vector2i(gx, gz), true)
			elif terrain.bank_at(p.x, p.y) < 1.0:
				w += WATER_WEIGHT
			weights[gz * gw + gx] = w
			grid.set_point_weight_scale(Vector2i(gx, gz), w)

	var n := sites.size()
	var paths := {}
	var costs := {}
	for i in n:
		for j in range(i + 1, n):
			var path: Array[Vector2i] = grid.get_id_path(_cell(sites[i]["pos"], gw, gh), _cell(sites[j]["pos"], gw, gh))
			var cost := 0.0
			for k in range(1, path.size()):
				var step := _world(path[k]).distance_to(_world(path[k - 1]))
				cost += step * weights[path[k].y * gw + path[k].x]
			paths[Vector2i(i, j)] = path
			costs[Vector2i(i, j)] = cost if not path.is_empty() else INF

	# Kruskal: a spanning forest over reachable pairs, so separate islands each
	# get their own road network (sea routes link them afterwards).
	var edges: Array[Vector2i] = []
	for edge in costs:
		if costs[edge] < INF:
			edges.append(edge)
	edges.sort_custom(func(x: Vector2i, y: Vector2i) -> bool: return costs[x] < costs[y])
	var parent: Array[int] = []
	for i in n:
		parent.append(i)
	var chosen: Array[Vector2i] = []
	for e in edges:
		var root_a := _find(parent, e.x)
		var root_b := _find(parent, e.y)
		if root_a != root_b:
			parent[root_a] = root_b
			chosen.append(e)
	var town := _index_of(sites, "town")
	var port := _index_of(sites, "port")
	if town >= 0 and port >= 0:
		var trade := Vector2i(mini(town, port), maxi(town, port))
		if not chosen.has(trade) and costs.has(trade) and costs[trade] < INF:
			chosen.append(trade)

	var roads: Array[Dictionary] = []
	for e in chosen:
		var a: Dictionary = sites[e.x]
		var b: Dictionary = sites[e.y]
		var line := PackedVector2Array()
		for cell in paths[e] as Array[Vector2i]:
			line.append(_world(cell))
		var simple := _simplify(line, SIMPLIFY)
		var points: Array = [{"settlement": a["id"]}]
		for k in range(1, simple.size() - 1):
			points.append(Vector3(simple[k].x, 0.0, simple[k].y))
		points.append({"settlement": b["id"]})
		roads.append({"id": "road_%d_%d" % [a["id"], b["id"]], "a": a["id"], "b": b["id"], "cost": costs[e], "points": points})
	return roads

## Adds a ford record for every pair of bank hits where a road crosses a river.
## An odd hit count (a grazing or ending-in-water path) is left for the
## validator's geometry check to report.
static func add_crossings(map: ValleyMapDefinition) -> void:
	map.crossings = {}
	for river_id in map.rivers:
		var outline := Ribbon.footprint(map.river_path(river_id), map.rivers[river_id]["width"])
		for road_id in map.roads:
			var samples := Ribbon._sample_catmull_rom(map.road_path(road_id), 0.6)
			var hits: Array[Vector2] = []
			var last := Vector2.INF
			for segment in range(samples.size() - 1):
				var a := Vector2(samples[segment].x, samples[segment].z)
				var b := Vector2(samples[segment + 1].x, samples[segment + 1].z)
				for i in outline.size():
					var hit: Variant = Geometry2D.segment_intersects_segment(a, b, outline[i], outline[(i + 1) % outline.size()])
					if hit == null or (hit as Vector2).distance_to(last) < 0.01:
						continue
					last = hit
					hits.append(hit)
			var pair := 0
			for k in range(0, hits.size() - 1, 2):
				var mid := (hits[k] + hits[k + 1]) * 0.5
				var id := "ford_%s_%s_%d" % [road_id, river_id, pair]
				pair += 1
				map.crossings[id] = {
					"kind": "ford", "name": id, "road": road_id, "river": river_id,
					"position": Vector3(mid.x, 0.0, mid.y),
					"radius": hits[k].distance_to(hits[k + 1]) * 0.5 + 8.0,
					"width": 3.8, "seed": 9000 + map.crossings.size(),
				}

static func _find(parent: Array[int], i: int) -> int:
	while parent[i] != i:
		parent[i] = parent[parent[i]]
		i = parent[i]
	return i

static func _index_of(sites: Array[Dictionary], role: String) -> int:
	for i in sites.size():
		if sites[i]["role"] == role:
			return i
	return -1

static func _world(cell: Vector2i) -> Vector2:
	return Vector2(cell.x * CELL - Terrain.SIZE.x * 0.5, cell.y * CELL - Terrain.SIZE.y * 0.5)

static func _cell(p: Vector2, gw: int, gh: int) -> Vector2i:
	return Vector2i(
		clampi(roundi((p.x + Terrain.SIZE.x * 0.5) / CELL), 0, gw - 1),
		clampi(roundi((p.y + Terrain.SIZE.y * 0.5) / CELL), 0, gh - 1))

## Ramer-Douglas-Peucker, keeping both endpoints.
static func _simplify(line: PackedVector2Array, epsilon: float) -> PackedVector2Array:
	if line.size() < 3:
		return line
	var worst := 0.0
	var index := 0
	var a := line[0]
	var b := line[line.size() - 1]
	for i in range(1, line.size() - 1):
		var d := _segment_distance(line[i], a, b)
		if d > worst:
			worst = d
			index = i
	if worst <= epsilon:
		return PackedVector2Array([a, b])
	var left := _simplify(line.slice(0, index + 1), epsilon)
	var right := _simplify(line.slice(index), epsilon)
	left.resize(left.size() - 1)
	left.append_array(right)
	return left

static func _segment_distance(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var length_sq := ab.length_squared()
	if length_sq == 0.0:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / length_sq, 0.0, 1.0)
	return p.distance_to(a + ab * t)
