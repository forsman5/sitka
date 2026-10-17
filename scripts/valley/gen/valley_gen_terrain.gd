extends RefCounted

## Heightfield and water for one generated landscape (river valley, coast or
## island). Rough sketch: see docs/valley-generation-sketch.md. This is also the
## terrain contract the town view and layout would consume: get_height /
## slope_at / is_water / SIZE.

const Ribbon = preload("res://scripts/valley/terrain_ribbon_builder.gd")

## Same footprint as the authored valley, so a generated one can replace it.
const SIZE := Vector2(320.0, 240.0)
const STEP := 2.5
const W := 129
const H := 97
## Rivers run past the map edge so clipping never shows an end cap.
const EXTENT := 190.0
const SAMPLE_SPACING := 6.0
const CARVE_DEPTH := 2.5
const BANK := 5.0
const ISLAND_STRETCH := 1.35

var world_seed := 0
var landscape := "river_valley"
var relief := 1.0
var has_sea := false
## Heights below this are open sea (coast and island only).
var sea_level := -1000.0

## Direction the main river runs (start -> end); its projection gives the
## "downstream" fraction used for floors and port placement.
var flow_start := Vector2.ZERO
var flow_end := Vector2.ZERO
var flow_sign := 1.0
var valley_half := 70.0
var valley_rise := 40.0
var source_height := 24.0
var mouth_height := 5.0

var sea_dir := Vector2.RIGHT
var coast_pos := 0.0
## The largest island (index 0): home of the main river and the focus point.
var island_center := Vector2.ZERO
var island_radius := 85.0
## [{center: Vector2, radius: float}], largest first.
var islands: Array[Dictionary] = []

var _hills := FastNoiseLite.new()
var _ridges := FastNoiseLite.new()
var _shore_noise := FastNoiseLite.new()

## Ground before river carving; pads are graded into this.
var land := PackedFloat32Array()
## Final surface (land with rivers carved).
var heights := PackedFloat32Array()
## Signed distance to the nearest water of any kind (river bank or shore):
## < 0 is water. Everything outside this class reads this one field.
var bank_dist := PackedFloat32Array()
## Signed distance to the nearest river bank (INF with no river); drives carving.
var river_bank := PackedFloat32Array()
## Signed distance from the coast: > 0 inland, < 0 sea (INF for a river valley).
var shore := PackedFloat32Array()
var bed_height := PackedFloat32Array()
var bank_half := PackedFloat32Array()

## id -> {kind: main|tributary, controls, map_points, ref_indices, width, samples,
##        floors, node_name}
var rivers: Dictionary = {}
## id -> Vector3
var junctions: Dictionary = {}

var _probe_d := 0.0
var _probe_floor := 0.0

func build(rng: RandomNumberGenerator, spec: RefCounted) -> void:
	landscape = spec.landscape
	relief = spec.relief
	has_sea = landscape != "river_valley"
	sea_level = 0.0 if has_sea else -1000.0
	_hills.seed = world_seed
	_hills.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_hills.frequency = 0.011
	_hills.fractal_octaves = 4
	_ridges.seed = world_seed + 101
	_ridges.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_ridges.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	_ridges.frequency = 0.012
	_ridges.fractal_octaves = 3
	_shore_noise.seed = world_seed + 202
	_shore_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_shore_noise.frequency = 0.015
	match landscape:
		"coast":
			_setup_coast(rng, spec.sea_side)
		"island":
			_setup_island(rng, spec.islands)
	valley_half = rng.randf_range(70.0, 120.0)
	valley_rise = rng.randf_range(22.0, 38.0) * relief
	_build_rivers(rng, spec)
	_build_land()
	heights = land.duplicate()
	finalize()

# -- landscape shape ---------------------------------------------------------

func _setup_coast(rng: RandomNumberGenerator, side: String) -> void:
	var sides := {"north": Vector2(0, -1), "south": Vector2(0, 1), "east": Vector2(1, 0), "west": Vector2(-1, 0)}
	if side == "":
		side = ["north", "south", "east", "west"][rng.randi_range(0, 3)]
	sea_dir = sides[side]
	coast_pos = _axis_half(sea_dir) * rng.randf_range(-0.05, 0.4)

func _setup_island(rng: RandomNumberGenerator, count: int) -> void:
	islands.clear()
	if count <= 1:
		islands.append({"center": Vector2(rng.randf_range(-20.0, 20.0), rng.randf_range(-12.0, 12.0)), "radius": rng.randf_range(75.0, 92.0)})
	else:
		var range_r := Vector2(40.0, 50.0) if count == 2 else Vector2(30.0, 40.0)
		var radii: Array[float] = []
		for i in count:
			radii.append(rng.randf_range(range_r.x, range_r.y))
		radii.sort()
		radii.reverse()
		# Spread the islands around a ring so there is room for each; retry the
		# whole arrangement until the channels between them are clear (or accept
		# the last try, where islands may touch and merge into one landmass).
		for attempt in 40:
			islands.clear()
			var start_angle := rng.randf() * TAU
			for i in count:
				var radius := radii[i]
				var angle := start_angle + TAU * float(i) / float(count) + rng.randf_range(-0.35, 0.35)
				var span := Vector2(SIZE.x * 0.5 - radius * ISLAND_STRETCH - 8.0, SIZE.y * 0.5 - radius - 8.0)
				var reach := rng.randf_range(0.75, 1.0)
				islands.append({"center": Vector2(cos(angle) * span.x * reach, sin(angle) * span.y * reach), "radius": radius})
			var clear := true
			for i in count:
				for j in range(i + 1, count):
					var o: Vector2 = islands[i]["center"] - islands[j]["center"]
					if sqrt(o.x * o.x / (ISLAND_STRETCH * ISLAND_STRETCH) + o.y * o.y) < (float(islands[i]["radius"]) + float(islands[j]["radius"])) * 1.1 + 8.0:
						clear = false
			if clear:
				break
	island_center = islands[0]["center"]
	island_radius = islands[0]["radius"]

## Elliptical distance from an island's centre (the islands are stretched along x).
func _island_distance(p: Vector2, island: Dictionary) -> float:
	var q: Vector2 = p - island["center"]
	return sqrt(q.x * q.x / (ISLAND_STRETCH * ISLAND_STRETCH) + q.y * q.y)

## Which island's coast `p` is closest to being inside (index into `islands`).
func island_at(p: Vector2) -> int:
	var best := 0
	var best_shore := -INF
	for i in islands.size():
		var shore_i := _island_shore(p, i)
		if shore_i > best_shore:
			best_shore = shore_i
			best = i
	return best

func _island_shore(p: Vector2, index: int) -> float:
	var island: Dictionary = islands[index]
	var q: Vector2 = p - island["center"]
	var dir := q.normalized() if q.length() > 0.001 else Vector2.RIGHT
	var radius: float = float(island["radius"]) * (1.0 + 0.22 * _shore_noise.get_noise_2d(dir.x * 200.0 + index * 53.0, dir.y * 200.0 + index * 97.0))
	return radius - _island_distance(p, island)

static func _axis_half(dir: Vector2) -> float:
	return absf(dir.x) * SIZE.x * 0.5 + absf(dir.y) * SIZE.y * 0.5

func _coast_wobble(perp: float) -> float:
	return 22.0 * _shore_noise.get_noise_2d(perp, 0.0) + 8.0 * _shore_noise.get_noise_2d(perp * 3.0, 100.0)

## Signed distance to the coast: positive on land, negative in the sea.
func _shore_at(p: Vector2) -> float:
	match landscape:
		"coast":
			var perp_dir := Vector2(-sea_dir.y, sea_dir.x)
			return coast_pos + _coast_wobble(p.dot(perp_dir)) - p.dot(sea_dir)
		"island":
			var best := -INF
			for i in islands.size():
				best = maxf(best, _island_shore(p, i))
			return best
	return INF

func _base_height(p: Vector2, shore_dist: float, noise_hills: float, noise_ridge: float) -> float:
	if shore_dist < 0.0:
		return -4.0 * smoothstep(0.0, 60.0, -shore_dist)
	var inland := smoothstep(0.0, 170.0, shore_dist)
	var rise := 30.0 * relief
	if landscape == "island":
		# Rise from the centre outward, not from the (angle-noised) shore, so the
		# interior is a smooth dome rather than radial streaks.
		inland = 0.0
		for island in islands:
			# Smaller islands rise less, so their slopes stay comparable.
			var dome := smoothstep(0.0, 1.0, clampf(1.0 - _island_distance(p, island) / float(island["radius"]), 0.0, 1.0))
			inland = maxf(inland, dome * clampf(float(island["radius"]) / 80.0, 0.5, 1.0))
		rise = 22.0 * relief
	var near := smoothstep(0.0, 40.0, shore_dist)
	inland *= near
	var h := rise * inland + near * (noise_hills * (1.0 + 6.0 * inland) * relief + noise_ridge * rise * 0.25 * inland * inland)
	return maxf(h, 0.02)

func _base_at(p: Vector2) -> float:
	return _base_height(p, _shore_at(p), _hills.get_noise_2d(p.x, p.y), _ridges.get_noise_2d(p.x, p.y) * 0.5 + 0.5)

## Where a ray from `origin` first reaches the sea (for a river mouth / waterfront).
func _shore_point(origin: Vector2, dir: Vector2) -> Vector2:
	var r := 0.0
	while r < 300.0 and _shore_at(origin + dir * r) >= 0.0:
		r += 2.0
	return origin + dir * r

func downstream_t(p: Vector2) -> float:
	var e := flow_end - flow_start
	var length_sq := e.length_squared()
	if length_sq < 1.0:
		return 0.5
	return clampf((p - flow_start).dot(e) / length_sq, 0.0, 1.0)

# -- rivers ------------------------------------------------------------------

func _build_rivers(rng: RandomNumberGenerator, spec: RefCounted) -> void:
	rivers.clear()
	junctions.clear()
	if not spec.main_river:
		return
	if landscape == "river_valley":
		_rivers_valley(rng, spec.tributaries)
	else:
		_rivers_shore(rng, spec.tributaries)
	for id in rivers:
		var river: Dictionary = rivers[id]
		var points: Array = []
		var refs: Dictionary = river["ref_indices"]
		var controls: PackedVector3Array = river["controls"]
		for i in controls.size():
			points.append({"junction": refs[i]} if refs.has(i) else controls[i])
		river["map_points"] = points

func _wavy_controls(rng: RandomNumberGenerator, start: Vector2, end: Vector2, count: int, amplitude: float) -> PackedVector3Array:
	var along := (end - start).normalized()
	var across := Vector2(-along.y, along.x)
	var phase := rng.randf_range(0.0, TAU)
	var cycles := rng.randf_range(0.8, 1.7)
	var controls := PackedVector3Array()
	for i in count:
		var t := float(i) / float(count - 1)
		var offset := amplitude * sin(TAU * t * cycles + phase) * sin(PI * t)
		if i > 0 and i < count - 1:
			offset += rng.randf_range(-4.0, 4.0)
		var p := start.lerp(end, t) + across * offset
		controls.append(Vector3(p.x, 0.0, p.y))
	return controls

func _pick_junction(rng: RandomNumberGenerator, used: Array) -> int:
	for attempt in 12:
		var index := rng.randi_range(3, 6)
		if not used.has(index) and not used.has(index - 1) and not used.has(index + 1):
			used.append(index)
			return index
	var fallback := 3 if not used.has(3) else 6
	used.append(fallback)
	return fallback

func _register_river(id: String, kind: String, controls: PackedVector3Array, width: float, floors: PackedFloat32Array, node_name: String, refs: Dictionary) -> void:
	rivers[id] = {
		"kind": kind, "controls": controls, "width": width, "samples": _sample_xz(controls),
		"floors": floors, "node_name": node_name, "ref_indices": refs, "map_points": [],
	}

static func _sample_xz(controls: PackedVector3Array) -> PackedVector2Array:
	var result := PackedVector2Array()
	for p in Ribbon._sample_catmull_rom(controls, SAMPLE_SPACING):
		result.append(Vector2(p.x, p.z))
	return result

func _descending_floors(samples: PackedVector2Array) -> PackedFloat32Array:
	var floors := PackedFloat32Array()
	var lowest := INF
	for s in samples:
		lowest = minf(lowest, _base_at(s) - 1.0)
		floors.append(lowest)
	return floors

func _rivers_valley(rng: RandomNumberGenerator, tributary_count: int) -> void:
	flow_sign = 1.0 if rng.randf() < 0.5 else -1.0
	var width := rng.randf_range(14.0, 20.0)
	var z0 := rng.randf_range(-35.0, 35.0)
	var amplitude := rng.randf_range(18.0, 42.0)
	var phase := rng.randf_range(0.0, TAU)
	var wavelength := rng.randf_range(190.0, 300.0)
	var controls := PackedVector3Array()
	var count := 11
	for i in count:
		var x := lerpf(-EXTENT, EXTENT, float(i) / float(count - 1))
		var z := z0 + amplitude * sin(TAU * x / wavelength + phase) + rng.randf_range(-6.0, 6.0)
		controls.append(Vector3(x, 0.0, clampf(z, -85.0, 85.0)))
	if flow_sign < 0.0:
		controls.reverse()
	flow_start = Vector2(-EXTENT * flow_sign, 0.0)
	flow_end = Vector2(EXTENT * flow_sign, 0.0)
	source_height = rng.randf_range(20.0, 28.0)
	mouth_height = rng.randf_range(4.0, 7.0)

	var main_samples := _sample_xz(controls)
	var main_floors := PackedFloat32Array()
	for p in main_samples:
		main_floors.append(lerpf(source_height, mouth_height, downstream_t(p)))
	var main_refs := {}
	_register_river("main", "main", controls, width, main_floors, "MainRiver", main_refs)

	var used: Array = []
	var side := 1.0 if rng.randf() < 0.5 else -1.0
	for t in tributary_count:
		var index := _pick_junction(rng, used)
		var join := controls[index]
		var id := "tributary" if t == 0 else "tributary_%d" % (t + 1)
		var junction_id := "confluence" if t == 0 else "confluence_%d" % (t + 1)
		junctions[junction_id] = join
		main_refs[index] = junction_id
		var start := Vector3(join.x + rng.randf_range(-90.0, 60.0), 0.0, side * 170.0)
		var trib := PackedVector3Array([start])
		for j in range(1, 4):
			var along := start.lerp(join, float(j) / 4.0)
			trib.append(Vector3(along.x + rng.randf_range(-22.0, 22.0), 0.0, along.z + rng.randf_range(-10.0, 10.0)))
		trib.append(join)
		var samples := _sample_xz(trib)
		var join_floor := lerpf(source_height, mouth_height, downstream_t(Vector2(join.x, join.z)))
		var head_floor := join_floor + rng.randf_range(12.0, 20.0)
		var floors := PackedFloat32Array()
		for i in samples.size():
			floors.append(lerpf(head_floor, join_floor, float(i) / float(maxi(samples.size() - 1, 1))))
		_register_river(id, "tributary", trib, rng.randf_range(8.0, 11.0), floors, id.capitalize().replace(" ", ""), {trib.size() - 1: junction_id})
		side = -side

func _rivers_shore(rng: RandomNumberGenerator, tributary_count: int) -> void:
	var start := Vector2.ZERO
	var end := Vector2.ZERO
	var width := 8.0
	var amplitude := 10.0
	if landscape == "coast":
		var perp_dir := Vector2(-sea_dir.y, sea_dir.x)
		var perp_half := _axis_half(perp_dir)
		var mouth_perp := rng.randf_range(-0.5, 0.5) * perp_half
		end = perp_dir * mouth_perp + sea_dir * (coast_pos + _coast_wobble(mouth_perp) + 14.0)
		var start_perp := clampf(mouth_perp + rng.randf_range(-0.4, 0.4) * perp_half, -perp_half * 0.7, perp_half * 0.7)
		start = perp_dir * start_perp - sea_dir * (_axis_half(sea_dir) + 30.0)
		width = rng.randf_range(12.0, 18.0)
		amplitude = rng.randf_range(14.0, 30.0)
	else:
		var theta := rng.randf() * TAU
		var dir := Vector2(cos(theta), sin(theta))
		start = island_center + Vector2(rng.randf_range(-10.0, 10.0), rng.randf_range(-8.0, 8.0))
		end = _shore_point(start, dir) + dir * 14.0
		width = rng.randf_range(7.0, 10.0)
		amplitude = rng.randf_range(6.0, 14.0)
	flow_start = start
	flow_end = end
	var controls := _wavy_controls(rng, start, end, 11, amplitude)
	var main_refs := {}
	_register_river("main", "main", controls, width, _descending_floors(_sample_xz(controls)), "MainRiver", main_refs)

	var used: Array = []
	var side := 1.0 if rng.randf() < 0.5 else -1.0
	for t in tributary_count:
		var index := _pick_junction(rng, used)
		var join := controls[index]
		var join_xz := Vector2(join.x, join.z)
		var tangent := (Vector2(controls[index + 1].x, controls[index + 1].z) - Vector2(controls[index - 1].x, controls[index - 1].z)).normalized()
		var across := Vector2(-tangent.y, tangent.x)
		var spring := Vector2.INF
		for attempt in 4:
			var candidate := join_xz + across * side * rng.randf_range(70.0, 120.0) + tangent * rng.randf_range(-40.0, 40.0)
			if _shore_at(candidate) > 15.0 and absf(candidate.x) < SIZE.x * 0.5 - 8.0 and absf(candidate.y) < SIZE.y * 0.5 - 8.0:
				spring = candidate
				break
			side = -side
		if spring == Vector2.INF:
			continue
		var id := "tributary" if t == 0 else "tributary_%d" % (t + 1)
		var junction_id := "confluence" if t == 0 else "confluence_%d" % (t + 1)
		junctions[junction_id] = join
		main_refs[index] = junction_id
		var trib := _wavy_controls(rng, spring, join_xz, 5, 10.0)
		trib[trib.size() - 1] = join
		_register_river(id, "tributary", trib, rng.randf_range(6.0, 8.0), _descending_floors(_sample_xz(trib)), id.capitalize().replace(" ", ""), {trib.size() - 1: junction_id})
		side = -side

# -- heightfield -------------------------------------------------------------

func _river_probe(samples: PackedVector2Array, floors: PackedFloat32Array, p: Vector2) -> void:
	var nearest := INF
	var nearest_index := 0
	for k in samples.size():
		var d2 := p.distance_squared_to(samples[k])
		if d2 < nearest:
			nearest = d2
			nearest_index = k
	_probe_d = sqrt(nearest)
	_probe_floor = floors[nearest_index]

func _build_land() -> void:
	var total := W * H
	land.resize(total)
	bank_dist.resize(total)
	river_bank.resize(total)
	shore.resize(total)
	bed_height.resize(total)
	bank_half.resize(total)
	var river_samples: Array[PackedVector2Array] = []
	var river_floors: Array[PackedFloat32Array] = []
	var river_half := PackedFloat32Array()
	for id in rivers:
		var river: Dictionary = rivers[id]
		river_samples.append(river["samples"])
		river_floors.append(river["floors"])
		river_half.append(float(river["width"]) * 0.5)

	for gz in H:
		for gx in W:
			var p := Vector2(gx * STEP - SIZE.x * 0.5, gz * STEP - SIZE.y * 0.5)
			var noise_hills := _hills.get_noise_2d(p.x, p.y)
			var noise_ridge := _ridges.get_noise_2d(p.x, p.y) * 0.5 + 0.5
			var shore_dist := _shore_at(p)
			var best_land := INF
			var best_bank := INF
			var best_bed := 0.0
			var best_half := 1.0
			for r in river_samples.size():
				_river_probe(river_samples[r], river_floors[r], p)
				var half := river_half[r]
				var floor_h := _probe_floor
				if landscape == "river_valley":
					# Far from the river the nearest sample can flip between
					# distant reaches with different floors, so fade to a smooth floor.
					floor_h = lerpf(floor_h, lerpf(source_height, mouth_height, downstream_t(p)), smoothstep(25.0, 70.0, _probe_d))
					var rise := smoothstep(half + 4.0, half + valley_half, _probe_d)
					var far := smoothstep(12.0, valley_half + 40.0, _probe_d)
					best_land = minf(best_land, floor_h + valley_rise * rise + noise_hills * (1.2 + 5.0 * far) * relief + noise_ridge * valley_rise * 0.18 * far * far)
				if _probe_d - half < best_bank:
					best_bank = _probe_d - half
					best_bed = floor_h - CARVE_DEPTH
					best_half = half
			var i := gz * W + gx
			land[i] = best_land if landscape == "river_valley" else _base_height(p, shore_dist, noise_hills, noise_ridge)
			shore[i] = shore_dist
			river_bank[i] = best_bank
			bank_dist[i] = minf(best_bank, shore_dist)
			bed_height[i] = best_bed
			bank_half[i] = best_half

## Recompute the carved surface from `land` (call after grading pads).
func finalize() -> void:
	heights.resize(land.size())
	for i in land.size():
		var w := 1.0 - smoothstep(-bank_half[i] * 0.5, BANK, river_bank[i])
		heights[i] = lerpf(land[i], bed_height[i], w)

func apply_pad(center: Vector2, radius: float, height: float) -> void:
	## Wide blend so a pad cut into a hillside does not leave a cliff.
	var reach := radius + 22.0
	var x0 := maxi(0, int(floor((center.x - reach + SIZE.x * 0.5) / STEP)))
	var x1 := mini(W - 1, int(ceil((center.x + reach + SIZE.x * 0.5) / STEP)))
	var z0 := maxi(0, int(floor((center.y - reach + SIZE.y * 0.5) / STEP)))
	var z1 := mini(H - 1, int(ceil((center.y + reach + SIZE.y * 0.5) / STEP)))
	for gz in range(z0, z1 + 1):
		for gx in range(x0, x1 + 1):
			var p := Vector2(gx * STEP - SIZE.x * 0.5, gz * STEP - SIZE.y * 0.5)
			var t := 1.0 - smoothstep(radius, reach, p.distance_to(center))
			var i := gz * W + gx
			if shore[i] < 0.0:
				continue
			land[i] = lerpf(land[i], height, t)

## Re-flatten a pad's core after every pad's blend is applied, so a neighbour's
## blend cannot tilt it.
func stamp_pad(center: Vector2, radius: float, height: float) -> void:
	var x0 := maxi(0, int(floor((center.x - radius + SIZE.x * 0.5) / STEP)))
	var x1 := mini(W - 1, int(ceil((center.x + radius + SIZE.x * 0.5) / STEP)))
	var z0 := maxi(0, int(floor((center.y - radius + SIZE.y * 0.5) / STEP)))
	var z1 := mini(H - 1, int(ceil((center.y + radius + SIZE.y * 0.5) / STEP)))
	for gz in range(z0, z1 + 1):
		for gx in range(x0, x1 + 1):
			var p := Vector2(gx * STEP - SIZE.x * 0.5, gz * STEP - SIZE.y * 0.5)
			var i := gz * W + gx
			if shore[i] >= 0.0 and p.distance_to(center) <= radius:
				land[i] = height

# -- queries -----------------------------------------------------------------

func _bilinear(data: PackedFloat32Array, x: float, z: float) -> float:
	var gx := clampf((x + SIZE.x * 0.5) / STEP, 0.0, float(W - 1) - 0.001)
	var gz := clampf((z + SIZE.y * 0.5) / STEP, 0.0, float(H - 1) - 0.001)
	var ix := int(gx)
	var iz := int(gz)
	var fx := gx - ix
	var fz := gz - iz
	var h00 := data[iz * W + ix]
	var h10 := data[iz * W + ix + 1]
	var h01 := data[(iz + 1) * W + ix]
	var h11 := data[(iz + 1) * W + ix + 1]
	return lerpf(lerpf(h00, h10, fx), lerpf(h01, h11, fx), fz)

func get_height(x: float, z: float) -> float:
	return _bilinear(heights, x, z)

func land_height(x: float, z: float) -> float:
	return _bilinear(land, x, z)

func slope_at(x: float, z: float, use_land := false) -> float:
	var data := land if use_land else heights
	var dx := (_bilinear(data, x + STEP, z) - _bilinear(data, x - STEP, z)) / (2.0 * STEP)
	var dz := (_bilinear(data, x, z + STEP) - _bilinear(data, x, z - STEP)) / (2.0 * STEP)
	return sqrt(dx * dx + dz * dz)

## Signed distance to the nearest water (river bank or shore); negative inside.
func bank_at(x: float, z: float) -> float:
	return _bilinear(bank_dist, x, z)

func is_water(x: float, z: float) -> bool:
	return bank_at(x, z) < 0.0

## Signed distance from the coast (positive inland); INF without a sea.
func shore_at(x: float, z: float) -> float:
	return _bilinear(shore, x, z) if has_sea else INF

func is_sea(x: float, z: float) -> bool:
	return has_sea and _bilinear(shore, x, z) < 0.0

## Signed distance from `p` to one river's bank.
func dist_to_river(id: String, p: Vector2) -> float:
	var river: Dictionary = rivers[id]
	var nearest := INF
	for s in river["samples"] as PackedVector2Array:
		nearest = minf(nearest, p.distance_squared_to(s))
	return sqrt(nearest) - float(river["width"]) * 0.5

## Nearest tributary bank (INF when the landscape has none).
func tributary_bank(p: Vector2) -> float:
	var best := INF
	for id in rivers:
		if rivers[id]["kind"] == "tributary":
			best = minf(best, dist_to_river(id, p))
	return best

func nearest_river_point(id: String, p: Vector2) -> Vector2:
	var river: Dictionary = rivers[id]
	var nearest := INF
	var best := p
	for s in river["samples"] as PackedVector2Array:
		var d2 := p.distance_squared_to(s)
		if d2 < nearest:
			nearest = d2
			best = s
	return best

## A waterfront anchor for a harbour at `p`: the nearest sea edge, else the
## main river's centerline.
func waterfront_for(p: Vector2) -> Vector3:
	if has_sea:
		var best := Vector2.INF
		var best_distance := INF
		for k in 24:
			var a := float(k) / 24.0 * TAU
			var hit := _shore_point(p, Vector2(cos(a), sin(a)))
			if p.distance_to(hit) < best_distance:
				best_distance = p.distance_to(hit)
				best = hit
		return Vector3(best.x, 0.0, best.y)
	if rivers.has("main"):
		var bank := nearest_river_point("main", p)
		return Vector3(bank.x, 0.0, bank.y)
	return Vector3(p.x, 0.0, p.y)

## A rough centre of interest (first confluence, island centre, or river middle).
func focus_point() -> Vector2:
	for id in junctions:
		return Vector2(junctions[id].x, junctions[id].z)
	if landscape == "island":
		return island_center
	if rivers.has("main"):
		return (flow_start + flow_end) * 0.5
	return Vector2.ZERO

## Elevation range of dry ground only.
func elevation_range() -> Vector2:
	var low := INF
	var high := -INF
	for h in land:
		if h >= sea_level:
			low = minf(low, h)
			high = maxf(high, h)
	return Vector2(low, high)

func height_range() -> Vector2:
	var low := INF
	var high := -INF
	for h in heights:
		low = minf(low, h)
		high = maxf(high, h)
	return Vector2(low, high)

func sea_fraction() -> float:
	if not has_sea:
		return 0.0
	var count := 0
	for s in shore:
		if s < 0.0:
			count += 1
	return float(count) / float(shore.size())
