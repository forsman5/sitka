class_name HEField
extends RefCounted

## One growing plot within a land-based PRODUCTION business (see
## he_business.gd's `fields`/`configure_land`) -- e.g. one of a Farm's
## 10-acre fields or a Woodlot's coppice stand. Grows silently for
## `growth_days` (the parent business's cycle length, read off the parent
## rather than duplicated here), then dumps its whole harvest into the
## parent's stock and replants immediately (see he_simulation.gd's
## _run_field_growth) -- no partial value trickles out while it's still
## growing, unlike the old one-recipe-tick-produces-output model this
## replaces for Farm/Woodlot.

var area: float
var days_growing: int

## Cumulative labor (worker-days) this field has received so far THIS
## cycle -- compared at harvest against area * labor_per_area_per_day *
## growth_days to determine how efficiently it was staffed (see
## he_simulation.gd's _run_field_growth's efficiency calc). Reset to 0.0
## alongside days_growing on every harvest/replant.
var labor_applied: float

func _init(p_area: float, p_days_growing: int = 0, p_labor_applied: float = 0.0) -> void:
	area = p_area
	days_growing = p_days_growing
	labor_applied = p_labor_applied
