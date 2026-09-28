class_name Commodity
extends RefCounted

enum Type { GRAIN, CATTLE, SHEEP, WOOL, TIMBER, CHARCOAL, IRON, TOOLS, IRON_ORE }

const ALL: Array[Type] = [
	Type.GRAIN, Type.CATTLE, Type.SHEEP, Type.WOOL,
	Type.TIMBER, Type.CHARCOAL, Type.IRON, Type.TOOLS, Type.IRON_ORE,
]

static func name_of(t: Type) -> String:
	match t:
		Type.GRAIN: return "Grain"
		Type.CATTLE: return "Cattle"
		Type.SHEEP: return "Sheep"
		Type.WOOL: return "Wool"
		Type.TIMBER: return "Timber"
		Type.CHARCOAL: return "Charcoal"
		Type.IRON: return "Iron"
		Type.TOOLS: return "Tools"
		Type.IRON_ORE: return "Iron Ore"
	return "Unknown"
