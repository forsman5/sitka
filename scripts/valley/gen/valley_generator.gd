extends RefCounted

## Rough valley generator sketch: roster -> terrain -> sites -> roads ->
## vegetation -> ValleyMapDefinition -> validation. One deterministic function of
## the seed. See docs/valley-generation-sketch.md.

const Spec = preload("res://scripts/valley/gen/valley_spec.gd")
const Terrain = preload("res://scripts/valley/gen/valley_gen_terrain.gd")
const Sites = preload("res://scripts/valley/gen/valley_gen_sites.gd")
const Roads = preload("res://scripts/valley/gen/valley_gen_roads.gd")
const Validator = preload("res://scripts/valley/gen/valley_gen_validator.gd")

const MAX_TREES := 700

## Generate from a landscape preset and a seed.
static func generate_seed(world_seed: int, landscape := "river_valley") -> Dictionary:
	return generate(Spec.preset(landscape, world_seed))

## Result: {seed, spec, terrain, sites, roads, map, trees, report, ms}.
static func generate(spec: Spec) -> Dictionary:
	var started := Time.get_ticks_msec()
	var world_seed: int = spec.seed
	var spec_errors := spec.validate()
	if not spec_errors.is_empty():
		return {"seed": world_seed, "spec": spec, "spec_errors": spec_errors}
	var rng := RandomNumberGenerator.new()

	var terrain := Terrain.new()
	terrain.world_seed = world_seed
	rng.seed = world_seed * 7919 + 1
	terrain.build(rng, spec)

	rng.seed = world_seed * 7919 + 2
	var picked := Sites.pick(terrain, rng, spec)
	var sites: Array[Dictionary] = picked["sites"]
	for site in sites:
		terrain.apply_pad(site["pos"], site["pad"], site["height"])
	for site in sites:
		terrain.stamp_pad(site["pos"], site["pad"], site["height"])
	terrain.finalize()

	var roads := Roads.build(terrain, sites)
	var map := _emit_map(terrain, sites, roads, world_seed)
	Roads.add_crossings(map)

	var result := {
		"seed": world_seed, "spec": spec, "terrain": terrain, "sites": sites,
		"roads": roads, "map": map, "failures": picked["failures"],
	}
	rng.seed = world_seed * 7919 + 3
	_add_vegetation(result, rng)
	result["trees"] = tree_points(result)
	result["report"] = Validator.run(result)
	result["ms"] = Time.get_ticks_msec() - started
	return result

static func _emit_map(terrain: Terrain, sites: Array[Dictionary], roads: Array[Dictionary], world_seed: int) -> ValleyMapDefinition:
	var map := ValleyMapDefinition.new()
	for site in sites:
		var pos: Vector2 = site["pos"]
		var record := {
			"site": Vector3(pos.x, site["height"], pos.y),
			"role": site["text"], "accent": site["accent"], "district": site["district"],
			"name": site["name"], "kind": site["role"], "pad": site["pad"],
		}
		if site["waterfront"] != null:
			record["waterfront"] = site["waterfront"]
		map.settlements[site["id"]] = record
	for id in terrain.junctions:
		map.junctions[id] = {"position": terrain.junctions[id], "inner_radius": 14.0, "outer_radius": 30.0}
	for id in terrain.rivers:
		var river: Dictionary = terrain.rivers[id]
		map.rivers[id] = {"node_name": river["node_name"], "width": river["width"], "points": river["map_points"]}
	var edge := 0
	for road in roads:
		map.roads[road["id"]] = {"simulation_edge": edge, "width": Roads.ROAD_WIDTH, "seed": world_seed + edge * 17, "points": road["points"]}
		edge += 1
	return map

static func _add_vegetation(result: Dictionary, rng: RandomNumberGenerator) -> void:
	var map: ValleyMapDefinition = result["map"]
	var terrain: Terrain = result["terrain"]
	var sites: Array[Dictionary] = result["sites"]
	var seed_base: int = result["seed"] * 31
	for site in sites:
		var role: String = site["role"]
		var radii := Vector2(24.0, 14.0)
		var count := 24
		match role:
			"woodland":
				radii = Vector2(46.0, 34.0)
				count = 210
			"pasture":
				radii = Vector2(31.0, 18.0)
				count = 16
			"ore":
				radii = Vector2(28.0, 18.0)
				count = 30
		map.vegetation["%s_%d_veg" % [role, site["id"]]] = {
			"center": {"settlement": site["id"], "offset": Vector3(rng.randf_range(-6.0, 6.0), 0.0, rng.randf_range(-6.0, 6.0))},
			"radii": radii, "count": count, "seed": seed_base + site["id"], "clearance": site["pad"] * 0.6 + 4.0,
		}
	# A few free forest patches on moderate slopes near water, clear of sites.
	var patches := 0
	for attempt in 300:
		if patches >= 3:
			break
		var c := Vector2(rng.randf_range(-130.0, 130.0), rng.randf_range(-90.0, 90.0))
		var bank := terrain.bank_at(c.x, c.y)
		var slope := terrain.slope_at(c.x, c.y)
		if bank < 14.0 or bank > 70.0 or slope < 0.04 or slope > 0.3:
			continue
		var clear := true
		for site in sites:
			if c.distance_to(site["pos"]) < float(site["pad"]) + 40.0:
				clear = false
		if not clear:
			continue
		map.vegetation["forest_%d" % patches] = {
			"center": Vector3(c.x, 0.0, c.y), "radii": Vector2(rng.randf_range(18.0, 32.0), rng.randf_range(12.0, 22.0)),
			"count": 90, "seed": seed_base + 100 + patches, "clearance": 0.0,
		}
		patches += 1

## Tree positions (xz) from the vegetation records, dry land and outside pads.
static func tree_points(result: Dictionary) -> PackedVector2Array:
	var map: ValleyMapDefinition = result["map"]
	var terrain: Terrain = result["terrain"]
	var sites: Array[Dictionary] = result["sites"]
	var points := PackedVector2Array()
	var rng := RandomNumberGenerator.new()
	for id in map.vegetation:
		var record: Dictionary = map.vegetation[id]
		var center3 := map.resolve_point(record["center"])
		var center := Vector2(center3.x, center3.z)
		var radii: Vector2 = record["radii"]
		rng.seed = record["seed"]
		for i in int(record["count"]):
			var a := rng.randf() * TAU
			var r := sqrt(rng.randf())
			var p := center + Vector2(cos(a) * radii.x, sin(a) * radii.y) * r
			if p.distance_to(center) < float(record["clearance"]):
				continue
			if absf(p.x) > Terrain.SIZE.x * 0.5 or absf(p.y) > Terrain.SIZE.y * 0.5:
				continue
			if terrain.bank_at(p.x, p.y) < 3.0:
				continue
			var blocked := false
			for site in sites:
				if p.distance_to(site["pos"]) < float(site["pad"]) + 2.0:
					blocked = true
					break
			if not blocked and points.size() < MAX_TREES:
				points.append(p)
	return points

## Road centerline samples (world xz) at `spacing`, for drawing and grade checks.
static func road_samples(map: ValleyMapDefinition, road_id: String, spacing: float) -> PackedVector2Array:
	var line := PackedVector2Array()
	for p in Terrain.Ribbon._sample_catmull_rom(map.road_path(road_id), spacing):
		line.append(Vector2(p.x, p.z))
	return line
