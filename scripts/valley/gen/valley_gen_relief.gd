extends RefCounted

## Image rendering for generated valleys: shaded relief with water, roads, fords
## and sites, vertex tint for the 3D view, and contact sheets for review.

const Terrain = preload("res://scripts/valley/gen/valley_gen_terrain.gd")
const Generator = preload("res://scripts/valley/gen/valley_generator.gd")

const WATER := Color(0.2, 0.4, 0.68)
const WET_BANK := Color(0.2, 0.3, 0.2)
const ROAD := Color(0.93, 0.87, 0.66)
const SEA := Color(0.1, 0.27, 0.5)
const SAND := Color(0.78, 0.72, 0.5)
const LIGHT := Vector3(-0.55, 0.75, -0.35)

static func _ground_color(t: float) -> Color:
	var stops := [
		Color(0.27, 0.42, 0.2), Color(0.42, 0.5, 0.25), Color(0.5, 0.45, 0.3),
		Color(0.47, 0.44, 0.4), Color(0.88, 0.88, 0.9)]
	var f := clampf(t, 0.0, 1.0) * float(stops.size() - 1)
	var i := mini(int(f), stops.size() - 2)
	return (stops[i] as Color).lerp(stops[i + 1], f - float(i))

## One RGB pixel per height sample: hypsometric tint, water and (optionally)
## roads baked in. This is also the 3D vertex color.
static func tint_grid(result: Dictionary, bake_roads: bool) -> Image:
	var terrain: Terrain = result["terrain"]
	var range_h := terrain.height_range()
	if terrain.has_sea:
		range_h.x = terrain.sea_level
	var image := Image.create(Terrain.W, Terrain.H, false, Image.FORMAT_RGB8)
	for gz in Terrain.H:
		for gx in Terrain.W:
			var i := gz * Terrain.W + gx
			var color := _ground_color((terrain.heights[i] - range_h.x) / maxf(range_h.y - range_h.x, 0.001))
			var bank := terrain.bank_dist[i]
			if terrain.has_sea and terrain.shore[i] < 0.0:
				color = WATER.lerp(SEA, clampf(-terrain.heights[i] / 4.0, 0.0, 1.0))
			elif bank < -0.5:
				color = WATER.lerp(WATER.darkened(0.25), clampf(-bank / 8.0, 0.0, 1.0))
			elif terrain.has_sea and terrain.shore[i] < 4.0:
				color = color.lerp(SAND, 0.75)
			elif bank < 3.0:
				color = color.lerp(WET_BANK, 0.6)
			image.set_pixel(gx, gz, color)
	if bake_roads:
		var map: ValleyMapDefinition = result["map"]
		for road_id in map.roads:
			for p in Generator.road_samples(map, road_id, 1.5):
				var gx := roundi((p.x + Terrain.SIZE.x * 0.5) / Terrain.STEP)
				var gz := roundi((p.y + Terrain.SIZE.y * 0.5) / Terrain.STEP)
				if gx >= 0 and gx < Terrain.W and gz >= 0 and gz < Terrain.H and terrain.bank_dist[gz * Terrain.W + gx] >= -0.5:
					image.set_pixel(gx, gz, ROAD.darkened(0.15))
	return image

static func _shade(terrain: Terrain, gx: int, gz: int) -> float:
	var x0 := maxi(gx - 1, 0)
	var x1 := mini(gx + 1, Terrain.W - 1)
	var z0 := maxi(gz - 1, 0)
	var z1 := mini(gz + 1, Terrain.H - 1)
	var dx := (terrain.heights[gz * Terrain.W + x1] - terrain.heights[gz * Terrain.W + x0]) / (float(x1 - x0) * Terrain.STEP)
	var dz := (terrain.heights[z1 * Terrain.W + gx] - terrain.heights[z0 * Terrain.W + gx]) / (float(z1 - z0) * Terrain.STEP)
	var normal := Vector3(-dx, 1.0, -dz).normalized()
	return clampf(0.45 + 1.3 * normal.dot(LIGHT.normalized()), 0.35, 1.25)

## World position (xz) to pixel in an image made at `scale` pixels per sample.
static func to_pixel(p: Vector2, scale: int) -> Vector2:
	return Vector2((p.x + Terrain.SIZE.x * 0.5) / Terrain.STEP + 0.5, (p.y + Terrain.SIZE.y * 0.5) / Terrain.STEP + 0.5) * float(scale)

static func relief_image(result: Dictionary, scale: int = 4, overlays := true) -> Image:
	var terrain: Terrain = result["terrain"]
	var tint := tint_grid(result, false)
	for gz in Terrain.H:
		for gx in Terrain.W:
			var c := tint.get_pixel(gx, gz)
			if terrain.bank_dist[gz * Terrain.W + gx] >= -0.5:
				var s := _shade(terrain, gx, gz)
				c = Color(c.r * s, c.g * s, c.b * s)
			tint.set_pixel(gx, gz, c)
	tint.resize(Terrain.W * scale, Terrain.H * scale, Image.INTERPOLATE_BILINEAR)
	if not overlays:
		return tint
	var map: ValleyMapDefinition = result["map"]
	var dot := maxi(scale / 2, 1)
	for p in result["trees"] as PackedVector2Array:
		_dot(tint, to_pixel(p, scale), maxi(scale / 4, 1), Color(0.08, 0.25, 0.1))
	for road_id in map.roads:
		for p in Generator.road_samples(map, road_id, 1.0):
			_dot(tint, to_pixel(p, scale), dot, ROAD)
	var step := 0
	for route_id in map.water_routes:
		for p in Generator.water_route_samples(map, route_id, 1.0):
			step += 1
			if (step / 5) % 2 == 0:
				_dot(tint, to_pixel(p, scale), dot, Color(0.95, 0.97, 1.0))
	for id in map.crossings:
		var pos: Vector3 = map.crossings[id]["position"]
		_square(tint, to_pixel(Vector2(pos.x, pos.z), scale), scale, Color(1, 1, 1))
	for site in result["sites"] as Array[Dictionary]:
		var center := to_pixel(site["pos"], scale)
		_ring(tint, center, float(site["pad"]) / Terrain.STEP * float(scale), Color(1, 1, 1, 0.5))
		var half := scale * (3 if site["role"] in ["town", "port"] else 2)
		_square(tint, center, half + 1, Color.BLACK)
		_square(tint, center, half, site["accent"])
	return tint

static func thumbnail(result: Dictionary, scale: int = 2) -> Image:
	var image := relief_image(result, scale)
	var ok: bool = result["report"]["ok"]
	var bar := Color(0.2, 0.7, 0.3) if ok else Color(0.8, 0.2, 0.2)
	for x in image.get_width():
		for y in 4:
			image.set_pixel(x, y, bar)
	return image

static func contact_sheet(thumbs: Array[Image], columns: int) -> Image:
	if thumbs.is_empty():
		return Image.create(1, 1, false, Image.FORMAT_RGB8)
	var cell := thumbs[0].get_size()
	var rows := ceili(float(thumbs.size()) / float(columns))
	var gap := 6
	var sheet := Image.create(columns * (cell.x + gap) + gap, rows * (cell.y + gap) + gap, false, Image.FORMAT_RGB8)
	sheet.fill(Color(0.1, 0.1, 0.12))
	for i in thumbs.size():
		sheet.blit_rect(thumbs[i], Rect2i(Vector2i.ZERO, cell), Vector2i(gap + (i % columns) * (cell.x + gap), gap + (i / columns) * (cell.y + gap)))
	return sheet

static func _dot(image: Image, center: Vector2, radius: int, color: Color) -> void:
	_square(image, center, radius, color)

static func _square(image: Image, center: Vector2, half: int, color: Color) -> void:
	var cx := roundi(center.x)
	var cy := roundi(center.y)
	for y in range(maxi(cy - half, 0), mini(cy + half + 1, image.get_height())):
		for x in range(maxi(cx - half, 0), mini(cx + half + 1, image.get_width())):
			image.set_pixel(x, y, color)

static func _ring(image: Image, center: Vector2, radius: float, color: Color) -> void:
	var steps := int(radius * 3.0)
	for k in steps:
		var a := float(k) / float(steps) * TAU
		var x := roundi(center.x + cos(a) * radius)
		var y := roundi(center.y + sin(a) * radius)
		if x >= 0 and y >= 0 and x < image.get_width() and y < image.get_height():
			image.set_pixel(x, y, image.get_pixel(x, y).lerp(Color(color.r, color.g, color.b), color.a))
