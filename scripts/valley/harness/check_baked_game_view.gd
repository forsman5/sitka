extends SceneTree

const ValleySeed = preload("res://scripts/sim/data/valley_seed.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var packed := load("res://scenes/valley/river_valley_baked.tscn") as PackedScene
	var view = packed.instantiate()
	root.add_child(view)
	var frame_count := 0
	while (view.get("_economy") == null or view.get("_baked_world") == null) and frame_count < 3000:
		await process_frame
		frame_count += 1
	var failures := 0
	if view.get("_economy") == null:
		push_error("Baked valley view did not finish loading")
		failures += 1
	else:
		var economy = view.get("_economy")
		if economy.towns.size() != 5:
			push_error("Expected five live settlement economies, got %d" % economy.towns.size())
			failures += 1
		var expected := {
			ValleySeed.ALDFORD: "town",
			ValleySeed.HIGH_FELL: "pasture",
			ValleySeed.OAKMERE: "woodland",
			ValleySeed.IRONBANK: "ore",
			ValleySeed.STAITHE: "port",
		}
		for settlement_id in expected:
			var record: Dictionary = view.map_definition.settlements.get(settlement_id, {})
			if record.get("kind", "") != expected[settlement_id]:
				push_error("Settlement %d mapped to %s instead of %s" % [settlement_id, record.get("kind", "missing"), expected[settlement_id]])
				failures += 1
		if view.get("_baked_world") == null:
			push_error("Baked terrain scene is missing")
			failures += 1
		elif view.get("_baked_world").get_node_or_null("River_main") == null:
			push_error("Baked main river surface is missing")
			failures += 1
		if view.get_node_or_null("ford_road_2_4_main_0FordShallows") == null:
			push_error("The generated road/river crossing has no ford overlay")
			failures += 1
		if view.map_definition.water_routes.size() != 0:
			push_error("The approved bake unexpectedly has water routes")
			failures += 1
		view._select_settlement(ValleySeed.STAITHE)
		if view.get("_selection_title").text != "Staithe":
			push_error("Generated port did not select the live Staithe economy")
			failures += 1
	var menu := (load("res://scenes/ui/main_menu.tscn") as PackedScene).instantiate()
	if menu.get_node_or_null("Panel/VBox/RiverValleyBakedButton") == null or menu.get_node_or_null("Panel/VBox/RiverValleyLegacyButton") == null:
		push_error("Main menu does not expose both baked and original valley views")
		failures += 1
	print("check_baked_game_view: %s (%d frames)" % ["FAILED" if failures > 0 else "OK", frame_count])
	view.queue_free()
	menu.free()
	await process_frame
	quit(1 if failures > 0 else 0)
