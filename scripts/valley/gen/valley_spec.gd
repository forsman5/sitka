extends RefCounted

## The input to the valley generator: what kind of landscape, which rivers, which
## settlements. The seed only supplies detail inside this shape. JSON-able
## (`to_dict` / `from_dict`) so a spec plus a seed can be a reviewed, approved
## record. See docs/valley-generation-sketch.md.

const LANDSCAPES := ["river_valley", "coast", "island"]
const SIDES := ["", "north", "south", "east", "west"]
const KNOWN_ROLES := ["town", "port", "ore", "woodland", "pasture", "farm", "fishing"]
const MAX_TRIBUTARIES := 2

var seed := 1
var landscape := "river_valley"
## A river crossing the landscape: valley floor, coast (ends at a river mouth),
## island (source in the hills, mouth on the shore).
var main_river := true
var tributaries := 1
## Scales hill and valley-wall height (1.0 = default).
var relief := 1.0
## Coast only: which side the sea is on; "" lets the seed choose.
var sea_side := ""
## [{role, count, optional}]. Optional roles are skipped silently when no site fits.
var settlements: Array = []

static func preset(landscape_name: String, seed_value: int) -> RefCounted:
	var spec: RefCounted = load("res://scripts/valley/gen/valley_spec.gd").new()
	spec.seed = seed_value
	spec.landscape = landscape_name
	match landscape_name:
		"coast":
			spec.main_river = true
			spec.tributaries = 1
			spec.settlements = [_s("town"), _s("port"), _s("fishing", 2, true), _s("pasture"), _s("woodland"), _s("farm", 1, true)]
		"island":
			spec.main_river = false
			spec.tributaries = 0
			spec.settlements = [_s("town"), _s("port"), _s("fishing", 1, true), _s("pasture"), _s("woodland"), _s("ore")]
		_:
			spec.landscape = "river_valley"
			spec.main_river = true
			spec.tributaries = 1
			spec.settlements = [_s("town"), _s("port"), _s("ore"), _s("woodland"), _s("pasture"), _s("farm", 1, true)]
	return spec

static func _s(role: String, count := 1, optional := false) -> Dictionary:
	return {"role": role, "count": count, "optional": optional}

## Role list with repeats expanded, in spec order.
func roster() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for entry in settlements:
		for i in int(entry.get("count", 1)):
			result.append({"role": str(entry["role"]), "optional": bool(entry.get("optional", false))})
	return result

func validate() -> PackedStringArray:
	var errors := PackedStringArray()
	if not LANDSCAPES.has(landscape):
		errors.append("Unknown landscape '%s'" % landscape)
	if tributaries < 0 or tributaries > MAX_TRIBUTARIES:
		errors.append("tributaries must be 0-%d" % MAX_TRIBUTARIES)
	if tributaries > 0 and not main_river:
		errors.append("tributaries need a main river")
	if landscape == "river_valley" and not main_river:
		errors.append("a river valley needs a main river")
	if relief < 0.3 or relief > 2.0:
		errors.append("relief must be 0.3-2.0")
	if not SIDES.has(sea_side):
		errors.append("sea_side must be one of north/south/east/west or empty")
	if settlements.is_empty():
		errors.append("settlements is empty")
	var total := 0
	for entry in settlements:
		if not entry is Dictionary or not KNOWN_ROLES.has(str(entry.get("role", ""))):
			errors.append("Unknown settlement role in %s" % [entry])
			continue
		total += int(entry.get("count", 1))
	if total > 10:
		errors.append("at most 10 settlements (got %d)" % total)
	return errors

func to_dict() -> Dictionary:
	return {
		"seed": seed, "landscape": landscape, "main_river": main_river, "tributaries": tributaries,
		"relief": relief, "sea_side": sea_side, "settlements": settlements.duplicate(true),
	}

func to_json() -> String:
	return JSON.stringify(to_dict(), "  ")

## Parses a saved spec. Returns {spec, errors}; spec is null when invalid.
static func from_json(text: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(text) != OK:
		return {"spec": null, "errors": PackedStringArray(["Invalid JSON: %s (line %d)" % [json.get_error_message(), json.get_error_line()]])}
	if not json.data is Dictionary:
		return {"spec": null, "errors": PackedStringArray(["Not a JSON object"])}
	var spec: RefCounted = from_dict(json.data)
	var errors: PackedStringArray = spec.validate()
	return {"spec": spec if errors.is_empty() else null, "errors": errors}

static func from_dict(data: Dictionary) -> RefCounted:
	var spec: RefCounted = preset(str(data.get("landscape", "river_valley")), int(data.get("seed", 1)))
	spec.main_river = bool(data.get("main_river", spec.main_river))
	spec.tributaries = int(data.get("tributaries", spec.tributaries))
	spec.relief = float(data.get("relief", spec.relief))
	spec.sea_side = str(data.get("sea_side", spec.sea_side))
	if data.has("settlements") and data["settlements"] is Array:
		spec.settlements = (data["settlements"] as Array).duplicate(true)
	return spec
