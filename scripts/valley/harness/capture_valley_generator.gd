extends SceneTree

## Saves the valley generator scene as PNGs (needs a real renderer, so run
## without --headless):
##   godot --path . --script res://scripts/valley/harness/capture_valley_generator.gd -- --output=C:/tmp/valley --seed=4
## Writes <output>_map.png, <output>_3d.png and <output>_sheet.png.

func _init() -> void:
	call_deferred("_capture")

func _capture() -> void:
	var output := "user://valley"
	var seed_value := 1
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--output="):
			output = argument.trim_prefix("--output=")
		elif argument.begins_with("--seed="):
			seed_value = argument.trim_prefix("--seed=").to_int()
	root.size = Vector2i(1400, 800)
	var view: Control = (load("res://scenes/valley/valley_generator.tscn") as PackedScene).instantiate()
	root.add_child(view)
	await process_frame
	view._set_seed(seed_value)
	for mode in [[view.Mode.MAP, "_map"], [view.Mode.VIEW_3D, "_3d"], [view.Mode.SHEET, "_sheet"]]:
		view._show(mode[0])
		for i in 24:
			await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output + mode[1] + ".png")
	print("Saved captures to %s_*.png" % output)
	quit(0)
