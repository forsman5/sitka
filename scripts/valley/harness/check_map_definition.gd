extends SceneTree

const Layout = preload("res://scripts/valley/river_valley_layout.gd")
const Simulation = preload("res://scripts/sim/simulation.gd")
const Valley = preload("res://scenes/valley/river_valley.tscn")
var failures: Array[String] = []

func _init() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

func _run() -> void:
	var map := Layout.create_map()
	check(map.validate_geometry().is_empty(), "Default geography: %s" % map.validate_geometry())
	var simulation := Simulation.new(12345)
	var ironbank_road := map.road_path("aldford_approach")
	check(ironbank_road[0] == map.settlements[1]["site"], "Ford road does not start at Aldford")
	check(ironbank_road[-1] == map.settlements[4]["site"], "Ford road does not reach Ironbank")
	var moved_ironbank := Layout.create_map()
	moved_ironbank.settlements[4]["site"] += Vector3(3, 0, 2)
	check(moved_ironbank.road_path("aldford_approach")[-1] == moved_ironbank.settlements[4]["site"], "Ford road did not follow Ironbank")
	check(moved_ironbank.road_path("aldford_approach")[-2] == moved_ironbank.settlements[4]["site"] + Vector3(-19, 0, 12), "Ironbank approach did not follow its site")
	for id in map.roads:
		var edge_id: int = map.roads[id]["simulation_edge"]
		if edge_id == 0:
			continue
		var edge := simulation.get_transport_edge_summary(edge_id)
		var path := map.road_path(id)
		check(path[0] == map.settlements[edge["settlement_a_id"]]["site"], "%s start disagrees with simulation" % id)
		check(path[-1] == map.settlements[edge["settlement_b_id"]]["site"], "%s end disagrees with simulation" % id)
	var previous_center := map.resolve_point(map.vegetation["oakmere_woodland"]["center"])
	var move := Vector3(-5, 0, 4)
	map.settlements[3]["site"] += move
	check(map.resolve_point(map.vegetation["oakmere_woodland"]["center"]) == previous_center + move, "Woodland did not follow moved Oakmere")
	check(map.road_path("oakmere_aldford")[0] == map.settlements[3]["site"], "Aldford road did not follow Oakmere")
	check(map.road_path("oakmere_ironbank")[0] == map.settlements[3]["site"], "Ironbank road did not follow Oakmere")
	check(map.validate_geometry().is_empty(), "Moved Oakmere broke geometry: %s" % map.validate_geometry())
	var view := Valley.instantiate()
	view.map_definition = map
	root.add_child(view)
	await process_frame
	await process_frame
	var site: Vector3 = map.settlements[3]["site"]
	check(view.settlement_cluster_positions[3] == Vector2(site.x, site.z), "Rendered village did not follow site")
	for crossing in map.crossings.values():
		check(view.has_node(crossing["name"] + "FordShallows"), "Missing ford " + crossing["name"])
	var half := preload("res://scripts/valley/authored_valley_terrain.gd").WORLD_SIZE * 0.5
	for river in map.rivers.values():
		for suffix in ["", "Bank"]:
			var node_name: String = river["node_name"] + suffix
			var ribbon: MeshInstance3D = view.get_node(node_name)
			check(ribbon.mesh.get_surface_count() > 0, node_name + " has no geometry")
			for vertex in ribbon.mesh.get_faces():
				check(absf(vertex.x) <= half.x + 0.001 and absf(vertex.z) <= half.y + 0.001, node_name + " extends beyond terrain")
	for tree in view.get_node("ValleyVegetation").get_children():
		check(view.is_building_clear(Vector2(tree.position.x, tree.position.z)), "Tree overlaps authored building")
		check(view.is_transport_clear(Vector2(tree.position.x, tree.position.z)), "Tree overlaps transport corridor")
	for building in map.settlements[1]["buildings"]:
		check(view.has_node(building["name"]), "Missing authored building " + building["name"])
	view.free()
	var broken := Layout.create_map()
	broken.crossings["oakmere"]["river"] = "missing"
	check(not broken.validate().is_empty(), "Missing river reference was accepted")
	broken = Layout.create_map()
	broken.crossings.erase("upstream")
	# Remove its anchor reference too, leaving an undeclared physical crossing.
	broken.roads["oakmere_ironbank"]["points"][7] = Vector3(-9, 0, -74)
	check(not broken.validate_geometry().is_empty(), "Undeclared crossing was accepted")
	if failures.is_empty():
		print("PASS: map references, geography, simulation links, moved settlement propagation, ford generation, vegetation clearance, and invalid map rejection")
	else:
		for failure in failures:
			push_error(failure)
	quit(0 if failures.is_empty() else 1)
