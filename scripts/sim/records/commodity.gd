class_name Commodity
extends RefCounted

enum Type { GRAIN, CATTLE, SHEEP, WOOL, TIMBER, CHARCOAL, IRON, TOOLS, IRON_ORE }

const ALL: Array[Type] = [
	Type.GRAIN, Type.CATTLE, Type.SHEEP, Type.WOOL,
	Type.TIMBER, Type.CHARCOAL, Type.IRON, Type.TOOLS, Type.IRON_ORE,
]

## Single source of truth for per-good display data: every dashboard, tooltip
## and map legend reads names/icons/colors from here instead of hardcoding
## "Grain"/"Timber" strings. Tuning values (BASE_PRICE, per-person demand)
## deliberately stay in the sims -- Simulation and HESimulation tune them
## independently.
const ICON_DIR := "res://assets/icons/goods/"
const DATA: Dictionary = {
	Type.GRAIN: {"name": "Grain", "icon": "grain.svg", "color": Color("d9b44a")},
	Type.CATTLE: {"name": "Cattle", "icon": "cattle.svg", "color": Color("a9744f")},
	Type.SHEEP: {"name": "Sheep", "icon": "sheep.svg", "color": Color("e8e4d8")},
	Type.WOOL: {"name": "Wool", "icon": "wool.svg", "color": Color("cfc6b4")},
	Type.TIMBER: {"name": "Timber", "icon": "timber.svg", "color": Color("8b5a2b")},
	Type.CHARCOAL: {"name": "Charcoal", "icon": "charcoal.svg", "color": Color("4a4a52")},
	Type.IRON: {"name": "Iron", "icon": "iron_ingot.svg", "color": Color("9aa5b1")},
	Type.TOOLS: {"name": "Tools", "icon": "tools.svg", "color": Color("b58b5a")},
	Type.IRON_ORE: {"name": "Iron Ore", "icon": "iron_ore.svg", "color": Color("7b5e57")},
}

## Gold is the player's currency (GameState.player_gold), not a tradable
## Commodity.Type -- it has no market row -- but it shares the icon set.
const GOLD_ICON_PATH := ICON_DIR + "gold.svg"
const GOLD_COLOR := Color("f2c230")

static func name_of(t: Type) -> String:
	if DATA.has(t):
		return DATA[t]["name"]
	return "Unknown"

static func color_of(t: Type) -> Color:
	return DATA[t]["color"] if DATA.has(t) else Color.WHITE

static func icon_path_of(t: Type) -> String:
	return ICON_DIR + DATA[t]["icon"] if DATA.has(t) else ""

## Null when the icon file hasn't been imported (e.g. headless harness runs
## before the editor has scanned assets) so callers can fall back to text.
static func icon_of(t: Type) -> Texture2D:
	var path := icon_path_of(t)
	if path != "" and ResourceLoader.exists(path):
		return load(path) as Texture2D
	return null

static func gold_icon() -> Texture2D:
	if ResourceLoader.exists(GOLD_ICON_PATH):
		return load(GOLD_ICON_PATH) as Texture2D
	return null

## Reverse of name_of() for UI code that only has the display string
## (summary dictionaries are keyed by name). Returns -1 if unknown.
static func type_from_name(display_name: String) -> int:
	for t in ALL:
		if name_of(t) == display_name:
			return t
	return -1
