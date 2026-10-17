extends SceneTree

## Bakes a generated valley coarsely (so it runs in seconds), builds its scene,
## cancels a second bake, and round-trips the saved files. Run:
##   Godot --headless --path . --script scripts/valley/harness/check_valley_bake.gd [-- <landscape> <seed>]
## Full-detail bakes take minutes; use the viewer's "Bake detailed" for those.

const Generator = preload("res://scripts/valley/gen/valley_generator.gd")
const Bake = preload("res://scripts/valley/gen/valley_gen_bake.gd")
const BakeScene = preload("res://scripts/valley/gen/valley_gen_bake_scene.gd")

const COARSE := {"step": 6.0, "erosion": 2, "tree_spacing": 8.0}
const SAVE_DIR := "user://valley_bake_check"

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var landscape: String = args[0] if args.size() > 0 else "coast"
	var seed_value: int = int(args[1]) if args.size() > 1 else 1
	var failures := 0
	var result := Generator.generate_seed(seed_value, landscape)

	var data: Dictionary = await Bake.new().run(result, self, Callable(), COARSE)
	var heights: PackedFloat32Array = data["heights"]
	if heights.size() != int(data["w"]) * int(data["h"]):
		print("FAIL: heights do not match the grid")
		failures += 1
	for value in heights:
		if is_nan(value) or is_inf(value):
			print("FAIL: non-finite height")
			failures += 1
			break
	if data["stats"]["trees"] <= 0 or data["stats"]["buildings"] <= 0:
		print("FAIL: bake has no trees (%d) or buildings (%d)" % [data["stats"]["trees"], data["stats"]["buildings"]])
		failures += 1
	if data["stats"]["map_errors"] != 0:
		print("FAIL: the scaled map no longer passes geometry validation (%d errors)" % data["stats"]["map_errors"])
		failures += 1
	if data["size"] != result["terrain"].SIZE * float(data["scale"]):
		print("FAIL: baked size is not the layout size times the scale")
		failures += 1
	# A site's pad must still be at its recorded height after detail and erosion.
	for site in data["sites"] as Array[Dictionary]:
		var ground := Bake.height_at(data, site["pos"])
		if absf(ground - float(site["height"])) > 2.5:
			print("FAIL: %s pad drifted to %.1f (expected %.1f)" % [site["name"], ground, site["height"]])
			failures += 1
	var again: Dictionary = await Bake.new().run(result, self, Callable(), COARSE)
	if again["heights"] != heights or again["trees"] != data["trees"]:
		print("FAIL: baking is not deterministic")
		failures += 1

	var baker := Bake.new()
	baker.cancel()
	var cancelled: Dictionary = await baker.run(result, self, Callable(), COARSE)
	if not cancelled.is_empty():
		print("FAIL: a cancelled bake still returned data")
		failures += 1

	var world: Node3D = await BakeScene.new().build(data, self, Callable())
	if world == null or world.get_child_count() < 10:
		print("FAIL: the baked scene is nearly empty")
		failures += 1
	else:
		# Every baked tree must reach a MultiMesh (one per mesh part, so >= trees).
		var planted := 0
		for child in world.get_children():
			if child is MultiMeshInstance3D and child.name.begins_with("Trees"):
				planted += (child as MultiMeshInstance3D).multimesh.instance_count
		if planted < int(data["stats"]["trees"]):
			print("FAIL: only %d of %d trees reached the scene" % [planted, data["stats"]["trees"]])
			failures += 1
		root.add_child(world)
		world.queue_free()

	var error := Bake.save(data, SAVE_DIR)
	if error != "":
		print("FAIL: save: %s" % error)
		failures += 1
	else:
		var loaded := Bake.load_dir(SAVE_DIR)
		if loaded.is_empty() or loaded["heights"] != heights or loaded["trees"] != data["trees"] or loaded["sites"].size() != data["sites"].size() or loaded["buildings"].size() != data["buildings"].size():
			print("FAIL: saved bake did not round-trip")
			failures += 1
		elif loaded["map"].settlements.size() != data["map"].settlements.size() or not loaded["map"].validate_geometry().is_empty():
			print("FAIL: saved map did not round-trip")
			failures += 1
		for file_name in ["heights.exr", "colors.png", "spec.json", "map.tres"]:
			if not FileAccess.file_exists("%s/%s" % [SAVE_DIR, file_name]):
				print("FAIL: %s was not saved" % file_name)
				failures += 1

	print("%s seed %d: %d x %d cells, %d trees, %d buildings, %d ms" % [landscape, seed_value, data["w"], data["h"], data["stats"]["trees"], data["stats"]["buildings"], data["stats"]["ms"]])
	print("check_valley_bake: %s" % ("FAILED" if failures > 0 else "OK"))
	quit(1 if failures > 0 else 0)
