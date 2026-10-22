class_name ValleyBakeData
extends RefCounted

## Read-only loader and height queries for a saved valley bake. This runtime
## contract deliberately does not parse generator specs or depend on tooling.

static var last_load_error := ""

## Reads a bake written by the valley generator. Returns {} when required data
## is missing or malformed, with the reason available for the UI and export check.
static func load_dir(dir: String) -> Dictionary:
	last_load_error = ""
	var meta_text := FileAccess.get_file_as_string("%s/bake.json" % dir)
	if meta_text.is_empty():
		return _load_failure("Could not read %s/bake.json" % dir)
	var parsed: Variant = JSON.parse_string(meta_text)
	if not parsed is Dictionary:
		return _load_failure("%s/bake.json is not a JSON object" % dir)
	var meta: Dictionary = parsed
	for key in ["scale", "step", "height_scale", "size", "w", "h", "has_sea", "height_max", "stats", "sites", "buildings"]:
		if not meta.has(key):
			return _load_failure("%s/bake.json is missing '%s'" % [dir, key])
	var width := int(meta["w"])
	var height := int(meta["h"])
	if width < 2 or height < 2:
		return _load_failure("%s/bake.json has invalid dimensions %dx%d" % [dir, width, height])
	var heights_bytes := FileAccess.get_file_as_bytes("%s/heights.bin" % dir)
	if heights_bytes.is_empty():
		return _load_failure("Could not read %s/heights.bin" % dir)
	var heights := heights_bytes.to_float32_array()
	if heights.size() != width * height:
		return _load_failure("%s/heights.bin has %d values; expected %d" % [dir, heights.size(), width * height])
	var trees_bytes := FileAccess.get_file_as_bytes("%s/trees.bin" % dir)
	if trees_bytes.is_empty():
		return _load_failure("Could not read %s/trees.bin" % dir)
	var trees := trees_bytes.to_float32_array()
	if trees.size() % 5 != 0:
		return _load_failure("%s/trees.bin has an invalid record length" % dir)
	var color_path := "%s/colors.png" % dir
	var colors: Image
	if dir.begins_with("res://"):
		var texture := ResourceLoader.load(color_path) as Texture2D
		colors = texture.get_image() if texture != null else Image.new()
	else:
		colors = Image.load_from_file(color_path)
	if colors.is_empty() or colors.get_width() != width or colors.get_height() != height:
		return _load_failure("Could not load %s/colors.png at %dx%d" % [dir, width, height])
	var map := ResourceLoader.load("%s/map.tres" % dir) as ValleyMapDefinition
	if map == null:
		return _load_failure("Could not load %s/map.tres as ValleyMapDefinition" % dir)
	return {
		"scale": float(meta["scale"]), "step": float(meta["step"]), "height_scale": float(meta["height_scale"]),
		"size": Vector2(float(meta["size"][0]), float(meta["size"][1])), "w": width, "h": height,
		"has_sea": bool(meta["has_sea"]), "height_max": float(meta["height_max"]), "stats": meta["stats"],
		"heights": heights, "trees": trees, "colors": colors, "map": map,
		"sites": _sites_from_plain(meta["sites"]), "buildings": _buildings_from_plain(meta["buildings"]),
	}

static func _load_failure(reason: String) -> Dictionary:
	last_load_error = reason
	push_error("Valley bake load failed: %s" % reason)
	return {}

static func _sites_from_plain(plain: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for site in plain:
		result.append({"id": int(site["id"]), "role": site["role"], "name": site["name"], "pos": Vector2(site["pos"][0], site["pos"][1]), "pad": float(site["pad"]), "height": float(site["height"]), "accent": Color(site["accent"])})
	return result

static func _buildings_from_plain(plain: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for building in plain:
		result.append({"site": int(building["site"]), "model": building["model"], "pos": Vector2(building["pos"][0], building["pos"][1]), "yaw": float(building["yaw"]), "width": float(building["width"])})
	return result

## Bilinear terrain height query in bake-local world coordinates.
static func height_at(bake: Dictionary, p: Vector2) -> float:
	var step: float = bake["step"]
	var size: Vector2 = bake["size"]
	var w: int = bake["w"]
	var h: int = bake["h"]
	var heights: PackedFloat32Array = bake["heights"]
	var gx := clampf((p.x + size.x * 0.5) / step, 0.0, float(w - 1) - 0.001)
	var gz := clampf((p.y + size.y * 0.5) / step, 0.0, float(h - 1) - 0.001)
	var ix := int(gx)
	var iz := int(gz)
	var fx := gx - ix
	var fz := gz - iz
	return lerpf(lerpf(heights[iz * w + ix], heights[iz * w + ix + 1], fx), lerpf(heights[(iz + 1) * w + ix], heights[(iz + 1) * w + ix + 1], fx), fz)
