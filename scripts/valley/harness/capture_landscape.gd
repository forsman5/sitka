extends SceneTree

const VALLEY_SCENE := preload("res://scenes/valley/river_valley.tscn")

func _init() -> void:
	call_deferred("_capture")

func _capture() -> void:
	var view := "overview"
	var output_path := "user://landscape-overview.png"
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--view="):
			view = argument.trim_prefix("--view=")
		elif argument.begins_with("--output="):
			output_path = argument.trim_prefix("--output=")

	var valley := VALLEY_SCENE.instantiate()
	root.add_child(valley)
	await process_frame
	await process_frame
	var camera_rig: Node3D = valley.get_node("RTSCamera")
	var camera: Camera3D = valley.get_node("RTSCamera/Camera3D")
	if view == "aldford":
		camera.size = 72.0
		camera_rig.call("center_on", Vector3(0.0, 0.0, -5.0))
	else:
		camera.size = 350.0
		camera_rig.call("center_on", Vector3.ZERO)
	await process_frame
	await process_frame
	var error := root.get_texture().get_image().save_png(output_path)
	if error == OK:
		print("Saved %s landscape view to %s" % [view, output_path])
		quit(0)
	else:
		push_error("Could not save landscape capture: %s" % error_string(error))
		quit(1)
