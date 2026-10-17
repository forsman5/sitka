extends RefCounted

## Builds the near-final 3D scene for a bake (or a bake loaded from disk): terrain
## chunks with ground colours, water, roads, the game's own tree and building
## models, and settlement labels. Time-sliced like the bake itself.

const Bake = preload("res://scripts/valley/gen/valley_gen_bake.gd")
const Generator = preload("res://scripts/valley/gen/valley_generator.gd")
const Ribbon = preload("res://scripts/valley/terrain_ribbon_builder.gd")

const CHUNK_CELLS := 80
const TREE_MODELS := ["res://assets/models/nature/tree_single_A.gltf", "res://assets/models/nature/tree_single_B.gltf"]
const SLICE_MS := 12

var cancelled := false
var _tree: SceneTree
var _progress := Callable()
var _slice_start := 0

## Coroutine. Returns the scene root, or null when cancelled. Progress runs from
## `from_fraction` to 1.
func build(bake: Dictionary, tree: SceneTree, progress: Callable, from_fraction := 0.78) -> Node3D:
	_tree = tree
	_progress = progress
	_slice_start = Time.get_ticks_msec()
	var root := Node3D.new()
	root.name = "BakedValley"
	var w: int = bake["w"]
	var h: int = bake["h"]
	var step: float = bake["step"]
	var size: Vector2 = bake["size"]
	var heights: PackedFloat32Array = bake["heights"]
	var colors: Image = bake["colors"]
	var height_at := func(p: Vector2) -> float: return Bake.height_at(bake, p)

	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.vertex_color_is_srgb = true
	material.roughness = 1.0
	material.cull_mode = BaseMaterial3D.CULL_DISABLED

	# Terrain in chunks (culling, and small vertex counts per mesh).
	var chunks_x := ceili(float(w - 1) / float(CHUNK_CELLS))
	var chunks_z := ceili(float(h - 1) / float(CHUNK_CELLS))
	for cz in chunks_z:
		for cx in chunks_x:
			var i0 := cx * CHUNK_CELLS
			var j0 := cz * CHUNK_CELLS
			var i1 := mini(i0 + CHUNK_CELLS, w - 1)
			var j1 := mini(j0 + CHUNK_CELLS, h - 1)
			var instance := _terrain_chunk(heights, colors, w, h, step, size, i0, j0, i1, j1)
			instance.material_override = material
			# The terrain shadowing itself is mostly acne at this scale; trees and
			# buildings still cast onto it.
			instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			instance.name = "Terrain_%d_%d" % [cx, cz]
			root.add_child(instance)
			await _tick(lerpf(from_fraction, 0.9, float(cz * chunks_x + cx + 1) / float(chunks_x * chunks_z)), "Meshing terrain")
			if cancelled:
				return null

	if bake["has_sea"]:
		var sea := MeshInstance3D.new()
		var plane := PlaneMesh.new()
		plane.size = size * 1.6
		sea.mesh = plane
		var sea_material := StandardMaterial3D.new()
		sea_material.albedo_color = Color(0.16, 0.38, 0.62, 0.78)
		sea_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		sea_material.roughness = 0.12
		sea_material.metallic = 0.1
		sea.material_override = sea_material
		sea.name = "Sea"
		sea.position.y = 0.0
		root.add_child(sea)

	await _tick(0.9, "Laying rivers and roads", true)
	var map: ValleyMapDefinition = bake["map"]
	var water_material := StandardMaterial3D.new()
	water_material.albedo_color = Color(0.2, 0.44, 0.7, 0.82)
	water_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	water_material.roughness = 0.1
	water_material.metallic = 0.1
	water_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	for id in map.rivers:
		var river: Dictionary = map.rivers[id]
		var ribbon := Ribbon.build("River_%s" % id, map.river_path(id), height_at, river["width"], -0.9, water_material, 6.0, 0.0, 0, true)
		root.add_child(ribbon)
	var road_material := StandardMaterial3D.new()
	road_material.albedo_color = Color(0.58, 0.49, 0.34)
	road_material.roughness = 1.0
	road_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	for id in map.roads:
		var road: Dictionary = map.roads[id]
		root.add_child(Ribbon.build("Road_%s" % id, map.road_path(id), height_at, road["width"], 0.18, road_material, 3.0, 0.25, int(hash(id)) % 1000))
	_add_route_dashes(root, map)

	await _tick(0.93, "Planting trees", true)
	_add_trees(root, bake)

	await _tick(0.96, "Placing buildings", true)
	_add_buildings(root, bake, height_at)
	_add_labels(root, bake)
	await _tick(1.0, "Done", true)
	return root

func cancel() -> void:
	cancelled = true

func _tick(fraction: float, text: String, force := false) -> void:
	if force or Time.get_ticks_msec() - _slice_start >= SLICE_MS:
		if _progress.is_valid():
			_progress.call(fraction, text)
		await _tree.process_frame
		_slice_start = Time.get_ticks_msec()

func _terrain_chunk(heights: PackedFloat32Array, colors: Image, w: int, h: int, step: float, size: Vector2, i0: int, j0: int, i1: int, j1: int) -> MeshInstance3D:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var vertex_colors := PackedColorArray()
	var indices := PackedInt32Array()
	var columns := i1 - i0 + 1
	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			var idx := j * w + i
			vertices.append(Vector3(i * step - size.x * 0.5, heights[idx], j * step - size.y * 0.5))
			# Normals come from the whole field so chunk seams stay invisible.
			var dx := heights[j * w + mini(i + 1, w - 1)] - heights[j * w + maxi(i - 1, 0)]
			var dz := heights[mini(j + 1, h - 1) * w + i] - heights[maxi(j - 1, 0) * w + i]
			normals.append(Vector3(-dx, 2.0 * step, -dz).normalized())
			vertex_colors.append(colors.get_pixel(i, j))
	for j in range(j1 - j0):
		for i in range(columns - 1):
			var a := j * columns + i
			indices.append_array([a, a + columns, a + 1, a + 1, a + columns, a + columns + 1])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = vertex_colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	return instance

func _add_route_dashes(root: Node3D, map: ValleyMapDefinition) -> void:
	var dashes: Array[Vector2] = []
	for id in map.water_routes:
		var step_count := 0
		for p in Generator.water_route_samples(map, id, 3.0):
			step_count += 1
			if (step_count / 3) % 2 == 0:
				dashes.append(p)
	if dashes.is_empty():
		return
	var disc := CylinderMesh.new()
	disc.top_radius = 2.0
	disc.bottom_radius = 2.0
	disc.height = 0.3
	var disc_material := StandardMaterial3D.new()
	disc_material.albedo_color = Color(1, 1, 1)
	disc_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	disc.material = disc_material
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.mesh = disc
	multi.instance_count = dashes.size()
	for i in dashes.size():
		multi.set_instance_transform(i, Transform3D(Basis.IDENTITY, Vector3(dashes[i].x, 0.5, dashes[i].y)))
	var instance := MultiMeshInstance3D.new()
	instance.name = "SeaRoutes"
	instance.multimesh = multi
	root.add_child(instance)

## Uses the game's own tree models: one MultiMesh per chunk, kind and mesh part.
func _add_trees(root: Node3D, bake: Dictionary) -> void:
	var trees: PackedFloat32Array = bake["trees"]
	var size: Vector2 = bake["size"]
	var chunk_world: float = CHUNK_CELLS * float(bake["step"])
	var parts: Array = []
	for path in TREE_MODELS:
		parts.append(_mesh_parts(path))
	var buckets := {}
	for i in range(0, trees.size(), 5):
		var key := Vector3i(floori((trees[i] + size.x * 0.5) / chunk_world), floori((trees[i + 1] + size.y * 0.5) / chunk_world), int(trees[i + 4]))
		var members: PackedInt32Array = buckets.get(key, PackedInt32Array())
		members.append(i)
		buckets[key] = members
	for key in buckets:
		var indices: PackedInt32Array = buckets[key]
		for part in parts[key.z]:
			var multi := MultiMesh.new()
			multi.transform_format = MultiMesh.TRANSFORM_3D
			multi.mesh = part["mesh"]
			multi.instance_count = indices.size()
			for n in indices.size():
				var i := indices[n]
				var ground := Bake.height_at(bake, Vector2(trees[i], trees[i + 1]))
				var basis := Basis(Vector3.UP, trees[i + 2]).scaled(Vector3.ONE * trees[i + 3])
				multi.set_instance_transform(n, Transform3D(basis, Vector3(trees[i], ground, trees[i + 1])) * (part["transform"] as Transform3D))
			var instance := MultiMeshInstance3D.new()
			instance.name = "Trees_%d_%d_%d" % [key.x, key.y, key.z]
			instance.multimesh = multi
			root.add_child(instance)

func _add_buildings(root: Node3D, bake: Dictionary, height_at: Callable) -> void:
	var cache := {}
	for building in bake["buildings"] as Array[Dictionary]:
		var path: String = building["model"]
		if not cache.has(path):
			cache[path] = load(path) as PackedScene
		var model := (cache[path] as PackedScene).instantiate() as Node3D
		root.add_child(model)
		model.rotation.y = deg_to_rad(float(building["yaw"]))
		var bounds := _bounds(model)
		var scale_factor: float = float(building["width"]) / maxf(maxf(bounds.size.x, bounds.size.z), 0.001)
		model.scale = Vector3.ONE * scale_factor
		bounds = _bounds(model)
		var pos: Vector2 = building["pos"]
		var high := -INF
		for x in [-bounds.size.x * 0.5, bounds.size.x * 0.5]:
			for z in [-bounds.size.z * 0.5, bounds.size.z * 0.5]:
				high = maxf(high, float(height_at.call(pos + Vector2(x, z))))
		model.position = Vector3(pos.x - bounds.get_center().x, high - bounds.position.y, pos.y - bounds.get_center().z)

func _add_labels(root: Node3D, bake: Dictionary) -> void:
	for site in bake["sites"] as Array[Dictionary]:
		var label := Label3D.new()
		label.text = "%s (%s)" % [site["name"], site["role"]]
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.pixel_size = 0.3
		label.font_size = 40
		label.outline_size = 12
		var pos: Vector2 = site["pos"]
		label.position = Vector3(pos.x, float(site["height"]) + 38.0, pos.y)
		root.add_child(label)

## Each mesh in a model with its transform relative to the model root.
static func _mesh_parts(path: String) -> Array:
	var parts: Array = []
	var model := (load(path) as PackedScene).instantiate() as Node3D
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		var xf := Transform3D()
		var n: Node = mi
		while n != model and n != null:
			xf = (n as Node3D).transform * xf
			n = n.get_parent()
		parts.append({"mesh": mi.mesh, "transform": xf})
	model.free()
	return parts

static func _bounds(model: Node3D) -> AABB:
	var merged := AABB()
	var first := true
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		var xf := Transform3D()
		var n: Node = mi
		while n != model and n != null:
			xf = (n as Node3D).transform * xf
			n = n.get_parent()
		var box := xf * mi.get_aabb()
		merged = box if first else merged.merge(box)
		first = false
	return model.transform * merged
