## Opens every business's detail page (and the trader export settings) in the
## HE dashboard so icon-cell code paths run. Needs the autoloads, so it runs as
## a scene: godot --headless --path . res://scripts/ci/check_he_detail_icons.tscn
extends Node

func _ready() -> void:
	var dash: Node = load("res://scenes/sim/he_dashboard.tscn").instantiate()
	add_child(dash)
	await get_tree().process_frame
	await get_tree().process_frame
	var sim = dash._simulation
	dash._speed_multiplier = 0.0 # drive the sim by hand
	sim.advance_ticks(60) # let the Trader actually move goods
	var icon_total := 0
	for r in sim.get_business_reports():
		dash._on_business_row_selected(r["business_id"])
		if r["kind"] == "trader":
			dash._on_trader_settings_pressed()
		if r["kind"] == "trader":
			print("  Trader activity text: %s -> grid icons: %d" % [r["output_commodity"], _count(dash._business_detail_grid)])
		var found := _count(dash._business_detail_panel) + _count(dash._trader_settings_list)
		print("%s (%s): %d icons" % [r["name"], r["kind"], found])
		icon_total += found
	print("TOTAL icons: %d" % icon_total)
	get_tree().quit(0 if icon_total > 0 else 1)

func _count(n: Node) -> int:
	var c := 0
	if n is TextureRect and (n as TextureRect).texture != null:
		c += 1
	if n is CheckBox and (n as CheckBox).icon != null:
		c += 1
	for ch in n.get_children():
		c += _count(ch)
	return c
