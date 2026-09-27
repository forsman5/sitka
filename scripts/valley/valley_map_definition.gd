class_name ValleyMapDefinition
extends Resource

const Ribbon = preload("res://scripts/valley/terrain_ribbon_builder.gd")

## Shared authored geography. References resolve on demand, not into cached
## coordinates, so roads and woodland follow edits to settlement sites.
@export var settlements: Dictionary = {}
@export var rivers: Dictionary = {}
@export var roads: Dictionary = {}
@export var crossings: Dictionary = {}
@export var junctions: Dictionary = {}
@export var vegetation: Dictionary = {}

func resolve_point(point: Variant) -> Vector3:
	if point is Vector3:
		return point
	var origin := Vector3.ZERO
	if point.has("settlement"):
		origin = settlements[point["settlement"]]["site"]
	elif point.has("waterfront"):
		origin = resolve_point(settlements[point["waterfront"]]["waterfront"])
	elif point.has("crossing"):
		origin = crossings[point["crossing"]]["position"]
	elif point.has("junction"):
		origin = junctions[point["junction"]]["position"]
	return origin + point.get("offset", Vector3.ZERO)

func resolve_path(points: Array) -> PackedVector3Array:
	var result := PackedVector3Array()
	for point in points:
		result.append(resolve_point(point))
	return result

func road_path(id: String) -> PackedVector3Array:
	return resolve_path(roads[id]["points"])

func river_path(id: String) -> PackedVector3Array:
	return resolve_path(rivers[id]["points"])

func validate() -> PackedStringArray:
	var errors := PackedStringArray()
	for id in settlements:
		if not settlements[id].get("site") is Vector3:
			errors.append("Settlement %s needs a site" % id)
		if settlements[id].has("waterfront"):
			var anchor: Variant = settlements[id]["waterfront"]
			if anchor is Dictionary and (anchor.has("waterfront") or anchor.has("settlement")):
				errors.append("Waterfront %s must be a fixed point or junction, not a settlement reference" % id)
			else:
				_validate_point(anchor, "Waterfront %s" % id, errors)
	for id in junctions:
		var junction: Dictionary = junctions[id]
		if not junction.get("position") is Vector3 or junction.get("inner_radius", -1.0) < 0.0 or junction.get("outer_radius", 0.0) <= junction.get("inner_radius", 0.0):
			errors.append("Junction %s needs a position and increasing blend radii" % id)
	for collection in [rivers, roads]:
		for id in collection:
			var spec: Dictionary = collection[id]
			if spec.get("width", 0.0) <= 0.0:
				errors.append("%s needs a positive width" % id)
			if spec.get("points", []).size() < 2:
				errors.append("%s needs at least two points" % id)
			for point in spec.get("points", []):
				_validate_point(point, str(id), errors)
	for id in crossings:
		var spec: Dictionary = crossings[id]
		if not roads.has(spec.get("road", "")) or not rivers.has(spec.get("river", "")):
			errors.append("%s references a missing road or river" % id)
		if spec.get("kind", "") != "ford":
			errors.append("%s has an unsupported crossing kind" % id)
		if not spec.get("position") is Vector3 or spec.get("radius", 0.0) <= 0.0 or spec.get("width", 0.0) <= 0.0:
			errors.append("%s needs a position, search radius, and positive width" % id)
	for id in vegetation:
		_validate_point(vegetation[id]["center"], str(id), errors)
	return errors

## Authoring check: every road/water intersection must belong to an explicit
## crossing, and every crossing must span two banks near its anchor.
func validate_geometry() -> PackedStringArray:
	var errors := validate()
	if not errors.is_empty():
		return errors
	var counts: Dictionary = {}
	for id in crossings:
		counts[id] = 0
	for river_id in rivers:
		var outline := Ribbon.footprint(river_path(river_id), rivers[river_id]["width"])
		for settlement_id in settlements:
			var site: Vector3 = settlements[settlement_id]["site"]
			if Geometry2D.is_point_in_polygon(Vector2(site.x, site.z), outline):
				errors.append("Settlement %s is inside river %s" % [settlement_id, river_id])
		for road_id in roads:
			var samples := Ribbon._sample_catmull_rom(road_path(road_id), 0.6)
			var last_hit := Vector2.INF
			for segment in range(samples.size() - 1):
				var a := Vector2(samples[segment].x, samples[segment].z)
				var b := Vector2(samples[segment + 1].x, samples[segment + 1].z)
				for i in outline.size():
					var hit: Variant = Geometry2D.segment_intersects_segment(a, b, outline[i], outline[(i + 1) % outline.size()])
					if hit == null or hit.distance_to(last_hit) < 0.01:
						continue
					last_hit = hit
					var owners: Array = []
					for id in crossings:
						var crossing: Dictionary = crossings[id]
						var position: Vector3 = crossing["position"]
						if crossing["river"] == river_id and crossing["road"] == road_id and hit.distance_to(Vector2(position.x, position.z)) <= crossing["radius"]:
							owners.append(id)
					if owners.size() != 1:
						errors.append("Road %s crosses %s without exactly one crossing at %s" % [road_id, river_id, hit])
					else:
						counts[owners[0]] += 1
	for id in counts:
		if counts[id] != 2:
			errors.append("Crossing %s has %d banks; expected two" % [id, counts[id]])
	return errors

func _validate_point(point: Variant, owner: String, errors: PackedStringArray) -> void:
	if point is Vector3:
		return
	if not point is Dictionary:
		errors.append("%s has an invalid point" % owner)
		return
	var references := 0
	for pair in [["settlement", settlements], ["waterfront", settlements], ["crossing", crossings], ["junction", junctions]]:
		if point.has(pair[0]):
			references += 1
			if not pair[1].has(point[pair[0]]):
				errors.append("%s references missing %s %s" % [owner, pair[0], point[pair[0]]])
			elif pair[0] == "waterfront" and not settlements[point[pair[0]]].has("waterfront"):
				errors.append("%s references a settlement without a waterfront" % owner)
	if references != 1:
		errors.append("%s point must reference exactly one anchor" % owner)
