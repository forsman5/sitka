extends SceneTree

## Opt-in headless scale probe. Uses the production Simulation unchanged.
const Sim = preload("res://scripts/sim/simulation.gd")
const MultiValleySeed = preload("res://scripts/sim/data/multivalley_seed.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var options: Dictionary = {"days": "360", "out": "user://multivalley.jsonl"}
	for arg in OS.get_cmdline_user_args():
		var parts: PackedStringArray = arg.trim_prefix("--").split("=", true, 1)
		if parts.size() != 2 or parts[0] not in ["graph", "days", "out"]:
			_fail("Use --graph=PATH --days=360 --out=PATH after Godot's -- separator")
			return
		options[parts[0]] = parts[1]
	var day_text: String = options["days"]
	if not options.has("graph") or not day_text.is_valid_int() or int(day_text) < 1:
		_fail("A graph path and positive integer days are required")
		return
	var builder = MultiValleySeed.new()
	var error: String = builder.load_graph(options["graph"])
	if not error.is_empty():
		_fail(error)
		return
	var graph: Dictionary = builder.graph
	var output: FileAccess = FileAccess.open(options["out"], FileAccess.WRITE)
	if output == null:
		_fail("Cannot write output (create its parent directory first)")
		return
	var sim = Sim.new(int(graph["seed"]), Callable(builder, "build"))
	output.store_line(JSON.stringify({"type": "configuration", "graph": graph,
		"days": int(day_text), "godot": Engine.get_version_info()}))
	var simulation_usec: int = 0
	var report_usec: int = 0
	for index in range(int(day_text)):
		var start: int = Time.get_ticks_usec()
		sim.advance_ticks(1)
		simulation_usec += Time.get_ticks_usec() - start
		# Every month plus the final day; history stays bounded in Simulation.
		if (index + 1) % 30 == 0 or index + 1 == int(day_text):
			start = Time.get_ticks_usec()
			var summaries: Array = []
			var population: int = 0
			var deaths: int = 0
			var collapsed: int = 0
			var delivered: int = 0
			for sid in sim.get_settlement_ids():
				var summary: Dictionary = sim.get_settlement_summary(sid)
				for quantity in summary["inventory"].values():
					if not is_finite(float(quantity)) or float(quantity) < -0.000001:
						_fail("Invalid inventory at settlement %s" % sid)
						return
				population += int(summary["population"])
				deaths += int(summary["starvation_deaths_total"])
				delivered += int(summary["shipments_received_total"])
				if summary["status"] == "collapsed":
					collapsed += 1
				summaries.append(summary)
			var economic: Dictionary = {"clock": sim.get_clock_summary(),
				"settlements": summaries, "shipments": sim.get_active_shipments()}
			var fingerprint: String = JSON.stringify(economic).sha256_text()
			output.store_line(JSON.stringify({"type": "sample", "state": economic,
				"fingerprint": fingerprint, "population": population,
				"starvation_deaths": deaths, "collapsed": collapsed,
				"shipments_delivered": delivered}))
			output.flush()
			report_usec += Time.get_ticks_usec() - start
			print("day=%d population=%d collapsed=%d delivered=%d sim_ms=%.1f" % [
				index + 1, population, collapsed, delivered, simulation_usec / 1000.0])
	output.store_line(JSON.stringify({"type": "timing", "simulation_usec": simulation_usec,
		"report_usec": report_usec, "mean_tick_ms": simulation_usec / (1000.0 * int(day_text))}))
	output.close()
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	quit(1)

