extends RefCounted

## Dev-tool bake: turns a validated strategic result (320x240 layout space) into
## a larger, more detailed valley: the geography scaled up (3x by default, about
## 10x the area), a finer heightfield with added detail and thermal erosion,
## ground colours, many trees and village buildings. Time-sliced so the UI stays
## responsive while a dev waits. See docs/valley-generation-sketch.md.
##
## The bake is plain data (heights, colours, tree list, scaled map) so it can be
## saved and reloaded without re-running any of this.

const Terrain = preload("res://scripts/valley/gen/valley_gen_terrain.gd")
const Relief = preload("res://scripts/valley/gen/valley_gen_relief.gd")
const Generator = preload("res://scripts/valley/gen/valley_generator.gd")

const DEFAULTS := {
	"scale": 3.0,
	"step": 1.0,
	"height_scale": 1.6,
	"erosion": 24,
	"tree_spacing": 2.0,
}
const SLICE_MS := 12
const ROAD_WIDTH := 4.0
const ROUTE_WIDTH := 3.0
const BUILDINGS_PER_ROLE := {"town": 40, "port": 24, "ore": 12, "woodland": 10, "pasture": 10, "farm": 12, "fishing": 9}
const HOUSES := ["res://assets/models/buildings/building_home_A_blue.gltf", "res://assets/models/buildings/building_home_B_blue.gltf"]
const HALLS := {
	"town": "res://assets/models/buildings/building_castle_blue.gltf",
	"ore": "res://assets/models/buildings/building_mine_blue.gltf",
}
const DEFAULT_HALL := "res://assets/models/buildings/building_tavern_blue.gltf"

var cancelled := false
var _tree: SceneTree
var _progress := Callable()
var _slice_start := 0

## Coroutine. Returns the bake Dictionary, or {} when cancelled. `progress` is
## called with (fraction 0-1, text). Fractions stop at 0.78; the scene build
## (BakedValleyRenderer) reports the rest.
func run(result: Dictionary, tree: SceneTree, progress: Callable, options := {}) -> Dictionary:
	_tree = tree
	_progress = progress
	_slice_start = Time.get_ticks_msec()
	var started := _slice_start
	var opts: Dictionary = DEFAULTS.duplicate()
	opts.merge(options, true)
	var s: float = opts["scale"]
	var step: float = opts["step"]
	var vs: float = opts["height_scale"]
	var terrain: Terrain = result["terrain"]
	var spec: RefCounted = result["spec"]
	var size_w := Terrain.SIZE * s
	var w := int(round(size_w.x / step)) + 1
	var h := int(round(size_w.y / step)) + 1

	var sites: Array[Dictionary] = []
	var site_pos := PackedVector2Array()
	var site_pad := PackedFloat32Array()
	for site in result["sites"] as Array[Dictionary]:
		var p: Vector2 = site["pos"] * s
		sites.append({"id": site["id"], "role": site["role"], "name": site["name"], "pos": p, "pad": float(site["pad"]) * s, "height": float(site["height"]) * vs, "accent": site["accent"]})
		site_pos.append(p)
		site_pad.append(float(site["pad"]) * s)

	await _tick(0.0, "Scaling the map", true)
	var map := _scaled_map(result["map"], s, vs)
	var map_errors := map.validate_geometry()

	# -- terrain detail ------------------------------------------------------
	var heights := PackedFloat32Array()
	var bank := PackedFloat32Array()
	var flags := PackedByteArray()
	var protect := PackedByteArray()
	heights.resize(w * h)
	bank.resize(w * h)
	flags.resize(w * h)
	protect.resize(w * h)
	var broad := _noise(spec.seed + 11, 0.018, 4)
	var fine := _noise(spec.seed + 12, 0.07, 2)
	var micro := _noise(spec.seed + 13, 0.18, 1)
	var detail_gain: float = 0.6 + 0.4 * float(spec.relief)
	for j in h:
		for i in w:
			var pw := Vector2(i * step - size_w.x * 0.5, j * step - size_w.y * 0.5)
			var pl := pw / s
			var idx := j * w + i
			var bank_w := terrain.bank_at(pl.x, pl.y) * s
			var nearest := INF
			for k in site_pos.size():
				nearest = minf(nearest, pw.distance_to(site_pos[k]) / site_pad[k])
			var mask := smoothstep(4.0, 30.0, bank_w) * smoothstep(0.9, 1.4, nearest)
			var detail := (broad.get_noise_2d(pw.x, pw.y) * 3.2 + fine.get_noise_2d(pw.x, pw.y) * 0.9 + micro.get_noise_2d(pw.x, pw.y) * 0.22) * mask * detail_gain
			heights[idx] = terrain.get_height(pl.x, pl.y) * vs + detail
			bank[idx] = bank_w
			flags[idx] = 1 if terrain.is_sea(pl.x, pl.y) else 0
			protect[idx] = 1 if (bank_w < 6.0 or nearest < 0.95) else 0
		await _tick(0.25 * float(j) / float(h), "Raising terrain detail")
		if cancelled:
			return {}

	# -- thermal erosion -----------------------------------------------------
	var talus := 0.8 * step
	var passes: int = opts["erosion"]
	for pass_index in passes:
		for j in range(1, h - 1):
			for i in range(1, w - 1):
				var idx := j * w + i
				if protect[idx] == 1:
					continue
				var here := heights[idx]
				var lowest_index := idx
				var biggest_drop := 0.0
				var drop := here - heights[idx - 1]
				if drop > biggest_drop:
					biggest_drop = drop
					lowest_index = idx - 1
				drop = here - heights[idx + 1]
				if drop > biggest_drop:
					biggest_drop = drop
					lowest_index = idx + 1
				drop = here - heights[idx - w]
				if drop > biggest_drop:
					biggest_drop = drop
					lowest_index = idx - w
				drop = here - heights[idx + w]
				if drop > biggest_drop:
					biggest_drop = drop
					lowest_index = idx + w
				if biggest_drop > talus and protect[lowest_index] == 0:
					var moved := (biggest_drop - talus) * 0.25
					heights[idx] = here - moved
					heights[lowest_index] += moved
			await _tick(0.25 + 0.25 * (float(pass_index) + float(j) / float(h)) / float(passes), "Eroding slopes (pass %d of %d)" % [pass_index + 1, passes])
			if cancelled:
				return {}

	var height_max := 1.0
	for value in heights:
		height_max = maxf(height_max, value)

	# -- ground colours ------------------------------------------------------
	var forest := _noise(spec.seed + 14, 0.012, 3)
	var patch := _noise(spec.seed + 15, 0.05, 2)
	var woodland_sites: Array[int] = []
	for k in sites.size():
		if sites[k]["role"] == "woodland":
			woodland_sites.append(k)
	var colors := Image.create(w, h, false, Image.FORMAT_RGB8)
	var land_low := 0.0 if terrain.has_sea else heights[0]
	if not terrain.has_sea:
		for value in heights:
			land_low = minf(land_low, value)
	for j in h:
		for i in w:
			var idx := j * w + i
			var pw := Vector2(i * step - size_w.x * 0.5, j * step - size_w.y * 0.5)
			var height := heights[idx]
			var bank_w := bank[idx]
			var slope := _slope(heights, w, h, i, j, step)
			var color: Color
			if flags[idx] == 1:
				color = Relief.WATER.lerp(Relief.SEA, clampf(-height / 6.0, 0.0, 1.0))
			elif bank_w < -1.0:
				color = Relief.WATER.lerp(Relief.WATER.darkened(0.3), clampf(-bank_w / 30.0, 0.0, 1.0))
			else:
				color = Relief._ground_color((height - land_low) / maxf(height_max - land_low, 0.001))
				var variation := 0.92 + 0.16 * (fine.get_noise_2d(pw.x * 1.7, pw.y * 1.7) * 0.5 + 0.5)
				color = Color(color.r * variation, color.g * variation, color.b * variation)
				if slope > 0.45:
					color = color.lerp(Color(0.46, 0.43, 0.4), smoothstep(0.45, 0.95, slope))
				if terrain.has_sea and bank_w < 14.0 and height < 3.0:
					color = color.lerp(Relief.SAND, 0.8 * (1.0 - smoothstep(4.0, 14.0, bank_w)))
				elif bank_w < 8.0:
					color = color.lerp(Relief.WET_BANK, 0.5 * (1.0 - smoothstep(0.0, 8.0, bank_w)))
				var density := _density(bank_w, slope, height, height_max, forest.get_noise_2d(pw.x, pw.y), _boost(pw, sites, woodland_sites))
				color = color.lerp(Color(0.1, 0.24, 0.1), clampf(density, 0.0, 1.0) * 0.45)
				for k in sites.size():
					var d := pw.distance_to(sites[k]["pos"])
					var pad: float = sites[k]["pad"]
					var role: String = sites[k]["role"]
					if (role == "town" or role == "farm") and d > pad and d < pad * 2.4 and slope < 0.25 and patch.get_noise_2d(pw.x, pw.y) > -0.1:
						var rows := int(floor((pw.x + pw.y) / 6.0)) % 2 == 0
						color = color.lerp(Color(0.66, 0.58, 0.28) if rows else Color(0.52, 0.55, 0.26), 0.7)
					elif role == "pasture" and d < pad * 2.8 and slope < 0.3:
						color = color.lerp(Color(0.46, 0.62, 0.3), 0.45)
			colors.set_pixel(i, j, color)
		await _tick(0.5 + 0.1 * float(j) / float(h), "Colouring the ground")
		if cancelled:
			return {}

	# -- trees ---------------------------------------------------------------
	var trees := PackedFloat32Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = int(spec.seed) * 131 + 17
	var road_cells := {}
	for road_id in map.roads:
		for p in Generator.road_samples(map, road_id, 3.0):
			road_cells[Vector2i(floori(p.x / 4.0), floori(p.y / 4.0))] = true
	var spacing: float = opts["tree_spacing"]
	var columns := int(size_w.x / spacing)
	var rows_count := int(size_w.y / spacing)
	for cz in rows_count:
		for cx in columns:
			var pw := Vector2((cx + rng.randf()) * spacing - size_w.x * 0.5, (cz + rng.randf()) * spacing - size_w.y * 0.5)
			var gi := clampi(roundi((pw.x + size_w.x * 0.5) / step), 1, w - 2)
			var gj := clampi(roundi((pw.y + size_w.y * 0.5) / step), 1, h - 2)
			var idx := gj * w + gi
			var accept_roll := rng.randf()
			var kind_roll := rng.randf()
			var scale_roll := rng.randf()
			var yaw := rng.randf() * TAU
			if flags[idx] == 1 or bank[idx] < 3.0:
				continue
			var blocked := false
			for k in sites.size():
				if pw.distance_to(sites[k]["pos"]) < float(sites[k]["pad"]) * 0.95:
					blocked = true
					break
			if blocked:
				continue
			var road_key := Vector2i(floori(pw.x / 4.0), floori(pw.y / 4.0))
			for dz in range(-1, 2):
				for dx in range(-1, 2):
					if road_cells.has(road_key + Vector2i(dx, dz)):
						blocked = true
			if blocked:
				continue
			var slope := _slope(heights, w, h, gi, gj, step)
			var density := _density(bank[idx], slope, heights[idx], height_max, forest.get_noise_2d(pw.x, pw.y), _boost(pw, sites, woodland_sites))
			for k in sites.size():
				var role: String = sites[k]["role"]
				if (role == "farm" or role == "pasture") and pw.distance_to(sites[k]["pos"]) < float(sites[k]["pad"]) * 2.0:
					density *= 0.15
			if accept_roll >= density:
				continue
			var high_ground := heights[idx] / height_max > 0.45
			var kind := 1.0 if (high_ground and kind_roll < 0.75) or kind_roll < 0.25 else 0.0
			trees.append_array([pw.x, pw.y, yaw, lerpf(3.6, 6.2, scale_roll), kind])
		await _tick(0.6 + 0.15 * float(cz) / float(rows_count), "Planting trees (%d so far)" % (trees.size() / 5))
		if cancelled:
			return {}

	# -- buildings -----------------------------------------------------------
	await _tick(0.75, "Building villages", true)
	var buildings := _place_buildings(sites, heights, bank, flags, w, h, step, size_w, rng)

	await _tick(0.78, "Baked data ready", true)
	return {
		"spec": spec, "scale": s, "step": step, "height_scale": vs, "size": size_w, "w": w, "h": h,
		"heights": heights, "colors": colors, "bank": bank, "flags": flags, "trees": trees,
		"buildings": buildings, "sites": sites, "map": map, "has_sea": terrain.has_sea,
		"height_max": height_max,
		"stats": {
			"cells": w * h, "trees": trees.size() / 5, "buildings": buildings.size(),
			"map_errors": map_errors.size(), "ms": Time.get_ticks_msec() - started, "erosion": passes,
		},
	}

func cancel() -> void:
	cancelled = true

# -- helpers -----------------------------------------------------------------

func _tick(fraction: float, text: String, force := false) -> void:
	if force or Time.get_ticks_msec() - _slice_start >= SLICE_MS:
		if _progress.is_valid():
			_progress.call(fraction, text)
		await _tree.process_frame
		_slice_start = Time.get_ticks_msec()

static func _noise(seed_value: int, frequency: float, octaves: int) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = seed_value
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = frequency
	n.fractal_octaves = octaves
	return n

static func _slope(heights: PackedFloat32Array, w: int, h: int, i: int, j: int, step: float) -> float:
	var x0 := maxi(i - 1, 0)
	var x1 := mini(i + 1, w - 1)
	var z0 := maxi(j - 1, 0)
	var z1 := mini(j + 1, h - 1)
	var dx := (heights[j * w + x1] - heights[j * w + x0]) / (float(x1 - x0) * step)
	var dz := (heights[z1 * w + i] - heights[z0 * w + i]) / (float(z1 - z0) * step)
	return sqrt(dx * dx + dz * dz)

## Chance (0-1) that a tree stands here: lusher near water, patchy, thinning with
## altitude and steepness, boosted around woodland settlements.
static func _density(bank_w: float, slope: float, height: float, height_max: float, patch_noise: float, boost: float) -> float:
	if bank_w < 2.0:
		return 0.0
	var f := 0.22 + 0.5 * exp(-maxf(bank_w, 0.0) / 90.0) + 0.38 * patch_noise + boost
	f *= (1.0 - smoothstep(0.6, 0.95, height / height_max)) * (1.0 - smoothstep(0.45, 0.8, slope))
	return clampf(f, 0.0, 1.0)

static func _boost(p: Vector2, sites: Array[Dictionary], woodland_sites: Array[int]) -> float:
	var best := 0.0
	for k in woodland_sites:
		var pad: float = sites[k]["pad"]
		best = maxf(best, 0.5 * (1.0 - smoothstep(pad, pad * 3.5, p.distance_to(sites[k]["pos"]))))
	return best

func _place_buildings(sites: Array[Dictionary], heights: PackedFloat32Array, bank: PackedFloat32Array, flags: PackedByteArray, w: int, h: int, step: float, size_w: Vector2, rng: RandomNumberGenerator) -> Array[Dictionary]:
	var placed: Array[Dictionary] = []
	for site in sites:
		var role: String = site["role"]
		var count: int = BUILDINGS_PER_ROLE.get(role, 8)
		var center: Vector2 = site["pos"]
		var radius: float = float(site["pad"]) * 0.5
		placed.append({"site": site["id"], "model": HALLS.get(role, DEFAULT_HALL), "pos": center, "yaw": 0.0, "width": 13.0 if role == "town" else 8.0})
		for i in count:
			# A golden-angle spiral gives an organic cluster with even spacing.
			var r := radius * sqrt((float(i) + 0.5) / float(count)) + 7.0
			var angle := float(i) * 2.399963 + rng.randf_range(-0.2, 0.2)
			var p := center + Vector2(cos(angle), sin(angle)) * r
			var gi := clampi(roundi((p.x + size_w.x * 0.5) / step), 1, w - 2)
			var gj := clampi(roundi((p.y + size_w.y * 0.5) / step), 1, h - 2)
			var idx := gj * w + gi
			if flags[idx] == 1 or bank[idx] < 8.0 or _slope(heights, w, h, gi, gj, step) > 0.4:
				continue
			var facing := rad_to_deg(atan2(center.x - p.x, center.y - p.y))
			placed.append({"site": site["id"], "model": HOUSES[i % HOUSES.size()], "pos": p, "yaw": snappedf(facing, 90.0), "width": rng.randf_range(4.6, 6.0)})
	return placed

static func _scale_point(point: Variant, s: float) -> Variant:
	if point is Vector3:
		return Vector3(point.x * s, 0.0, point.z * s)
	return point

func _scaled_map(src: ValleyMapDefinition, s: float, vs: float) -> ValleyMapDefinition:
	var map := ValleyMapDefinition.new()
	for id in src.settlements:
		var record: Dictionary = (src.settlements[id] as Dictionary).duplicate(true)
		var site: Vector3 = record["site"]
		record["site"] = Vector3(site.x * s, site.y * vs, site.z * s)
		record["pad"] = float(record["pad"]) * s
		if record.has("waterfront"):
			record["waterfront"] = _scale_point(record["waterfront"], s)
		map.settlements[id] = record
	for id in src.junctions:
		var junction: Dictionary = (src.junctions[id] as Dictionary).duplicate()
		junction["position"] = _scale_point(junction["position"], s)
		junction["inner_radius"] = float(junction["inner_radius"]) * s
		junction["outer_radius"] = float(junction["outer_radius"]) * s
		map.junctions[id] = junction
	for id in src.rivers:
		var river: Dictionary = (src.rivers[id] as Dictionary).duplicate()
		river["width"] = float(river["width"]) * s
		river["points"] = _scale_points(river["points"], s)
		map.rivers[id] = river
	for id in src.roads:
		var road: Dictionary = (src.roads[id] as Dictionary).duplicate()
		road["width"] = ROAD_WIDTH
		road["points"] = _scale_points(road["points"], s)
		map.roads[id] = road
	for id in src.water_routes:
		var route: Dictionary = (src.water_routes[id] as Dictionary).duplicate()
		route["width"] = ROUTE_WIDTH
		route["points"] = _scale_points(route["points"], s)
		map.water_routes[id] = route
	for id in src.crossings:
		var crossing: Dictionary = (src.crossings[id] as Dictionary).duplicate()
		crossing["position"] = _scale_point(crossing["position"], s)
		crossing["radius"] = float(crossing["radius"]) * s
		crossing["width"] = ROAD_WIDTH + 1.0
		map.crossings[id] = crossing
	return map

static func _scale_points(points: Array, s: float) -> Array:
	var result: Array = []
	for p in points:
		result.append(_scale_point(p, s))
	return result

# -- saving and loading --------------------------------------------------------

## Writes the bake as plain files into `dir`: spec.json, bake.json (settings,
## sites, buildings, stats), heights.bin (float32) and heights.exr (a heightmap
## image for tooling), colors.png, trees.bin (float32 x,z,yaw,scale,kind) and
## map.tres (the scaled ValleyMapDefinition). Returns an error string, empty on success.
static func save(bake: Dictionary, dir: String) -> String:
	var made := DirAccess.make_dir_recursive_absolute(dir)
	if made != OK:
		return "Could not create %s (%s)" % [dir, error_string(made)]
	var w: int = bake["w"]
	var h: int = bake["h"]
	var meta := {
		"format": 1, "scale": bake["scale"], "step": bake["step"], "height_scale": bake["height_scale"],
		"size": [bake["size"].x, bake["size"].y], "w": w, "h": h, "has_sea": bake["has_sea"],
		"height_max": bake["height_max"], "stats": bake["stats"],
		"sites": _plain_sites(bake["sites"]), "buildings": _plain_buildings(bake["buildings"]),
	}
	var files := {
		"spec.json": bake["spec"].to_json().to_utf8_buffer(),
		"bake.json": JSON.stringify(meta, "  ").to_utf8_buffer(),
		"heights.bin": (bake["heights"] as PackedFloat32Array).to_byte_array(),
		"trees.bin": (bake["trees"] as PackedFloat32Array).to_byte_array(),
	}
	for name in files:
		var file := FileAccess.open("%s/%s" % [dir, name], FileAccess.WRITE)
		if file == null:
			return "Could not write %s/%s" % [dir, name]
		file.store_buffer(files[name])
		file.close()
	var height_image := Image.create_from_data(w, h, false, Image.FORMAT_RF, (bake["heights"] as PackedFloat32Array).to_byte_array())
	var errors: Array[int] = [
		height_image.save_exr("%s/heights.exr" % dir, true),
		(bake["colors"] as Image).save_png("%s/colors.png" % dir),
		ResourceSaver.save(bake["map"], "%s/map.tres" % dir),
	]
	for code in errors:
		if code != OK:
			return "A bake file failed to save (%s)" % error_string(code)
	return ""

static func _plain_sites(sites: Array) -> Array:
	var result: Array = []
	for s in sites:
		result.append({"id": s["id"], "role": s["role"], "name": s["name"], "pos": [s["pos"].x, s["pos"].y], "pad": s["pad"], "height": s["height"], "accent": s["accent"].to_html()})
	return result

static func _plain_buildings(buildings: Array) -> Array:
	var result: Array = []
	for b in buildings:
		result.append({"site": b["site"], "model": b["model"], "pos": [b["pos"].x, b["pos"].y], "yaw": b["yaw"], "width": b["width"]})
	return result

