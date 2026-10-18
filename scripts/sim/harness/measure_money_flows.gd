extends SceneTree

## Measurement: where does money enter and leave the town? For each preset,
## reports total money at day 0 and at intervals, with the tracked sources
## (export revenue, business startup cash) and sinks (imports, construction
## spend, write-offs by cause), and the residual the identity leaves
## unexplained (should be ~0).
## Run: Godot --headless --path . --script res://scripts/sim/harness/measure_money_flows.gd

const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")

const SEED := 20260901
const PRESETS := ["small_village", "mining_village", "large_village"]
const CHECKPOINTS := [120, 360, 720]

func _init() -> void:
	for preset in PRESETS:
		var builder := Callable(HEScenarioSeeds, "build_preset").bind(preset)
		var sim := HESimulation.new(SEED, builder)
		var base := _snapshot(sim)
		print("\n##### %s: day 0 money %.0f, %d households" % [preset, base["money"], sim.households.size()])
		var done := 0
		for target in CHECKPOINTS:
			sim.advance_ticks(target - done)
			done = target
			_print_delta(sim, base, target)
	quit()

func _snapshot(sim) -> Dictionary:
	return {
		"money": sim._total_money(),
		"export": sim._export_revenue_total,
		"import": sim._import_cost_total,
		"construction": sim._construction_spend_total,
		"written_off": sim._money_written_off_total,
		"injection": sim._startup_injection_total,
		"by_cause": sim._money_written_off_by_cause.duplicate(),
	}

func _print_delta(sim, base: Dictionary, day: int) -> void:
	var now := _snapshot(sim)
	var export: float = now["export"] - base["export"]
	var imported: float = now["import"] - base["import"]
	var construction: float = now["construction"] - base["construction"]
	var written_off: float = now["written_off"] - base["written_off"]
	var injection: float = now["injection"] - base["injection"]
	var change: float = now["money"] - base["money"]
	var explained := export + injection - imported - construction - written_off
	print("  day %d: money %+.0f (now %.0f) | in: exports %.0f, startup cash %.0f | out: imports %.0f, construction %.0f, written off %.0f | unexplained %.1f" % [
		day, change, now["money"], export, injection, imported, construction, written_off, change - explained])
	var causes := []
	for cause in now["by_cause"].keys():
		causes.append("%s %.0f" % [cause if cause != "" else "other", now["by_cause"][cause] - float(base["by_cause"].get(cause, 0.0))])
	print("          written off by cause: %s" % ", ".join(causes))
	if day == CHECKPOINTS[-1]:
		_print_holders(sim)

## Who holds the money: households in total, then each business by type.
func _print_holders(sim) -> void:
	var household_total := 0.0
	for h in sim.households.values():
		household_total += h.balance
	var by_type: Dictionary = {}
	var workers_by_type: Dictionary = {}
	for b in sim.businesses.values():
		by_type[b.type_key] = float(by_type.get(b.type_key, 0.0)) + b.balance
		workers_by_type[b.type_key] = int(workers_by_type.get(b.type_key, 0)) + sim._business_employed_worker_count(b.id)
	print("          held by: households %.0f (%.0f per household)" % [household_total, household_total / maxf(sim.households.size(), 1)])
	var parts := []
	for type_key in by_type.keys():
		parts.append("%s %.0f (%d workers)" % [type_key, by_type[type_key], workers_by_type[type_key]])
	print("                   businesses: %s" % ", ".join(parts))
