extends Node

## Frame-time measurement of the Town view's villagers, as a node so it runs
## both from the desktop harness (perf_town_villagers.gd) and as a scene in a
## web export (scenes/sim/perf_town_villagers.tscn; pass the scene path and
## `-- --households=120 --zoom=100,30 [--hour=7]` as the web shell's engine args).
##
## Builds the large village with `households` households (tenements so they
## are housed), opens the Town view and, for each zoom, times FRAMES frames in
## several configurations. Results print, and in a web build are also POSTed
## to /perf-result on the serving host. Emits `finished` with the lines.

signal finished(lines: PackedStringArray)

const FRAMES := 240
const WARMUP := 60

var _dashboard: Control
var _view
var _layer: Node3D
var _lines := PackedStringArray()

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var households := 120
	var zooms: Array[float] = [100.0]
	var hour := -1.0
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--households="):
			households = argument.trim_prefix("--households=").to_int()
		elif argument.begins_with("--hour="):
			hour = argument.trim_prefix("--hour=").to_float()
		elif argument.begins_with("--zoom="):
			zooms.clear()
			for part in argument.trim_prefix("--zoom=").split(","):
				zooms.append(part.to_float())
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	_log("start: %d households, zooms %s, static memory %.0f MB" % [households, str(zooms), OS.get_static_memory_usage() / 1048576.0])
	var presets: GDScript = load("res://scripts/sim/household_economy/data/he_presets.gd")
	var seeds: GDScript = load("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")
	var spec: Dictionary = (presets.PRESETS["large_village"] as Dictionary).duplicate(true)
	spec["households"] = households
	# Same 56 lots; enough of them dense (4 households) to house everyone.
	spec["housing"] = {"houses": 56, "tenements": clampi(ceili((households - 56) / 3.0) + 1, 0, 56)}
	var dashboard_script: GDScript = load("res://scripts/sim/household_economy/he_dashboard.gd")
	dashboard_script.pending_builder = Callable(seeds, "build_from_spec").bind(spec).unbind(1)
	_dashboard = (load("res://scenes/sim/he_dashboard.tscn") as PackedScene).instantiate()
	add_child(_dashboard)
	_dashboard._speed_multiplier = 1.0
	_log("dashboard built, static memory %.0f MB" % (OS.get_static_memory_usage() / 1048576.0))
	await get_tree().process_frame
	_dashboard._set_town_mode(true)
	_view = _dashboard._town_view
	if hour >= 0.0:
		_dashboard._town_phase = hour / 24.0 # town clock start, e.g. --hour=7 for the morning commute
	_layer = _view.villagers()
	_log("town mode on, %d villagers, static memory %.0f MB" % [_view.villager_count(), OS.get_static_memory_usage() / 1048576.0])
	await get_tree().process_frame
	_log("first town frame drawn")

	_log("platform %s, renderer %s, %s" % [OS.get_name(), RenderingServer.get_current_rendering_method(), RenderingServer.get_video_adapter_name()])
	_log("town: %d households, %d villagers, %d sites drawn, window %s" % [
		_dashboard._simulation.get_household_ids().size(), _view.villager_count(), _view.site_node_count(), str(get_viewport().get_visible_rect().size)])
	_log_villager_anatomy()

	for zoom in zooms:
		_view.camera().size = zoom
		_log("zoom %.0f" % zoom)
		await _measure("as shipped")
		_set_old_behaviour(true)
		await _measure("old: anims every frame + shadows")
		_set_old_behaviour(false)
		_set_shadows(true)
		await _measure("with villager shadows only")
		_set_shadows(false)
		_layer.process_mode = Node.PROCESS_MODE_DISABLED
		await _measure("villager script+anims off")
		_layer.visible = false
		await _measure("villagers hidden + disabled")
		_layer.visible = true
		_layer.process_mode = Node.PROCESS_MODE_INHERIT
	var start := Time.get_ticks_usec()
	for i in 100:
		_layer._process(1.0 / 60.0)
	_log("villager _process (GDScript only): %.3f ms per frame" % ((Time.get_ticks_usec() - start) / 100000.0))
	_post_results()
	finished.emit(_lines)

func _log(line: String) -> void:
	print(line)
	_lines.append(line)
	# Streamed as it goes, so a web run that crashes still shows how far it got.
	if OS.has_feature("web"):
		JavaScriptBridge.eval("fetch('/perf-line', {method: 'POST', body: %s});" % JSON.stringify(line))

## Per-villager node, mesh, surface and material counts.
func _log_villager_anatomy() -> void:
	var keys: Array = _layer.villager_keys()
	var node: Node3D = _layer._villagers[keys[0]]["node"]
	var meshes := node.find_children("*", "MeshInstance3D", true, false)
	var surfaces := 0
	var tris := 0
	for mesh_node in meshes:
		var mesh := (mesh_node as MeshInstance3D).mesh
		surfaces += mesh.get_surface_count()
		for i in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(i)
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			tris += indices.size() / 3 if not indices.is_empty() else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	var skeletons := node.find_children("*", "Skeleton3D", true, false)
	var bones := (skeletons[0] as Skeleton3D).get_bone_count() if not skeletons.is_empty() else 0
	var materials := {}
	for key in keys:
		for mesh_node in (_layer._villagers[key]["node"] as Node3D).find_children("*", "MeshInstance3D", true, false):
			var m := mesh_node as MeshInstance3D
			for i in m.mesh.get_surface_count():
				var material := m.get_active_material(i)
				if material != null:
					materials[material.get_instance_id()] = true
	_log("per villager: %d MeshInstance3D, %d surfaces, %d bones, %d triangles; %d distinct materials across all villagers" % [meshes.size(), surfaces, bones, tris, materials.size()])

func _set_shadows(on: bool) -> void:
	for mesh_node in _layer.find_children("*", "MeshInstance3D", true, false):
		(mesh_node as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

## Before the animation budget: every AnimationPlayer processes itself each
## frame, and villagers cast shadows (skin materials stay shared).
func _set_old_behaviour(on: bool) -> void:
	_set_shadows(on)
	for anim in _layer.find_children("*", "AnimationPlayer", true, false):
		(anim as AnimationPlayer).callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE if on else AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL

func _measure(label: String) -> void:
	for i in WARMUP:
		await get_tree().process_frame
	var times: Array[float] = []
	var draw_calls := 0.0
	var primitives := 0.0
	var last := Time.get_ticks_usec()
	for i in FRAMES:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		times.append((now - last) / 1000.0)
		last = now
		draw_calls += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		primitives += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	times.sort()
	var total := 0.0
	for t in times:
		total += t
	var mean := total / times.size()
	_log("  %-34s mean %6.2f ms (%5.1f fps)  p95 %6.2f ms  draws %6.0f  prims %8.0f" % [
		label, mean, 1000.0 / mean, times[int(times.size() * 0.95)], draw_calls / FRAMES, primitives / FRAMES])

func _post_results() -> void:
	if not OS.has_feature("web"):
		return
	var body := JSON.stringify("\n".join(_lines))
	JavaScriptBridge.eval("fetch('/perf-result', {method: 'POST', body: %s}); document.title = 'PERF DONE';" % body)
