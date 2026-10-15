extends RefCounted

## Heightfield and river geometry for one generated valley. Rough sketch: see
## docs/valley-generation-sketch.md. This is also the terrain contract the town
## view and layout would consume: get_height / slope_at / is_water / SIZE.

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

var world_seed := 0
## +1 when the main river flows toward +x, -1 toward -x.
var flow_sign := 1.0
var junction := Vector3.ZERO
var valley_half := 70.0
var valley_rise := 40.0
var source_height := 24.0
var mouth_height := 5.0

## Ground before river carving; pads are graded into this.
var land := PackedFloat32Array()
## Final surface (land with rivers carved).
var heights := PackedFloat32Array()
## Signed distance to the nearest bank: < 0 is water.
var bank_dist := PackedFloat32Array()
var bed_height := PackedFloat32Array()
var bank_half := PackedFloat32Array()

## id -> {controls: PackedVector3Array, map_points: Array, width: float,
##        samples: PackedVector2Array, floors: PackedFloat32Array}
var rivers: Dictionary = {}

func build(rng: RandomNumberGenerator) -> void:
	_build_rivers(rng)
	valley_half = rng.randf_range(70.0, 120.0)
	valley_rise = rng.randf_range(22.0, 38.0)
	_build_land()
	heights = land.duplicate()
	finalize()

func downstream_t(x: float) -> float:
	return clampf((x * flow_sign + EXTENT) / (2.0 * EXTENT), 0.0, 1.0)

func _build_rivers(rng: RandomNumberGenerator) -> void:
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
	var junction_index := rng.randi_range(3, 6)
	junction = controls[junction_index]

	source_height = rng.randf_range(20.0, 28.0)
	mouth_height = rng.randf_range(4.0, 7.0)
	var main_map_points: Array = []
	for i in controls.size():
		main_map_points.append({"junction": "confluence"} if i == junction_index else controls[i])
	var main_samples := _sample_xz(controls)
	var main_floors := PackedFloat32Array()
	for p in main_samples:
		main_floors.append(lerpf(source_height, mouth_height, downstream_t(p.x)))
	rivers["main"] = {"controls": controls, "map_points": main_map_points, "width": width, "samples": main_samples, "floors": main_floors, "node_name": "MainRiver"}

	var side := 1.0 if rng.randf() < 0.5 else -1.0
	var start := Vector3(junction.x + rng.randf_range(-90.0, 60.0), 0.0, side * 170.0)
	var trib := PackedVector3Array([start])
	for j in range(1, 4):
		var t := float(j) / 4.0
		var along := start.lerp(junction, t)
		trib.append(Vector3(along.x + rng.randf_range(-22.0, 22.0), 0.0, along.z + rng.randf_range(-10.0, 10.0)))
	trib.append(junction)
	var trib_map_points: Array = []
	for i in trib.size():
		trib_map_points.append({"junction": "confluence"} if i == trib.size() - 1 else trib[i])
	var trib_samples := _sample_xz(trib)
	var junction_floor := lerpf(source_height, mouth_height, downstream_t(junction.x))
	var head_floor := junction_floor + rng.randf_range(12.0, 20.0)
	var trib_floors := PackedFloat32Array()
	for i in trib_samples.size():
		trib_floors.append(lerpf(head_floor, junction_floor, float(i) / float(maxi(trib_samples.size() - 1, 1))))
	rivers["tributary"] = {"controls": trib, "map_points": trib_map_points, "width": rng.randf_range(8.0, 11.0), "samples": trib_samples, "floors": trib_floors, "node_name": "Tributary"}

static func _sample_xz(controls: PackedVector3Array) -> PackedVector2Array:
	var result := PackedVector2Array()
	for p in Ribbon._sample_catmull_rom(controls, SAMPLE_SPACING):
		result.append(Vector2(p.x, p.z))
	return result

func _build_land() -> void:
	var hills := FastNoiseLite.new()
	hills.seed = world_seed
	hills.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	hills.frequency = 0.011
	hills.fractal_octaves = 4
	var ridges := FastNoiseLite.new()
	ridges.seed = world_seed + 101
	ridges.noise_type = FastNoiseLite.TYPE_SIMPLEX
	ridges.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	ridges.frequency = 0.012
	ridges.fractal_octaves = 3

	var total := W * H
	land.resize(total)
	bank_dist.resize(total)
	bed_height.resize(total)
	bank_half.resize(total)
	var river_samples: Array[PackedVector2Array] = []
	var river_floors: Array[PackedFloat32Array] = []
	var river_half: PackedFloat32Array = PackedFloat32Array()
	for id in rivers:
		var river: Dictionary = rivers[id]
		river_samples.append(river["samples"])
		river_floors.append(river["floors"])
		river_half.append(float(river["width"]) * 0.5)

	for gz in H:
		for gx in W:
			var p := Vector2(gx * STEP - SIZE.x * 0.5, gz * STEP - SIZE.y * 0.5)
			var noise_hills := hills.get_noise_2d(p.x, p.y)
			var noise_ridge := ridges.get_noise_2d(p.x, p.y) * 0.5 + 0.5
			var best_land := INF
			var best_bank := INF
			var best_bed := 0.0
			var best_half := 1.0
			for r in river_samples.size():
				var samples := river_samples[r]
				var nearest := INF
				var nearest_index := 0
				for k in samples.size():
					var d2 := p.distance_squared_to(samples[k])
					if d2 < nearest:
						nearest = d2
						nearest_index = k
				var d := sqrt(nearest)
				var half := river_half[r]
				# Far from the river the nearest sample can flip between distant
				# reaches with different floors, so fade to a smooth floor.
				var floor_h := lerpf(river_floors[r][nearest_index], lerpf(source_height, mouth_height, downstream_t(p.x)), smoothstep(25.0, 70.0, d))
				var rise := smoothstep(half + 4.0, half + valley_half, d)
				var far := smoothstep(12.0, valley_half + 40.0, d)
				var h := floor_h + valley_rise * rise + noise_hills * (1.2 + 5.0 * far) + noise_ridge * valley_rise * 0.18 * far * far
				best_land = minf(best_land, h)
				if d - half < best_bank:
					best_bank = d - half
					best_bed = floor_h - CARVE_DEPTH
					best_half = half
			var i := gz * W + gx
			land[i] = best_land
			bank_dist[i] = best_bank
			bed_height[i] = best_bed
			bank_half[i] = best_half

## Recompute the carved surface from `land` (call after grading pads).
func finalize() -> void:
	heights.resize(land.size())
	for i in land.size():
		var w := 1.0 - smoothstep(-bank_half[i] * 0.5, BANK, bank_dist[i])
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
			land[i] = lerpf(land[i], height, t)

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

## Signed distance to the nearest river bank; negative inside water.
func bank_at(x: float, z: float) -> float:
	return _bilinear(bank_dist, x, z)

func is_water(x: float, z: float) -> bool:
	return bank_at(x, z) < 0.0

## Signed distance from `p` to one river's bank.
func dist_to_river(id: String, p: Vector2) -> float:
	var river: Dictionary = rivers[id]
	var nearest := INF
	for s in river["samples"] as PackedVector2Array:
		nearest = minf(nearest, p.distance_squared_to(s))
	return sqrt(nearest) - float(river["width"]) * 0.5

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

func elevation_range() -> Vector2:
	var low := INF
	var high := -INF
	for h in land:
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
