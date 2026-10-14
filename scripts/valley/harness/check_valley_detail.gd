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
	if detail._town_layout == null or detail._town_view == null:
		push_error("Embedded town detail has no town layout or view")
		quit(1)
		return
	detail._set_town_mode(true)
	await process_frame
	if not detail._town_view.visible or detail._town_view.site_node_count() < detail.external_simulation.get_business_reports().size():
		push_error("Embedded town view does not show the town's businesses")
		quit(1)
		return
	if detail._town_layout.unplaced_business_ids().size() > 0 or detail._town_layout.unplaced_dwelling_ids().size() > 0:
		print("Aldford unplaced: businesses %d, houses %d" % [detail._town_layout.unplaced_business_ids().size(), detail._town_layout.unplaced_dwelling_ids().size()])
		push_error("Embedded town view could not place the town's businesses or houses")
		quit(1)
		return
	if not detail._speed_buttons[2].visible or not detail._speed_buttons[3].visible:
		push_error("Embedded town view lost the shared valley speed controls")
		quit(1)
		return
	detail.set_external_town_phase(0.5)
	if absf(detail._town_view.time_of_day() - 0.5) > 0.0001:
		push_error("Embedded town view did not follow the valley clock phase")
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
	for town_id in ValleySeed.HOUSEHOLDS_PER_SETTLEMENT.keys():
		if town_id == ValleySeed.ALDFORD:
			continue
		valley.call("_select_settlement", town_id)
		valley.call("_open_detail_view")
		await process_frame
		detail = valley.get("_detail_view")
		if detail == null or detail.external_simulation != valley.get("_economy").towns[town_id]:
			push_error("Town %d detail lost its persistent economy" % town_id)
			quit(1)
			return
		if detail._town_layout.unplaced_business_ids().size() > 0 or detail._town_layout.unplaced_dwelling_ids().size() > 0:
			push_error("Town %d layout left businesses or houses unplaced" % town_id)
			quit(1)
			return
		valley.call("_close_detail_view")
		await process_frame
	print("Valley town detail OK")
	quit()
