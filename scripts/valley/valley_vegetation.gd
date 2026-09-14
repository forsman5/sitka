class_name ValleyVegetation
extends Node3D

## Static, deterministic scenery for the authored valley. This deliberately
## differs from the legacy ForestManager: it does not spawn over time, create
## harvestable resource nodes, or inspect the legacy world's building groups.
## Later milestones can replace a region's scenery with economic woodland
## entities while retaining the same seed and visual boundaries.

const TreeA := preload("res://assets/models/nature/tree_single_A.gltf")
const TreeB := preload("res://assets/models/nature/tree_single_B.gltf")
const AuthoredValleyTerrain = preload("res://scripts/valley/authored_valley_terrain.gd")

const TREE_SCENES: Array[PackedScene] = [TreeA, TreeB]

## Oakmere's ellipse radius (46 units) reaches past the heightmap's west edge
## (world half-width 160 at that center's x=-128), so a slice of it used to
## land beyond the terrain mesh -- get_height() clamps out-of-range samples to
## the boundary row/column instead of extrapolating, so those trees floated
## over empty space at a flat height. Keeping every candidate point strictly
## inside the heightmap bounds is more robust than re-tuning each ellipse by
## hand, and covers any region added later too.
const MAP_EDGE_MARGIN := 4.0

## Keeps scenery off a settlement's actual house footprint. Checked against
## settlement_cluster_positions (the parent's post-CLUSTER_OFFSETS positions)
## rather than each ellipse's own authored center, since for Aldford, Oakmere,
## and Staithe those two points differ -- the ellipse is still centered on the
## district's riverside anchor, but the houses were moved off the water.
const SETTLEMENT_CLEARANCE := 8.0

func _ready() -> void:
	# The parent first creates the valley's ground geometry in its _ready().
	call_deferred("_populate")

func _populate() -> void:
	# Oakmere is the dominant visual forest. It has enough density to read at
	# valley scale, while the clear core leaves room for its timber camp.
	_scatter_ellipse("oakmere_woodland", Vector2(-128.0, -78.0), Vector2(46.0, 34.0), 210, 5103, 14.0)
	# Small, irregular riverside groups tie the transport corridor to the
	# landscape without closing off fields or future construction space.
	_scatter_ellipse("aldford_riverbank", Vector2(-15.0, 17.0), Vector2(24.0, 13.0), 26, 5104, 7.0)
	_scatter_ellipse("staithe_riverbank", Vector2(77.0, 79.0), Vector2(27.0, 16.0), 32, 5105, 8.0)
	# High Fell remains visibly open pasture; only a light fringe breaks its
	# silhouette and preserves broad grazing/construction land.
	_scatter_ellipse("high_fell_fringe", Vector2(-118.0, 72.0), Vector2(31.0, 18.0), 16, 5106, 10.0)

func _scatter_ellipse(region: String, center: Vector2, radii: Vector2, count: int, seed: int, center_clearance: float) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var placed := 0
	var attempts := 0
	while placed < count and attempts < count * 20:
		attempts += 1
		var angle := rng.randf_range(0.0, TAU)
		var radial := sqrt(rng.randf())
		var point := center + Vector2(cos(angle) * radii.x * radial, sin(angle) * radii.y * radial)
		if not _within_map_bounds(point):
			continue
		if point.distance_to(center) < center_clearance:
			continue
		if _too_close_to_settlement(point):
			continue
		if _too_close_to_tree(point, 2.7):
			continue
		_add_tree(region, point, rng)
		placed += 1

func _within_map_bounds(point: Vector2) -> bool:
	var half_extent := AuthoredValleyTerrain.WORLD_SIZE * 0.5 - Vector2.ONE * MAP_EDGE_MARGIN
	return absf(point.x) <= half_extent.x and absf(point.y) <= half_extent.y

func _too_close_to_settlement(point: Vector2) -> bool:
	var valley := get_parent()
	if valley == null or not ("settlement_cluster_positions" in valley):
		return false
	for cluster_position in valley.settlement_cluster_positions.values():
		if point.distance_to(cluster_position) < SETTLEMENT_CLEARANCE:
			return true
	return false

func _too_close_to_tree(point: Vector2, minimum_distance: float) -> bool:
	for tree in get_children():
		if tree is Node3D:
			var tree_position: Vector3 = tree.position
			if Vector2(tree_position.x, tree_position.z).distance_to(point) < minimum_distance:
				return true
	return false

func _add_tree(region: String, point: Vector2, rng: RandomNumberGenerator) -> void:
	var tree: Node3D = TREE_SCENES[rng.randi_range(0, TREE_SCENES.size() - 1)].instantiate()
	tree.name = "%s_tree" % region
	tree.position = Vector3(point.x, _ground_height(point), point.y)
	tree.rotation.y = rng.randf_range(0.0, TAU)
	var scale_factor := rng.randf_range(1.45, 2.25)
	tree.scale = Vector3.ONE * scale_factor
	tree.add_to_group("valley_scenery_trees")
	tree.set_meta("valley_region", region)
	add_child(tree)

func _ground_height(point: Vector2) -> float:
	var valley := get_parent()
	if valley != null and valley.has_method("get_valley_ground_height"):
		return float(valley.call("get_valley_ground_height", point))
	return 0.0
