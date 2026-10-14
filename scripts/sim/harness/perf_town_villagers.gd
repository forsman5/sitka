extends SceneTree

## Frame-time measurement of the Town view's villagers (needs a real renderer,
## so run without --headless):
##   godot --path . --resolution 1600x900 --script res://scripts/sim/harness/perf_town_villagers.gd -- [--households=120] [--zoom=100]
## Builds the large village with `households` households (tenements so they
## are housed), opens the Town view and times FRAMES frames with vsync off in
## several configurations, so the cost of each part of the villagers shows.

const FRAMES := 240
const WARMUP := 60

var _dashboard: Control
var _view
var _layer: Node3D

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var households := 120
	var zoom := 100.0
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--households="):
			households = argument.trim_prefix("--households=").to_int()
		elif argument.begins_with("--zoom="):
			zoom = argument.trim_prefix("--zoom=").to_float()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	var presets: GDScript = load("res://scripts/sim/household_economy/data/he_presets.gd")
	var seeds: GDScript = load("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
	var spec: Dictionary = (presets.PRESETS["large_village"] as Dictionary).duplicate(true)
	spec["households"] = households
	# Same 56 lots; enough of them dense (4 households) to house everyone.
	spec["housing"] = {"houses": 56, "tenements": clampi(ceili((households - 56) / 3.0) + 1, 0, 56)}
	var dashboard_script: GDScript = load("res://scripts/sim/household_economy/he_dashboard.gd")
	dashboard_script.pending_builder = Callable(seeds, "build_from_spec").bind(spec).unbind(1)
	_dashboard = (load("res://scenes/sim/he_dashboard.tscn") as PackedScene).instantiate()
	root.add_child(_dashboard)
	_dashboard._speed_multiplier = 1.0
	await process_frame
	_dashboard._set_town_mode(true)
	_view = _dashboard._town_view
	_view.camera().size = zoom
	_layer = _view.villagers()
	await process_frame
	await process_frame

	print("town: %d households, %d villagers, %d sites drawn, zoom %.0f, window %s" % [
		_dashboard._simulation.get_household_ids().size(), _view.villager_count(), _view.site_node_count(), zoom, str(root.size)])
	_print_villager_anatomy()

	await _measure("as shipped")
	_set_shadows(true)
	await _measure("with villager shadows (old)")
	_set_shadows(false)
	_layer.process_mode = Node.PROCESS_MODE_DISABLED
	await _measure("villager script+anims off")
	_layer.process_mode = Node.PROCESS_MODE_INHERIT
	_set_anim_active(false)
	await _measure("AnimationPlayers off (script on)")
	_set_anim_active(true)
	_layer.visible = false
	await _measure("villagers hidden (anims still run)")
	_layer.process_mode = Node.PROCESS_MODE_DISABLED
	await _measure("villagers hidden + disabled")
	_layer.visible = true
	_layer.process_mode = Node.PROCESS_MODE_INHERIT

	# GDScript milling cost alone, outside rendering.
	var start := Time.get_ticks_usec()
	for i in 100:
		_layer._process(1.0 / 60.0)
	print("  villager _process (GDScript only): %.3f ms per frame" % ((Time.get_ticks_usec() - start) / 100000.0))
	quit(0)

## Per-villager node, mesh, surface and material counts.
func _print_villager_anatomy() -> void:
	var keys: Array = _layer.villager_keys()
	var node: Node3D = _layer._villagers[keys[0]]["node"]
	var meshes := node.find_children("*", "MeshInstance3D", true, false)
	var surfaces := 0
	for mesh_node in meshes:
		surfaces += (mesh_node as MeshInstance3D).mesh.get_surface_count()
	var skeletons := node.find_children("*", "Skeleton3D", true, false)
	var bones := (skeletons[0] as Skeleton3D).get_bone_count() if not skeletons.is_empty() else 0
	var all_nodes := node.find_children("*", "", true, false).size()
	var materials := {}
	for key in keys:
		var villager: Node3D = _layer._villagers[key]["node"]
		for mesh_node in villager.find_children("*", "MeshInstance3D", true, false):
			var m := mesh_node as MeshInstance3D
			for i in m.mesh.get_surface_count():
				var material := m.get_active_material(i)
				if material != null:
					materials[material.get_instance_id()] = true
	var tris := 0
	for mesh_node in meshes:
		var mesh := (mesh_node as MeshInstance3D).mesh
		for i in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(i)
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			tris += indices.size() / 3 if not indices.is_empty() else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	print("  per villager: %d nodes, %d MeshInstance3D, %d surfaces, %d bones, %d triangles; %d distinct materials across all villagers" % [all_nodes, meshes.size(), surfaces, bones, tris, materials.size()])

func _set_shadows(on: bool) -> void:
	for mesh_node in _layer.find_children("*", "MeshInstance3D", true, false):
		(mesh_node as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func _set_anim_active(on: bool) -> void:
	for anim in _layer.find_children("*", "AnimationPlayer", true, false):
		(anim as AnimationPlayer).active = on

func _measure(label: String) -> void:
	for i in WARMUP:
		await process_frame
	var times: Array[float] = []
	var draw_calls := 0.0
	var objects := 0.0
	var primitives := 0.0
	var process_ms := 0.0
	var last := Time.get_ticks_usec()
	for i in FRAMES:
		await process_frame
		var now := Time.get_ticks_usec()
		times.append((now - last) / 1000.0)
		last = now
		draw_calls += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		objects += Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
		primitives += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
		process_ms += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	times.sort()
	var total := 0.0
	for t in times:
		total += t
	var mean := total / times.size()
	print("  %-36s mean %6.2f ms (%5.1f fps)  p95 %6.2f ms  draws %6.0f  objects %6.0f  prims %8.0f  process %5.2f ms" % [
		label, mean, 1000.0 / mean, times[int(times.size() * 0.95)], draw_calls / FRAMES, objects / FRAMES, primitives / FRAMES, process_ms / FRAMES])
