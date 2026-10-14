extends SceneTree

## Frame-time measurement of the Town view's villagers on the desktop (needs a
## real renderer, so run without --headless):
##   godot --path . --resolution 1600x900 --script res://scripts/sim/harness/perf_town_villagers.gd -- [--households=120] [--zoom=100,30]
## The measurement itself is perf_town_villagers_runner.gd, which a web export
## can also run as scenes/sim/perf_town_villagers.tscn.

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var runner: Node = load("res://scripts/sim/harness/perf_town_villagers_runner.gd").new()
	runner.finished.connect(func(_lines: PackedStringArray) -> void: quit(0))
	root.add_child(runner)
