extends SceneTree

const ValleySeed = preload("res://scripts/sim/data/valley_seed.gd")
const VALLEY_SCENE_PATH := "res://scenes/valley/river_valley.tscn"

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var valley = load(VALLEY_SCENE_PATH).instantiate()
	root.add_child(valley)
	await process_frame
	valley._process(0.0)
	if not valley.get("_day_label").text.contains("Spring"):
		push_error("Valley clock does not display the current season")
		quit(1)
		return
	valley.get("_economy").day = 90
	valley._process(0.0)
	if not valley.get("_day_label").text.contains("Summer"):
		push_error("Valley clock did not update at the season boundary")
		quit(1)
		return
	valley.get("_economy").day = 0
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
	valley.set("_speed_multiplier", 100.0)
	detail._set_town_mode(true)
	await process_frame
	if valley.get("_speed_multiplier") != 0.0:
		push_error("Town view did not pause the valley clock")
		quit(1)
		return
	var paused_day: int = valley.get("_economy").day
	valley._process(0.25)
	if valley.get("_economy").day != paused_day:
		push_error("Valley time advanced while Town view was open")
		quit(1)
		return
	if not detail._town_view.visible or detail._town_view.site_node_count() < detail.external_simulation.get_business_reports().size():
		push_error("Embedded town view does not show the town's businesses")
		quit(1)
		return
	if detail._town_layout.unplaced_business_ids().size() > 0 or detail._town_layout.unplaced_dwelling_ids().size() > 0:
		print("Aldford unplaced: businesses %s, houses %s" % [str(detail._town_layout.unplaced_business_ids()), str(detail._town_layout.unplaced_dwelling_ids())])
		push_error("Embedded town view could not place the town's businesses or houses")
		quit(1)
		return
	for button in detail._speed_buttons:
		if button.visible:
			push_error("Embedded town view still exposes valley speed controls")
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
	if valley.get("_speed_multiplier") != 100.0:
		push_error("Closing Town view did not restore the previous valley speed")
		quit(1)
		return
	valley.set("_speed_multiplier", 0.0)
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
			print("Town %d unplaced: businesses %s, houses %s" % [town_id, str(detail._town_layout.unplaced_business_ids()), str(detail._town_layout.unplaced_dwelling_ids())])
			push_error("Town %d layout left businesses or houses unplaced" % town_id)
			quit(1)
			return
		valley.call("_close_detail_view")
		await process_frame
	print("Valley town detail OK")
	quit()
