extends SceneTree

## Saves the household Town view as a PNG (needs a real renderer, so run
## without --headless):
##   godot --path . --script res://scripts/sim/harness/capture_town_view.gd -- --output=C:/tmp/town.png [--days=30] [--preset=large_village] [--select=1] [--time=0.75] [--zoom=30] [--villager] [--tilt=45]
## --villager centres on and selects the first housed villager (person window).

func _init() -> void:
	call_deferred("_capture")

func _capture() -> void:
	var output_path := "user://town-view.png"
	var days := 0
	var preset := "small_village"
	var select_id := -1
	var time_of_day := -1.0
	var zoom := -1.0
	var pick_villager := false
	var tilt := -1.0
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--zoom="):
			zoom = argument.trim_prefix("--zoom=").to_float()
		elif argument == "--villager":
			pick_villager = true
		elif argument.begins_with("--tilt="):
			tilt = argument.trim_prefix("--tilt=").to_float()
		if argument.begins_with("--output="):
			output_path = argument.trim_prefix("--output=")
		elif argument.begins_with("--days="):
			days = argument.trim_prefix("--days=").to_int()
		elif argument.begins_with("--preset="):
			preset = argument.trim_prefix("--preset=")
		elif argument.begins_with("--time="):
			time_of_day = argument.trim_prefix("--time=").to_float()
		elif argument.begins_with("--select="):
			select_id = argument.trim_prefix("--select=").to_int()
	var seeds: GDScript = load("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
	var dashboard_script: GDScript = load("res://scripts/sim/household_economy/he_dashboard.gd")
	dashboard_script.pending_builder = Callable(seeds, "build_preset").bind(preset)
	var dashboard: Control = (load("res://scenes/sim/he_dashboard.tscn") as PackedScene).instantiate()
	root.add_child(dashboard)
	dashboard._speed_multiplier = 0.0
	await process_frame
	if days > 0:
		dashboard._simulation.advance_ticks(days)
		dashboard._refresh()
	dashboard._set_town_mode(true)
	if time_of_day >= 0.0:
		dashboard._town_view.set_time_of_day(time_of_day)
	if select_id != -1:
		dashboard._town_view.select_business(select_id)
		# Frame the selected site (handy for pastures).
		var picked: Dictionary = dashboard._town_layout.site_of_business(select_id)
		if not picked.is_empty():
			dashboard._town_view.focus_on(picked["position"])
	if pick_villager:
		# The first housed villager: centred, selected, person window open.
		var view = dashboard._town_view
		for report in dashboard._simulation.get_villager_reports(dashboard._town_settlement_id()):
			if int(report["dwelling_id"]) != -1:
				var key := Vector2i(int(report["household_id"]), 1)
				var at: Vector3 = view.villagers().villager_position(key)
				view.focus_on(Vector2(at.x, at.z))
				view.select_villager(key.x, key.y)
				break
	if zoom > 0.0:
		dashboard._town_view.camera().size = zoom
	if tilt > 0.0:
		var rig: Node3D = dashboard._town_view._rig
		rig._current_tilt = tilt
		rig._apply_tilt()
	# Let the villagers mill and their animations settle.
	dashboard._town_view.set_villagers_paused(false)
	for i in 30:
		await process_frame
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var error := root.get_texture().get_image().save_png(output_path)
	if error == OK:
		print("Saved town view to %s" % output_path)
		quit(0)
	else:
		push_error("Could not save town capture: %s" % error_string(error))
		quit(1)
