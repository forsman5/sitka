extends SceneTree

## Sheep pen slot layout check (no scene needed). Run with:
##   godot --headless --path . --script res://scripts/sim/harness/check_sheep_pen.gd

const PenScript = preload("res://scripts/on_foot/sheep_pen.gd")

var _ok := true

func _initialize() -> void:
	_check_default_capacity()
	_check_growth_fits_flock()
	_check_slots_fill_interior_and_respect_spacing()
	_check_gate_leaf_clear()
	print("SHEEP PEN %s" % ("OK" if _ok else "FAILED"))
	quit(0 if _ok else 1)

func _assert(condition: bool, message: String) -> void:
	if not condition:
		_ok = false
		push_error("FAIL: " + message)

func _pen(wide: int = 4, deep: int = 3) -> Node3D:
	var pen: Node3D = PenScript.new()
	pen.segments_wide = wide
	pen.segments_deep = deep
	return pen

func _slots(pen: Node3D) -> Array:
	# Build the same list _ready would, without instancing fence models.
	var half_w: float = pen.segments_wide * PenScript.SEGMENT_LENGTH * 0.5
	var half_d: float = pen.segments_deep * PenScript.SEGMENT_LENGTH * 0.5
	pen._build_slots(half_w, half_d)
	return pen._slots

func _check_default_capacity() -> void:
	var cap: int = PenScript.capacity_for(4, 3)
	_assert(cap >= 25, "default pen should hold the default flock of 25, holds %d" % cap)

func _check_growth_fits_flock() -> void:
	for heads in [1, 10, 25, 60, 120]:
		var grow: int = PenScript.growth_for(heads, 4, 3)
		_assert(PenScript.capacity_for(4 + grow, 3 + grow) >= heads, "growth %d does not fit %d" % [grow, heads])
		if grow > 0:
			_assert(PenScript.capacity_for(3 + grow, 2 + grow) < heads, "growth %d is not minimal for %d" % [grow, heads])

func _check_slots_fill_interior_and_respect_spacing() -> void:
	var pen := _pen()
	var slots := _slots(pen)
	var half_w: float = 4 * PenScript.SEGMENT_LENGTH * 0.5
	var half_d: float = 3 * PenScript.SEGMENT_LENGTH * 0.5
	var interior := 0
	for i in slots.size():
		var p: Vector3 = slots[i]
		_assert(absf(p.x) <= half_w - PenScript.SLOT_INSET + 0.01 and absf(p.z) <= half_d - PenScript.SLOT_INSET + 0.01, "slot %d outside the fence inset" % i)
		if absf(p.x) < half_w - PenScript.SLOT_INSET - 0.1 and absf(p.z) < half_d - PenScript.SLOT_INSET - 0.1:
			interior += 1
		for j in range(i + 1, slots.size()):
			_assert(p.distance_to(slots[j]) >= PenScript.SLOT_SPACING - 0.01, "slots %d and %d overlap" % [i, j])
	_assert(interior > 0, "no interior slots: sheep only line the fence")
	# Back-first ordering: z never decreases through the list.
	for i in range(1, slots.size()):
		_assert(slots[i].z >= slots[i - 1].z - 0.001, "slot order is not back-row first at %d" % i)
	pen.free()

func _check_gate_leaf_clear() -> void:
	var pen := _pen()
	var slots := _slots(pen)
	var half_d: float = 3 * PenScript.SEGMENT_LENGTH * 0.5
	var hinge_x: float = PenScript._gate_hinge_x(4, 1)
	for p in slots:
		var in_leaf: bool = absf(p.x - hinge_x) < PenScript.GATE_CLEARANCE and p.z > half_d - PenScript.SEGMENT_LENGTH - PenScript.GATE_CLEARANCE
		_assert(not in_leaf, "slot at %s is inside the open gate leaf" % p)
	pen.free()
