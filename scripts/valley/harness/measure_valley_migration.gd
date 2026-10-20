extends SceneTree

## Migration experiment: runs the valley with migration off and on and prints,
## per 90 days, population per town, moves, utility spread and an equilibrium
## verdict. Args after `--`: [years] (default 5).
##
## Equilibrium is declared when, for the last EQ_WINDOW months, (a) the utility
## spread between towns stays under EQ_SPREAD, (b) no town's population drifts
## more than EQ_DRIFT of its mean across the window, and (c) net flow per town
## averages under EQ_NET households/month -- while gross moves stay above zero
## (a frozen valley is not an equilibrium, it is a stuck one).

const ValleyEconomy = preload("res://scripts/valley/valley_economy.gd")

const EQ_WINDOW := 12
const EQ_SPREAD := 0.35
const EQ_DRIFT := 0.08
const EQ_NET := 0.5

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var years := 5
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		years = int(args[0])
	for enabled in [false, true]:
		_measure(enabled, years)
	quit()

func _population(valley: ValleyEconomy) -> Dictionary:
	var pops := {}
	for town_id in valley.towns:
		pops[town_id] = valley.towns[town_id].get_migration_signals()["population"]
	return pops

func _measure(enabled: bool, years: int) -> void:
	var valley := ValleyEconomy.new()
	valley.migration_enabled = enabled
	var ids := valley.get_settlement_ids()
	var pop_history: Array[Dictionary] = []
	var spread_history: Array[float] = []
	var moves_history: Array[int] = []
	var net_history: Array[Dictionary] = []
	var seen_moves := 0
	var settled_month := -1
	print("=== migration %s, %d years ===" % ["ON" if enabled else "OFF", years])
	for month in years * 12:
		valley.advance_ticks(30)
		var pops := _population(valley)
		pop_history.append(pops)
		var net := {}
		for town_id in ids:
			net[town_id] = 0
		for i in range(seen_moves, valley.migration_log.size()):
			var move: Dictionary = valley.migration_log[i]
			net[move["from"]] -= 1
			net[move["to"]] += 1
		moves_history.append(valley.migration_log.size() - seen_moves)
		seen_moves = valley.migration_log.size()
		net_history.append(net)
		var spread := 0.0
		if not valley.town_utility.is_empty():
			spread = valley.town_utility.values().max() - valley.town_utility.values().min()
		spread_history.append(spread)
		var verdict := _equilibrium(pop_history, spread_history, moves_history, net_history, ids, enabled)
		if verdict and settled_month < 0:
			settled_month = month
		elif not verdict:
			settled_month = -1
		if (month + 1) % 3 == 0:
			var cells := []
			for town_id in ids:
				cells.append("%s %d" % [valley.TOWN_NAMES[town_id], pops[town_id]])
			print("month %3d  pop[%s]  moves/qtr %d  spread %.2f  %s" % [month + 1, ", ".join(cells),
				moves_history.slice(-3).reduce(func(a, b): return a + b, 0), spread,
				"EQUILIBRIUM" if verdict else "-"])
	var final_cells := []
	for town_id in ids:
		var series := []
		for pops in pop_history:
			series.append(float(pops[town_id]))
		final_cells.append("%s mean %.0f sd %.1f" % [valley.TOWN_NAMES[town_id], _mean(series.slice(-EQ_WINDOW)), _sd(series.slice(-EQ_WINDOW))])
	print("total moves %d (%.1f/yr), equilibrium since month %s" % [valley.migration_total, float(valley.migration_total) / years, str(settled_month + 1) if settled_month >= 0 else "never"])
	print("last-year population: %s" % "; ".join(final_cells))

func _equilibrium(pop_history: Array, spread_history: Array, moves_history: Array, net_history: Array, ids: Array, enabled: bool) -> bool:
	if pop_history.size() < EQ_WINDOW or not enabled:
		return false
	var spread_ok := true
	for s in spread_history.slice(-EQ_WINDOW):
		spread_ok = spread_ok and s < EQ_SPREAD
	var moves := 0
	for m in moves_history.slice(-EQ_WINDOW):
		moves += m
	var drift_ok := true
	var net_ok := true
	for town_id in ids:
		var series := []
		var net_total := 0
		for i in range(pop_history.size() - EQ_WINDOW, pop_history.size()):
			series.append(float(pop_history[i][town_id]))
			net_total += net_history[i][town_id]
		var mean := _mean(series)
		drift_ok = drift_ok and mean > 0.0 and (series.max() - series.min()) / mean < EQ_DRIFT * 2.0
		net_ok = net_ok and absf(float(net_total) / EQ_WINDOW) < EQ_NET
	return spread_ok and drift_ok and net_ok and moves > 0

func _mean(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for v in values:
		total += v
	return total / values.size()

func _sd(values: Array) -> float:
	var m := _mean(values)
	var total := 0.0
	for v in values:
		total += (v - m) * (v - m)
	return sqrt(total / maxf(1.0, values.size()))
