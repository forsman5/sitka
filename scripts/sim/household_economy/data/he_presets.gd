extends RefCounted

## Starting towns for the household economy: the three presets a player picks
## from. Each is a plain, JSON-able dictionary -- the save-game format for a new
## town -- so a preset, a saved start, and a hand-edited file are the same
## thing. HEScenarioSeeds.build_from_spec turns one into a world.
##
## Spec (format 1):
##   format        int     spec version, bumped on a breaking change
##   key, label    String  stable id / display name
##   blurb         String  one-line description for the setup page
##   settlement_name String
##   households    int     starting households (4 people each)
##   crews         {type_key: int}  starting workers: trader, bloomery,
##                 iron_mine, charcoal_burner, toolsmith. Farm and Woodlot take
##                 the rest, split by farm_share. Ranches and the Butcher always
##                 exist and staff themselves.
##   farm_share    float   share of the remaining workers on the Farm (0..1)
##   housing       {houses, tenements}  seeded dwellings; `tenements` of the
##                 houses start already densified (HEHouse.DENSE_CAPACITY)
##   treasury_bonus float  gold added to the government's starting float
##   warehouse     {stock: {grain|timber|wool: units}}  present = a Government
##                 Warehouse already stands, holding this stock (what a
##                 house/tenement build draws on); empty/absent = none
##
## Adding a field: read it in HEScenarioSeeds.build_from_spec with a default so
## older specs keep loading, and document it here.

const FORMAT := 1

const PRESETS := {
	"small_village": {
		"format": FORMAT,
		"key": "small_village",
		"label": "Small village",
		"blurb": "20 households farming and logging, one trader, a few spare houses.",
		"settlement_name": "Small Village",
		"households": 20,
		"crews": {"trader": 6},
		"farm_share": 0.55,
		"housing": {"houses": 24, "tenements": 0},
		"treasury_bonus": 250.0,
		"warehouse": {"stock": {"timber": 150}},
	},
	"mining_village": {
		"format": FORMAT,
		"key": "mining_village",
		"label": "Mining village",
		"blurb": "30 households around an iron mine, bloomery and charcoal burner; ore leaves through the trader.",
		"settlement_name": "Mining Village",
		"households": 30,
		"crews": {"trader": 8, "bloomery": 8, "iron_mine": 10, "charcoal_burner": 2},
		"farm_share": 0.5,
		"housing": {"houses": 36, "tenements": 0},
		"treasury_bonus": 150.0,
		"warehouse": {"stock": {"timber": 300}},
	},
	"large_village": {
		"format": FORMAT,
		"key": "large_village",
		"label": "Large village",
		"blurb": "48 households and a full set of trades, with housing already at what the street grid fits.",
		"settlement_name": "Large Village",
		"households": 48,
		"crews": {"trader": 10, "bloomery": 6, "iron_mine": 6, "charcoal_burner": 2, "toolsmith": 8},
		"farm_share": 0.6,
		"housing": {"houses": 56, "tenements": 0},
		"treasury_bonus": 400.0,
		"warehouse": {"stock": {"timber": 600}},
	},
}

## Display order on the setup page.
const ORDER := ["small_village", "mining_village", "large_village"]
const DEFAULT_KEY := "small_village"

static func keys() -> Array:
	return ORDER.duplicate()

## A copy of the spec for `key`, or {} if unknown.
static func spec(key: String) -> Dictionary:
	if not PRESETS.has(key):
		return {}
	return (PRESETS[key] as Dictionary).duplicate(true)

## Problems with a spec (empty when it can be built): the checks a loader runs
## before trusting a hand-edited or saved file.
static func validate(candidate: Dictionary) -> Array[String]:
	var problems: Array[String] = []
	if int(candidate.get("format", 0)) != FORMAT:
		problems.append("unsupported format %s" % str(candidate.get("format", "missing")))
	var households := int(candidate.get("households", 0))
	if households < 1:
		problems.append("households must be at least 1")
	var crews: Dictionary = candidate.get("crews", {})
	var crewed := 0
	for crew in crews.values():
		crewed += int(crew)
	if crewed > households * 2:
		problems.append("crews (%d workers) exceed the %d workers available" % [crewed, households * 2])
	var housing: Dictionary = candidate.get("housing", {})
	if housing.has("houses") and int(housing.get("tenements", 0)) > int(housing["houses"]):
		problems.append("more tenements than houses")
	var share := float(candidate.get("farm_share", 0.5))
	if share < 0.0 or share > 1.0:
		problems.append("farm_share must be 0..1")
	return problems
