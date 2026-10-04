extends SceneTree

const ValleySeed = preload("res://scripts/sim/data/valley_seed.gd")
const VALLEY_SCENE_PATH := "res://scenes/valley/river_valley.tscn"

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var valley = load(VALLEY_SCENE_PATH).instantiate()
	root.add_child(valley)
	await process_frame
	valley.call("_select_settlement", ValleySeed.ALDFORD)
	valley.call("_open_detail_view")
	await process_frame
	var detail = valley.get("_detail_view")
	if detail == null or detail.external_simulation != valley.get("_economy").towns[ValleySeed.ALDFORD]:
		push_error("Town detail is not showing the persistent town economy")
		quit(1)
		return
	if valley.get("_valley_canvas").visible:
		push_error("Valley controls remained over the town detail")
		quit(1)
		return
	valley.get("_economy").advance_ticks(1)
	detail.refresh_external()
	if detail.external_simulation.day != 1:
		push_error("Town detail did not stay connected to the live economy")
		quit(1)
		return
	valley.call("_close_detail_view")
	if not valley.get("_valley_canvas").visible:
		push_error("Valley controls did not return")
		quit(1)
		return
	print("Valley town detail OK")
	quit()
