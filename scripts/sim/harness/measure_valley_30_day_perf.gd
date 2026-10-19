extends SceneTree

const ValleyEconomy = preload("res://scripts/valley/valley_economy.gd")
const MEASURED_RUNS := 5
const DAYS_PER_RUN := 30

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var warmup := ValleyEconomy.new()
	warmup.advance_ticks(1)
	var samples: Array[float] = []
	for run_index in range(MEASURED_RUNS + 1):
		var valley := ValleyEconomy.new()
		var started := Time.get_ticks_usec()
		valley.advance_ticks(DAYS_PER_RUN)
		var elapsed_usec := Time.get_ticks_usec() - started
		if valley.day != DAYS_PER_RUN or valley.towns.size() != 5:
			push_error("Valley benchmark did not complete 30 days across five towns")
			quit(1)
			return
		if run_index == 0:
			print("warmup_ms=%.2f" % (float(elapsed_usec) / 1000.0))
		else:
			samples.append(float(elapsed_usec) / 1000.0)
			print("run=%d days=%d sim_ms=%.2f mean_tick_ms=%.3f" % [
				run_index, DAYS_PER_RUN, samples[-1], samples[-1] / DAYS_PER_RUN])
	var sorted_samples := samples.duplicate()
	sorted_samples.sort()
	var total := 0.0
	for sample in samples:
		total += sample
	print("summary runs=%d days=%d median_ms=%.2f mean_ms=%.2f min_ms=%.2f max_ms=%.2f median_tick_ms=%.3f" % [
		MEASURED_RUNS, DAYS_PER_RUN, sorted_samples[int(MEASURED_RUNS / 2)],
		total / MEASURED_RUNS, sorted_samples[0], sorted_samples[-1],
		sorted_samples[int(MEASURED_RUNS / 2)] / DAYS_PER_RUN])
	quit(0)
