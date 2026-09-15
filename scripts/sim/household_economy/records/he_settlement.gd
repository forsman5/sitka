class_name HESettlement
extends RefCounted

## Membership only. Derived summaries (population, totals) are computed on
## demand from the authoritative household records -- there is no
## authoritative duplicate inventory or population count here. See
## docs/household-economy-next-cut.md: "Settlement: membership and derived
## summaries. No authoritative duplicate inventory."

var id: int
var name: String
var household_ids: Array[int] = []
var business_ids: Array[int] = []

func _init(p_id: int, p_name: String) -> void:
	id = p_id
	name = p_name
