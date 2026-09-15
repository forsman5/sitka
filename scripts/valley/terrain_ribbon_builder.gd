class_name TerrainRibbonBuilder
extends RefCounted

## Builds a continuous strip whose center line and edges are sampled against
## the authored terrain. Rivers, roads, and ford surfaces share this geometry
## so joins do not depend on overlapping, horizontal BoxMesh segments.

const CROSS_SEGMENTS := 4
const CROSS_VERTICES := CROSS_SEGMENTS + 1

static func build(
		node_name: String,
		control_points: PackedVector3Array,
		height_at: Callable,
		width: float,
		y_offset: float,
		material: Material,
		sample_spacing: float = 3.0,
		width_variation: float = 0.0,
		variation_seed: int = 0,
		flat_cross_section: bool = false,
	) -> MeshInstance3D:
	var centers := _sample_catmull_rom(control_points, sample_spacing)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var distance_along := 0.0

	for i in range(centers.size()):
		var center: Vector3 = centers[i]
		if i > 0:
			distance_along += center.distance_to(centers[i - 1])
		var previous: Vector3 = centers[maxi(i - 1, 0)]
		var following: Vector3 = centers[mini(i + 1, centers.size() - 1)]
		var tangent := Vector2(following.x - previous.x, following.z - previous.z).normalized()
		if tangent == Vector2.ZERO:
			tangent = Vector2.RIGHT
		var side := Vector2(-tangent.y, tangent.x)
		var variation := sin(distance_along * 0.17 + float(variation_seed) * 1.731)
		variation += 0.45 * sin(distance_along * 0.071 + float(variation_seed) * 0.913)
		var half_width := maxf(0.1, width * 0.5 + variation * width_variation)
		var section_points: Array[Vector2] = []
		var section_heights: Array[float] = []
		var highest_ground := -INF
		for cross_index in range(CROSS_VERTICES):
			var cross_t := float(cross_index) / float(CROSS_SEGMENTS)
			var point := Vector2(center.x, center.z) + side * lerpf(half_width, -half_width, cross_t)
			var ground_height := float(height_at.call(point))
			section_points.append(point)
			section_heights.append(ground_height)
			highest_ground = maxf(highest_ground, ground_height)
		for cross_index in range(CROSS_VERTICES):
			var point := section_points[cross_index]
			var surface_height := highest_ground if flat_cross_section else section_heights[cross_index]
			vertices.append(Vector3(point.x, surface_height + y_offset, point.y))
			normals.append(Vector3.UP)
			uvs.append(Vector2(float(cross_index) / float(CROSS_SEGMENTS), distance_along / maxf(width, 0.1)))

	for i in range(centers.size() - 1):
		var row := i * CROSS_VERTICES
		var next_row := (i + 1) * CROSS_VERTICES
		for cross_index in range(CROSS_SEGMENTS):
			var index := row + cross_index
			var next_index := next_row + cross_index
			# Godot treats clockwise triangles as front-facing. This order presents
			# the strip upward without requiring two-sided road/water materials.
			indices.append_array([index, index + 1, next_index, index + 1, next_index + 1, next_index])

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = material
	return instance

static func build_disc(node_name: String, center: Vector2, radius: float, height_at: Callable, y_offset: float, material: Material, segments: int = 40) -> MeshInstance3D:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var surface_height := float(height_at.call(center))
	for index in range(segments):
		var angle := TAU * float(index) / float(segments)
		var point := center + Vector2(cos(angle), sin(angle)) * radius
		surface_height = maxf(surface_height, float(height_at.call(point)))
	vertices.append(Vector3(center.x, surface_height + y_offset, center.y))
	normals.append(Vector3.UP)
	uvs.append(Vector2(0.5, 0.5))
	for index in range(segments):
		var angle := TAU * float(index) / float(segments)
		var offset := Vector2(cos(angle), sin(angle))
		vertices.append(Vector3(center.x + offset.x * radius, surface_height + y_offset, center.y + offset.y * radius))
		normals.append(Vector3.UP)
		uvs.append(offset * 0.5 + Vector2(0.5, 0.5))
	var indices := PackedInt32Array()
	for index in range(segments):
		var current := index + 1
		var following := (index + 1) % segments + 1
		indices.append_array([0, following, current])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = material
	return instance

static func _sample_catmull_rom(points: PackedVector3Array, spacing: float) -> PackedVector3Array:
	var result := PackedVector3Array()
	if points.size() < 2:
		return points.duplicate()
	for segment in range(points.size() - 1):
		var p0: Vector3 = points[maxi(segment - 1, 0)]
		var p1: Vector3 = points[segment]
		var p2: Vector3 = points[segment + 1]
		var p3: Vector3 = points[mini(segment + 2, points.size() - 1)]
		var steps := maxi(2, int(ceil(p1.distance_to(p2) / maxf(spacing, 0.25))))
		for step in range(steps):
			var t := float(step) / float(steps)
			var t2 := t * t
			var t3 := t2 * t
			result.append(0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3))
	result.append(points[points.size() - 1])
	return result
