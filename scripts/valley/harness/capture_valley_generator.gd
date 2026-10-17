extends SceneTree

## Saves the valley generator scene as PNGs (needs a real renderer, so run
## without --headless):
##   godot --path . --script res://scripts/valley/harness/capture_valley_generator.gd -- --output=C:/tmp/valley --seed=4 [--landscape=coast] [--bake]
## Writes <output>_map.png, <output>_3d.png and <output>_sheet.png.

func _init() -> void:
	call_deferred("_capture")

func _capture() -> void:
	var output := "user://valley"
	var seed_value := 1
	var landscape := "river_valley"
	var bake := false
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--output="):
			output = argument.trim_prefix("--output=")
		elif argument == "--bake":
			bake = true
		elif argument.begins_with("--landscape="):
			landscape = argument.trim_prefix("--landscape=")
		elif argument.begins_with("--seed="):
			seed_value = argument.trim_prefix("--seed=").to_int()
	root.size = Vector2i(1400, 800)
	var view: Control = (load("res://scenes/valley/valley_generator.tscn") as PackedScene).instantiate()
	root.add_child(view)
	await process_frame
	view._spec = load("res://scripts/valley/gen/valley_spec.gd").preset(landscape, seed_value)
	view._generate()
	for mode in [[view.Mode.MAP, "_map"], [view.Mode.VIEW_3D, "_3d"], [view.Mode.SHEET, "_sheet"]]:
		view._show(mode[0])
		for i in 24:
			await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output + mode[1] + ".png")
	if bake:
		# Full-detail bake, then an overview and a close-up on the first settlement.
		var started := Time.get_ticks_msec()
		view._bake_detailed()
		await view.bake_finished
		print("Bake took %.1f s: %s" % [float(Time.get_ticks_msec() - started) / 1000.0, view._status.text])
		view._save_bake()
		print("Save: %s" % view._status.text)
		for i in 20:
			await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output + "_baked.png")
		var site: Vector2 = view._bake["sites"][0]["pos"]
		view._rig.center_on(Vector3(site.x, 0.0, site.y))
		view._rig.get_node("Camera3D").size = 140.0
		view._rig._current_tilt = 40.0
		view._rig._apply_tilt()
		for i in 20:
			await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output + "_baked_close.png")
		# Close-up on woodland (or the last settlement), where the trees are densest.
		var woods: Vector2 = view._bake["sites"][view._bake["sites"].size() - 1]["pos"]
		for candidate in view._bake["sites"]:
			if candidate["role"] == "woodland":
				woods = candidate["pos"]
		view._rig.center_on(Vector3(woods.x + 60.0, 0.0, woods.y))
		view._rig.get_node("Camera3D").size = 220.0
		for i in 20:
			await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output + "_baked_woods.png")
		print("Primitives in frame: %d, draw calls: %d" % [RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME), RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)])
	print("Saved captures to %s_*.png" % output)
	quit(0)
