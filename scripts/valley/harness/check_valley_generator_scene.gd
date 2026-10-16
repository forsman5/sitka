extends SceneTree

## Loads the valley generator scene, flips through its modes and a seed change,
## and checks it built a texture, a 3D mesh and a full contact sheet.
## Needs no renderer output; run with --headless.

func _init() -> void:
	var scene := load("res://scenes/valley/valley_generator.tscn") as PackedScene
	var view := scene.instantiate()
	root.add_child(view)
	await process_frame
	var failures := 0
	if view._map.texture == null:
		print("FAIL: no relief texture")
		failures += 1
	if view._world.get_child_count() < 3:
		print("FAIL: 3D world is empty")
		failures += 1
	view._show(view.Mode.VIEW_3D)
	view._show(view.Mode.SHEET)
	for i in 12:
		await process_frame
	if view._sheet_grid.get_child_count() != view.SHEET_COUNT:
		print("FAIL: contact sheet has %d cells" % view._sheet_grid.get_child_count())
		failures += 1
	view._set_seed(7)
	await process_frame
	if view._result["seed"] != 7:
		print("FAIL: seed change did not regenerate")
		failures += 1
	# Editing the spec box and applying it switches landscape.
	var edited: Dictionary = JSON.parse_string(view._spec_text.text)
	edited["landscape"] = "coast"
	edited["seed"] = 3
	view._spec_text.text = JSON.stringify(edited)
	view._apply_spec_text()
	await process_frame
	if view._result["spec"].landscape != "coast" or view._result["seed"] != 3 or not view._result["terrain"].has_sea:
		print("FAIL: applying an edited spec did not regenerate as a coast")
		failures += 1
	view._spec_text.text = "{not json"
	view._apply_spec_text()
	if view._result["spec"].landscape != "coast" or not view._status.text.begins_with("Spec not applied"):
		print("FAIL: an invalid spec was not rejected cleanly")
		failures += 1
	print("check_valley_generator_scene: %s" % ("FAILED" if failures > 0 else "OK"))
	quit(1 if failures > 0 else 0)
