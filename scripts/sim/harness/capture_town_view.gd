extends SceneTree

## Saves the household Town view as a PNG (needs a real renderer, so run
## without --headless):
##   godot --path . --script res://scripts/sim/harness/capture_town_view.gd -- --output=C:/tmp/town.png [--days=30] [--preset=build_economy_with_charcoal_burner] [--select=1] [--time=0.75]

func _init() -> void:
	call_deferred("_capture")

func _capture() -> void:
	var output_path := "user://town-view.png"
	var days := 0
	var preset := "build_three_business_economy"
	var select_id := -1
	var time_of_day := -1.0
	for argument in OS.get_cmdline_user_args():
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
	dashboard_script.pending_builder = Callable(seeds, preset)
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
