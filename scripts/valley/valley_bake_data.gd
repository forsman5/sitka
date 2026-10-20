class_name ValleyBakeData
extends RefCounted

## Read-only loader and height queries for a saved valley bake. This runtime
## contract deliberately does not parse generator specs or depend on tooling.

## Reads a bake written by the valley generator. Returns {} when required data
## is missing or malformed.
static func load_dir(dir: String) -> Dictionary:
	var meta_text := FileAccess.get_file_as_string("%s/bake.json" % dir)
	if meta_text.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(meta_text)
	if not parsed is Dictionary:
		return {}
	var meta: Dictionary = parsed
	for key in ["scale", "step", "height_scale", "size", "w", "h", "has_sea", "height_max", "stats", "sites", "buildings"]:
		if not meta.has(key):
			return {}
	var width := int(meta["w"])
	var height := int(meta["h"])
	if width < 2 or height < 2:
		return {}
	var heights := FileAccess.get_file_as_bytes("%s/heights.bin" % dir).to_float32_array()
	if heights.size() != width * height:
		return {}
	var trees := FileAccess.get_file_as_bytes("%s/trees.bin" % dir).to_float32_array()
	if trees.size() % 5 != 0:
		return {}
	var color_path := "%s/colors.png" % dir
	var colors: Image
	if dir.begins_with("res://"):
		var texture := ResourceLoader.load(color_path) as Texture2D
		colors = texture.get_image() if texture != null else Image.new()
	else:
		colors = Image.load_from_file(color_path)
	if colors.is_empty() or colors.get_width() != width or colors.get_height() != height:
		return {}
	var map := ResourceLoader.load("%s/map.tres" % dir) as ValleyMapDefinition
	if map == null:
		return {}
	return {
		"scale": float(meta["scale"]), "step": float(meta["step"]), "height_scale": float(meta["height_scale"]),
		"size": Vector2(float(meta["size"][0]), float(meta["size"][1])), "w": width, "h": height,
		"has_sea": bool(meta["has_sea"]), "height_max": float(meta["height_max"]), "stats": meta["stats"],
		"heights": heights, "trees": trees, "colors": colors, "map": map,
		"sites": _sites_from_plain(meta["sites"]), "buildings": _buildings_from_plain(meta["buildings"]),
	}

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
