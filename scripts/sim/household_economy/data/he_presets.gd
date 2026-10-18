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
##                 iron_mine, quarry, mill, bakery, charcoal_burner, toolsmith. Farm and Woodlot take
##                 the rest, split by farm_share. Ranches and the Butcher always
##                 exist and staff themselves.
##   farm_share    float   share of the remaining workers on the Farm (0..1)
##   housing       {houses, tenements}  seeded dwellings; `tenements` of the
##                 houses start already densified (HEHouse.DENSE_CAPACITY)
##   include       [type_key]  optional: keep only these businesses (plus the
##                 Government and Warehouse); absent keeps every default one
##   treasury_bonus float  gold added to the government's starting float
##   warehouse     {stock: {grain|timber|wool|stone: units}}  present = a Government
##                 Warehouse already stands, holding this stock (what a
##                 house/tenement build draws on); empty/absent = none
##
##   water         {wells, river_intakes}  optional: seeded water sources (the
##                 government services them from the warehouse's timber). Absent
##                 = none, so older specs load unchanged
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
		"warehouse": {"stock": {"timber": 150, "stone": 100}},
		"water": {"wells": 2},
	},
	"mining_village": {
		"format": FORMAT,
		"key": "mining_village",
		"label": "Mining village",
		"blurb": "30 households around an iron mine, quarry, bloomery and charcoal burner; ore leaves through the trader.",
		"settlement_name": "Mining Village",
		"households": 30,
		"crews": {"trader": 8, "bloomery": 8, "iron_mine": 10, "charcoal_burner": 2, "quarry": 4},
		"farm_share": 0.5,
		"housing": {"houses": 36, "tenements": 0},
		"treasury_bonus": 150.0,
		"warehouse": {"stock": {"timber": 300, "stone": 200}},
		"water": {"wells": 3},
	},
	"bakery_village": {
		"format": FORMAT,
		"key": "bakery_village",
		"label": "Bakery village",
		"blurb": "30 households with a mill and bakery: grain is milled, baked and eaten as bread; surplus leaves by the trader.",
		"settlement_name": "Bakery Village",
		"households": 30,
		"crews": {"trader": 8, "charcoal_burner": 2, "mill": 4, "bakery": 4},
		"farm_share": 0.6,
		"housing": {"houses": 36, "tenements": 0},
		"treasury_bonus": 150.0,
		"warehouse": {"stock": {"timber": 300, "stone": 100}},
		"water": {"wells": 3},
	},
	"large_village": {
		"format": FORMAT,
		"key": "large_village",
		"label": "Large village",
		"blurb": "48 households and a full set of trades, with housing already at what the street grid fits.",
		"settlement_name": "Large Village",
		"households": 48,
		"crews": {"trader": 10, "bloomery": 6, "iron_mine": 6, "charcoal_burner": 2, "toolsmith": 8, "quarry": 6},
		"farm_share": 0.6,
		"housing": {"houses": 56, "tenements": 0},
		"treasury_bonus": 400.0,
		"warehouse": {"stock": {"timber": 600, "stone": 400}},
		"water": {"wells": 5},
	},
}

## Display order on the setup page.
const ORDER := ["small_village", "mining_village", "bakery_village", "large_village"]
const DEFAULT_KEY := "small_village"

## Starting crews a Custom roster gives each trade it includes.
const CUSTOM_CREWS := {"trader": 8, "bloomery": 8, "iron_mine": 8, "charcoal_burner": 2, "toolsmith": 12, "quarry": 6, "mill": 4, "bakery": 4}
## Farm and Woodlot are the only food and fuel makers; a roster needs one.
const CUSTOM_REQUIRED_ANY := ["farm", "woodlot"]
const CUSTOM_MIN_HOUSEHOLDS := 10
const CUSTOM_MAX_HOUSEHOLDS := 50
## The town layout seats roughly this many houses before reporting them unplaced.
const CUSTOM_MAX_HOUSES := 100
const CUSTOM_MAX_GOLD := 5000
## People a seeded well supplies (HEScenarioSeeds.WELL_PEOPLE, kept equal by the water check); a Custom roster gets enough wells for its 4-person households.
const CUSTOM_PEOPLE_PER_WELL := 40

## The business type_keys a preset starts with: its crewed trades plus the
## ones every town gets (Farm, Woodlot, Trader, ranches, Butcher).
static func included_trades(spec: Dictionary) -> Array:
	var trades := ["farm", "woodlot", "trader", "cattle_ranch", "sheep_farm", "butcher"]
	for crew_key in spec.get("crews", {}):
		if int(spec["crews"][crew_key]) > 0 and not trades.has(crew_key):
			trades.append(crew_key)
	return trades

## A spec for a hand-picked roster: `included` is business type_keys. Staffed
## crews come from CUSTOM_CREWS; Farm and Woodlot split the rest (all of it to
## whichever is present). `options` overrides the household-scaled defaults:
## `houses` (plain houses), `tenements`, `treasury_bonus` (gold) and
## `farm_share` (used only when both Farm and Woodlot are included).
static func custom_spec(included: Array, households: int, options: Dictionary = {}) -> Dictionary:
	var crews: Dictionary = {}
	for trade in CUSTOM_CREWS:
		if included.has(trade):
			crews[trade] = CUSTOM_CREWS[trade]
	var share := float(options.get("farm_share", 0.5))
	if included.has("farm") and not included.has("woodlot"):
		share = 1.0
	elif included.has("woodlot") and not included.has("farm"):
		share = 0.0
	var sorted_include := included.duplicate()
	sorted_include.sort()
	var plain_houses := int(options.get("houses", ceili(households * 1.2)))
	var tenements := int(options.get("tenements", 0))
	return {
		"format": FORMAT,
		"key": "custom",
		"label": "Custom",
		"blurb": "A hand-picked roster.",
		"settlement_name": "Custom Village",
		"households": households,
		"crews": crews,
		"farm_share": share,
		"include": sorted_include,
		"housing": {"houses": plain_houses + tenements, "tenements": tenements},
		"treasury_bonus": float(options.get("treasury_bonus", 5.0 * households)),
		"warehouse": {"stock": {"timber": 7.5 * households, "stone": 5.0 * households}},
		"water": {"wells": ceili(households * 4.0 / CUSTOM_PEOPLE_PER_WELL)},
	}

## Whether a roster can be started: it needs a Farm or a Woodlot.
static func custom_roster_valid(included: Array) -> bool:
	for required in CUSTOM_REQUIRED_ANY:
		if included.has(required):
			return true
	return false

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
