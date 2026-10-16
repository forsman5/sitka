extends SceneTree

## Hiring order acceptance check (no scene needed). Run with:
##   godot --headless --script res://scripts/sim/harness/check_job_proximity.gd
## HESimulation._reconcile_employment fills a business from the unemployed
## pool nearest-first when `position_lookup` is set, and by ascending household
## id otherwise.

const HESimulation = preload("res://scripts/sim/household_economy/he_simulation.gd")
const HEScenarioSeeds = preload("res://scripts/sim/household_economy/data/he_scenario_seeds.gd")

const SEED := 4242
const SID := HEScenarioSeeds.SETTLEMENT_ID
const FAR := 1000000.0

var _ok := true

func _init() -> void:
	_check_unset_and_unknown_positions_match()
	_check_nearest_is_hired_first()
	_check_ties_and_unhoused()
	print("JOB PROXIMITY %s" % ("OK" if _ok else "FAILED"))
	quit(0 if _ok else 1)

func _assert(condition: bool, message: String) -> void:
	if not condition:
		_ok = false
		push_error("FAIL: " + message)

func _fresh() -> HESimulation:
	var sim := HESimulation.new(SEED, Callable(HEScenarioSeeds, "build_preset").bind("small_village"))
	for household_id in sim.get_household_ids(SID):
		(sim.households[household_id] as HEHousehold).employer_business_id = -1
	# Fewer jobs than workers, so who gets hired is a real choice.
	for business_id in sim.businesses:
		var b: HEBusiness = sim.businesses[business_id]
		b.capacity = maxi(1, b.capacity / 2)
	return sim

func _employers(sim: HESimulation) -> Dictionary:
	var out := {}
	for household_id in sim.get_household_ids(SID):
		out[household_id] = (sim.households[household_id] as HEHousehold).employer_business_id
	return out

## Households a business hired from the pool (not the administrator or the
## warehouse crew, which are picked by their own rules).
func _hired_ids(sim: HESimulation) -> Array[int]:
	var out: Array[int] = []
	for household_id in sim.get_household_ids(SID):
		var employer: int = (sim.households[household_id] as HEHousehold).employer_business_id
		if employer == -1:
			continue
		var kind: int = (sim.businesses[employer] as HEBusiness).kind
		if kind != HEBusiness.Kind.GOVERNMENT and kind != HEBusiness.Kind.WAREHOUSE:
			out.append(household_id)
	return out

func _leftover_ids(sim: HESimulation) -> Array[int]:
	var out: Array[int] = []
	for household_id in sim.get_household_ids(SID):
		var h: HEHousehold = sim.households[household_id]
		if h.employer_business_id == -1 and h.worker_capacity() > 0:
			out.append(household_id)
	return out

## Dwellings sit on a line by id; every business is far to the right.
func _line_lookup(kind: String, id: int) -> Vector2:
	return Vector2(FAR, 0.0) if kind == "business" else Vector2(float(id), 0.0)

func _unknown_lookup(_kind: String, _id: int) -> Vector2:
	return Vector2.INF

func _check_unset_and_unknown_positions_match() -> void:
	var plain := _fresh()
	plain._reconcile_employment()
	var unknown := _fresh()
	unknown.position_lookup = _unknown_lookup
	unknown._reconcile_employment()
	_assert(_employers(plain) == _employers(unknown), "Unknown positions hire exactly like no lookup")
	var hired := _hired_ids(plain)
	var leftover := _leftover_ids(plain)
	_assert(not hired.is_empty() and not leftover.is_empty(), "Fixture needs both hires and a leftover pool (hired %d, leftover %d)" % [hired.size(), leftover.size()])
	for h in hired:
		for l in leftover:
			_assert(h < l, "Without positions the lowest ids are hired first (hired %d, left %d)" % [h, l])

func _check_nearest_is_hired_first() -> void:
	var plain := _fresh()
	plain._reconcile_employment()
	var near := _fresh()
	near.position_lookup = _line_lookup
	near._reconcile_employment()
	_assert(_hired_ids(near).size() == _hired_ids(plain).size(), "Positions change who is hired, not how many")
	var hired := _hired_ids(near)
	var leftover := _leftover_ids(near)
	_assert(not hired.is_empty() and not leftover.is_empty(), "Fixture needs both hires and a leftover pool")
	for h in hired:
		var h_dwelling: int = (near.households[h] as HEHousehold).dwelling_id
		for l in leftover:
			var l_dwelling: int = (near.households[l] as HEHousehold).dwelling_id
			_assert(h_dwelling >= l_dwelling, "A nearer home is hired first (hired house %d, left house %d)" % [h_dwelling, l_dwelling])

## Equal distances fall back to the lowest household id, and a household with
## no house ranks after every housed one.
func _check_ties_and_unhoused() -> void:
	var tie := _fresh()
	tie.position_lookup = func(_kind: String, _id: int) -> Vector2: return Vector2.ZERO
	var plain := _fresh()
	plain._reconcile_employment()
	tie._reconcile_employment()
	_assert(_employers(plain) == _employers(tie), "Equal distances break ties by lowest household id")

	var homeless := _fresh()
	var ids := homeless.get_household_ids(SID)
	var unhoused_id: int = ids[ids.size() - 1] # the nearest home on the line, were it housed
	(homeless.households[unhoused_id] as HEHousehold).dwelling_id = -1
	homeless.position_lookup = _line_lookup
	# Housing reconcile would re-house the household; this check calls the
	# employment pass directly so the dwelling stays cleared.
	homeless._reconcile_employment()
	_assert(not _hired_ids(homeless).has(unhoused_id) or _leftover_ids(homeless).is_empty(), "An unhoused household is hired from the pool only after every housed one")
